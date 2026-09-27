// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMYT} from "../interfaces/alchemix/IMYT.sol";
import {IMYTStrategy} from "../interfaces/alchemix/IMYTStrategy.sol";

/// @notice Withdraw sizing for MYT, whose `maxRedeem` always returns 0
/// @dev Adapted from tapired/tokenized-morpho-vaultv2-lender `MorphoVaultV2Limits.sol`.
/// Exact for Alchemix's `ERC4626Strategy` adapter, 0 for any other
library MYTLimitsLib {

    /// @notice Assets the vault can pay out to the caller right now
    /// @param _vault The MYT vault
    /// @return Amount of `asset`
    function availableLiquidity(
        IMYT _vault
    ) internal view returns (uint256) {
        // Transfer gates
        if (!_vault.canSendShares(address(this)) || !_vault.canReceiveAssets(address(this))) return 0;

        // Idle asset in the vault
        uint256 _liquid = IERC20(_vault.asset()).balanceOf(address(_vault));

        // Plus what the liquidity adapter can pull from its underlying vault. The
        // allocator can switch adapters at any time, an unknown one counts as illiquid
        address _adapter = _vault.liquidityAdapter();
        if (_adapter != address(0)) {
            try IMYTStrategy(_adapter).vault() returns (address _underlying) {
                _liquid += IERC4626(_underlying).maxWithdraw(_adapter);
            } catch {}
        }

        return _liquid;
    }

}
