// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Auction} from "@periphery/Auctions/Auction.sol";
import {AuctionFactory} from "@periphery/Auctions/AuctionFactory.sol";

import {ITransmuter} from "./interfaces/alchemix/ITransmuter.sol";
import {IAlchemistV3} from "./interfaces/alchemix/IAlchemistV3.sol";
import {MYTLimitsLib, IMYT} from "./periphery/MYTLimitsLib.sol";

/// @notice Buys alAsset below peg by auctioning off idle `asset`, then redeems
/// it 1:1 through the Alchemix v3 Transmuter. Both Dutch auctions (asset to
/// alAsset, and the emergency way back) are Yearn Auction clones governed by
/// this strategy: only it can kick them, it prices each lot, and proceeds are
/// paid straight back here. Matured redemptions pay out in the alchemist's
/// yield token (MYT, a Morpho Vault V2), which is withdrawn back to `asset`.
contract Strategy is BaseHealthCheck {

    using SafeERC20 for ERC20;
    using MYTLimitsLib for IMYT;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Active redemption NFT ids held by the strategy (the ladder).
    uint256[] public positionIds;

    /// @notice Cap on concurrent ladder positions. Caps gas and accounting surface.
    uint256 public maxPositions = 7;

    /// @notice Minimum idle alAsset before opening a new redemption position.
    uint256 public minRedemptionAmount;

    /// @notice Minimum idle `asset` before an auction can be kicked.
    uint256 public minAuctionAmount;

    /// @notice Maximum `asset` a single auction can offer. Kicks are blocked until set.
    uint256 public maxAuctionAmount;

    /// @notice Max base fee (wei) for keeper tends and kicks.
    uint256 public maxTendBasefee = 30 gwei;

    /// @notice Seconds after kicking an auction that wasn't fully taken before
    /// another can be kicked. Bounds keeper gas when alAsset is at peg.
    uint256 public kickCooldown = 1 days;

    /// @notice Opening asset auction price in alAsset per `asset`, scaled 1e18
    /// (1.05e18 = 1.05 alAsset per asset). Decays toward `minimumPrice`.
    uint256 public startingPricePerUnit = 1.15e18;

    /// @notice Asset auction price floor in alAsset per `asset`, scaled 1e18.
    /// Also the price untransmuted alAsset is valued at, so keep it close to
    /// the starting price: fills above it book the extra at fill.
    uint256 public minimumPrice = 1.1e18;

    // ===============================================================
    // Constants
    // ===============================================================

    ERC20 public immutable AL_ASSET;
    ITransmuter public immutable TRANSMUTER;
    IAlchemistV3 public immutable ALCHEMIST;
    IMYT public immutable MYT; // Alchemix yield token, a Morpho Vault V2

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

    /// @dev Redeemable MYT worth less `asset` than this is not worth a tend.
    uint256 internal constant DUST_AMOUNT = 1e6;

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor(
        address _asset,
        string memory _name,
        address _alAsset,
        address _transmuter
    ) BaseHealthCheck(_asset, _name) {
        ITransmuter _t = ITransmuter(_transmuter);
        require(_t.syntheticToken() == _alAsset, "!alAsset");

        IAlchemistV3 _alchemist = IAlchemistV3(_t.alchemist());
        // Sanity: alchemist's underlying matches the strategy's asset.
        require(_alchemist.underlyingToken() == _asset, "!underlying");

        IMYT _myt = IMYT(_alchemist.myt());
        // Sanity: MYT withdraws directly to the strategy's asset.
        require(_myt.asset() == _asset, "!myt");

        AL_ASSET = ERC20(_alAsset);
        TRANSMUTER = _t;
        ALCHEMIST = _alchemist;
        MYT = _myt;

        uint256 _alDecimals = ERC20(_alAsset).decimals();
        uint256 _assetDecimals = ERC20(_asset).decimals();
        require(_alDecimals >= _assetDecimals, "!decimals");
        AL_TO_ASSET_SCALER = 10 ** (_alDecimals - _assetDecimals);
        ASSET_UNIT = 10 ** _assetDecimals;

        // Both auctions pay this strategy and are governed by it: only it can
        // kick them, and it prices each lot. Small, slow steps (~4.7% decay
        // per day) so a normal start-to-floor range is covered within the
        // auction length; the defaults (0.5% per minute) would cross the
        // floor and end the auction within minutes.
        AuctionFactory _factory = AuctionFactory(AUCTION_FACTORY);

        // Forward: sells `asset`, receives alAsset.
        Auction _assetAuction = Auction(_factory.createNewAuction(_alAsset, address(this), address(this)));
        _assetAuction.enable(_asset);
        _assetAuction.setGovernanceOnlyKick(true);
        _assetAuction.setStepDecayRate(1);
        _assetAuction.setStepDuration(3 minutes);
        ASSET_AUCTION = _assetAuction;

        // The way back: sells alAsset for `asset`. Emergency use only.
        Auction _alAssetAuction = Auction(_factory.createNewAuction(_asset, address(this), address(this)));
        _alAssetAuction.enable(_alAsset);
        _alAssetAuction.setGovernanceOnlyKick(true);
        _alAssetAuction.setStepDecayRate(1);
        _alAssetAuction.setStepDuration(3 minutes);
        AL_ASSET_AUCTION = _alAssetAuction;

        // Approve transmuter to pull alAsset for createRedemption.
        ERC20(_alAsset).safeApprove(_transmuter, type(uint256).max);
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Number of open transmuter positions
    /// @return Number of open positions
    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    /// @notice Whether a keeper should kick the asset auction, and the calldata to do it
    /// @dev Same signature as `AuctionSwapper.auctionTrigger`
    /// @param _from Token to sell, only `asset` is supported
    /// @return True if the auction should be kicked
    /// @return Calldata for `kickAuction`, or the reason not to kick
    function auctionTrigger(
        address _from
    ) external view returns (bool, bytes memory) {
        // Only `asset` is sold
        if (_from != address(asset)) return (false, bytes("!asset"));

        // Don't overpay gas
        if (block.basefee >= maxTendBasefee) return (false, bytes("basefee"));

        // Nothing to sell
        if (_kickable() == 0) return (false, bytes("0 kickable"));

        // Otherwise, kick it
        return (true, abi.encodeCall(this.kickAuction, (_from)));
    }

    /// @notice Estimated total assets
    /// @dev alAsset is valued at the auction floor price until transmuted, then at
    /// par minus the transmutation fee. All alAsset value is scaled down on bad debt
    /// @return Total assets in `asset`
    function estimatedTotalAssets() public view returns (uint256) {
        // Idle asset, here and in the auction
        uint256 _total = asset.balanceOf(address(this)) + asset.balanceOf(address(ASSET_AUCTION));

        // MYT at the vault's rate
        _total += MYT.convertToAssets(MYT.balanceOf(address(this)));

        // Untransmuted alAsset is worth what the auction pays for it: 1 / floor price
        uint256 _alAssetPrice = WAD * WAD / minimumPrice;

        // Idle alAsset, here and in the alAsset auction
        uint256 _alValue = (
            AL_ASSET.balanceOf(address(this)) + AL_ASSET.balanceOf(address(AL_ASSET_AUCTION))
        ) * _alAssetPrice / WAD;

        // Positions: transmuted part at par minus fee, the rest at the auction price
        uint256 _fee = TRANSMUTER.transmutationFee();
        for (uint256 _i; _i < positionIds.length; ++_i) {
            ITransmuter.StakingPosition memory _position = TRANSMUTER.getPosition(positionIds[_i]);
            uint256 _untransmuted = _position.maturationBlock > block.number
                ? Math.mulDiv(
                    _position.amount,
                    _position.maturationBlock - block.number,
                    _position.maturationBlock - _position.startBlock,
                    Math.Rounding.Up
                )
                : 0;
            _alValue +=
                (_position.amount - _untransmuted) * (MAX_BPS - _fee) / MAX_BPS +
                _untransmuted * _alAssetPrice / WAD;
        }

        // Scale down on bad debt and convert to `asset` decimals
        return _total + _alValue * _badDebtMultiplier() / WAD / AL_TO_ASSET_SCALER;
    }

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Don't accept more than the transmuter can absorb beyond what is
        // already queued as idle or auctioned asset and idle alAsset.
        uint256 _headroom = _transmuterHeadroom() / AL_TO_ASSET_SCALER;
        uint256 _queued = asset.balanceOf(address(this)) +
            asset.balanceOf(address(ASSET_AUCTION)) +
            AL_ASSET.balanceOf(address(this)) / AL_TO_ASSET_SCALER;
        return _queued < _headroom ? _headroom - _queued : 0;
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Asset here plus an unsold lot left in an ended auction (swept back
        // in `_freeFunds`). A live auction's lot is not withdrawable.
        uint256 _limit = asset.balanceOf(address(this));
        if (!ASSET_AUCTION.isActive(address(asset))) _limit += asset.balanceOf(address(ASSET_AUCTION));

        // Beyond that: matured positions (claimable at full value, no exitFee)
        // and MYT already held. Immature positions are never force-claimed
        // for a withdrawal, that is management's call via manualClaim.
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
        uint256 _claimable = _maturedAl / AL_TO_ASSET_SCALER + MYT.convertToAssets(MYT.balanceOf(address(this)));
        return _limit + MYT.availableWithdrawLimit(_claimable);
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Set the max number of open positions
    /// @dev Bounds the gas of the loops over `positionIds`
    /// @param _maxPositions Max number of open positions
    function setMaxPositions(uint256 _maxPositions) external onlyManagement {
        maxPositions = _maxPositions;
    }

    /// @notice Set the min idle alAsset to open a new position
    /// @param _minRedemptionAmount Min amount of alAsset
    function setMinRedemptionAmount(uint256 _minRedemptionAmount) external onlyManagement {
        minRedemptionAmount = _minRedemptionAmount;
    }

    /// @notice Set the min idle `asset` to kick and the max per auction
    /// @param _minAuctionAmount Min amount of `asset` to kick
    /// @param _maxAuctionAmount Max amount of `asset` per auction
    function setAuctionAmounts(
        uint256 _minAuctionAmount,
        uint256 _maxAuctionAmount
    ) external onlyManagement {
        require(_minAuctionAmount <= _maxAuctionAmount, "!range");
        minAuctionAmount = _minAuctionAmount;
        maxAuctionAmount = _maxAuctionAmount;
    }

    /// @notice Set the max base fee for keeper tends and kicks
    /// @param _maxTendBasefee Max base fee in wei
    function setMaxTendBasefee(uint256 _maxTendBasefee) external onlyManagement {
        maxTendBasefee = _maxTendBasefee;
    }

    /// @notice Set the cooldown after an auction that wasn't fully taken
    /// @param _kickCooldown Cooldown in seconds, 0 for none
    function setKickCooldown(uint256 _kickCooldown) external onlyManagement {
        kickCooldown = _kickCooldown;
    }

    /// @notice Set the asset auction's opening price and floor
    /// @dev The floor is also the price untransmuted alAsset is valued at. Applies from the next kick
    /// @param _startingPricePerUnit Opening price in alAsset per `asset`, WAD scaled
    /// @param _minimumPrice Price floor in alAsset per `asset`, WAD scaled, above par
    function setAuctionPrices(uint256 _startingPricePerUnit, uint256 _minimumPrice) external onlyManagement {
        require(_minimumPrice > WAD && _startingPricePerUnit > _minimumPrice, "!price");
        startingPricePerUnit = _startingPricePerUnit;
        minimumPrice = _minimumPrice;
    }

    /// @notice Set an auction's price decay
    /// @param _alAssetAuction True for the alAsset auction, false for the asset auction
    /// @param _stepDecayRate Decay per step in bps
    /// @param _stepDuration Step length in seconds
    function setAuctionSteps(
        bool _alAssetAuction,
        uint256 _stepDecayRate,
        uint256 _stepDuration
    ) external onlyManagement {
        Auction _auction = _alAssetAuction ? AL_ASSET_AUCTION : ASSET_AUCTION;
        _auction.setStepDecayRate(_stepDecayRate);
        _auction.setStepDuration(_stepDuration);
    }

    /// @notice Sweep a stray token to management
    /// @dev Can't sweep `asset`, alAsset, or MYT
    /// @param _token Token to sweep, can't be `asset`, alAsset or MYT
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
    // Emergency authorized functions
    // ===============================================================

    /// @notice Claim a position by index regardless of maturity
    /// @dev Pays the transmuted part as MYT (minus transmutationFee) and returns
    /// the untransmuted part as alAsset (minus exitFee)
    /// @param _index Index of the position in the ladder to claim
    function manualClaim(uint256 _index) external onlyEmergencyAuthorized {
        // Claim, matured part as MYT, rest as alAsset
        TRANSMUTER.claimRedemption(positionIds[_index]);

        // Swap-and-pop
        uint256 _last = positionIds.length - 1;
        if (_index != _last) positionIds[_index] = positionIds[_last];
        positionIds.pop();
    }

    /// @notice Redeem MYT for `asset`
    /// @dev Escape hatch for if the liquidity estimate in `_freeFunds()` is off
    /// @param _shares Amount of MYT to redeem
    function manualRedeemMYT(uint256 _shares) external onlyEmergencyAuthorized {
        MYT.redeem(_shares, address(this), address(this));
    }

    /// @notice Kick the alAsset auction, selling idle alAsset for `asset`
    /// @dev Emergency exit for alAsset that can't be transmuted. Reverts while a
    /// previous alAsset auction is live
    /// @param _amount Amount of alAsset to sell
    /// @param _startingPricePerUnit Opening price in `asset` per alAsset, WAD scaled
    /// @param _minimumPrice Price floor in `asset` per alAsset, WAD scaled
    function kickAlAssetAuction(
        uint256 _amount,
        uint256 _startingPricePerUnit,
        uint256 _minimumPrice
    ) external onlyEmergencyAuthorized {
        require(_minimumPrice != 0 && _startingPricePerUnit > _minimumPrice, "!price");

        // Price the lot. `startingPrice` is the whole lot in whole tokens
        (, uint64 _scaler, ) = AL_ASSET_AUCTION.auctions(address(AL_ASSET));
        AL_ASSET_AUCTION.setMinimumPrice(_minimumPrice);
        AL_ASSET_AUCTION.setStartingPrice(
            Math.mulDiv(_startingPricePerUnit, _amount * _scaler, WAD * WAD, Math.Rounding.Up)
        );

        // Fund and kick
        AL_ASSET.safeTransfer(address(AL_ASSET_AUCTION), _amount);
        AL_ASSET_AUCTION.kick(address(AL_ASSET));
    }

    /// @notice Pull the lot back from an auction and end it if live
    /// @dev Abort a mispriced or unwanted auction. Unsold alAsset has no other way back
    /// @param _alAssetAuction True for the alAsset auction, false for the asset auction
    function sweepAuction(bool _alAssetAuction) external onlyEmergencyAuthorized {
        Auction _auction = _alAssetAuction ? AL_ASSET_AUCTION : ASSET_AUCTION;
        ERC20 _token = _alAssetAuction ? AL_ASSET : asset;

        // Take the lot back
        if (_token.balanceOf(address(_auction)) != 0) _auction.sweep(address(_token));

        // End the auction so it can be kicked again
        if (_auction.isActive(address(_token))) _auction.settle(address(_token));
    }

    // ===============================================================
    // Keeper functions
    // ===============================================================

    /// @notice Kick the auction, selling idle `asset` for alAsset
    /// @dev Same signature as `AuctionSwapper.kickAuction`
    /// @dev Reverts while an auction is live or nothing is kickable
    /// @param _from Token to sell, must be `asset`
    /// @return _available Amount of `asset` put up for auction
    function kickAuction(address _from) external onlyKeepers returns (uint256 _available) {
        require(_from == address(asset), "!asset");

        // How much to sell
        _available = _kickable();
        require(_available != 0, "!kickable");

        // Sweep unsold lot. Live auction will revert here
        if (asset.balanceOf(address(ASSET_AUCTION)) != 0) ASSET_AUCTION.sweep(address(asset));

        // Price the lot. `startingPrice` is the whole lot in whole tokens
        (, uint64 _scaler, ) = ASSET_AUCTION.auctions(_from);
        ASSET_AUCTION.setMinimumPrice(minimumPrice);
        ASSET_AUCTION.setStartingPrice(
            Math.mulDiv(startingPricePerUnit, _available * _scaler, WAD * WAD, Math.Rounding.Up)
        );

        // Fund and kick
        asset.safeTransfer(address(ASSET_AUCTION), _available);
        ASSET_AUCTION.kick(_from);
    }

    // ===============================================================
    // Internal mutated functions
    // ===============================================================

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 /*_amount*/) internal override {
        // Do nothing. Idle assets gets auctioned for alAsset in `_tend()`
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 /*_amount*/) internal override {
        // Sweep idle assets from an expired auction. Never touches a live one
        if (!ASSET_AUCTION.isActive(address(asset)) && asset.balanceOf(address(ASSET_AUCTION)) != 0) {
            ASSET_AUCTION.sweep(address(asset));
        }

        // Claim matured positions as MYT. Immature positions are never
        // force-claimed here as the exitFee and the restarted maturation would
        // fall on the remaining depositors
        for (uint256 _i = positionIds.length; _i > 0; --_i) {
            uint256 _id = positionIds[_i - 1];
            if (TRANSMUTER.getPosition(_id).maturationBlock > block.number) continue;
            TRANSMUTER.claimRedemption(_id);

            // Swap-and-pop
            positionIds[_i - 1] = positionIds[positionIds.length - 1];
            positionIds.pop();
        }

        // Redeem all MYT back into asset, sized by the vault's real liquidity
        // since Morpho V2's maxRedeem always returns 0. Reverts are swallowed.
        // The MYT stays idle for a later attempt and is priced into totalAssets
        uint256 _maxAssets = MYT.availableWithdrawLimit();
        if (_maxAssets != 0) {
            uint256 _shares = Math.min(MYT.balanceOf(address(this)), MYT.convertToShares(_maxAssets));
            if (_shares != 0) try MYT.redeem(_shares, address(this), address(this)) {} catch {}
        }
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256) {
        // Accounting only. All position maintenance happens in `_tend()`
        return estimatedTotalAssets();
    }

    /// @inheritdoc BaseStrategy
    function _tend(uint256 /*_totalIdle*/) internal override {
        // Sweep idle assets from auction, claim matured positions, and redeem MYTs
        _freeFunds(0);

        // Transmute idle alAssets
        uint256 _amount = _transmutableAmount();
        if (_amount == 0) return;
        TRANSMUTER.createRedemption(_amount, address(this));

        // Transmuter is ERC721Enumerable, the fresh position is at the tail
        positionIds.push(
            TRANSMUTER.tokenOfOwnerByIndex(address(this), TRANSMUTER.balanceOf(address(this)) - 1)
        );
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 /*_amount*/) internal override {
        // Sweep idle assets from auction, claim matured positions, and redeem MYTs
        _freeFunds(0);
    }

    // ===============================================================
    // Internal view functions
    // ===============================================================

    /// @inheritdoc BaseStrategy
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0) return false;

        // Don't overpay gas
        if (block.basefee >= maxTendBasefee) return false;

        // A matured position should be claimed immediately to reduce exposure
        uint256 _length = positionIds.length;
        for (uint256 _i; _i < _length; ++_i)
            if (TRANSMUTER.getPosition(positionIds[_i]).maturationBlock <= block.number) return true;

        // MYT stuck from a previously failed withdrawal has liquidity again
        if (MYT.availableWithdrawLimit() > DUST_AMOUNT) return true;

        // Idle alAsset ready to be transmuted
        return _transmutableAmount() != 0;
    }

    /// @notice Amount of `asset` a kick should auction right now
    /// @dev 0 if an auction is live, cooling down, shut down, or the ladder is full
    /// @return Amount of `asset` to auction
    function _kickable() internal view returns (uint256) {
        if (TokenizedStrategy.isShutdown()) return 0;

        // If active auction, wait
        if (ASSET_AUCTION.isActive(address(asset))) return 0;

        // Wait the cooldown
        (uint64 _kicked, , ) = ASSET_AUCTION.auctions(address(asset));
        if (block.timestamp < _kicked + kickCooldown) return 0;

        // Check the ladder isn't full
        if (positionIds.length >= maxPositions) return 0;

        // Idle assets, capped by `maxAuctionAmount`
        uint256 _amount = Math.min(
            asset.balanceOf(address(this)) + asset.balanceOf(address(ASSET_AUCTION)),
            maxAuctionAmount
        );

        // Kickable is the idle amount if above `minAuctionAmount`, else 0
        return _amount < minAuctionAmount ? 0 : _amount;
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

    /// @dev alAsset that would be staked if `_tend` ran now. 0 if below
    /// the minimum, the ladder is full, or an auction is still live: takers
    /// fill in pieces, so wait for the whole fill and stake it as one
    /// position instead of fragmenting the ladder.
    function _transmutableAmount() internal view returns (uint256) {
        if (positionIds.length >= maxPositions) return 0;
        if (ASSET_AUCTION.isActive(address(asset))) return 0;
        uint256 _amount = Math.min(AL_ASSET.balanceOf(address(this)), _transmuterHeadroom());
        return _amount < minRedemptionAmount ? 0 : _amount;
    }
}
