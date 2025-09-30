// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface ISushiBar is IERC20 {
    function enter(uint256 _amount) external;
    function leave(uint256 _share) external;
    function sushi() external view returns (IERC20);
}
