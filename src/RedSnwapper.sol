// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RedSnwapper {
    using SafeERC20 for IERC20;
    using Utils for IERC20;

    SafeExecutor public immutable safeExecutor;

    constructor() {
        safeExecutor = new SafeExecutor();
    }

    // @notice Swaps tokens
    // @notice 1. Transfers amountIn of tokens tokenIn to executor
    // @notice 2. launches executor with executorData and value = msg.value
    // @notice 3. Checks that recipient's tokenOut balance was increased at least amountOutMin
    function snwap(
        IERC20 tokenIn,
        uint256 amountIn, // if amountIn == 0 then amountIn = tokenIn.balance(this) - 1
        address recipient,
        IERC20 tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256 amountOut) {
        uint256 initialOutputBalance = tokenOut.universalBalanceOf(recipient);

        if (address(tokenIn) != NATIVE_ADDRESS) {
            if (amountIn > 0) tokenIn.safeTransferFrom(msg.sender, executor, amountIn);
            else tokenIn.safeTransfer(executor, tokenIn.balanceOf(address(this)) - 1); // -1 is slot undrain protection
        }

        safeExecutor.execute{value: msg.value}(executor, executorData);

        amountOut = tokenOut.universalBalanceOf(recipient) - initialOutputBalance;
        if (amountOut < amountOutMin) {
            revert MinimalOutputBalanceViolation(address(tokenOut), amountOut);
        }
    }

    // @notice Swaps multiple tokens
    // @notice 1. Transfers inputTokens to inputTokens[i].transferTo
    // @notice 2. launches executors
    // @notice 3. Checks that recipient's tokenOut balance was increased at least amountOutMin
    function snwapMultiple(
        InputToken[] calldata inputTokens,
        OutputToken[] calldata outputTokens,
        Executor[] calldata executors
    ) external payable returns (uint256[] memory amountOut) {
        uint256[] memory initialOutputBalance = new uint256[](outputTokens.length);
        for (uint256 i = 0; i < outputTokens.length; i++) {
            initialOutputBalance[i] = outputTokens[i].token.universalBalanceOf(outputTokens[i].recipient);
        }

        for (uint256 i = 0; i < inputTokens.length; i++) {
            IERC20 tokenIn = inputTokens[i].token;
            if (address(tokenIn) != NATIVE_ADDRESS) {
                if (inputTokens[i].amountIn > 0) {
                    tokenIn.safeTransferFrom(msg.sender, inputTokens[i].transferTo, inputTokens[i].amountIn);
                } else {
                    tokenIn.safeTransfer(inputTokens[i].transferTo, tokenIn.balanceOf(address(this)) - 1);
                } // -1 is slot undrain protection
            }
        }

        safeExecutor.executeMultiple{value: msg.value}(executors);

        amountOut = new uint256[](outputTokens.length);
        for (uint256 i = 0; i < outputTokens.length; i++) {
            amountOut[i] = outputTokens[i].token.universalBalanceOf(outputTokens[i].recipient) - initialOutputBalance[i];
            if (amountOut[i] < outputTokens[i].amountOutMin) {
                revert MinimalOutputBalanceViolation(address(outputTokens[i].token), amountOut[i]);
            }
        }
    }
}

// This contract doesn't have token approves, so can safely call other contracts
contract SafeExecutor {
    using Utils for address;

    function execute(address executor, bytes calldata executorData) external payable {
        executor.callRevertBubbleUp(msg.value, executorData);
    }

    function executeMultiple(Executor[] calldata executors) external payable {
        for (uint256 i = 0; i < executors.length; i++) {
            executors[i].executor.callRevertBubbleUp(executors[i].value, executors[i].data);
        }
    }
}

error MinimalOutputBalanceViolation(address tokenOut, uint256 amountOut);

address constant NATIVE_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

struct InputToken {
    IERC20 token;
    uint256 amountIn;
    address transferTo;
}

struct OutputToken {
    IERC20 token;
    address recipient;
    uint256 amountOutMin;
}

struct Executor {
    address executor;
    uint256 value;
    bytes data;
}

library Utils {
    using SafeERC20 for IERC20;

    function universalBalanceOf(IERC20 token, address user) internal view returns (uint256) {
        if (address(token) == NATIVE_ADDRESS) return address(user).balance;
        else return token.balanceOf(user);
    }

    function callRevertBubbleUp(address contr, uint256 value, bytes memory data) internal {
        (bool success, bytes memory returnBytes) = contr.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(32, returnBytes), mload(returnBytes))
            }
        }
    }
}
