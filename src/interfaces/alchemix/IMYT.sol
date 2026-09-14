// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Alchemix's MYT yield token, a Morpho Vault V2
interface IMYT is IERC4626 {

    function liquidityAdapter() external view returns (address);
    function canSendShares(
        address account
    ) external view returns (bool);
    function canReceiveAssets(
        address account
    ) external view returns (bool);

}
