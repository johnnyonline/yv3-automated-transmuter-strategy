// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Auction} from "@periphery/Auctions/Auction.sol";
import {AuctionFactory} from "@periphery/Auctions/AuctionFactory.sol";

import {IMYT} from "./interfaces/alchemix/IMYT.sol";
import {ITransmuter} from "./interfaces/alchemix/ITransmuter.sol";
import {IAlchemistV3} from "./interfaces/alchemix/IAlchemistV3.sol";
import {MYTLimitsLib} from "./periphery/MYTLimitsLib.sol";

contract AutomatedTransmuterStrategy is BaseHealthCheck {

    using SafeERC20 for ERC20;
    using MYTLimitsLib for IMYT;

    // ===============================================================
    // Storage
    // ===============================================================

    struct Position {
        uint128 id; // Transmuter NFT id
        uint128 price; // `asset` per alAsset for the untransmuted part, WAD scaled
    }

    /// @notice Max open positions
    uint16 public maxPositions = 7;

    /// @notice Cooldown after an auction that wasn't fully taken, in seconds
    uint32 public kickCooldown = 1 days;

    /// @notice Max base fee for keeper tends and kicks, in wei
    uint64 public maxTendBasefee = 30 gwei;

    /// @notice Auction price floor in alAsset per `asset`, WAD scaled. Also
    /// the price new positions are valued at
    /// @dev E.g. 1.1e18 = 1.1 alAsset per asset = 10% gain over the ~6 month
    /// transmute cycle (~20% APR). Fills above the floor book the extra as
    /// profit at fill, the rest accretes as the position transmutes
    uint96 public minimumPrice = 1.1e18;

    /// @notice Auction opening price in alAsset per `asset`, WAD scaled
    /// @dev E.g. 1.15e18. Decays toward `minimumPrice` at ~4.7% per day, so
    /// keep the range tight to limit profit booked at fill
    uint96 public startingPricePerUnit = 1.15e18;

    /// @notice Min idle `asset` to kick an auction
    uint96 public minAuctionAmount;

    /// @notice Max `asset` per auction. Kicks are blocked until set
    uint96 public maxAuctionAmount;

    /// @notice Min idle alAsset to open a position
    uint96 public minRedemptionAmount;

    /// @notice Open transmuter positions, each valued at the floor price it was opened at
    Position[] public positions;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The WAD constant
    uint256 internal constant _WAD = 1e18;

    /// @notice Redeemable MYT worth less `asset` than this is not worth a tend
    uint256 internal constant _DUST_AMOUNT = 1e6;

    /// @notice Auction price decay: 1 bp every 3 minutes
    uint256 internal constant _AUCTION_STEP_DECAY_RATE = 1;
    uint256 internal constant _AUCTION_STEP_DURATION = 3 minutes;

    /// @notice Divides alAsset amounts down to `asset` decimals
    uint256 public immutable AL_TO_ASSET_SCALER;

    /// @notice One whole unit of `asset`
    uint256 public immutable ASSET_UNIT;

    /// @notice Alchemix addresses
    ERC20 public immutable AL_ASSET;
    ITransmuter public immutable TRANSMUTER;
    IAlchemistV3 public immutable ALCHEMIST;
    IMYT public immutable MYT; // Alchemix yield token, a Morpho Vault V2

    /// @notice Sells `asset` for alAsset
    Auction public immutable ASSET_AUCTION;

    /// @notice Sells alAsset for `asset`
    Auction public immutable AL_ASSET_AUCTION;

    /// @notice Yearn AuctionFactory v1.0.5
    AuctionFactory internal constant _AUCTION_FACTORY = AuctionFactory(0x55B3830B4D85e6868c73f00A2e857e9AdbF89568);

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor(
        address _asset,
        string memory _name,
        address _alAsset,
        address _transmuter
    ) BaseHealthCheck(_asset, _name) {
        AL_ASSET = ERC20(_alAsset);
        TRANSMUTER = ITransmuter(_transmuter);
        ALCHEMIST = IAlchemistV3(TRANSMUTER.alchemist());
        MYT = IMYT(ALCHEMIST.myt());

        // Sanity checks
        require(TRANSMUTER.syntheticToken() == _alAsset, "!alAsset");
        require(ALCHEMIST.underlyingToken() == _asset, "!underlying");
        require(MYT.asset() == _asset, "!myt");

        // Decimal scalers. alAsset must have at least as many decimals as `asset`
        ASSET_UNIT = 10 ** asset.decimals();
        AL_TO_ASSET_SCALER = 10 ** AL_ASSET.decimals() / ASSET_UNIT;
        require(AL_TO_ASSET_SCALER != 0, "!decimals");

        // Both auctions pay this strategy and are governed by it
        ASSET_AUCTION = Auction(_AUCTION_FACTORY.createNewAuction(_alAsset));
        ASSET_AUCTION.enable(_asset);
        ASSET_AUCTION.setGovernanceOnlyKick(true);
        ASSET_AUCTION.setStepDecayRate(_AUCTION_STEP_DECAY_RATE);
        ASSET_AUCTION.setStepDuration(_AUCTION_STEP_DURATION);

        AL_ASSET_AUCTION = Auction(_AUCTION_FACTORY.createNewAuction(_asset));
        AL_ASSET_AUCTION.enable(_alAsset);
        AL_ASSET_AUCTION.setGovernanceOnlyKick(true);
        AL_ASSET_AUCTION.setStepDecayRate(_AUCTION_STEP_DECAY_RATE);
        AL_ASSET_AUCTION.setStepDuration(_AUCTION_STEP_DURATION);

        // Let the transmuter pull alAsset for new positions
        AL_ASSET.forceApprove(_transmuter, type(uint256).max);
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Number of open transmuter positions
    /// @return Number of open positions
    function positionCount() external view returns (uint256) {
        return positions.length;
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

        // Untransmuted alAsset is worth what the auction pays for it (pessimistic case)
        uint256 _alAssetPrice = _WAD * _WAD / minimumPrice;

        // Idle alAsset, here and in the alAsset auction
        uint256 _alValue =
            (AL_ASSET.balanceOf(address(this)) + AL_ASSET.balanceOf(address(AL_ASSET_AUCTION))) * _alAssetPrice / _WAD;

        // Positions: transmuted part at par minus fee, the rest at the price it was opened at
        uint256 _fee = TRANSMUTER.transmutationFee();
        for (uint256 _i; _i < positions.length; ++_i) {
            ITransmuter.StakingPosition memory _position = TRANSMUTER.getPosition(positions[_i].id);
            uint256 _untransmuted = _position.maturationBlock > block.number
                ? Math.mulDiv(
                    _position.amount,
                    _position.maturationBlock - block.number,
                    _position.maturationBlock - _position.startBlock,
                    Math.Rounding.Up
                )
                : 0;
            _alValue += (_position.amount - _untransmuted) * (MAX_BPS - _fee) / MAX_BPS + _untransmuted
                * positions[_i].price / _WAD;
        }

        // Scale down on bad debt and convert to `asset` decimals
        return _total + _alValue * _badDebtMultiplier() / _WAD / AL_TO_ASSET_SCALER;
    }

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // What the transmuter can still absorb, in `asset`
        uint256 _headroom = _transmuterHeadroom() / AL_TO_ASSET_SCALER;

        // What's already waiting for that room: asset here and in its auction,
        // alAsset here and in its auction
        uint256 _queued = asset.balanceOf(address(this)) + asset.balanceOf(address(ASSET_AUCTION))
            + (AL_ASSET.balanceOf(address(this)) + AL_ASSET.balanceOf(address(AL_ASSET_AUCTION))) / AL_TO_ASSET_SCALER;

        return _queued < _headroom ? _headroom - _queued : 0;
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Idle asset. An unsold lot in an ended auction counts, a live one doesn't
        uint256 _idle = asset.balanceOf(address(this));
        if (!ASSET_AUCTION.isActive(address(asset))) _idle += asset.balanceOf(address(ASSET_AUCTION));

        // Matured positions at face. The transmutation fee and any bad debt
        // haircut come out of what's freed and land on the withdrawer as loss
        uint256 _matured;
        for (uint256 _i; _i < positions.length; ++_i) {
            ITransmuter.StakingPosition memory _position = TRANSMUTER.getPosition(positions[_i].id);
            if (_position.maturationBlock <= block.number) _matured += _position.amount;
        }
        _matured /= AL_TO_ASSET_SCALER;

        // Matured positions pay MYT, so they and MYT already held are bounded
        // by what the MYT vault can pay out right now
        uint256 _myt = MYT.convertToAssets(MYT.balanceOf(address(this)));
        return _idle + MYT.availableWithdrawLimit(_matured + _myt);
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Set the max number of open positions
    /// @dev Bounds the gas of the loops over `positions`
    /// @param _maxPositions Max number of open positions
    function setMaxPositions(
        uint16 _maxPositions
    ) external onlyManagement {
        maxPositions = _maxPositions;
    }

    /// @notice Set the min idle alAsset to open a new position
    /// @param _minRedemptionAmount Min amount of alAsset
    function setMinRedemptionAmount(
        uint96 _minRedemptionAmount
    ) external onlyManagement {
        minRedemptionAmount = _minRedemptionAmount;
    }

    /// @notice Set the min idle `asset` to kick and the max per auction
    /// @param _minAuctionAmount Min amount of `asset` to kick
    /// @param _maxAuctionAmount Max amount of `asset` per auction
    function setAuctionAmounts(
        uint96 _minAuctionAmount,
        uint96 _maxAuctionAmount
    ) external onlyManagement {
        require(_minAuctionAmount <= _maxAuctionAmount, "!range");
        minAuctionAmount = _minAuctionAmount;
        maxAuctionAmount = _maxAuctionAmount;
    }

    /// @notice Set the max base fee for keeper tends and kicks
    /// @param _maxTendBasefee Max base fee in wei
    function setMaxTendBasefee(
        uint64 _maxTendBasefee
    ) external onlyManagement {
        maxTendBasefee = _maxTendBasefee;
    }

    /// @notice Set the cooldown after an auction that wasn't fully taken
    /// @param _kickCooldown Cooldown in seconds, 0 for none
    function setKickCooldown(
        uint32 _kickCooldown
    ) external onlyManagement {
        kickCooldown = _kickCooldown;
    }

    /// @notice Set the asset auction's opening price and floor
    /// @dev The floor is also the price untransmuted alAsset is valued at. Applies from the next kick
    /// @param _startingPricePerUnit Opening price in alAsset per `asset`, WAD scaled
    /// @param _minimumPrice Price floor in alAsset per `asset`, WAD scaled, above par
    function setAuctionPrices(
        uint96 _startingPricePerUnit,
        uint96 _minimumPrice
    ) external onlyManagement {
        require(_minimumPrice > _WAD && _startingPricePerUnit > _minimumPrice, "!price");
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
    function sweep(
        address _token
    ) external onlyManagement {
        require(_token != address(asset), "!asset");
        require(_token != address(AL_ASSET), "!alAsset");
        require(_token != address(MYT), "!myt");
        ERC20(_token).safeTransfer(TokenizedStrategy.management(), ERC20(_token).balanceOf(address(this)));
    }

    // ===============================================================
    // Emergency authorized functions
    // ===============================================================

    /// @notice Claim a position by index regardless of maturity
    /// @dev Pays the transmuted part as MYT (minus transmutationFee) and returns
    /// the untransmuted part as alAsset (minus exitFee)
    /// @param _index Index of the position in the ladder to claim
    function manualClaim(
        uint256 _index
    ) external onlyEmergencyAuthorized {
        // Claim, matured part as MYT, rest as alAsset
        TRANSMUTER.claimRedemption(positions[_index].id);

        // Swap-and-pop
        positions[_index] = positions[positions.length - 1];
        positions.pop();
    }

    /// @notice Redeem MYT for `asset`
    /// @dev Escape hatch for if the liquidity estimate in `_freeFunds()` is off
    /// @param _shares Amount of MYT to redeem
    function manualRedeemMYT(
        uint256 _shares
    ) external onlyEmergencyAuthorized {
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
        (, uint64 _scaler,) = AL_ASSET_AUCTION.auctions(address(AL_ASSET));
        AL_ASSET_AUCTION.setMinimumPrice(_minimumPrice);
        AL_ASSET_AUCTION.setStartingPrice(Math.mulDiv(_startingPricePerUnit, _amount * _scaler, _WAD, Math.Rounding.Up));

        // Fund and kick
        AL_ASSET.safeTransfer(address(AL_ASSET_AUCTION), _amount);
        AL_ASSET_AUCTION.kick(address(AL_ASSET));
    }

    /// @notice Pull the lot back from an auction and end it if live
    /// @dev Abort a mispriced or unwanted auction. Unsold alAsset has no other way back
    /// @param _alAssetAuction True for the alAsset auction, false for the asset auction
    function sweepAuction(
        bool _alAssetAuction
    ) external onlyEmergencyAuthorized {
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
    function kickAuction(
        address _from
    ) external onlyKeepers returns (uint256 _available) {
        require(_from == address(asset), "!asset");

        // How much to sell
        _available = _kickable();
        require(_available != 0, "!kickable");

        // Sweep unsold lot. Live auction will revert here
        if (asset.balanceOf(address(ASSET_AUCTION)) != 0) ASSET_AUCTION.sweep(address(asset));

        // Price the lot. `startingPrice` is the whole lot in whole tokens
        (, uint64 _scaler,) = ASSET_AUCTION.auctions(_from);
        ASSET_AUCTION.setMinimumPrice(minimumPrice);
        ASSET_AUCTION.setStartingPrice(Math.mulDiv(startingPricePerUnit, _available * _scaler, _WAD, Math.Rounding.Up));

        // Fund and kick
        asset.safeTransfer(address(ASSET_AUCTION), _available);
        ASSET_AUCTION.kick(_from);
    }

    // ===============================================================
    // Internal mutated functions
    // ===============================================================

    /// @inheritdoc BaseStrategy
    function _deployFunds(
        uint256 /*_amount*/
    ) internal override {
        // Do nothing. Idle assets gets auctioned for alAsset in `_tend()`
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(
        uint256 /*_amount*/
    ) internal override {
        // Sweep idle assets from an expired auction. Never touches a live one
        if (!ASSET_AUCTION.isActive(address(asset)) && asset.balanceOf(address(ASSET_AUCTION)) != 0) {
            ASSET_AUCTION.sweep(address(asset));
        }

        // Claim matured positions as MYT. Immature positions are never
        // force-claimed here as the exitFee and the restarted maturation would
        // fall on the remaining depositors
        for (uint256 _i = positions.length; _i > 0; --_i) {
            uint256 _id = positions[_i - 1].id;
            if (TRANSMUTER.getPosition(_id).maturationBlock > block.number) continue;
            TRANSMUTER.claimRedemption(_id);

            // Swap-and-pop
            positions[_i - 1] = positions[positions.length - 1];
            positions.pop();
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
    function _tend(
        uint256 /*_totalIdle*/
    ) internal override {
        // Sweep idle assets from auction, claim matured positions, and redeem MYTs
        _freeFunds(0);

        // Transmute idle alAssets
        uint256 _amount = _transmutableAmount();
        if (_amount == 0) return;
        TRANSMUTER.createRedemption(_amount, address(this));

        // Transmuter is ERC721Enumerable, the fresh position is at the tail.
        // It keeps today's floor price as its valuation for life
        positions.push(
            Position({
                id: uint128(TRANSMUTER.tokenOfOwnerByIndex(address(this), TRANSMUTER.balanceOf(address(this)) - 1)),
                price: uint128(_WAD * _WAD / minimumPrice)
            })
        );
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(
        uint256 /*_amount*/
    ) internal override {
        // Sweep idle assets from auction, claim matured positions, and redeem MYTs
        _freeFunds(0);
    }

    // ===============================================================
    // Internal view functions
    // ===============================================================

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal view override returns (uint256) {
        // Accounting only. All position maintenance happens in `_tend()`
        return estimatedTotalAssets();
    }

    /// @inheritdoc BaseStrategy
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0) return false;

        // Don't overpay gas
        if (block.basefee >= maxTendBasefee) return false;

        // A matured position should be claimed immediately to reduce exposure
        for (uint256 _i; _i < positions.length; ++_i) {
            if (TRANSMUTER.getPosition(positions[_i].id).maturationBlock <= block.number) return true;
        }

        // MYT stuck from a previously failed withdrawal has liquidity again
        if (MYT.availableWithdrawLimit() > _DUST_AMOUNT) return true;

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
        (uint64 _kicked,,) = ASSET_AUCTION.auctions(address(asset));
        if (block.timestamp < _kicked + kickCooldown) return 0;

        // Check the ladder isn't full
        if (positions.length >= maxPositions) return 0;

        // Idle assets, capped by `maxAuctionAmount`
        uint256 _amount =
            Math.min(asset.balanceOf(address(this)) + asset.balanceOf(address(ASSET_AUCTION)), maxAuctionAmount);

        // Kickable is the idle amount if above `minAuctionAmount`, else 0
        return _amount < minAuctionAmount ? 0 : _amount;
    }

    /// @notice Multiplier the transmuter applies to claims when the alchemist has bad debt
    /// @dev Mirrors the transmuter's `badDebtRatio` math
    /// @return WAD scaled multiplier, 1e18 when fully backed
    function _badDebtMultiplier() internal view returns (uint256) {
        // Underlying backing the synthetics: locked collateral plus the transmuter's MYT
        uint256 _backing = ALCHEMIST.getTotalLockedUnderlyingValue()
            + ALCHEMIST.convertYieldTokensToUnderlying(MYT.balanceOf(address(TRANSMUTER)));
        if (_backing == 0) return 0;

        // Synthetics issued per unit of backing, rounded up like the transmuter does
        uint256 _ratio = Math.mulDiv(ALCHEMIST.totalSyntheticsIssued(), ASSET_UNIT, _backing, Math.Rounding.Up);

        // Only scale down, never up
        return _ratio > _WAD ? Math.mulDiv(_WAD, _WAD, _ratio) : _WAD;
    }

    /// @notice alAsset the transmuter can still absorb
    /// @dev Same two checks as `Transmuter.createRedemption`
    /// @return Amount of alAsset
    function _transmuterHeadroom() internal view returns (uint256) {
        // Deposit cap, against positions still counting toward it
        uint256 _cap = TRANSMUTER.depositCap();
        uint256 _activeLocked = TRANSMUTER.totalActiveLocked();
        uint256 _capLeft = _cap > _activeLocked ? _cap - _activeLocked : 0;

        // Can't lock more than the synthetics outstanding
        uint256 _issued = ALCHEMIST.totalSyntheticsIssued();
        uint256 _locked = TRANSMUTER.totalLocked();
        uint256 _issuedLeft = _issued > _locked ? _issued - _locked : 0;

        return Math.min(_capLeft, _issuedLeft);
    }

    /// @notice Amount of alAsset a tend would stake right now
    /// @return Amount of alAsset to stake
    function _transmutableAmount() internal view returns (uint256) {
        // Ladder full
        if (positions.length >= maxPositions) return 0;

        // Wait for the whole fill
        if (ASSET_AUCTION.isActive(address(asset))) return 0;

        // Idle alAsset, capped by what the transmuter can take
        uint256 _amount = Math.min(AL_ASSET.balanceOf(address(this)), _transmuterHeadroom());
        return _amount < minRedemptionAmount ? 0 : _amount;
    }

}
