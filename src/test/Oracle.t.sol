// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Setup, ITransmuter} from "./utils/Setup.sol";
import {IAlchemistV3} from "../interfaces/alchemix/IAlchemistV3.sol";

import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";

contract OracleTest is Setup {

    StrategyAprOracle public oracle;

    function setUp() public override {
        super.setUp();
        oracle = new StrategyAprOracle();
    }

    // APR of a position opened at the current floor
    function grossApr() public view returns (uint256) {
        uint256 par = WAD * (MAX_BPS - transmuter.transmutationFee()) / MAX_BPS;
        uint256 cycleReturn = strategy.minimumPrice() * par / WAD - WAD;
        return cycleReturn * 365 days / (timeToTransmute * 12);
    }

    function test_oracle(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Idle asset earns nothing
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(oracle.aprAfterDebtChange(address(strategy), 0), 0, "!idle");

        // Idle alAsset is priced as if opened at the floor
        kick();
        take();
        uint256 apr = oracle.aprAfterDebtChange(address(strategy), 0);
        assertApproxEq(apr, grossApr(), 1e12, "!idle alAsset");

        // Same once it is transmuting
        tend();
        apr = oracle.aprAfterDebtChange(address(strategy), 0);
        assertApproxEq(apr, grossApr(), 1e12, "!apr");
        assertGt(apr, 0, "ZERO");
        assertLt(apr, 1e18, "+100%");

        // Bad debt haircuts the gain and the total alike
        address alchemist = strategy.ALCHEMIST();
        uint256 issued = IAlchemistV3(alchemist).totalSyntheticsIssued();
        uint256 eta = strategy.estimatedTotalAssets();
        vm.mockCall(
            alchemist, abi.encodeWithSelector(IAlchemistV3.totalSyntheticsIssued.selector), abi.encode(issued * 10)
        );
        assertLt(strategy.estimatedTotalAssets(), eta, "!haircut");
        assertApproxEq(oracle.aprAfterDebtChange(address(strategy), 0), apr, 1e12, "!bad debt");
        vm.clearMockedCalls();

        // New idle asset dilutes
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertLt(oracle.aprAfterDebtChange(address(strategy), 0), apr, "!diluted");

        // A fee eating the whole discount means no yield
        vm.mockCall(
            address(transmuter), abi.encodeWithSelector(ITransmuter.transmutationFee.selector), abi.encode(1_000)
        );
        assertEq(oracle.aprAfterDebtChange(address(strategy), 0), 0, "!fee");
        vm.clearMockedCalls();

        // A matured position has nothing left to earn
        mature();
        assertEq(oracle.aprAfterDebtChange(address(strategy), 0), 0, "!matured");
    }

    // Each position earns from the floor it was opened at
    function test_oracle_positionPrices(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        buyAndTransmute(_amount);
        uint256 low = oracle.aprAfterDebtChange(address(strategy), 0);

        // Second position at a deeper discount
        vm.prank(management);
        strategy.setAuctionPrices(1.3e18, 1.2e18);
        skip(1 days);
        buyAndTransmute(_amount);
        uint256 high = grossApr();

        uint256 blended = oracle.aprAfterDebtChange(address(strategy), 0);
        assertGt(blended, low, "!above low");
        assertLt(blended, high, "!below high");
    }

}
