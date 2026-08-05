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

    function AL_ASSET() external view returns (address);

    function TRANSMUTER() external view returns (address);

    function ALCHEMIST() external view returns (address);

    function YIELD_TOKEN() external view returns (address);

    function AL_TO_ASSET_SCALER() external view returns (uint256);

    // ===============================================================
    // Management
    // ===============================================================

    function setMaxPositions(uint256 _maxPositions) external;

    function setMinRedemptionAmount(uint256 _minRedemptionAmount) external;

    function setDepositLimit(uint256 _depositLimit) external;

    function setAuctionAmounts(uint256 _minAuctionAmount, uint256 _maxAuctionAmount) external;

    function setMaxTendBasefeeGwei(uint256 _maxTendBasefeeGwei) external;

    function manualClaimRedemption(uint256 _index) external;

    function manualUnwrap(uint256 _shares) external;

    function sweep(address _token) external;

    // ===============================================================
    // Auction (embedded — the strategy is its own auction)
    // ===============================================================

    function kick(address _from) external returns (uint256);

    function kickable(address _from) external view returns (uint256);

    function auctionTrigger(address _from) external view returns (bool, bytes memory);

    function want() external view returns (address);

    function receiver() external view returns (address);

    function governance() external view returns (address);

    function available(address _from) external view returns (uint256);

    function isActive(address _from) external view returns (bool);

    function kicked(address _from) external view returns (uint256);

    function getAmountNeeded(address _from, uint256 _amountToTake) external view returns (uint256);

    function price(address _from) external view returns (uint256);

    function minimumPrice() external view returns (uint256);

    function startingPrice() external view returns (uint256);

    function take(address _from) external returns (uint256);

    function take(address _from, uint256 _maxAmount) external returns (uint256);

    function settle(address _from) external;

    function enable(address _from) external;

    function disable(address _from) external;

    function setMinimumPrice(uint256 _minimumPrice) external;

    function setStartingPrice(uint256 _startingPrice) external;

    function setStepDecayRate(uint256 _stepDecayRate) external;

    function setStepDuration(uint256 _stepDuration) external;

    function setGovernanceOnlyKick(bool _governanceOnlyKick) external;
}
