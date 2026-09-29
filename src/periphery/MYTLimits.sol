// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMYT} from "../interfaces/alchemix/IMYT.sol";
import {IMYTStrategy} from "../interfaces/alchemix/IMYTStrategy.sol";
import {IMYTLimits} from "../interfaces/IMYTLimits.sol";

/// @notice Withdraw sizing for MYT, whose `maxRedeem` always returns 0
/// @dev Adapted from tapired/tokenized-morpho-vaultv2-lender `MorphoVaultV2Limits.sol`.
/// Exact for Alchemix's `ERC4626Strategy` adapter, 0 for any other. Replace through
/// the strategy's `setMYTLimits()` if the adapter changes
contract MYTLimits is IMYTLimits {

    /// @notice The MYT vault
    IMYT public immutable MYT;

    constructor(
        address _myt
    ) {
        MYT = IMYT(_myt);
    }

    /// @notice Assets MYT can pay out to the caller right now
    /// @return Amount of `asset`
    function availableLiquidity() external view returns (uint256) {
        // Transfer gates
        if (!MYT.canSendShares(msg.sender) || !MYT.canReceiveAssets(msg.sender)) return 0;

        // Idle asset in the vault
        uint256 _liquid = IERC20(MYT.asset()).balanceOf(address(MYT));

        // Plus what the liquidity adapter can pull from its underlying vault. The
        // allocator can switch adapters at any time, an unknown one counts as illiquid
        address _adapter = MYT.liquidityAdapter();
        if (_adapter != address(0)) {
            try IMYTStrategy(_adapter).vault() returns (address _underlying) {
                try IERC4626(_underlying).maxWithdraw(_adapter) returns (uint256 _max) {
                    _liquid += _max;
                } catch {}
            } catch {}
        }

        return _liquid;
    }

}
