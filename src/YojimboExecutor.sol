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
  /// @param amountIn If 0, uses SUSHI balance
  /// @param recipient Who receives xSUSHI
  function enterSushiBar(uint256 amountIn, address recipient) external {
    if (amountIn == 0) {
      amountIn = SUSHI.balanceOf(address(this));
    }

    xSUSHI.enter(amountIn);

    xSUSHI.safeTransfer(recipient, xSUSHI.balanceOf(address(this)));
  }

  /// @notice Burn xSUSHI -> withdraw SUSHI, send to recipient
  /// @param amountIn If 0, uses xSUSHI balance
  /// @param recipient Who receives SUSHI
  function leaveSushiBar(uint256 amountIn, address recipient) external {
    if (amountIn == 0) {
      amountIn = xSUSHI.balanceOf(address(this));
    }

    xSUSHI.leave(amountIn);

    SUSHI.safeTransfer(recipient, SUSHI.balanceOf(address(this)));
  }
}
