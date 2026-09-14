// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract ShutdownTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        skip(1 days);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        report();

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        skip(1 days);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    // Shutdown stops buying alAsset but not converting it back
    function test_shutdown_windsDown(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Buy alAsset, then shut down before it is staked
        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();
        uint256 bought = take();
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // No more kicks, even once the cooldown is over
        skip(1 days);
        (bool shouldKick,) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);
        vm.expectRevert("!kickable");
        vm.prank(keeper);
        strategy.kickAuction(address(asset));

        // Transmuting still runs
        assertTrue(tendTrigger());
        tend();
        assertEq(strategy.positionCount(), 1);

        // Emergency withdraw claims once matured
        mature();
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);
        assertEq(strategy.positionCount(), 0);
        assertApproxEq(asset.balanceOf(address(strategy)), _amount + bought / 1e12, bought / 1e12 / 1000, "!idle");

        report();
        skip(profitMaxUnlockTime);

        uint256 balanceBefore = asset.balanceOf(user);
        uint256 maxShares = strategy.maxRedeem(user);
        vm.prank(user);
        strategy.redeem(maxShares, user, user);
        assertGt(asset.balanceOf(user), balanceBefore + 2 * _amount, "!final balance");
    }

    // A live auction can be aborted after shutdown and the lot withdrawn
    function test_shutdown_abortAuction(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(emergencyAdmin);
        strategy.sweepAuction(false);
        assertEq(asset.balanceOf(address(strategy)), _amount);
        assertFalse(assetAuction.isActive(address(asset)));

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        assertEq(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_sweep(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        ERC20 stuck = ERC20(tokenAddrs["DAI"]);
        airdrop(asset, address(strategy), _amount);
        airdrop(alAsset, address(strategy), _amount);
        airdrop(stuck, address(strategy), _amount);

        vm.expectRevert("!management");
        vm.prank(user);
        strategy.sweep(address(stuck));

        // Sweep stuck token
        uint256 beforeBalance = stuck.balanceOf(management);
        vm.prank(management);
        strategy.sweep(address(stuck));
        assertEq(stuck.balanceOf(management), beforeBalance + _amount, "stuck swept");

        // Can't sweep strategy funds
        vm.startPrank(management);
        vm.expectRevert("!asset");
        strategy.sweep(address(asset));
        vm.expectRevert("!alAsset");
        strategy.sweep(address(alAsset));
        vm.expectRevert(bytes("!myt"));
        strategy.sweep(address(myt));
        vm.stopPrank();
    }

}
