// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    // ===============================================================
    // Views
    // ===============================================================

    function positionIds(uint256 _index) external view returns (uint256);

    function positionCount() external view returns (uint256);

    function estimatedTotalAssets() external view returns (uint256);

    function maxPositions() external view returns (uint256);

    function minRedemptionAmount() external view returns (uint256);

    function depositLimit() external view returns (uint256);

    function minAuctionAmount() external view returns (uint256);

    function maxAuctionAmount() external view returns (uint256);

    function maxTendBasefeeGwei() external view returns (uint256);

    function kickCooldown() external view returns (uint256);

    function startingPricePerUnit() external view returns (uint256);

    function AL_ASSET() external view returns (address);

    function TRANSMUTER() external view returns (address);

    function ALCHEMIST() external view returns (address);

    function MYT() external view returns (address);

    function ASSET_AUCTION() external view returns (address);

    function AL_ASSET_AUCTION() external view returns (address);

    function AL_TO_ASSET_SCALER() external view returns (uint256);

    function ASSET_UNIT() external view returns (uint256);

    // ===============================================================
    // Management
    // ===============================================================

    function setMaxPositions(uint256 _maxPositions) external;

    function setMinRedemptionAmount(uint256 _minRedemptionAmount) external;

    function setDepositLimit(uint256 _depositLimit) external;

    function setAuctionAmounts(uint256 _minAuctionAmount, uint256 _maxAuctionAmount) external;

    function setMaxTendBasefeeGwei(uint256 _maxTendBasefeeGwei) external;

    function setKickCooldown(uint256 _kickCooldown) external;

    function setStartingPricePerUnit(uint256 _startingPricePerUnit) external;

    function setAssetAuctionMinimumPrice(uint256 _minimumPrice) external;

    function setAssetAuctionSteps(uint256 _stepDecayRate, uint256 _stepDuration) external;

    function manualClaimPosition(uint256 _index) external;

    function manualWithdrawFromMytVault(uint256 _shares) external;

    function kickAlAssetAuction(uint256 _amount, uint256 _startingPricePerUnit, uint256 _minimumPrice) external;

    function sweepAssetAuction() external;

    function sweepAlAssetAuction() external;

    function sweep(address _token) external;

    // ===============================================================
    // Auction (external Yearn Auction clones governed by the strategy)
    // ===============================================================

    function kickAuction(address _from) external returns (uint256);

    function kickable(address _from) external view returns (uint256);

    function auctionTrigger(address _from) external view returns (bool, bytes memory);
}
