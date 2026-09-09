// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Auction} from "@periphery/Auctions/Auction.sol";
import {AuctionFactory} from "@periphery/Auctions/AuctionFactory.sol";

import {ITransmuter} from "./interfaces/alchemix/ITransmuter.sol";
import {IAlchemistV3} from "./interfaces/alchemix/IAlchemistV3.sol";
import {MYTLimitsLib, IVaultV2Like} from "./periphery/MYTLimitsLib.sol";

/// @notice Buys alAsset below peg by auctioning off idle `asset`, then redeems
/// it 1:1 through the Alchemix v3 Transmuter. Both Dutch auctions (asset to
/// alAsset, and the emergency way back) are Yearn Auction clones governed by
/// this strategy: only it can kick them, it prices each lot, and proceeds are
/// paid straight back here. Matured redemptions pay out in the alchemist's
/// yield token (MYT, a Morpho Vault V2), which is withdrawn back to `asset`.
contract Strategy is BaseHealthCheck {

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

    /// @notice Seconds after kicking an auction that wasn't fully taken before
    /// another can be kicked. Bounds keeper gas when alAsset is at peg.
    uint256 public kickCooldown = 1 days;

    /// @notice Opening asset auction price in alAsset per `asset`, scaled 1e18
    /// (1.05e18 = 1.05 alAsset per asset). Decays toward the auction's floor.
    uint256 public startingPricePerUnit;

    // ===============================================================
    // Constants
    // ===============================================================

    ERC20 public immutable AL_ASSET;
    ITransmuter public immutable TRANSMUTER;
    IAlchemistV3 public immutable ALCHEMIST;
    ERC20 public immutable MYT; // Alchemix yield token, a Morpho Vault V2

    /// @notice Auction selling `asset` for alAsset. Kicked by keepers via
    /// `kickAuction`; alAsset is paid back here on every take.
    Auction public immutable ASSET_AUCTION;

    /// @notice Auction selling alAsset for `asset`: the only exit for alAsset
    /// besides transmuting. Kicked via `kickAlAssetAuction`; proceeds return here.
    Auction public immutable AL_ASSET_AUCTION;

    /// @dev Divides alAsset amounts down to `asset` decimals (1:1 value).
    uint256 public immutable AL_TO_ASSET_SCALER;

    /// @dev One whole unit of `asset`, used for the bad-debt ratio math.
    uint256 public immutable ASSET_UNIT;

    /// @dev Yearn AuctionFactory v1.0.4, deploys both auctions.
    address internal constant AUCTION_FACTORY = 0xbA7FCb508c7195eE5AE823F37eE2c11D7ED52F8e;

    uint256 internal constant WAD = 1e18;

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor(
        address _asset,
        string memory _name,
        address _alAsset,
        address _transmuter,
        uint256 _startingPricePerUnit
    ) BaseHealthCheck(_asset, _name) {
        ITransmuter _t = ITransmuter(_transmuter);
        require(_t.syntheticToken() == _alAsset, "!alAsset");

        IAlchemistV3 _alchemist = IAlchemistV3(_t.alchemist());
        // Sanity: alchemist's underlying matches the strategy's asset.
        require(_alchemist.underlyingToken() == _asset, "!underlying");

        address _myt = _alchemist.myt();
        // Sanity: MYT withdraws directly to the strategy's asset.
        require(IERC4626(_myt).asset() == _asset, "!myt");

        AL_ASSET = ERC20(_alAsset);
        TRANSMUTER = _t;
        ALCHEMIST = _alchemist;
        MYT = ERC20(_myt);

        uint256 _alDecimals = ERC20(_alAsset).decimals();
        uint256 _assetDecimals = ERC20(_asset).decimals();
        require(_alDecimals >= _assetDecimals, "!decimals");
        AL_TO_ASSET_SCALER = 10 ** (_alDecimals - _assetDecimals);
        ASSET_UNIT = 10 ** _assetDecimals;

        // Forward: sells `asset`, receives alAsset. Management must
        // `setAssetAuctionMinimumPrice` before kicks work.
        ASSET_AUCTION = _deployAuction(_alAsset, _asset);

        // The way back: sells alAsset for `asset`. Emergency use only.
        AL_ASSET_AUCTION = _deployAuction(_asset, _alAsset);

        // The auctions' `startingPrice` is the whole lot's want value in
        // whole tokens; it is recomputed on every kick from this per-unit price.
        startingPricePerUnit = _startingPricePerUnit;

        // Approve transmuter to pull alAsset for createRedemption.
        ERC20(_alAsset).safeApprove(_transmuter, type(uint256).max);
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Estimated total assets held by the strategy.
    /// @dev Untransmuted alAsset is carried at the most the asset auction
    /// would pay for it and accretes to par as it transmutes; all alAsset
    /// value is scaled down if the alchemist has bad debt. MYT is valued at
    /// the vault's rate.
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
        // already queued as idle or auctioned asset and idle alAsset.
        uint256 _headroom = _transmuterHeadroom() / AL_TO_ASSET_SCALER;
        uint256 _queued = asset.balanceOf(address(this)) +
            asset.balanceOf(address(ASSET_AUCTION)) +
            AL_ASSET.balanceOf(address(this)) / AL_TO_ASSET_SCALER;
        if (_queued >= _headroom) return 0;

        return Math.min(_limit, _headroom - _queued);
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Asset here plus an unsold lot left in an ended auction (swept back
        // in `_freeFunds`). A live auction's lot is not withdrawable.
        uint256 _limit = asset.balanceOf(address(this)) + _idleInAuction();

        // Beyond that: matured positions (claimable at full value, no exitFee)
        // and MYT already held. Immature positions are never force-claimed
        // for a withdrawal, that is management's call via manualClaimPosition.
        // Matured value is counted gross of transmutationFee, which comes out
        // of what's freed and lands on the withdrawer as loss (maxLoss opt-in).
        uint256 _maturedAl;
        uint256 _length = positionIds.length;
        for (uint256 _i; _i < _length; ++_i) {
            ITransmuter.StakingPosition memory _position = TRANSMUTER.getPosition(positionIds[_i]);
            if (_position.maturationBlock <= block.number) _maturedAl += _position.amount;
        }
        _maturedAl = _maturedAl * _badDebtMultiplier() / WAD;

        // Bounded by the MYT vault's real liquidity.
        uint256 _claimable = _maturedAl / AL_TO_ASSET_SCALER +
            IERC4626(address(MYT)).convertToAssets(MYT.balanceOf(address(this)));
        _claimable = MYTLimitsLib.availableWithdrawLimit(
            IVaultV2Like(address(MYT)),
            address(this),
            _claimable
        );

        return _limit + _claimable;
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

    /// @notice Set the cooldown after a not-fully-taken auction. Must cover
    /// the auction length so at most one auction runs per cooldown.
    function setKickCooldown(uint256 _kickCooldown) external onlyManagement {
        require(_kickCooldown >= ASSET_AUCTION.auctionLength(), "!cooldown");
        kickCooldown = _kickCooldown;
    }

    /// @notice Set the opening asset auction price in alAsset per `asset`, scaled 1e18.
    /// @dev Takes effect from the next kick; a live auction keeps its price.
    function setStartingPricePerUnit(uint256 _startingPricePerUnit) external onlyManagement {
        require(_startingPricePerUnit != 0, "!price");
        startingPricePerUnit = _startingPricePerUnit;
    }

    /// @notice Set the asset auction's price floor in alAsset per `asset`,
    /// scaled 1e18. Also sets the price untransmuted alAsset is carried at.
    function setAssetAuctionMinimumPrice(uint256 _minimumPrice) external onlyManagement {
        ASSET_AUCTION.setMinimumPrice(_minimumPrice);
    }

    /// @notice Set the asset auction's decay: bps per step and step length.
    function setAssetAuctionSteps(uint256 _stepDecayRate, uint256 _stepDuration) external onlyManagement {
        ASSET_AUCTION.setStepDecayRate(_stepDecayRate);
        ASSET_AUCTION.setStepDuration(_stepDuration);
    }

    /// @notice Claim a position by index regardless of maturity.
    /// @dev The transmuter applies its exitFee on immature claims. Only for
    /// emergencies; the normal path never force-claims.
    function manualClaimPosition(uint256 _index) external onlyEmergencyAuthorized {
        TRANSMUTER.claimRedemption(positionIds[_index]);
        uint256 _last = positionIds.length - 1;
        if (_index != _last) positionIds[_index] = positionIds[_last];
        positionIds.pop();
    }

    /// @notice Withdraw `asset` from the MYT vault for `_shares` of MYT.
    function manualWithdrawFromMytVault(uint256 _shares) external onlyEmergencyAuthorized {
        IERC4626(address(MYT)).redeem(_shares, address(this), address(this));
    }

    /// @notice Kick the alAsset auction, selling `_amount` of idle alAsset for `asset`.
    /// @dev Prices are `asset` per alAsset scaled 1e18; the auction decays
    /// from `_startingPricePerUnit` and never sells below `_minimumPrice`.
    /// Reverts while a previous alAsset auction is still live.
    function kickAlAssetAuction(
        uint256 _amount,
        uint256 _startingPricePerUnit,
        uint256 _minimumPrice
    ) external onlyEmergencyAuthorized {
        require(_minimumPrice != 0 && _startingPricePerUnit > _minimumPrice, "!price");
        AL_ASSET_AUCTION.setMinimumPrice(_minimumPrice);
        _kickAuction(AL_ASSET_AUCTION, AL_ASSET, _amount, _startingPricePerUnit);
    }

    /// @notice Pull `asset` back from the asset auction, ending it if live.
    function sweepAssetAuction() external onlyEmergencyAuthorized {
        _sweepAndSettleAuction(ASSET_AUCTION, address(asset));
    }

    /// @notice Pull alAsset back from the alAsset auction, ending it if live.
    function sweepAlAssetAuction() external onlyEmergencyAuthorized {
        _sweepAndSettleAuction(AL_ASSET_AUCTION, address(AL_ASSET));
    }

    /// @notice Sweep stray tokens to management. Strategy funds are excluded.
    function sweep(address _token) external onlyManagement {
        require(_token != address(asset), "!asset");
        require(_token != address(AL_ASSET), "!alAsset");
        require(_token != address(MYT), "!myt");
        ERC20(_token).safeTransfer(
            TokenizedStrategy.management(),
            ERC20(_token).balanceOf(address(this))
        );
    }

    // ===============================================================
    // Auction functions
    // ===============================================================

    /// @notice Kick the asset auction, selling idle `asset` for alAsset.
    function kickAuction(address _from) external onlyKeepers returns (uint256 _available) {
        require(_from == address(asset), "!asset");

        // An unsold lot from an ended auction rejoins idle first, so the size
        // cap applies to the whole new lot.
        _sweepIdleInAuction();

        _available = _kickableAmount();
        require(_available != 0, "nothing to kick");

        _kickAuction(ASSET_AUCTION, asset, _available, startingPricePerUnit);
    }

    /// @notice How much `asset` can currently be kicked into an auction.
    function kickable(address _from) external view returns (uint256) {
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
        return (true, abi.encodeCall(this.kickAuction, (_from)));
    }

    /// @dev Deploy an auction selling `_from` for `_want`, paid to this
    /// strategy. Governed by this strategy: only it can kick, and it prices
    /// each lot.
    function _deployAuction(address _want, address _from) internal returns (Auction _auction) {
        _auction = Auction(
            AuctionFactory(AUCTION_FACTORY).createNewAuction(_want, address(this), address(this))
        );
        _auction.enable(_from);
        _auction.setGovernanceOnlyKick(true);

        // Small, slow steps: ~4.7% decay per day so a normal start-to-floor
        // range is covered within the auction length. The defaults (0.5% per
        // minute) would cross the floor and end the auction within minutes.
        _auction.setStepDecayRate(1);
        _auction.setStepDuration(3 minutes);
    }

    /// @dev Price a lot, fund the auction and kick it. The auction's
    /// `startingPrice` is the whole lot in whole tokens, derived here from a
    /// per-unit price and rounded up so the opening price is never below it.
    function _kickAuction(
        Auction _auction,
        ERC20 _token,
        uint256 _amount,
        uint256 _startingPricePerUnit
    ) internal {
        (, uint64 _scaler, ) = _auction.auctions(address(_token));
        _auction.setStartingPrice(
            Math.mulDiv(_startingPricePerUnit, _amount * _scaler, 1e36, Math.Rounding.Up)
        );
        _token.safeTransfer(address(_auction), _amount);
        _auction.kick(address(_token));
    }

    /// @dev Bring an unsold `asset` lot back from the asset auction once it
    /// has ended. Never touches a live auction.
    function _sweepIdleInAuction() internal {
        if (_idleInAuction() != 0) ASSET_AUCTION.sweep(address(asset));
    }

    /// @dev Pull `_token` back from an auction and, if it is still live, end
    /// it so it can be kicked again.
    function _sweepAndSettleAuction(Auction _auction, address _token) internal {
        _auction.sweep(_token);
        if (_auction.isActive(_token)) _auction.settle(_token);
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
        // Immature positions are never force-claimed for a withdrawal: the
        // exitFee and the restarted maturation would fall on the remaining
        // depositors.
        _sweepIdleInAuction();
        _claimMaturedPositions();
        _withdrawFromMytVault();
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256) {
        _sweepIdleInAuction();
        _claimMaturedPositions();
        _withdrawFromMytVault();

        // Transmuting keeps running after shutdown: it is how alAsset gets
        // back to asset. Only buying more alAsset (kicking) stops.
        _transmute();

        return _estimatedTotalAssets();
    }

    /// @inheritdoc BaseStrategy
    function _tend(uint256 /*_totalIdle*/) internal override {
        _sweepIdleInAuction();
        _claimMaturedPositions();
        _withdrawFromMytVault();
        _transmute();
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 /*_amount*/) internal override {
        // Immature positions are never force-claimed here (exitFee); use
        // manualClaimPosition if needed.
        _sweepIdleInAuction();
        _claimMaturedPositions();
        _withdrawFromMytVault();
    }

    // ===============================================================
    // Position management
    // ===============================================================

    /// @dev Claim every matured position. Pays out in MYT.
    function _claimMaturedPositions() internal {
        uint256 _i;
        while (_i < positionIds.length) {
            uint256 _id = positionIds[_i];
            if (TRANSMUTER.getPosition(_id).maturationBlock <= block.number) {
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
    }

    /// @dev Withdraw `asset` from the MYT vault for the MYT held, sized by the
    /// vault's real liquidity since Morpho V2's maxRedeem always returns 0.
    /// Reverts are swallowed: the MYT stays here for a later attempt and is
    /// priced into totalAssets meanwhile.
    function _withdrawFromMytVault() internal {
        uint256 _maxAssets = _maxWithdrawableFromMytVault();
        if (_maxAssets == 0) return;

        IERC4626 _vault = IERC4626(address(MYT));
        uint256 _shares = Math.min(
            MYT.balanceOf(address(this)),
            _vault.convertToShares(_maxAssets)
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

        // MYT stuck from a previously failed withdrawal has liquidity again.
        if (MYT.balanceOf(address(this)) != 0 && _maxWithdrawableFromMytVault() != 0) return true;

        // Idle alAsset ready to be transmuted (also post shutdown). Auctions
        // are kicked through `auctionTrigger`/`kickAuction`, not tend.
        return _transmutableAmount() != 0;
    }

    function _estimatedTotalAssets() internal view returns (uint256) {
        uint256 _alAssetPrice = _maxAssetPerAlAsset();
        uint256 _transmutationFee = TRANSMUTER.transmutationFee();

        // Idle alAsset, here or in the alAsset auction, is carried at the most
        // the asset auction would pay for it until transmuted or sold.
        uint256 _alValue = (
            AL_ASSET.balanceOf(address(this)) + AL_ASSET.balanceOf(address(AL_ASSET_AUCTION))
        ) * _alAssetPrice / WAD;

        // Positions accrete linearly from that price to par (net of
        // transmutationFee) as they transmute, so profit is booked over the
        // position's life instead of all at once.
        uint256 _length = positionIds.length;
        for (uint256 _i; _i < _length; ++_i) {
            ITransmuter.StakingPosition memory _position = TRANSMUTER.getPosition(positionIds[_i]);
            uint256 _untransmuted = _untransmutedAmount(_position);
            _alValue +=
                (_position.amount - _untransmuted) * (MAX_BPS - _transmutationFee) / MAX_BPS +
                _untransmuted * _alAssetPrice / WAD;
        }

        // Scale all alAsset value down if the alchemist has bad debt.
        _alValue = _alValue * _badDebtMultiplier() / WAD;

        return
            asset.balanceOf(address(this)) +
            asset.balanceOf(address(ASSET_AUCTION)) +
            _alValue / AL_TO_ASSET_SCALER +
            IERC4626(address(MYT)).convertToAssets(MYT.balanceOf(address(this)));
    }

    /// @dev The most `asset` the asset auction would pay per alAsset, scaled
    /// 1e18: the inverse of its price floor. Untransmuted alAsset is carried
    /// at this price so buying it never books instant profit. Par if no floor
    /// is set.
    function _maxAssetPerAlAsset() internal view returns (uint256) {
        uint256 _minimumPrice = ASSET_AUCTION.minimumPrice();
        return _minimumPrice > WAD ? WAD * WAD / _minimumPrice : WAD;
    }

    /// @dev Mirrors the transmuter's `badDebtRatio`: a 1e18 multiplier that
    /// drops below 1e18 when synthetics issued exceed the underlying value
    /// backing them, in which case the transmuter scales claims down by the
    /// same ratio.
    function _badDebtMultiplier() internal view returns (uint256) {
        uint256 _backing = ALCHEMIST.getTotalLockedUnderlyingValue() +
            ALCHEMIST.convertYieldTokensToUnderlying(MYT.balanceOf(address(TRANSMUTER)));
        if (_backing == 0) return 0;
        uint256 _ratio = Math.mulDiv(
            ALCHEMIST.totalSyntheticsIssued(),
            ASSET_UNIT,
            _backing,
            Math.Rounding.Up
        );
        return _ratio > WAD ? Math.mulDiv(WAD, WAD, _ratio) : WAD;
    }

    /// @dev How much of a position has not transmuted yet, using the
    /// transmuter's own linear-in-blocks math (rounded up like it does).
    function _untransmutedAmount(
        ITransmuter.StakingPosition memory _position
    ) internal view returns (uint256) {
        uint256 _blocksLeft =
            _position.maturationBlock > block.number ? _position.maturationBlock - block.number : 0;
        if (_blocksLeft == 0) return 0;
        return
            Math.mulDiv(
                _position.amount,
                _blocksLeft,
                _position.maturationBlock - _position.startBlock,
                Math.Rounding.Up
            );
    }

    /// @dev alAsset the transmuter can absorb: bounded by its deposit cap
    /// (checked against active locked, matured positions can be poked out)
    /// and by synthetics outstanding (can't redeem more than exists).
    function _transmuterHeadroom() internal view returns (uint256) {
        uint256 _activeLocked = TRANSMUTER.totalActiveLocked();
        uint256 _cap = TRANSMUTER.depositCap();
        uint256 _capLeft = _cap > _activeLocked ? _cap - _activeLocked : 0;
        uint256 _locked = TRANSMUTER.totalLocked();
        uint256 _issued = ALCHEMIST.totalSyntheticsIssued();
        uint256 _issuedLeft = _issued > _locked ? _issued - _locked : 0;
        return Math.min(_capLeft, _issuedLeft);
    }

    /// @dev alAsset that would be staked if `_transmute` ran now. 0 if below
    /// the minimum, the ladder is full, or an auction is still live: takers
    /// fill in pieces, so wait for the whole fill and stake it as one
    /// position instead of fragmenting the ladder.
    function _transmutableAmount() internal view returns (uint256) {
        if (positionIds.length >= maxPositions) return 0;
        if (ASSET_AUCTION.isActive(address(asset))) return 0;
        uint256 _amount = Math.min(AL_ASSET.balanceOf(address(this)), _transmuterHeadroom());
        if (_amount == 0 || _amount < minRedemptionAmount) return 0;
        return _amount;
    }

    /// @dev `asset` that would be offered if an auction were kicked now. 0
    /// unless the auction has a price floor, is idle, and the transmuter side
    /// can absorb the proceeds.
    function _kickableAmount() internal view returns (uint256) {
        address _asset = address(asset);
        Auction _auction = ASSET_AUCTION;

        // Never sell without a price floor, and the ramp must start above it.
        uint256 _minimumPrice = _auction.minimumPrice();
        if (_minimumPrice == 0 || startingPricePerUnit <= _minimumPrice) return 0;
        if (_auction.isActive(_asset)) return 0;
        if (TokenizedStrategy.isShutdown()) return 0;

        // Back off after an auction that wasn't fully taken. `kicked` is
        // reset on a full take, so a filled auction can be re-kicked at once.
        (uint64 _kicked, , ) = _auction.auctions(_asset);
        if (_kicked != 0 && block.timestamp < _kicked + kickCooldown) return 0;

        // The proceeds must fit in the ladder and transmuter.
        if (positionIds.length >= maxPositions) return 0;
        uint256 _headroom = _transmuterHeadroom();
        uint256 _queuedAl = AL_ASSET.balanceOf(address(this));
        if (_headroom <= _queuedAl) return 0;
        uint256 _absorbable = _headroom - _queuedAl;
        if (_absorbable < minRedemptionAmount) return 0;

        uint256 _amount = Math.min(
            asset.balanceOf(address(this)) + _idleInAuction(),
            Math.min(maxAuctionAmount, _absorbable / AL_TO_ASSET_SCALER)
        );
        if (_amount == 0 || _amount < minAuctionAmount) return 0;
        return _amount;
    }

    /// @dev Unsold `asset` sitting in the asset auction after it ended. 0
    /// while an auction is live, since that lot is still for sale.
    function _idleInAuction() internal view returns (uint256) {
        Auction _auction = ASSET_AUCTION;
        if (_auction.isActive(address(asset))) return 0;
        return asset.balanceOf(address(_auction));
    }

    /// @dev `asset` the MYT vault can pay out right now for the MYT held,
    /// sized via idle vault liquidity plus its liquidity adapter.
    function _maxWithdrawableFromMytVault() internal view returns (uint256) {
        uint256 _balance = MYT.balanceOf(address(this));
        if (_balance == 0) return 0;
        return
            MYTLimitsLib.availableWithdrawLimit(
                IVaultV2Like(address(MYT)),
                address(this),
                IERC4626(address(MYT)).convertToAssets(_balance)
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
