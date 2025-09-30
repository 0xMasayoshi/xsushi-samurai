// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ISushiBar.sol";

/// @title YojimboExecutor — minimal SushiBar executor for RedSnwapper
/// @notice Assumes RedSnwapper has already moved tokenIn to this contract and will enforce amountOutMin.
contract YojimboExecutor {
  using SafeERC20 for IERC20;
  using SafeERC20 for ISushiBar;

  IERC20 public SUSHI;
  ISushiBar public xSUSHI;

  constructor(ISushiBar _xSUSHI) {
    xSUSHI = _xSUSHI;
    SUSHI = xSUSHI.sushi();
    SUSHI.forceApprove(address(xSUSHI), type(uint256).max);
  }

  /// @notice Deposit SUSHI -> mint xSUSHI, send to recipient
  /// @param amountIn If 0, uses (SUSHI balance - 1)
  /// @param recipient Who receives xSUSHI
  function enterSushiBar(uint256 amountIn, address recipient) external {
    if (amountIn == 0) {
      uint256 bal = SUSHI.balanceOf(address(this));
      require(bal > 1, "no SUSHI");
      unchecked { amountIn = bal - 1; }
    }

    uint256 beforeShares = xSUSHI.balanceOf(address(this));
    xSUSHI.enter(amountIn);
    uint256 minted = xSUSHI.balanceOf(address(this)) - beforeShares;

    xSUSHI.safeTransfer(recipient, minted);
  }

  /// @notice Burn xSUSHI -> withdraw SUSHI, send to recipient
  /// @param amountIn If 0, uses (xSUSHI balance - 1)
  /// @param recipient Who receives SUSHI
  function leaveSushiBar(uint256 amountIn, address recipient) external {
    if (amountIn == 0) {
      uint256 bal = xSUSHI.balanceOf(address(this));
      require(bal > 1, "no xSUSHI");
      unchecked { amountIn = bal - 1; }
    }

    IERC20 SUSHI = xSUSHI.sushi();
    uint256 before = SUSHI.balanceOf(address(this));
    xSUSHI.leave(amountIn);
    uint256 received = SUSHI.balanceOf(address(this)) - before;

    SUSHI.safeTransfer(recipient, received);
  }
}
