// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";

import {ITransmuter} from "../interfaces/alchemix/ITransmuter.sol";
import {IAlchemistV3} from "../interfaces/alchemix/IAlchemistV3.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";

contract StrategyAprOracle is AprOracleBase {

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice WAD constant
    uint256 private constant _WAD = 1e18;

    /// @notice Max basis points
    uint256 private constant _MAX_BPS = 10_000;

    /// @notice Seconds in a year
    uint256 private constant _SECONDS_PER_YEAR = 365 days;

    /// @notice Mainnet block time
    uint256 private constant _BLOCK_TIME = 12 seconds;

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor() AprOracleBase("Automated Transmuter Strategy APR Oracle", msg.sender) {}

    // ===============================================================
    // View functions
    // ===============================================================

    /// @inheritdoc AprOracleBase
    /// @dev Each position accretes linearly from the price it was opened at to par minus
    /// the fee over its own cycle. Idle alAsset is assumed to open at the current floor. Idle
    /// `asset`, the auction lot, matured positions and MYT earn nothing. Gains are haircut
    /// on bad debt like `estimatedTotalAssets`. `_delta` is ignored, allocations are manual
    function aprAfterDebtChange(
        address _strategy,
        int256 /*_delta*/
    ) external view override returns (uint256) {
        IStrategyInterface _s = IStrategyInterface(_strategy);
        ITransmuter _transmuter = ITransmuter(_s.TRANSMUTER());

        // What one alAsset transmutes to, in `asset`
        uint256 _par = _WAD * (_MAX_BPS - _transmuter.transmutationFee()) / _MAX_BPS;

        // Yearly gain of each open position, in alAsset decimals. Accretion is
        // linear over the position's own cycle
        uint256 _gain;
        uint256 _count = _s.positionCount();
        for (uint256 _i; _i < _count; ++_i) {
            (uint128 _id, uint128 _price) = _s.positions(_i);
            ITransmuter.StakingPosition memory _position = _transmuter.getPosition(_id);
            if (_position.maturationBlock <= block.number || _price >= _par) continue;
            _gain += _position.amount * (_par - _price) / _WAD * _SECONDS_PER_YEAR
            / ((_position.maturationBlock - _position.startBlock) * _BLOCK_TIME);
        }

        // Plus idle alAsset, assumed to open at the current floor for the current cycle
        uint256 _floor = _WAD * _WAD / _s.minimumPrice();
        if (_floor < _par) {
            _gain += IERC20(_s.AL_ASSET()).balanceOf(_strategy) * (_par - _floor) / _WAD * _SECONDS_PER_YEAR
            / (_transmuter.timeToTransmute() * _BLOCK_TIME);
        }
        if (_gain == 0) return 0;

        // Bad debt haircut, mirroring the strategy's `_badDebtMultiplier()`
        IAlchemistV3 _alchemist = IAlchemistV3(_s.ALCHEMIST());
        uint256 _backing = _alchemist.getTotalLockedUnderlyingValue()
            + _alchemist.convertYieldTokensToUnderlying(IERC20(_s.MYT()).balanceOf(address(_transmuter)));
        if (_backing == 0) return 0;
        uint256 _ratio = Math.mulDiv(_alchemist.totalSyntheticsIssued(), _s.ASSET_UNIT(), _backing, Math.Rounding.Up);
        if (_ratio > _WAD) _gain = _gain * _WAD / _ratio;

        // To `asset` decimals
        _gain /= _s.AL_TO_ASSET_SCALER();

        // Relative to total assets
        uint256 _total = _s.estimatedTotalAssets();
        if (_total == 0) return 0;
        return _gain * _WAD / _total;
    }

}
