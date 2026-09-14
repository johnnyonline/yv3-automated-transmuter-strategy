// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IAlchemistV3 {

    function myt() external view returns (address);
    function underlyingToken() external view returns (address);
    function totalSyntheticsIssued() external view returns (uint256);

    /// @notice Underlying value of all collateral locked in the alchemist.
    function getTotalLockedUnderlyingValue() external view returns (uint256);

    function convertYieldTokensToUnderlying(
        uint256 amount
    ) external view returns (uint256);
    function convertUnderlyingTokensToYield(
        uint256 amount
    ) external view returns (uint256);
    function convertYieldTokensToDebt(
        uint256 amount
    ) external view returns (uint256);
    function convertDebtTokensToYield(
        uint256 amount
    ) external view returns (uint256);

}
