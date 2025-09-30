// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockSushiBar.sol";
import "../src/YojimboExecutor.sol";
import "../src/RedSnwapper.sol";

contract YojimboExecutorTest is Test {
    MockERC20 SUSHI;
    MockSushiBar xSUSHI;
    YojimboExecutor exec;
    RedSnwapper wrapper; // your facade that enforces minOut

    address user = address(0xBEEF);
    address recipient = address(0xCAFE);

    function setUp() public {
        SUSHI = new MockERC20("SUSHI", "SUSHI");
        xSUSHI = new MockSushiBar(SUSHI);
        exec = new YojimboExecutor(xSUSHI);
        wrapper = new RedSnwapper();

        // seed user with SUSHI
        SUSHI.mint(user, 1_000_000 ether);
        // user approvals to wrapper for SUSHI/xSUSHI when needed
        vm.prank(user);
        SUSHI.approve(address(wrapper), type(uint256).max);
        vm.prank(user);
        IERC20(address(xSUSHI)).approve(address(wrapper), type(uint256).max);
    }

    function _revertSelector(
        bytes memory err
    ) internal pure returns (bytes4 sel) {
        if (err.length >= 4)
            assembly {
                sel := mload(add(err, 32))
            }
    }

    /* ============ direct executor tests (without minOut) ============ */

    function testEnterExplicitAmount() public {
        // move tokens to executor (simulate RedSnwapper behaviour)
        SUSHI.mint(address(exec), 10 ether);

        uint256 before = xSUSHI.balanceOf(recipient);
        exec.enterSushiBar(5 ether, recipient);
        uint256 afterBal = xSUSHI.balanceOf(recipient);

        assertGt(afterBal, before, "xSUSHI not minted to recipient");
        assertEq(
            SUSHI.balanceOf(address(xSUSHI)),
            5 ether,
            "bar should hold SUSHI"
        );
    }

    function testEnterAll() public {
        SUSHI.mint(address(exec), 10 ether);
        // amountIn = 0 => uses entire balance
        exec.enterSushiBar(0, recipient);
        assertGt(xSUSHI.balanceOf(recipient), 0, "xSUSHI minted");
        // bar holds full executor balance
        assertEq(
            SUSHI.balanceOf(address(xSUSHI)),
            10 ether,
            "bar should hold entire executor balance"
        );
    }

    function testLeaveExplicitShares() public {
        // prepare: send SUSHI to executor and enter so it holds xSUSHI
        SUSHI.mint(address(exec), 20 ether);
        exec.enterSushiBar(10 ether, address(this)); // we receive xSUSHI
        uint256 shares = xSUSHI.balanceOf(address(this));
        // give shares to executor to leave
        IERC20(address(xSUSHI)).transfer(address(exec), shares);

        uint256 before = SUSHI.balanceOf(recipient);
        exec.leaveSushiBar(shares / 2, recipient);
        uint256 afterBal = SUSHI.balanceOf(recipient);

        assertGt(afterBal, before, "SUSHI not received");
    }

    function testLeaveAll() public {
        // mint and enter to get some xSUSHI onto executor
        SUSHI.mint(address(exec), 5 ether);
        exec.enterSushiBar(5 ether, address(exec));
        uint256 bal = xSUSHI.balanceOf(address(exec));
        assertGt(bal, 0, "executor must have xSUSHI");

        exec.leaveSushiBar(0, recipient); // use entire balance
        assertGt(SUSHI.balanceOf(recipient), 0, "recipient got SUSHI");
        assertEq(
            xSUSHI.balanceOf(address(exec)),
            0,
            "executor should be emptied"
        );
    }

    /* ============ RedSnwapper integration (minOut enforced) ============ */

    function testSnwap_Enter_Succeeds_WhenMinMet() public {
        // user calls wrapper.snwap to deposit SUSHI -> xSUSHI to recipient
        uint amountIn = 100 ether;

        // pre-compute expected shares (first deposit => shares == amount)
        uint minShares = 100 ether; // set min equal to expected

        vm.prank(user);
        RedSnwapper(wrapper).snwap(
            IERC20(address(SUSHI)),
            amountIn,
            recipient,
            IERC20(address(xSUSHI)),
            minShares,
            address(exec),
            abi.encodeWithSelector(
                YojimboExecutor.enterSushiBar.selector,
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
    }

    function testSnwap_Enter_Reverts_WhenMinNotMet() public {
        uint amountIn = 50 ether;

        // Make the ratio bad by pre-funding xSUSHI so shares per sushi decreases.
        // Mint some SUSHI to bar directly then mint initial shares to a dummy to change ratio.
        // Simulate a prior deposit:
        SUSHI.mint(address(this), 100 ether);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(100 ether); // now totalShares=100, barSushi=100

        // user wants 50 in, but we force min too high to trigger revert:
        uint tooHighMinShares = 51 ether; // expected is exactly 50

        bytes memory err = abi.encodeWithSelector(
            MinimalOutputBalanceViolation.selector,
            address(xSUSHI),
            amountIn 
        );
        vm.expectRevert(err);
        vm.prank(user);
        RedSnwapper(wrapper).snwap(
            SUSHI,
            amountIn,
            recipient,
            xSUSHI,
            tooHighMinShares,
            address(exec),
            abi.encodeWithSelector(
                YojimboExecutor.enterSushiBar.selector,
                amountIn,
                recipient
            )
        );
    }

    function testSnwap_Leave_Succeeds_WhenMinMet() public {
        // First, deposit via executor so user holds xSUSHI to burn
        // We'll just mint SUSHI to user and do a direct enter via bar.
        vm.startPrank(user);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(80 ether); // user gets 80 xSUSHI (first liquidity)
        // approve wrapper to move user's xSUSHI (already done in setUp, but ok)
        IERC20(address(xSUSHI)).approve(address(wrapper), type(uint256).max);

        uint sharesToBurn = 40 ether;
        uint sushiInBar = SUSHI.balanceOf(address(xSUSHI));
        uint totalShares = xSUSHI.totalSupply();
        uint expectedOut = (sharesToBurn * sushiInBar) / totalShares;

        // Set minOut to expectedOut (should pass)
        RedSnwapper(wrapper).snwap(
            IERC20(address(xSUSHI)),
            sharesToBurn,
            recipient,
            IERC20(address(SUSHI)),
            expectedOut,
            address(exec),
            abi.encodeWithSelector(
                YojimboExecutor.leaveSushiBar.selector,
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
    }

    function testSnwap_Leave_Reverts_WhenMinNotMet() public {
        // Prepare liquidity as above
        vm.startPrank(user);
        SUSHI.approve(address(xSUSHI), type(uint256).max);
        xSUSHI.enter(60 ether);
        IERC20(address(xSUSHI)).approve(address(wrapper), type(uint256).max);

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
        RedSnwapper(wrapper).snwap(
            IERC20(address(xSUSHI)),
            sharesToBurn,
            recipient,
            IERC20(address(SUSHI)),
            tooHighMin,
            address(exec),
            abi.encodeWithSelector(
                YojimboExecutor.leaveSushiBar.selector,
                sharesToBurn,
                recipient
            )
        );
        vm.stopPrank();
    }
}
