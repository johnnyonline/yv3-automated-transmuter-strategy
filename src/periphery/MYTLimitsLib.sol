// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev Alchemix's MYT yield token: a Morpho Vault V2.
interface IMYT is IERC4626 {
    function liquidityAdapter() external view returns (address);
    function canSendShares(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);
}

interface IMYTStrategyLike {
    function realAssets() external view returns (uint256);
}

/// @dev Withdraw sizing for MYT, whose `maxRedeem` always returns 0. Liquidity
/// is the vault's idle asset plus whatever its liquidity adapter holds.
library MYTLimitsLib {
    /// @dev Assets the vault can pay out right now for the shares the caller holds.
    function availableWithdrawLimit(IMYT vault) internal view returns (uint256) {
        uint256 balance = vault.balanceOf(address(this));
        if (balance == 0) return 0;
        return availableWithdrawLimit(vault, vault.convertToAssets(balance));
    }

    /// @dev `vaultClaim` bounded by what the vault can pay out right now.
    function availableWithdrawLimit(IMYT vault, uint256 vaultClaim) internal view returns (uint256) {
        if (vaultClaim == 0) return 0;
        if (!vault.canSendShares(address(this))) return 0;
        if (!vault.canReceiveAssets(address(this))) return 0;

        uint256 liquid = IERC20(vault.asset()).balanceOf(address(vault));

        address adapter = vault.liquidityAdapter();
        if (adapter != address(0)) {
            try IMYTStrategyLike(adapter).realAssets() returns (uint256 adapterAssets) {
                liquid += adapterAssets;
            } catch {}
        }

        return Math.min(vaultClaim, liquid);
    }
}
