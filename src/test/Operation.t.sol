// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface, ITransmuter, Strategy} from "./utils/Setup.sol";
import {IMYTStrategy} from "../interfaces/alchemix/IMYTStrategy.sol";

contract OperationTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertEq(strategy.emergencyAdmin(), emergencyAdmin);

        // Alchemix wiring
        assertEq(strategy.AL_ASSET(), address(alAsset));
        assertEq(strategy.TRANSMUTER(), address(transmuter));
        assertEq(strategy.ALCHEMIST(), transmuter.alchemist());
        assertEq(strategy.MYT(), address(myt));
        assertEq(strategy.AL_TO_ASSET_SCALER(), 1e12);
        assertEq(strategy.ASSET_UNIT(), 1e6);
        assertEq(alAsset.allowance(address(strategy), address(transmuter)), type(uint256).max);

        // Both auctions pay the strategy and are governed by it
        assertEq(assetAuction.want(), address(alAsset));
        assertEq(assetAuction.receiver(), address(strategy));
        assertEq(assetAuction.governance(), address(strategy));
        assertTrue(assetAuction.governanceOnlyKick());
        assertEq(assetAuction.stepDecayRate(), 1);
        assertEq(assetAuction.stepDuration(), 3 minutes);
        assertEq(alAssetAuction.want(), address(asset));
        assertEq(alAssetAuction.receiver(), address(strategy));
        assertEq(alAssetAuction.governance(), address(strategy));
        assertTrue(alAssetAuction.governanceOnlyKick());

        // Defaults
        assertEq(strategy.maxPositions(), 7);
        assertEq(strategy.kickCooldown(), 1 days);
        assertEq(strategy.maxTendBasefee(), 30 gwei);
        assertEq(strategy.minimumPrice(), 1.1e18);
        assertEq(strategy.startingPricePerUnit(), 1.15e18);
        assertEq(strategy.positionCount(), 0);
        assertEq(strategy.estimatedTotalAssets(), 0);
    }

    // Deposit and withdraw with nothing auctioned. Everything stays idle
    function test_operation_idle(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        checkStrategyTotals(strategy, _amount, 0, _amount);
        assertEq(strategy.estimatedTotalAssets(), _amount);

        skip(1 days);

        (uint256 profit, uint256 loss) = report();
        assertEq(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertEq(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    // Full cycle: deposit -> kick -> fill -> transmute -> mature -> claim -> withdraw with profit
    function test_operation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Kick: the whole lot leaves for the auction, accounting still counts it
        (bool shouldKick,) = strategy.auctionTrigger(address(asset));
        assertTrue(shouldKick, "!trigger");
        kick();
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(assetAuction)), _amount);
        assertEq(assetAuction.available(address(asset)), _amount);
        assertTrue(assetAuction.isActive(address(asset)));
        assertEq(strategy.estimatedTotalAssets(), _amount);
        assertEq(strategy.availableWithdrawLimit(user), 0, "live lot not withdrawable");

        // Fill at the opening price: 1.15 alUSD per USDC
        uint256 bought = take();
        assertEq(bought, _amount * 1.15e18 / 1e6, "!bought");
        assertEq(alAsset.balanceOf(address(strategy)), bought);
        assertEq(asset.balanceOf(address(assetAuction)), 0);
        assertFalse(assetAuction.isActive(address(asset)), "settled on full take");

        // alAsset is carried at 1 / floor, so the fill above the floor is booked now
        uint256 expected = bought * 1e18 / 1.1e18 / 1e12;
        assertApproxEq(strategy.estimatedTotalAssets(), expected, 1, "!eta after fill");
        (uint256 profit, uint256 loss) = report();
        assertApproxEq(profit, expected - _amount, 1, "!fill profit");
        assertEq(loss, 0);

        // Transmute
        assertTrue(tendTrigger(), "!tendTrigger");
        tend();
        assertEq(strategy.positionCount(), 1);
        assertEq(alAsset.balanceOf(address(strategy)), 0);
        (uint128 id, uint128 price) = strategy.positions(0);
        assertEq(price, uint256(1e36) / 1.1e18, "!position price");
        ITransmuter.StakingPosition memory position = transmuter.getPosition(id);
        assertEq(position.amount, bought);
        assertEq(position.maturationBlock, block.number + timeToTransmute);
        assertApproxEq(strategy.estimatedTotalAssets(), expected, 1, "!eta after transmute");
        assertFalse(tendTrigger());

        // Mature: the rest of the gain accreted to par (fee is 0)
        mature();
        uint256 par = bought / 1e12;
        assertApproxEq(strategy.estimatedTotalAssets(), par, 1, "!eta matured");
        assertTrue(tendTrigger(), "!tendTrigger matured");

        // Claim and redeem MYT back to asset
        tend();
        assertEq(strategy.positionCount(), 0);
        assertApproxEq(asset.balanceOf(address(strategy)), par, par / 1000, "!claimed");
        assertLt(myt.convertToAssets(myt.balanceOf(address(strategy))), 10, "MYT dust only");

        (profit, loss) = report();
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        skip(profitMaxUnlockTime);

        // Withdraw everything with the gain. Priced-in alAsset dust keeps the
        // last share locked, so go by the limit
        uint256 maxShares = strategy.maxRedeem(user);
        assertApproxEq(maxShares, _amount, 1, "!maxRedeem");
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(maxShares, user, user);
        assertApproxEq(asset.balanceOf(user), balanceBefore + par, par / 1000, "!final balance");
    }

    // The lot is priced by the auction, not the strategy: a later fill pays less
    function test_operation_fillNearFloor(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();

        // 20 hours in the price is ~1.105, just above the 1.1 floor
        skip(20 hours);
        assertTrue(assetAuction.isActive(address(asset)));
        uint256 price = assetAuction.price(address(asset));
        assertGt(price, 1.1e18);
        assertLt(price, 1.11e18);

        uint256 bought = take();
        assertApproxEq(bought, _amount * price / 1e6, _amount, "!bought");

        // Almost nothing booked at fill
        (uint256 profit,) = report();
        assertLt(profit, _amount / 100, "!small fill profit");

        tend();
        mature();
        tend();
        assertApproxEq(strategy.estimatedTotalAssets(), bought / 1e12, bought / 1e12 / 1000, "!matured");
    }

    // Untransmuted alAsset accretes linearly from the floor price to par
    function test_estimatedTotalAssets_accretes(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 bought = buyAndTransmute(_amount);
        uint256 start = strategy.estimatedTotalAssets();
        uint256 par = bought / 1e12;
        assertLt(start, par);

        vm.roll(block.number + timeToTransmute / 2);
        uint256 mid = strategy.estimatedTotalAssets();
        assertApproxEq(mid, (start + par) / 2, par / 10_000, "!mid");

        vm.roll(block.number + timeToTransmute / 2);
        assertApproxEq(strategy.estimatedTotalAssets(), par, 1, "!par");

        // Never above par with a 0 fee
        vm.roll(block.number + timeToTransmute);
        assertApproxEq(strategy.estimatedTotalAssets(), par, 1, "!still par");
    }

    function test_profitableReport_withFees(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        uint256 bought = buyAndTransmute(_amount);
        mature();
        tend();

        (uint256 profit, uint256 loss) = report();
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;
        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        skip(profitMaxUnlockTime);

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        assertGt(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // Idle alAsset dust is priced in but not withdrawable, so go by the limit
        uint256 maxShares = strategy.maxRedeem(performanceFeeRecipient);
        assertApproxEq(maxShares, expectedShares, 1, "!maxRedeem");
        vm.prank(performanceFeeRecipient);
        strategy.redeem(maxShares, performanceFeeRecipient, performanceFeeRecipient);
        assertGe(asset.balanceOf(performanceFeeRecipient), maxShares, "!perf fee out");

        // Everything paid out
        assertLt(strategy.totalAssets(), bought / 1e12 / 1000, "!dust");
    }

    // A live auction locks its lot. Once it ends unsold it is withdrawable again
    function test_withdraw_aroundAuction(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();

        assertEq(strategy.availableWithdrawLimit(user), 0);
        assertEq(strategy.maxRedeem(user), 0);
        vm.expectRevert("ERC4626: redeem more than max");
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Auction decays below the floor and ends unsold
        skip(1 days);
        assertFalse(assetAuction.isActive(address(asset)));
        assertEq(strategy.availableWithdrawLimit(user), _amount);
        assertEq(strategy.estimatedTotalAssets(), _amount);

        // Withdraw sweeps the lot back
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        assertEq(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
        assertEq(asset.balanceOf(address(assetAuction)), 0);
    }

    // Withdrawing while positions are immature only pays idle asset
    function test_withdraw_immaturePositionsLocked(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        buyAndTransmute(_amount);
        assertEq(strategy.availableWithdrawLimit(user), 0);
        assertEq(strategy.maxWithdraw(user), 0);

        // Matured positions count, and a withdrawal claims them
        mature();
        uint256 limit = strategy.availableWithdrawLimit(user);
        assertGt(limit, _amount, "!matured limit");

        // The gain is not reported yet, so shares are still worth par
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        assertEq(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
        assertEq(strategy.positionCount(), 0);
        assertGt(asset.balanceOf(address(strategy)), 0, "!unreported gain");
    }

    // Partial fills: the sold part becomes a position, the unsold lot rejoins idle
    function test_partialFill(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();

        uint256 half = _amount / 2;
        uint256 bought = take(half);
        assertEq(asset.balanceOf(address(assetAuction)), _amount - half);
        assertTrue(assetAuction.isActive(address(asset)), "still live");

        // Can't transmute while the auction is live
        assertFalse(tendTrigger());
        tend();
        assertEq(strategy.positionCount(), 0);

        // Auction ends: transmute the fill, the unsold lot is swept back
        skip(1 days);
        assertTrue(tendTrigger());
        tend();
        assertEq(strategy.positionCount(), 1);
        assertEq(asset.balanceOf(address(strategy)), _amount - half);
        assertEq(asset.balanceOf(address(assetAuction)), 0);
        (uint128 id,) = strategy.positions(0);
        assertEq(transmuter.getPosition(id).amount, bought);

        // The leftover can be kicked again once the cooldown passed
        (bool shouldKick,) = strategy.auctionTrigger(address(asset));
        assertTrue(shouldKick);
        kick();
        assertEq(assetAuction.available(address(asset)), _amount - half);
    }

    function test_auctionTrigger(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Nothing to sell
        (bool shouldKick, bytes memory data) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);
        assertEq(data, bytes("0 kickable"));

        // Wrong token
        (shouldKick, data) = strategy.auctionTrigger(address(alAsset));
        assertFalse(shouldKick);
        assertEq(data, bytes("!asset"));

        mintAndDepositIntoStrategy(strategy, user, _amount);
        (shouldKick, data) = strategy.auctionTrigger(address(asset));
        assertTrue(shouldKick);
        assertEq(data, abi.encodeCall(strategy.kickAuction, (address(asset))));

        // Base fee too high
        vm.fee(31 gwei);
        (shouldKick, data) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);
        assertEq(data, bytes("basefee"));
        vm.fee(1 gwei);

        // Below the min
        vm.prank(management);
        strategy.setAuctionAmounts(uint96(_amount + 1), type(uint96).max);
        (shouldKick,) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);
        vm.prank(management);
        strategy.setAuctionAmounts(1e6, type(uint96).max);

        // Ladder full
        vm.prank(management);
        strategy.setMaxPositions(0);
        (shouldKick,) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);
        vm.prank(management);
        strategy.setMaxPositions(7);

        // Live auction
        kick();
        (shouldKick,) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);
        vm.expectRevert("!kickable");
        vm.prank(keeper);
        strategy.kickAuction(address(asset));

        // Ended unsold, but cooling down
        skip(23 hours);
        assertFalse(assetAuction.isActive(address(asset)));
        (shouldKick,) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);

        // Cooldown over
        skip(1 hours);
        (shouldKick,) = strategy.auctionTrigger(address(asset));
        assertTrue(shouldKick);

        // A full take resets the cooldown, so new idle asset can be kicked right away
        kick();
        take();
        mintAndDepositIntoStrategy(strategy, user, _amount);
        (shouldKick,) = strategy.auctionTrigger(address(asset));
        assertTrue(shouldKick);

        // Shutdown blocks kicks
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();
        (shouldKick,) = strategy.auctionTrigger(address(asset));
        assertFalse(shouldKick);
    }

    function test_kickAuction_capsAtMax(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 max = _amount / 3;
        vm.prank(management);
        strategy.setAuctionAmounts(1e6, uint96(max));

        vm.prank(keeper);
        uint256 kicked = strategy.kickAuction(address(asset));
        assertEq(kicked, max);
        assertEq(asset.balanceOf(address(assetAuction)), max);
        assertEq(asset.balanceOf(address(strategy)), _amount - max);

        // Lot pricing: opening price is per unit, floor is what we set
        assertEq(assetAuction.minimumPrice(), 1.1e18);
        assertApproxEq(assetAuction.price(address(asset)), 1.15e18, 1e12, "!opening price");
    }

    function test_kickAuction_wrongCaller(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.expectRevert("!keeper");
        vm.prank(user);
        strategy.kickAuction(address(asset));

        vm.expectRevert("!asset");
        vm.prank(keeper);
        strategy.kickAuction(address(alAsset));
    }

    function test_tendTrigger(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        assertFalse(tendTrigger());

        // Idle asset alone doesn't tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertFalse(tendTrigger());

        // Live auction
        kick();
        assertFalse(tendTrigger());

        // Filled: alAsset to transmute
        take();
        assertTrue(tendTrigger());

        // Base fee too high
        vm.fee(31 gwei);
        assertFalse(tendTrigger());
        vm.fee(1 gwei);

        // Below the min redemption
        vm.prank(management);
        strategy.setMinRedemptionAmount(type(uint96).max);
        assertFalse(tendTrigger());
        vm.prank(management);
        strategy.setMinRedemptionAmount(0);

        tend();
        assertFalse(tendTrigger());

        // Matured position
        mature();
        assertTrue(tendTrigger());
        tend();
        assertFalse(tendTrigger());
    }

    function test_availableDepositLimit(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 limit = strategy.availableDepositLimit(user);
        assertGt(limit, maxFuzzAmount, "!headroom");
        assertEq(strategy.maxDeposit(user), limit);

        // Can't deposit more than the transmuter can absorb
        airdrop(asset, user, limit + 1);
        vm.prank(user);
        asset.approve(address(strategy), limit + 1);
        vm.expectRevert("ERC4626: deposit more than max");
        vm.prank(user);
        strategy.deposit(limit + 1, user);

        // Idle asset counts against the room
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.availableDepositLimit(user), limit - _amount);

        // So does asset in the auction, and alAsset after a fill
        kick();
        assertEq(strategy.availableDepositLimit(user), limit - _amount);
        uint256 bought = take();
        assertEq(strategy.availableDepositLimit(user), limit - bought / 1e12);
    }

    // Positions keep the floor price they were opened at
    function test_positionPriceIsFrozen(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        buyAndTransmute(_amount);
        uint256 before = strategy.estimatedTotalAssets();

        vm.prank(management);
        strategy.setAuctionPrices(1.3e18, 1.2e18);

        (, uint128 price) = strategy.positions(0);
        assertEq(price, uint256(1e36) / 1.1e18);
        assertEq(strategy.estimatedTotalAssets(), before, "re-marked");
    }

    // Ladder full: idle alAsset waits and the immature position is left alone
    function test_tend_ladderFull(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        buyAndTransmute(_amount);

        // Second lot fills once the kick cooldown is over
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        kick();
        uint256 bought = take();

        vm.prank(management);
        strategy.setMaxPositions(1);
        assertFalse(tendTrigger(), "ladder full");
        tend();
        assertEq(strategy.positionCount(), 1);
        assertEq(alAsset.balanceOf(address(strategy)), bought);

        vm.prank(management);
        strategy.setMaxPositions(2);
        assertTrue(tendTrigger(), "!tendTrigger");
        tend();
        assertEq(strategy.positionCount(), 2);
        assertEq(alAsset.balanceOf(address(strategy)), 0);
    }

    // MYT transfer gates zero out the vault's share of the withdraw limit
    function test_availableWithdrawLimit_mytGates(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        buyAndTransmute(_amount);
        mature();
        assertGt(strategy.availableWithdrawLimit(user), 0);

        vm.mockCall(
            address(myt), abi.encodeWithSelector(myt.canSendShares.selector, address(strategy)), abi.encode(false)
        );
        assertEq(strategy.availableWithdrawLimit(user), 0, "!canSendShares");
        vm.clearMockedCalls();

        vm.mockCall(
            address(myt), abi.encodeWithSelector(myt.canReceiveAssets.selector, address(strategy)), abi.encode(false)
        );
        assertEq(strategy.availableWithdrawLimit(user), 0, "!canReceiveAssets");
    }

    // A liquidity adapter without `vault()` counts all of its assets instead
    function test_availableWithdrawLimit_adapterFallback(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        buyAndTransmute(_amount);
        mature();
        uint256 limit = strategy.availableWithdrawLimit(user);
        assertGt(limit, 0);

        address adapter = myt.liquidityAdapter();
        vm.mockCallRevert(adapter, abi.encodeWithSelector(IMYTStrategy.vault.selector), "");
        assertEq(strategy.availableWithdrawLimit(user), limit, "!fallback");

        vm.mockCall(adapter, abi.encodeWithSelector(IMYTStrategy.realAssets.selector), abi.encode(1e6));
        assertEq(strategy.availableWithdrawLimit(user), asset.balanceOf(address(myt)) + 1e6, "!realAssets");
    }

    function test_constructor_sanityChecks() public {
        vm.expectRevert("!alAsset");
        new Strategy(address(asset), "Strategy", address(asset), address(transmuter));

        vm.expectRevert("!underlying");
        new Strategy(address(alAsset), "Strategy", address(alAsset), address(transmuter));
    }

    function test_setters() public {
        vm.startPrank(management);
        strategy.setMaxPositions(3);
        assertEq(strategy.maxPositions(), 3);
        strategy.setMinRedemptionAmount(5e18);
        assertEq(strategy.minRedemptionAmount(), 5e18);
        strategy.setAuctionAmounts(2e6, 3e6);
        assertEq(strategy.minAuctionAmount(), 2e6);
        assertEq(strategy.maxAuctionAmount(), 3e6);
        strategy.setMaxTendBasefee(1 gwei);
        assertEq(strategy.maxTendBasefee(), 1 gwei);
        strategy.setKickCooldown(2 days);
        assertEq(strategy.kickCooldown(), 2 days);
        strategy.setAuctionPrices(1.2e18, 1.05e18);
        assertEq(strategy.startingPricePerUnit(), 1.2e18);
        assertEq(strategy.minimumPrice(), 1.05e18);
        strategy.setAuctionSteps(false, 5, 10 minutes);
        assertEq(assetAuction.stepDecayRate(), 5);
        assertEq(assetAuction.stepDuration(), 10 minutes);
        strategy.setAuctionSteps(true, 7, 20 minutes);
        assertEq(alAssetAuction.stepDecayRate(), 7);
        assertEq(alAssetAuction.stepDuration(), 20 minutes);

        // Invalid values
        vm.expectRevert("!range");
        strategy.setAuctionAmounts(3e6, 2e6);
        vm.expectRevert("!price");
        strategy.setAuctionPrices(1.2e18, 1e18);
        vm.expectRevert("!price");
        strategy.setAuctionPrices(1.05e18, 1.05e18);
        vm.stopPrank();
    }

    function test_setters_wrongCaller() public {
        vm.startPrank(user);
        vm.expectRevert("!management");
        strategy.setMaxPositions(3);
        vm.expectRevert("!management");
        strategy.setMinRedemptionAmount(1);
        vm.expectRevert("!management");
        strategy.setAuctionAmounts(1, 2);
        vm.expectRevert("!management");
        strategy.setMaxTendBasefee(1);
        vm.expectRevert("!management");
        strategy.setKickCooldown(1);
        vm.expectRevert("!management");
        strategy.setAuctionPrices(1.2e18, 1.1e18);
        vm.expectRevert("!management");
        strategy.setAuctionSteps(false, 1, 1);
        vm.stopPrank();
    }

}
