// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ISushiBar.sol";

/// @title Yojimbo — minimal SushiBar executor for RedSnwapper
/// @notice Assumes RedSnwapper has already moved tokenIn to this contract and will enforce amountOutMin.
contract Yojimbo {
  using SafeERC20 for IERC20;
  using SafeERC20 for ISushiBar;

  IERC20 public SUSHI;
  ISushiBar public xSUSHI;

  /// @notice Initializes the executor for a specific SushiBar and grants it max SUSHI allowance.
  /// @param _xSUSHI SushiBar contract the executor should interact with.
  constructor(ISushiBar _xSUSHI) {
    xSUSHI = _xSUSHI;
    SUSHI = xSUSHI.sushi();
    SUSHI.forceApprove(address(xSUSHI), type(uint256).max);
  }

  /// @notice Deposits SUSHI that already sits on this contract into the SushiBar and forwards the minted xSUSHI.
  /// @param amountIn Exact SUSHI amount to deposit; supply 0 to use the full SUSHI balance of this contract.
  /// @param recipient Address that should receive the freshly minted xSUSHI.
  function enterSushiBar(uint256 amountIn, address recipient) external {
    if (amountIn == 0) {
      amountIn = SUSHI.balanceOf(address(this));
    }

    xSUSHI.enter(amountIn);

    xSUSHI.safeTransfer(recipient, xSUSHI.balanceOf(address(this)));
  }

  /// @notice Burns xSUSHI held by this contract and transfers the redeemed SUSHI to the recipient.
  /// @param amountIn Exact xSUSHI amount to redeem; supply 0 to use the full xSUSHI balance of this contract.
  /// @param recipient Address that should receive the withdrawn SUSHI.
  function leaveSushiBar(uint256 amountIn, address recipient) external {
    if (amountIn == 0) {
      amountIn = xSUSHI.balanceOf(address(this));
    }

    xSUSHI.leave(amountIn);

    SUSHI.safeTransfer(recipient, SUSHI.balanceOf(address(this)));
  }

  /// @notice Quotes how many xSUSHI the SushiBar would mint for a prospective deposit.
  /// @param amountIn SUSHI amount to simulate depositing via {enterSushiBar}.
  /// @return amountOut Estimated xSUSHI that would be minted.
  function quoteEnterSushiBar(uint256 amountIn) external view returns (uint256 amountOut) {
    uint256 totalShares = xSUSHI.totalSupply();
    uint256 totalSushi = SUSHI.balanceOf(address(xSUSHI));

    if (totalShares == 0 || totalSushi == 0) {
      return amountIn;
    }

    return amountIn * totalShares / totalSushi;
  }

  /// @notice Quotes how much SUSHI the SushiBar would return for a prospective redemption.
  /// @param amountIn xSUSHI amount to simulate redeeming via {leaveSushiBar}.
  /// @return amountOut Estimated SUSHI that would be withdrawn.
  function quoteLeaveSushiBar(uint256 amountIn) external view returns (uint256 amountOut) {
    uint256 totalShares = xSUSHI.totalSupply();
    uint256 totalSushi = SUSHI.balanceOf(address(xSUSHI));

    if (totalShares == 0) {
      return 0;
    }

    return amountIn * totalSushi / totalShares;
  }
}
