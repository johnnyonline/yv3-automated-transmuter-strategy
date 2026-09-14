// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";

import {ITransmuter} from "../interfaces/alchemix/ITransmuter.sol";
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
    /// the fee over one cycle. Idle alAsset is assumed to open at the current floor. Idle
    /// `asset`, the auction lot, matured positions and MYT earn nothing. `_delta` is
    /// ignored, allocations are manual
    function aprAfterDebtChange(
        address _strategy,
        int256 /*_delta*/
    ) external view override returns (uint256) {
        IStrategyInterface _s = IStrategyInterface(_strategy);
        ITransmuter _transmuter = ITransmuter(_s.TRANSMUTER());

        // What one alAsset transmutes to, in `asset`
        uint256 _par = _WAD * (_MAX_BPS - _transmuter.transmutationFee()) / _MAX_BPS;

        // Gain over a cycle for each open position, in alAsset decimals
        uint256 _gain;
        uint256 _count = _s.positionCount();
        for (uint256 _i; _i < _count; ++_i) {
            (uint128 _id, uint128 _price) = _s.positions(_i);
            ITransmuter.StakingPosition memory _position = _transmuter.getPosition(_id);
            if (_position.maturationBlock <= block.number || _price >= _par) continue;
            _gain += _position.amount * (_par - _price) / _WAD;
        }

        // Plus idle alAsset, assumed to open at the current floor
        uint256 _floor = _WAD * _WAD / _s.minimumPrice();
        if (_floor < _par) _gain += IERC20(_s.AL_ASSET()).balanceOf(_strategy) * (_par - _floor) / _WAD;
        if (_gain == 0) return 0;

        // Annualize over one cycle and scale to `asset` decimals
        _gain = _gain * _SECONDS_PER_YEAR / (_transmuter.timeToTransmute() * _BLOCK_TIME) / _s.AL_TO_ASSET_SCALER();

        // Relative to total assets
        uint256 _total = _s.estimatedTotalAssets();
        if (_total == 0) return 0;
        return _gain * _WAD / _total;
    }

}
