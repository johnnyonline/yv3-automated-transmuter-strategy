// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IAlchemistV3 {
    function yieldToken() external view returns (address);
    function underlyingToken() external view returns (address);
    function totalSyntheticsIssued() external view returns (uint256);

    function convertYieldTokensToUnderlying(uint256 amount) external view returns (uint256);
    function convertUnderlyingTokensToYield(uint256 amount) external view returns (uint256);
}
