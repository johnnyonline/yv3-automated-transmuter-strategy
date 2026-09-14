// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

/// @notice An Alchemix MYT adapter. `realAssets()` is on every adapter, `vault()` only on `ERC4626Strategy`
interface IMYTStrategy {

    function realAssets() external view returns (uint256);
    function vault() external view returns (address);

}
