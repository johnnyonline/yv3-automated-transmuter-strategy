// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "forge-std/Script.sol";

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";
import {AutomatedTransmuterStrategy as Strategy} from "../src/Strategy.sol";

// ---- Usage ----

// deploy:
// forge script script/Deploy.s.sol:Deploy --verify -g 250 --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract Deploy is Script {

    bool public isTest;
    address public s_asset;
    address public s_alAsset;
    address public s_transmuter;
    address public s_management;
    address public s_performanceFeeRecipient;
    address public s_keeper;
    address public s_emergencyAdmin;
    IStrategyInterface public s_newStrategy;

    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // SMS mainnet
    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // SMS mainnet accountant
    address public constant DEPLOYER = 0x285E3b1E82f74A99D07D2aD25e159E75382bB43B; // johnnyonline.eth
    address public constant YHAAS = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHAAS

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant ALUSD = 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9;
    address public constant ALUSD_TRANSMUTER = 0x2584E8b0616b3E750492c9629a3b27679C410cb9;

    function run() public {
        uint256 _pk = isTest ? 42069 : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_pk);

        if (!isTest) {
            require(_deployer == DEPLOYER, "!deployer");

            s_asset = USDC;
            s_alAsset = ALUSD;
            s_transmuter = ALUSD_TRANSMUTER;
            s_management = SMS;
            s_performanceFeeRecipient = ACCOUNTANT;
            s_keeper = YHAAS;
            s_emergencyAdmin = SMS;
        }

        string memory _name = "Alchemix alUSD Automated Transmuter";

        vm.startBroadcast(_pk);

        // deploy
        s_newStrategy = IStrategyInterface(address(new Strategy(s_asset, _name, s_alAsset, s_transmuter)));

        // init
        s_newStrategy.setPerformanceFeeRecipient(s_performanceFeeRecipient);
        s_newStrategy.setKeeper(s_keeper);
        s_newStrategy.setPendingManagement(s_management);
        s_newStrategy.setEmergencyAdmin(s_emergencyAdmin);

        vm.stopBroadcast();

        if (!isTest) console.log("Strategy address: %s", address(s_newStrategy));
    }

}
