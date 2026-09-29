// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IMYT} from "./alchemix/IMYT.sol";

interface IMYTLimits {

    function MYT() external view returns (IMYT);
    function availableLiquidity() external view returns (uint256);

}
