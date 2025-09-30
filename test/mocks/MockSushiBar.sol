// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/interfaces/ISushiBar.sol";

contract MockSushiBar is ERC20("SushiBar", "xSUSHI"), ISushiBar {
    IERC20 public immutable sushi;

    constructor(IERC20 _sushi) {
        sushi = _sushi;
    }

    // Enter the bar. Pay some SUSHIs. Earn some shares.
    function enter(uint256 _amount) external {
        uint256 totalSushi = sushi.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        if (totalShares == 0 || totalSushi == 0) {
            _mint(msg.sender, _amount);
        } else {
            uint256 what = (_amount * totalShares) / totalSushi;
            _mint(msg.sender, what);
        }
        require(sushi.transferFrom(msg.sender, address(this), _amount), "transferFrom failed");
    }

    // Leave the bar. Claim back your SUSHIs.
    function leave(uint256 _share) external {
        uint256 totalShares = totalSupply();
        uint256 what = (_share * sushi.balanceOf(address(this))) / totalShares;
        _burn(msg.sender, _share);
        require(sushi.transfer(msg.sender, what), "transfer failed");
    }
}
