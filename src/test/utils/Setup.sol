// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.21;

import "forge-std/console2.sol";
import "../../../script/Deploy.s.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {AutomatedTransmuterStrategy as Strategy, ERC20} from "../../Strategy.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {ITransmuter} from "../../interfaces/alchemix/ITransmuter.sol";
import {IMYT} from "../../interfaces/alchemix/IMYT.sol";
import {Auction} from "@periphery/Auctions/Auction.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {

    function governance() external view returns (address);

    function set_protocol_fee_bps(
        uint16
    ) external;

    function set_protocol_fee_recipient(
        address
    ) external;

}

contract Setup is Deploy, ExtendedTest, IEvents {

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    ERC20 public alAsset;
    IStrategyInterface public strategy;
    ITransmuter public transmuter;
    IMYT public myt;
    Auction public assetAuction;
    Auction public alAssetAuction;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);
    address public taker = address(6);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;
    uint256 public WAD = 1e18;

    // Blocks until a transmuter position matures
    uint256 public timeToTransmute;

    // Fuzz from 1k USDC up to 100k USDC. The transmuter has ~350k alUSD of headroom at the fork block
    uint256 public maxFuzzAmount = 100_000e6;
    uint256 public minFuzzAmount = 1_000e6;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        uint256 _blockNumber = 25_969_940; // Caching for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDC"]);
        alAsset = ERC20(tokenAddrs["alUSD"]);

        // Set decimals
        decimals = asset.decimals();

        // Set script vars
        s_asset = address(asset);
        s_alAsset = address(alAsset);
        s_transmuter = ALUSD_TRANSMUTER;
        s_management = management;
        s_performanceFeeRecipient = performanceFeeRecipient;
        s_keeper = keeper;
        s_emergencyAdmin = emergencyAdmin;
        s_minRedemptionAmount = 100e18;

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();
        transmuter = ITransmuter(strategy.TRANSMUTER());
        myt = IMYT(strategy.MYT());
        assetAuction = Auction(strategy.ASSET_AUCTION());
        alAssetAuction = Auction(strategy.AL_ASSET_AUCTION());
        timeToTransmute = transmuter.timeToTransmute();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(address(alAsset), "alAsset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(address(transmuter), "transmuter");
        vm.label(address(myt), "myt");
        vm.label(address(assetAuction), "assetAuction");
        vm.label(address(alAssetAuction), "alAssetAuction");
    }

    function setUpStrategy() public returns (address) {
        // notify deplyment script that this is a test
        isTest = true;
        // deploy and initialize contracts
        run();
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = s_newStrategy;

        vm.startPrank(management);
        _strategy.acceptManagement();
        // Deposits are whitelisted until opened
        _strategy.setOpen(true);
        // Kicks are blocked until the auction amounts are set
        _strategy.setAuctionAmounts(1e6, type(uint96).max);
        // Exact accounting in tests. `test_profitableReport_withFees` sets its own fee
        _strategy.setPerformanceFee(0);
        // Allow dust losses from MYT vault rounding on redeem
        _strategy.setLossLimitRatio(10);
        vm.stopPrank();

        return address(_strategy);
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(
        ERC20 _asset,
        address _to,
        uint256 _amount
    ) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(
        uint16 _protocolFee,
        uint16 _performanceFee
    ) public {
        address _gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(_gov);
        IFactory(factory).set_protocol_fee_recipient(_gov);

        vm.prank(_gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    // ===============================================================
    // Strategy flow helpers
    // ===============================================================

    // Keeper kicks the asset auction
    function kick() public {
        vm.prank(keeper);
        strategy.kickAuction(address(asset));
    }

    // Taker buys the whole lot at the current price, paying alAsset to the strategy
    function take() public returns (uint256 _paid) {
        return take(type(uint256).max);
    }

    // Taker buys up to `_maxAmount` of the lot at the current price
    function take(
        uint256 _maxAmount
    ) public returns (uint256 _paid) {
        uint256 _available = assetAuction.available(address(asset));
        uint256 _amount = _maxAmount < _available ? _maxAmount : _available;
        _paid = assetAuction.getAmountNeeded(address(asset), _amount);
        airdrop(alAsset, taker, _paid);
        vm.startPrank(taker);
        alAsset.approve(address(assetAuction), _paid);
        assetAuction.take(address(asset), _amount);
        vm.stopPrank();
    }

    // Keeper tends: sweeps, claims, redeems MYT, transmutes
    function tend() public {
        vm.prank(keeper);
        strategy.tend();
    }

    // TokenizedStrategy returns (bool, bytes), tests only care about the bool
    function tendTrigger() public view returns (bool _trigger) {
        (_trigger,) = strategy.tendTrigger();
    }

    function report() public returns (uint256 _profit, uint256 _loss) {
        vm.prank(keeper);
        return strategy.report();
    }

    // Deposit, kick, get fully taken, and stake the alAsset in one position
    function buyAndTransmute(
        uint256 _amount
    ) public returns (uint256 _alAssetBought) {
        mintAndDepositIntoStrategy(strategy, user, _amount);
        kick();
        _alAssetBought = take();
        tend();
    }

    // Move past every open position's maturation
    function mature() public {
        vm.roll(block.number + timeToTransmute);
        skip(timeToTransmute * 12);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        tokenAddrs["alUSD"] = 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9;
    }

}
