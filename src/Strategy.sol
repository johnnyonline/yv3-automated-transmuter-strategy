// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Auction} from "@periphery/Auctions/Auction.sol";

import {ITransmuter} from "./interfaces/alchemix/ITransmuter.sol";
import {IAlchemistV3} from "./interfaces/alchemix/IAlchemistV3.sol";
import {MYTLimitsLib, IVaultV2Like} from "./periphery/MYTLimitsLib.sol";

/// @notice Buys alAsset below peg by auctioning off idle `asset`, then redeems
/// it 1:1 through the Alchemix v3 Transmuter. The strategy IS its own Dutch
/// auction (want = alAsset, receiver = this), so `asset` never leaves the
/// contract while an auction runs and alAsset lands here directly on `take`.
/// Matured redemptions pay out in the alchemist's yield token (MYT), which is
/// unwrapped back to `asset` via ERC4626 redeem.
contract Strategy is BaseHealthCheck, Auction {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Active redemption NFT ids held by the strategy (the ladder).
    uint256[] public positionIds;

    /// @notice Cap on concurrent ladder positions. Caps gas and accounting surface.
    uint256 public maxPositions = 7;

    /// @notice Minimum idle alAsset before opening a new redemption position.
    uint256 public minRedemptionAmount;

    /// @notice Strategy-level deposit cap in `asset`. Deposits are blocked until set.
    uint256 public depositLimit;

    /// @notice Minimum idle `asset` before an auction can be kicked.
    uint256 public minAuctionAmount;

    /// @notice Maximum `asset` a single auction can offer. Kicks are blocked until set.
    uint256 public maxAuctionAmount;

    /// @notice Max base fee in gwei for keeper-driven `tend`. 0 = no cap.
    uint256 public maxTendBasefeeGwei = 30;

    // ===============================================================
    // Constants
    // ===============================================================

    ERC20 public immutable AL_ASSET;
    ITransmuter public immutable TRANSMUTER;
    IAlchemistV3 public immutable ALCHEMIST;
    ERC20 public immutable YIELD_TOKEN; // MYT (Morpho Vault V2)

    /// @dev Divides alAsset amounts down to `asset` decimals (1:1 value).
    uint256 public immutable AL_TO_ASSET_SCALER;

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor(
        address _asset,
        string memory _name,
        address _alAsset,
        address _transmuter,
        address _auctionGovernance,
        uint256 _auctionStartingPrice
    ) BaseHealthCheck(_asset, _name) {
        ITransmuter _t = ITransmuter(_transmuter);
        require(_t.syntheticToken() == _alAsset, "!alAsset");

        IAlchemistV3 _alchemist = IAlchemistV3(_t.alchemist());
        // Sanity: alchemist's underlying matches the strategy's asset.
        require(_alchemist.underlyingToken() == _asset, "!underlying");

        address _yieldToken = _alchemist.yieldToken();
        // Sanity: MYT unwraps directly to the strategy's asset.
        require(IERC4626(_yieldToken).asset() == _asset, "!yieldToken");

        AL_ASSET = ERC20(_alAsset);
        TRANSMUTER = _t;
        ALCHEMIST = _alchemist;
        YIELD_TOKEN = ERC20(_yieldToken);

        uint256 _alDecimals = ERC20(_alAsset).decimals();
        uint256 _assetDecimals = ERC20(_asset).decimals();
        require(_alDecimals >= _assetDecimals, "!decimals");
        AL_TO_ASSET_SCALER = 10 ** (_alDecimals - _assetDecimals);

        // The strategy is its own auction: sells `asset`, receives alAsset.
        // Governance must `enable(asset)` and `setMinimumPrice` before kicks work.
        initialize(_alAsset, address(this), _auctionGovernance, _auctionStartingPrice);

        // Approve transmuter to pull alAsset for createRedemption.
        ERC20(_alAsset).safeApprove(_transmuter, type(uint256).max);
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Estimated total assets held by the strategy.
    /// @dev Values alAsset (idle and locked) at 1:1 and MYT at the vault's rate.
    function estimatedTotalAssets() external view returns (uint256) {
        return _estimatedTotalAssets();
    }

    /// @notice Number of open redemption positions in the ladder.
    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        if (_totalAssets >= depositLimit) return 0;
        uint256 _limit = depositLimit - _totalAssets;

        // Don't accept more than the transmuter can absorb beyond what is
        // already queued here as idle asset and alAsset.
        uint256 _headroom = _transmuterHeadroom() / AL_TO_ASSET_SCALER;
        uint256 _queued = asset.balanceOf(address(this)) +
            AL_ASSET.balanceOf(address(this)) / AL_TO_ASSET_SCALER;
        if (_queued >= _headroom) return 0;

        return Math.min(_limit, _headroom - _queued);
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Only idle asset, excluding whatever a live auction has on offer.
        uint256 _idle = asset.balanceOf(address(this));
        uint256 _onAuction = available(address(asset));
        return _idle > _onAuction ? _idle - _onAuction : 0;
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Set the cap on concurrent redemption positions.
    function setMaxPositions(uint256 _maxPositions) external onlyManagement {
        require(_maxPositions != 0 && _maxPositions <= 32, "!range");
        maxPositions = _maxPositions;
    }

    /// @notice Set the minimum idle alAsset needed to open a new position.
    function setMinRedemptionAmount(uint256 _minRedemptionAmount) external onlyManagement {
        minRedemptionAmount = _minRedemptionAmount;
    }

    /// @notice Set the strategy-level deposit cap in `asset`.
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /// @notice Set the min idle `asset` to kick and the max a single auction can offer.
    function setAuctionAmounts(
        uint256 _minAuctionAmount,
        uint256 _maxAuctionAmount
    ) external onlyManagement {
        require(_minAuctionAmount <= _maxAuctionAmount, "!range");
        minAuctionAmount = _minAuctionAmount;
        maxAuctionAmount = _maxAuctionAmount;
    }

    /// @notice Set the max base fee in gwei for keeper tends. 0 = no cap.
    function setMaxTendBasefeeGwei(uint256 _maxTendBasefeeGwei) external onlyManagement {
        maxTendBasefeeGwei = _maxTendBasefeeGwei;
    }

    /// @notice Claim a redemption position by index regardless of maturity.
    /// @dev The transmuter applies its exitFee on immature claims. Only for
    /// emergencies; the normal path never force-claims.
    function manualClaimRedemption(uint256 _index) external onlyEmergencyAuthorized {
        TRANSMUTER.claimRedemption(positionIds[_index]);
        uint256 _last = positionIds.length - 1;
        if (_index != _last) positionIds[_index] = positionIds[_last];
        positionIds.pop();
    }

    /// @notice Manually redeem MYT shares for `asset`.
    function manualUnwrap(uint256 _shares) external onlyEmergencyAuthorized {
        IERC4626(address(YIELD_TOKEN)).redeem(_shares, address(this), address(this));
    }

    /// @notice Sweep stray tokens to management. Strategy funds are excluded.
    /// @dev Replaces the Auction sweep so auction governance cannot touch funds.
    function sweep(address _token) external override onlyManagement {
        require(_token != address(asset), "!asset");
        require(_token != address(AL_ASSET), "!alAsset");
        require(_token != address(YIELD_TOKEN), "!yieldToken");
        address _management = TokenizedStrategy.management();
        ERC20(_token).safeTransfer(_management, ERC20(_token).balanceOf(address(this)));
        emit AuctionSwept(_token, _management);
    }

    // ===============================================================
    // Auction functions
    // ===============================================================

    /// @notice Kick an auction selling idle `asset` for alAsset. Keeper-gated.
    function kick(
        address _from
    ) external override onlyKeepers nonReentrant returns (uint256) {
        return _kick(_from);
    }

    /// @dev Caps the offered amount and enforces the kick policy instead of
    /// auctioning the full balance like the base implementation.
    function _kick(address _from) internal override returns (uint256 _available) {
        require(_from == address(asset), "!asset");
        require(auctions[_from].scaler != 0, "not enabled");

        _available = _kickableAmount();
        require(_available != 0, "nothing to kick");

        auctions[_from].kicked = uint64(block.timestamp);
        auctions[_from].initialAvailable = uint128(_available);

        emit AuctionKicked(_from, _available);
    }

    /// @notice How much `asset` can currently be kicked into an auction.
    function kickable(address _from) external view override returns (uint256) {
        return _from == address(asset) ? _kickableAmount() : 0;
    }

    /// @notice Keeper trigger: whether to kick and the calldata to do it.
    function auctionTrigger(
        address _from
    ) external view returns (bool, bytes memory) {
        if (_from != address(asset)) return (false, bytes("!asset"));
        if (maxTendBasefeeGwei != 0 && block.basefee >= maxTendBasefeeGwei * 1e9) {
            return (false, bytes("basefee"));
        }
        if (_kickableAmount() == 0) return (false, bytes("0 kickable"));
        return (true, abi.encodeCall(this.kick, (_from)));
    }

    // ===============================================================
    // Internal mutated functions
    // ===============================================================

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 /*_amount*/) internal override {
        // Do nothing. Idle asset waits to be auctioned for alAsset.
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 /*_amount*/) internal override {
        // Withdrawals are limited to idle asset, so this is only a
        // best-effort top-up: claim matured positions and unwrap MYT.
        _claimAndUnwrap();
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256) {
        _claimAndUnwrap();
        if (!TokenizedStrategy.isShutdown()) _transmute();
        return _estimatedTotalAssets();
    }

    /// @inheritdoc BaseStrategy
    function _tend(uint256 /*_totalIdle*/) internal override {
        _claimAndUnwrap();
        if (TokenizedStrategy.isShutdown()) return;
        _transmute();
        if (_kickableAmount() != 0) _kick(address(asset));
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 /*_amount*/) internal override {
        // Claim matured positions and unwrap MYT. Immature positions are never
        // force-claimed here (exitFee); use manualClaimRedemption if needed.
        _claimAndUnwrap();
    }

    // ===============================================================
    // Position management
    // ===============================================================

    /// @dev Claim every matured position, then try to unwrap MYT to `asset`.
    function _claimAndUnwrap() internal {
        uint256 _i;
        while (_i < positionIds.length) {
            uint256 _id = positionIds[_i];
            if (TRANSMUTER.getPosition(_id).maturationBlock <= block.number) {
                // Pays out in MYT.
                TRANSMUTER.claimRedemption(_id);

                // Swap-and-pop; don't increment, the index now holds the tail.
                uint256 _last = positionIds.length - 1;
                if (_i != _last) positionIds[_i] = positionIds[_last];
                positionIds.pop();
                continue;
            }
            unchecked {
                ++_i;
            }
        }

        _unwrap();
    }

    /// @dev Redeem MYT for `asset`, sized by the vault's real liquidity since
    /// Morpho V2's maxRedeem always returns 0. Reverts are swallowed: the MYT
    /// stays idle for a later attempt and is priced into totalAssets meanwhile.
    function _unwrap() internal {
        uint256 _maxAssetsOut = _maxUnwrappable();
        if (_maxAssetsOut == 0) return;

        IERC4626 _vault = IERC4626(address(YIELD_TOKEN));
        uint256 _shares = Math.min(
            YIELD_TOKEN.balanceOf(address(this)),
            _vault.convertToShares(_maxAssetsOut)
        );
        if (_shares == 0) return;

        try _vault.redeem(_shares, address(this), address(this)) {} catch {}
    }

    /// @dev Stake idle alAsset into a new transmuter redemption position.
    function _transmute() internal {
        uint256 _amount = _transmutableAmount();
        if (_amount == 0) return;

        TRANSMUTER.createRedemption(_amount, address(this));

        // Transmuter is ERC721Enumerable; the fresh position is at the tail.
        positionIds.push(
            TRANSMUTER.tokenOfOwnerByIndex(
                address(this),
                TRANSMUTER.balanceOf(address(this)) - 1
            )
        );
    }

    // ===============================================================
    // Internal view functions
    // ===============================================================

    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0) return false;

        // Don't overpay gas.
        if (maxTendBasefeeGwei != 0 && block.basefee >= maxTendBasefeeGwei * 1e9) return false;

        // A matured position should be claimed immediately to reduce exposure.
        uint256 _length = positionIds.length;
        for (uint256 _i; _i < _length; ++_i) {
            if (TRANSMUTER.getPosition(positionIds[_i]).maturationBlock <= block.number) return true;
        }

        // MYT stuck from a previously failed unwrap has liquidity again.
        if (YIELD_TOKEN.balanceOf(address(this)) != 0 && _maxUnwrappable() != 0) return true;

        // Post shutdown we only claim and unwrap.
        if (TokenizedStrategy.isShutdown()) return false;

        // Idle alAsset ready to be transmuted.
        if (_transmutableAmount() != 0) return true;

        // Idle asset ready to be auctioned.
        return _kickableAmount() != 0;
    }

    function _estimatedTotalAssets() internal view returns (uint256) {
        // alAsset idle plus locked in the ladder, valued 1:1 with asset.
        uint256 _alAssets = AL_ASSET.balanceOf(address(this));
        uint256 _length = positionIds.length;
        for (uint256 _i; _i < _length; ++_i) {
            _alAssets += TRANSMUTER.getPosition(positionIds[_i]).amount;
        }

        return
            asset.balanceOf(address(this)) +
            _alAssets / AL_TO_ASSET_SCALER +
            IERC4626(address(YIELD_TOKEN)).convertToAssets(
                YIELD_TOKEN.balanceOf(address(this))
            );
    }

    /// @dev alAsset the transmuter can absorb: bounded by its deposit cap and
    /// by synthetics outstanding (can't redeem more than exists).
    function _transmuterHeadroom() internal view returns (uint256) {
        uint256 _locked = TRANSMUTER.totalLocked();
        uint256 _cap = TRANSMUTER.depositCap();
        uint256 _capLeft = _cap > _locked ? _cap - _locked : 0;
        uint256 _issued = ALCHEMIST.totalSyntheticsIssued();
        uint256 _issuedLeft = _issued > _locked ? _issued - _locked : 0;
        return Math.min(_capLeft, _issuedLeft);
    }

    /// @dev alAsset that would be staked if `_transmute` ran now. 0 if below
    /// the minimum or the ladder is full.
    function _transmutableAmount() internal view returns (uint256) {
        if (positionIds.length >= maxPositions) return 0;
        uint256 _amount = Math.min(AL_ASSET.balanceOf(address(this)), _transmuterHeadroom());
        if (_amount == 0 || _amount < minRedemptionAmount) return 0;
        return _amount;
    }

    /// @dev `asset` that would be offered if an auction were kicked now. 0
    /// unless the auction is enabled, configured with a price floor, idle and
    /// the transmuter side can absorb the proceeds.
    function _kickableAmount() internal view returns (uint256) {
        address _asset = address(asset);
        if (auctions[_asset].scaler == 0) return 0;
        // Never sell without a configured price floor.
        if (minimumPrice == 0) return 0;
        if (isActive(_asset)) return 0;
        if (TokenizedStrategy.isShutdown()) return 0;

        // The proceeds must fit in the ladder and transmuter.
        if (positionIds.length >= maxPositions) return 0;
        uint256 _headroom = _transmuterHeadroom();
        uint256 _queuedAl = AL_ASSET.balanceOf(address(this));
        if (_headroom <= _queuedAl) return 0;
        uint256 _absorbable = _headroom - _queuedAl;
        if (_absorbable < minRedemptionAmount) return 0;

        uint256 _amount = Math.min(
            asset.balanceOf(address(this)),
            Math.min(maxAuctionAmount, _absorbable / AL_TO_ASSET_SCALER)
        );
        if (_amount == 0 || _amount < minAuctionAmount) return 0;
        return _amount;
    }

    /// @dev `asset` the MYT vault can actually pay out right now for our
    /// balance. Sized via idle vault liquidity plus its liquidity adapter.
    function _maxUnwrappable() internal view returns (uint256) {
        uint256 _balance = YIELD_TOKEN.balanceOf(address(this));
        if (_balance == 0) return 0;
        return
            MYTLimitsLib.availableWithdrawLimit(
                IVaultV2Like(address(YIELD_TOKEN)),
                address(this),
                IERC4626(address(YIELD_TOKEN)).convertToAssets(_balance)
            );
    }

    // ===============================================================
    // ERC721 receiver
    // ===============================================================

    /// @notice Accept transmuter position NFTs in case it safe-mints.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
