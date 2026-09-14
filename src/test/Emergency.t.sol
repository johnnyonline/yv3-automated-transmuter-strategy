// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface, ITransmuter} from "./utils/Setup.sol";

contract EmergencyTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    // Force-claim an immature position: the transmuted part pays MYT, the rest
    // comes back as alAsset minus the 1% exit fee
    function test_manualClaim_immature(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 bought = buyAndTransmute(_amount);

        // 10% of the way to maturity
        vm.roll(block.number + timeToTransmute / 10);

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.manualClaim(0);

        vm.prank(management);
        strategy.manualClaim(0);
        assertEq(strategy.positionCount(), 0);

        // 90% back as alAsset, minus the exit fee
        uint256 untransmuted = bought * 9 / 10;
        uint256 expectedAlAsset = untransmuted - untransmuted * transmuter.exitFee() / MAX_BPS;
        assertApproxEq(alAsset.balanceOf(address(strategy)), expectedAlAsset, expectedAlAsset / 1000, "!alAsset");

        // 10% as MYT
        uint256 mytValue = myt.convertToAssets(myt.balanceOf(address(strategy)));
        assertApproxEq(mytValue, bought / 10 / 1e12, bought / 10 / 1e12 / 100, "!myt");

        // The returned alAsset is transmuted again on the next tend
        assertTrue(tendTrigger());
        tend();
        assertEq(strategy.positionCount(), 1);
    }

    function test_manualClaim_matured_and_manualRedeemMYT(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 bought = buyAndTransmute(_amount);
        mature();

        vm.prank(emergencyAdmin);
        strategy.manualClaim(0);
        assertEq(strategy.positionCount(), 0);
        // The transmuter hands back dust alAsset even at full maturity
        assertLt(alAsset.balanceOf(address(strategy)), 1e18, "alAsset dust only");

        uint256 shares = myt.balanceOf(address(strategy));
        assertApproxEq(myt.convertToAssets(shares), bought / 1e12, bought / 1e12 / 1000, "!myt");

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.manualRedeemMYT(shares);

        vm.prank(management);
        strategy.manualRedeemMYT(shares);
        assertEq(myt.balanceOf(address(strategy)), 0);
        assertApproxEq(asset.balanceOf(address(strategy)), bought / 1e12, bought / 1e12 / 1000, "!asset");
    }

    // Sell alAsset back for asset through the alAsset auction
    function test_kickAlAssetAuction(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();
        uint256 bought = take();

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.kickAlAssetAuction(bought, 1e18, 0.95e18);

        vm.startPrank(management);
        vm.expectRevert("!price");
        strategy.kickAlAssetAuction(bought, 1e18, 0);
        vm.expectRevert("!price");
        strategy.kickAlAssetAuction(bought, 0.95e18, 0.95e18);

        // Sell at par, floor at 0.95 asset per alAsset
        strategy.kickAlAssetAuction(bought, 1e18, 0.95e18);
        vm.stopPrank();

        assertEq(alAsset.balanceOf(address(strategy)), 0);
        assertEq(alAsset.balanceOf(address(alAssetAuction)), bought);
        assertTrue(alAssetAuction.isActive(address(alAsset)));
        assertEq(alAssetAuction.minimumPrice(), 0.95e18);
        // Quoted in asset units per one alAsset
        assertApproxEq(alAssetAuction.price(address(alAsset)), 1e6, 1, "!opening price");

        // Still fully accounted for while on sale
        assertApproxEq(strategy.estimatedTotalAssets(), bought * 1e18 / 1.1e18 / 1e12, 1, "!eta");

        // A taker pays asset for the lot
        uint256 needed = alAssetAuction.getAmountNeeded(address(alAsset));
        assertApproxEq(needed, bought / 1e12, 1, "!needed");
        airdrop(asset, taker, needed);
        vm.startPrank(taker);
        asset.approve(address(alAssetAuction), needed);
        alAssetAuction.take(address(alAsset));
        vm.stopPrank();

        assertEq(asset.balanceOf(address(strategy)), needed);
        assertEq(alAsset.balanceOf(address(alAssetAuction)), 0);
        assertFalse(alAssetAuction.isActive(address(alAsset)));

        // Sold at par: booked as profit against the floor carrying price
        (uint256 profit,) = report();
        assertGt(profit, 0);
    }

    function test_sweepAuction(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Abort a live asset auction
        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();
        assertTrue(assetAuction.isActive(address(asset)));

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.sweepAuction(false);

        vm.prank(management);
        strategy.sweepAuction(false);
        assertEq(asset.balanceOf(address(strategy)), _amount);
        assertEq(asset.balanceOf(address(assetAuction)), 0);
        assertFalse(assetAuction.isActive(address(asset)));

        // Can be kicked again right away
        (bool shouldKick,) = strategy.auctionTrigger(address(asset));
        assertTrue(shouldKick);
        kick();
        uint256 bought = take();

        // Abort a live alAsset auction
        vm.prank(management);
        strategy.kickAlAssetAuction(bought, 1e18, 0.95e18);
        assertTrue(alAssetAuction.isActive(address(alAsset)));

        vm.prank(emergencyAdmin);
        strategy.sweepAuction(true);
        assertEq(alAsset.balanceOf(address(strategy)), bought);
        assertEq(alAsset.balanceOf(address(alAssetAuction)), 0);
        assertFalse(alAssetAuction.isActive(address(alAsset)));

        // Nothing to sweep is fine too
        vm.prank(management);
        strategy.sweepAuction(true);
    }

}
