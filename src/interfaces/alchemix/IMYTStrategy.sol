// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

/// @notice Alchemix's `ERC4626Strategy`, the MYT liquidity adapter. Wraps an ERC4626 vault
interface IMYTStrategy {

    function vault() external view returns (address);

}
