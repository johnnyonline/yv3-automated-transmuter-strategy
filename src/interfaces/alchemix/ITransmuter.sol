// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface ITransmuter {
    struct StakingPosition {
        uint256 amount;
        uint256 startBlock;
        uint256 maturationBlock;
    }

    function alchemist() external view returns (address);
    function syntheticToken() external view returns (address);
    function timeToTransmute() external view returns (uint256);
    function transmutationFee() external view returns (uint256);
    function exitFee() external view returns (uint256);
    function depositCap() external view returns (uint256);
    function totalLocked() external view returns (uint256);

    function getPosition(uint256 id) external view returns (StakingPosition memory);
    function createRedemption(uint256 syntheticDepositAmount, address recipient) external;
    function claimRedemption(uint256 id) external returns (
        uint256 claimYield,
        uint256 feeYield,
        uint256 syntheticReturned,
        uint256 syntheticFee
    );

    // ERC721Enumerable surface (Transmuter inherits ERC721Enumerable in v3 canonical)
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}
