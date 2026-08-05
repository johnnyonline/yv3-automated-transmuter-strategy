// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultV2Like {
    function asset() external view returns (address);
    function liquidityAdapter() external view returns (address);
    function totalAssets() external view returns (uint256);
    function absoluteCap(bytes32 id) external view returns (uint256);
    function relativeCap(bytes32 id) external view returns (uint256);
    function allocation(bytes32 id) external view returns (uint256);
    function canSendAssets(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);
    function canSendShares(address account) external view returns (bool);
    function canReceiveShares(address account) external view returns (bool);
}

interface IMYTStrategyLike {
    function killSwitch() external view returns (bool);
    function getCap() external view returns (uint256);
    function realAssets() external view returns (uint256);
}

/// @dev Assumes the vault's liquidityAdapter is a MYTStrategy (single id =
/// keccak256(abi.encode("this", adapter))). The adapter is queried via
/// IMYTStrategyLike for kill-switch, cap, and realAssets.
library MYTLimitsLib {
    uint256 internal constant WAD = 1e18;

    function availableDepositLimit(IVaultV2Like vault, address strategy) internal view returns (uint256) {
        if (!vault.canSendAssets(strategy)) return 0;
        if (!vault.canReceiveShares(strategy)) return 0;

        address adapter = vault.liquidityAdapter();
        if (adapter == address(0)) return type(uint256).max;

        if (IMYTStrategyLike(adapter).killSwitch()) return 0;

        bytes32 id = keccak256(abi.encode("this", adapter));
        uint256 limit = _capHeadroom(vault, id, vault.totalAssets());

        uint256 adapterCap = IMYTStrategyLike(adapter).getCap();
        if (adapterCap != 0) {
            uint256 adapterPosition = IMYTStrategyLike(adapter).realAssets();
            uint256 adapterHeadroom = adapterCap > adapterPosition ? adapterCap - adapterPosition : 0;
            limit = Math.min(limit, adapterHeadroom);
        }

        return limit;
    }

    function availableWithdrawLimit(IVaultV2Like vault, address strategy, uint256 vaultClaim)
        internal
        view
        returns (uint256)
    {
        if (vaultClaim == 0) return 0;
        if (!vault.canSendShares(strategy)) return 0;
        if (!vault.canReceiveAssets(strategy)) return 0;

        uint256 liquid = IERC20(vault.asset()).balanceOf(address(vault));

        address adapter = vault.liquidityAdapter();
        if (adapter != address(0)) {
            try IMYTStrategyLike(adapter).realAssets() returns (uint256 adapterAssets) {
                liquid += adapterAssets;
            } catch {}
        }

        return Math.min(vaultClaim, liquid);
    }

    function _capHeadroom(IVaultV2Like vault, bytes32 id, uint256 firstTotalAssets)
        private
        view
        returns (uint256)
    {
        uint256 absCap = vault.absoluteCap(id);
        uint256 currentAllocation = vault.allocation(id);

        if (absCap == 0 || currentAllocation >= absCap) return 0;

        uint256 limit = absCap - currentAllocation;
        uint256 relCap = vault.relativeCap(id);

        if (relCap != WAD) {
            uint256 relativeLimit = Math.mulDiv(firstTotalAssets, relCap, WAD);
            if (currentAllocation >= relativeLimit) return 0;
            limit = Math.min(limit, relativeLimit - currentAllocation);
        }

        return limit;
    }
}
