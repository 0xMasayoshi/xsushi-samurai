// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * Fuzz suite for Yojimbo
 *
 * Focus:
 *  - Quote ↔ Actual parity across random ratios (enter/leave).
 *  - Directional no-dust after each operation (enter → no xSUSHI on executor; leave → no SUSHI on executor).
 *  - MinOut enforcement via RedSnwapper: exact min passes; min+1 reverts.
 *
 * Notes:
 *  - We use `bound` to keep inputs in sane ranges and avoid overflow-y magnitudes.
 *  - We bootstrap the bar with random liquidity so ratios are not always 1:1.
 */

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSushiBar} from "./mocks/MockSushiBar.sol";
import {Yojimbo} from "../src/Yojimbo.sol";
import {RedSnwapper, MinimalOutputBalanceViolation} from "../src/RedSnwapper.sol";

contract YojimboFuzzTest is Test {
    MockERC20 SUSHI;
    MockSushiBar xSUSHI;
    Yojimbo yojimbo;
    RedSnwapper redSnwapper;

    address user = address(0xBEEF);
    address recipient = address(0xCAFE);

    function setUp() public {
        SUSHI = new MockERC20("SUSHI", "SUSHI");
        xSUSHI = new MockSushiBar(SUSHI);
        yojimbo = new Yojimbo(xSUSHI);
        redSnwapper = new RedSnwapper();

        // Seed user and approvals for RedSnwapper paths.
        SUSHI.mint(user, type(uint128).max); // plenty
        vm.startPrank(user);
        SUSHI.approve(address(redSnwapper), type(uint256).max);
        xSUSHI.approve(address(redSnwapper), type(uint256).max);
        vm.stopPrank();
    }

    /* ----------------------------- helpers ----------------------------- */

    function _bootstrapBar(uint256 seedSushi) internal {
        if (seedSushi == 0) return;
        SUSHI.mint(address(this), seedSushi);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(seedSushi);
    }

    /* -------------------- fuzz: enter parity + no dust ------------------ */

    function testFuzz_Enter_Parity_NoDust(uint96 seedSushiRaw, uint96 amountInRaw) public {
        // Keep values reasonable and non-zero.
        uint256 seedSushi = bound(uint256(seedSushiRaw), 1e9, 1_000_000e18);
        uint256 amountIn = bound(uint256(amountInRaw), 1, 1_000_000e18);

        // Randomize ratio (non-1:1) by bootstrapping the bar.
        _bootstrapBar(seedSushi);

        // Fund executor, compute quote, then enter to recipient (this).
        SUSHI.mint(address(yojimbo), amountIn);

        uint256 quotedAmountOut = yojimbo.quoteEnterSushiBar(amountIn);

        // Track recipient balance delta
        uint256 beforeBalance = xSUSHI.balanceOf(address(this));
        yojimbo.enterSushiBar(amountIn, address(this));
        uint256 afterBalance = xSUSHI.balanceOf(address(this));

        // Parity: minted == quote.
        assertEq(afterBalance - beforeBalance, quotedAmountOut, "enter: quote != actual");

        // Directional no-dust: after enter, executor forwards all minted xSUSHI.
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "enter: executor kept xSUSHI");
        // SUSHI may remain if caller only entered a portion; don't assert SUSHI==0 here.
    }

    /* -------------------- fuzz: leave parity + no dust ------------------ */

    function testFuzz_Leave_Parity_NoDust(uint96 seedSushiRaw, uint96 sharesRaw) public {
        // Bootstrap bar with random liquidity.
        uint256 seedSushi = bound(uint256(seedSushiRaw), 1e9, 1_000_000e18);
        _bootstrapBar(seedSushi);

        // Give executor some shares to redeem.
        uint256 maxShares = xSUSHI.balanceOf(address(this));
        // If bar had no liquidity (extremely unlikely after bound), bail out safely.
        vm.assume(maxShares > 0);

        uint256 shares = bound(uint256(sharesRaw), 1, maxShares);
        xSUSHI.transfer(address(yojimbo), shares);

        uint256 quotedAmountOut = yojimbo.quoteLeaveSushiBar(shares);

        // Track recipient balance delta
        uint256 beforeBalance = SUSHI.balanceOf(address(this));
        yojimbo.leaveSushiBar(shares, address(this));
        uint256 afterBalance = SUSHI.balanceOf(address(this));

        // Parity: redeemed == quote.
        assertEq(afterBalance - beforeBalance, quotedAmountOut, "leave: quote != actual");

        // Directional no-dust: after leave, executor forwards all redeemed SUSHI.
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "leave: executor kept SUSHI");
        // xSUSHI may remain on executor if caller later transfers more shares; not asserted here.
    }

    /* --------------------- fuzz: minOut (enter) path -------------------- */

    function testFuzz_MinOut_Enter_PassAndRevert(uint96 seedSushiRaw, uint96 amountInRaw) public {
        uint256 seedSushi = bound(uint256(seedSushiRaw), 1e9, 1_000_000e18);
        uint256 amountIn = bound(uint256(amountInRaw), 1, 1_000_000e18);

        _bootstrapBar(seedSushi);

        // Move funds to user and approve already done in setUp.
        vm.startPrank(user);

        // Compute expected shares at call-time ratio.
        uint256 sushiInBar = SUSHI.balanceOf(address(xSUSHI));
        uint256 totalShares = xSUSHI.totalSupply();
        // First deposit corner-case: if bar empty, expectedOut0 == amountIn (handled by math below).
        uint256 expectedOut = (sushiInBar == 0 || totalShares == 0) ? amountIn : (amountIn * totalShares) / sushiInBar;

        uint256 beforeSnapshot = vm.snapshot();

        // Exact min passes.
        redSnwapper.snwap(
            SUSHI,
            amountIn,
            recipient,
            xSUSHI,
            expectedOut,
            address(yojimbo),
            abi.encodeWithSelector(Yojimbo.enterSushiBar.selector, amountIn, recipient)
        );

        vm.revertTo(beforeSnapshot);

        // Min + 1 reverts.
        bytes memory err = abi.encodeWithSelector(MinimalOutputBalanceViolation.selector, address(xSUSHI), expectedOut);
        vm.expectRevert(err);
        redSnwapper.snwap(
            SUSHI,
            amountIn,
            recipient,
            xSUSHI,
            expectedOut + 1,
            address(yojimbo),
            abi.encodeWithSelector(Yojimbo.enterSushiBar.selector, amountIn, recipient)
        );

        vm.stopPrank();

        // Directional no-dust on executor.
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "enter(min): executor kept SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "enter(min): executor kept xSUSHI");
    }

    /* --------------------- fuzz: minOut (leave) path -------------------- */

    function testFuzz_MinOut_Leave_PassAndRevert(uint96 seedSushiRaw, uint96 sharesSeedRaw, uint96 sharesToBurnRaw)
        public
    {
        uint256 seedSushi = bound(uint256(seedSushiRaw), 1e9, 1_000_000e18);
        uint256 sharesSeed = bound(uint256(sharesSeedRaw), 1e9, 1_000_000e18); // user mints some xSUSHI
        uint256 sharesToTry = bound(uint256(sharesToBurnRaw), 1, 1_000_000e18);

        _bootstrapBar(seedSushi);

        // Give user xSUSHI by entering directly (simulate prior stake).
        vm.startPrank(user);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(sharesSeed);
        xSUSHI.approve(address(redSnwapper), type(uint256).max);

        uint256 userShares = xSUSHI.balanceOf(user);
        vm.assume(userShares > 0);
        uint256 burn = bound(sharesToTry, 1, userShares);

        // Compute expectedOut at current ratio.
        uint256 sushiInBar = SUSHI.balanceOf(address(xSUSHI));
        uint256 totalShares = xSUSHI.totalSupply();
        uint256 expectedOut = (burn * sushiInBar) / totalShares;

        uint256 beforeSnapshot = vm.snapshot();

        // Exact min passes.
        redSnwapper.snwap(
            xSUSHI,
            burn,
            recipient,
            SUSHI,
            expectedOut,
            address(yojimbo),
            abi.encodeWithSelector(Yojimbo.leaveSushiBar.selector, burn, recipient)
        );

        vm.revertTo(beforeSnapshot);

        // Min + 1 reverts.
        bytes memory err = abi.encodeWithSelector(MinimalOutputBalanceViolation.selector, address(SUSHI), expectedOut);
        vm.expectRevert(err);
        redSnwapper.snwap(
            xSUSHI,
            burn,
            recipient,
            SUSHI,
            expectedOut + 1,
            address(yojimbo),
            abi.encodeWithSelector(Yojimbo.leaveSushiBar.selector, burn, recipient)
        );
        vm.stopPrank();

        // Directional no-dust on executor.
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "leave(min): executor kept SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "leave(min): executor kept xSUSHI");
    }
}
