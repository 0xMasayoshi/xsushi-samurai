// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockSushiBar.sol";
import "../src/Yojimbo.sol";
import "../src/RedSnwapper.sol";

/* 
 * TEST INTENT
 * - Exercise Yojimbo’s minimal executor surface (enter/leave) and prove:
 *   (1) Directional no-dust: after enter -> no xSUSHI left on executor; after leave -> no SUSHI left.
 *   (2) “All” path empties executor of both tokens (amountIn = 0).
 *   (3) Quote parity: on-chain quote == actual minted/burned under the same state.
 *   (4) Min-out is enforced by RedSnwapper; revert payload matches the failing OUTPUT amount/token.
 * - We intentionally do NOT assert both-token-zero in partial paths (explicit amounts), since leftovers are expected.
 */

contract YojimboTest is Test {
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

        // Seed user with sushi and pre-approve RedSnwapper.
        SUSHI.mint(user, 1_000_000 ether);
        vm.prank(user);
        SUSHI.approve(address(redSnwapper), type(uint256).max);
        vm.prank(user);
        xSUSHI.approve(address(redSnwapper), type(uint256).max);
    }

    function testConstructorSetsMaxAllowance() public {
        assertEq(
            SUSHI.allowance(address(yojimbo), address(xSUSHI)),
            type(uint256).max,
            "max allowance not set"
        );
    }

    /* ============ direct executor tests (without minOut) ============ */

    function testEnterExplicitAmount() public {
        uint amount = 5 ether;

        // Simulate router behavior - pre-fund executor
        SUSHI.mint(address(yojimbo), amount);

        uint256 before = xSUSHI.balanceOf(recipient);
        yojimbo.enterSushiBar(amount, recipient);
        uint256 afterBal = xSUSHI.balanceOf(recipient);

        assertGt(afterBal, before, "xSUSHI not minted to recipient");
        assertEq(
            SUSHI.balanceOf(address(xSUSHI)),
            amount,
            "bar should hold SUSHI"
        );
        // Directional no-dust: after enter, executor should NOT retain xSUSHI it just minted.
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain xSUSHI");
    }

    function testEnterAll() public {
        SUSHI.mint(address(yojimbo), 10 ether);
        // amountIn = 0 => full-balance mode: executor should be emptied of both tokens.
        yojimbo.enterSushiBar(0, recipient);
        assertGt(xSUSHI.balanceOf(recipient), 0, "xSUSHI minted");
        // bar holds full executor balance
        assertEq(
            SUSHI.balanceOf(address(xSUSHI)),
            10 ether,
            "bar should hold entire executor balance"
        );
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain xSUSHI");
    }

    function testLeaveExplicitShares() public {
        uint amount = 10 ether;

        SUSHI.mint(address(yojimbo), amount);
        yojimbo.enterSushiBar(amount, address(this)); // we receive xSUSHI
        uint256 shares = xSUSHI.balanceOf(address(this));
        // give shares to executor to leave
        xSUSHI.transfer(address(yojimbo), shares);

        uint256 before = SUSHI.balanceOf(recipient);
        yojimbo.leaveSushiBar(shares / 2, recipient);
        uint256 afterBal = SUSHI.balanceOf(recipient);

        assertGt(afterBal, before, "SUSHI not received");
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain SUSHI");
    }

    function testLeaveAll() public {
        // mint and enter to get some xSUSHI onto executor
        SUSHI.mint(address(yojimbo), 5 ether);
        yojimbo.enterSushiBar(5 ether, address(yojimbo));
        uint256 bal = xSUSHI.balanceOf(address(yojimbo));
        assertGt(bal, 0, "executor must have xSUSHI");

        // amountIn = 0 => full-balance mode: executor should be emptied of both tokens.
        yojimbo.leaveSushiBar(0, recipient);
        assertGt(SUSHI.balanceOf(recipient), 0, "recipient got SUSHI");
        assertEq(
            xSUSHI.balanceOf(address(yojimbo)),
            0,
            "executor should be emptied"
        );
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain xSUSHI");
    }

    function testQuoteEnterSushiBar() public {
        uint256 amountIn = 50 ether;
        assertEq(yojimbo.quoteEnterSushiBar(amountIn), amountIn, "first deposit should mint 1:1");

        SUSHI.mint(address(this), 100 ether);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(100 ether);

        uint256 expected =
            (amountIn * xSUSHI.totalSupply()) /
            SUSHI.balanceOf(address(xSUSHI));
        assertEq(yojimbo.quoteEnterSushiBar(amountIn), expected, "quoteEnterSushiBar mismatches bar math");
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain xSUSHI");
    }

    function testEnterQuoteMatchesActual() public {
        // Parity check: quoted mint == actual mint under same state.
        SUSHI.mint(address(yojimbo), 123 ether);
        uint q = yojimbo.quoteEnterSushiBar(123 ether);
        yojimbo.enterSushiBar(123 ether, address(this));
        assertEq(xSUSHI.balanceOf(address(this)), q, "quote != actual");
    }

    function testQuoteLeaveSushiBar() public {
        SUSHI.mint(address(this), 120 ether);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(120 ether);

        uint256 sharesIn = 40 ether;
        uint256 expected =
            (sharesIn * SUSHI.balanceOf(address(xSUSHI))) /
            xSUSHI.totalSupply();
        assertEq(yojimbo.quoteLeaveSushiBar(sharesIn), expected, "quoteLeaveSushiBar mismatches bar math");
        assertEq(yojimbo.quoteLeaveSushiBar(0), 0, "quoteLeaveSushiBar zero input should be zero");
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain xSUSHI");
    }

    function testLeaveQuoteMatchesActual() public {
        // Parity check: quoted redemption == actual redemption under same state.
        SUSHI.mint(address(this), 200 ether);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(200 ether);

        uint shares = 77 ether;
        xSUSHI.transfer(address(yojimbo), shares);
        uint q = yojimbo.quoteLeaveSushiBar(shares);
        yojimbo.leaveSushiBar(shares, address(this));
        assertEq(SUSHI.balanceOf(address(this)), q, "quote != actual");
    }

    /* ============ RedSnwapper integration (minOut enforced) ============ */

    function testSnwap_Enter_Succeeds_WhenMinMet() public {
        // SUCCESS path: minOut == actualOut should pass.

        // user calls RedSnwapper.snwap to deposit SUSHI -> xSUSHI to recipient
        uint amountIn = 100 ether;

        // pre-compute expected shares (first deposit => shares == amount)
        uint minShares = 100 ether; // set min equal to expected

        vm.prank(user);
        redSnwapper.snwap(
            SUSHI,
            amountIn,
            recipient,
            xSUSHI,
            minShares,
            address(yojimbo),
            abi.encodeWithSelector(
                Yojimbo.enterSushiBar.selector,
                amountIn,
                recipient
            )
        );

        assertEq(
            xSUSHI.balanceOf(recipient),
            minShares,
            "recipient should receive shares >= min"
        );
        assertEq(SUSHI.balanceOf(address(xSUSHI)), amountIn, "bar sushi wrong");
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain xSUSHI");
    }

    function testSnwap_Enter_Reverts_WhenMinNotMet() public {
        // FAILURE path: minOut > actualOut should revert with OUTPUT token + actualOut.

        // Make the ratio bad by pre-funding xSUSHI so shares per sushi decreases.
        // Mint some SUSHI to bar directly then mint initial shares to a dummy to change ratio.
        // Simulate a prior deposit:
        SUSHI.mint(address(this), 100 ether);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(100 ether); // now totalShares=100, barSushi=100

        uint amountIn = 50 ether;
        uint sushiInBar = SUSHI.balanceOf(address(xSUSHI));
        uint totalShares = xSUSHI.totalSupply();
        uint expectedOut = (amountIn * totalShares) / sushiInBar;

        // user wants 50 in, but we force min too high to trigger revert:
        uint tooHighMinShares = expectedOut + 1;

        bytes memory err = abi.encodeWithSelector(
            MinimalOutputBalanceViolation.selector,
            address(xSUSHI),
            expectedOut 
        );
        vm.expectRevert(err);
        vm.prank(user);
        redSnwapper.snwap(
            SUSHI,
            amountIn,
            recipient,
            xSUSHI,
            tooHighMinShares,
            address(yojimbo),
            abi.encodeWithSelector(
                Yojimbo.enterSushiBar.selector,
                amountIn,
                recipient
            )
        );
    }

    function testSnwap_Leave_Succeeds_WhenMinMet() public {
        // SUCCESS path: minOut == actualOut should pass.

        // First, deposit via executor so user holds xSUSHI to burn
        // We'll just mint SUSHI to user and do a direct enter via bar.
        vm.startPrank(user);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(80 ether); // user gets 80 xSUSHI (first liquidity)
        // approve RedSnwapper to move user's xSUSHI (already done in setUp, but ok)
        xSUSHI.approve(address(redSnwapper), type(uint256).max);

        uint sharesToBurn = 40 ether;
        uint sushiInBar = SUSHI.balanceOf(address(xSUSHI));
        uint totalShares = xSUSHI.totalSupply();
        uint expectedOut = (sharesToBurn * sushiInBar) / totalShares;

        // Set minOut to expectedOut
        redSnwapper.snwap(
            xSUSHI,
            sharesToBurn,
            recipient,
            SUSHI,
            expectedOut,
            address(yojimbo),
            abi.encodeWithSelector(
                Yojimbo.leaveSushiBar.selector,
                sharesToBurn,
                recipient
            )
        );
        vm.stopPrank();

        assertEq(
            SUSHI.balanceOf(recipient),
            expectedOut,
            "recipient received SUSHI >= min"
        );
        assertEq(SUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain SUSHI");
        assertEq(xSUSHI.balanceOf(address(yojimbo)), 0, "executor should not retain xSUSHI");
    }

    function testSnwap_Leave_Reverts_WhenMinNotMet() public {
        // FAILURE path: minOut > actualOut should revert with OUTPUT token + actualOut.
        vm.startPrank(user);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(60 ether);
        xSUSHI.approve(address(redSnwapper), type(uint256).max);

        uint sharesToBurn = 30 ether;
        uint sushiInBar = SUSHI.balanceOf(address(xSUSHI));
        uint totalShares = xSUSHI.totalSupply();
        uint expectedOut = (sharesToBurn * sushiInBar) / totalShares;

        // Require more than expected to trigger revert
        uint tooHighMin = expectedOut + 1;

        bytes memory err = abi.encodeWithSelector(
            MinimalOutputBalanceViolation.selector,
            address(SUSHI),
            expectedOut 
        );
        vm.expectRevert(err);
        redSnwapper.snwap(
            xSUSHI,
            sharesToBurn,
            recipient,
            SUSHI,
            tooHighMin,
            address(yojimbo),
            abi.encodeWithSelector(
                Yojimbo.leaveSushiBar.selector,
                sharesToBurn,
                recipient
            )
        );
        vm.stopPrank();
    }
}
