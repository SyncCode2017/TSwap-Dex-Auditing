// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {TSwapPool} from "../../src/PoolFactory.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract TSwapPoolTest is Test {
    TSwapPool pool;
    ERC20Mock poolToken;
    ERC20Mock weth;

    address liquidityProvider = makeAddr("liquidityProvider");
    address user = makeAddr("user");

    function setUp() public {
        poolToken = new ERC20Mock();
        weth = new ERC20Mock();
        pool = new TSwapPool(
            address(poolToken),
            address(weth),
            "LTokenA",
            "LA"
        );

        weth.mint(liquidityProvider, 200e18);
        poolToken.mint(liquidityProvider, 200e18);

        weth.mint(user, 10e18);
        poolToken.mint(user, 10e18);
    }

    function testDeposit() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));

        assertEq(pool.balanceOf(liquidityProvider), 100e18);
        assertEq(weth.balanceOf(liquidityProvider), 100e18);
        assertEq(poolToken.balanceOf(liquidityProvider), 100e18);

        assertEq(weth.balanceOf(address(pool)), 100e18);
        assertEq(poolToken.balanceOf(address(pool)), 100e18);
    }

    function testDepositSwap() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        vm.startPrank(user);
        poolToken.approve(address(pool), 10e18);
        // After we swap, there will be ~110 tokenA, and ~91 WETH
        // 100 * 100 = 10,000
        // 110 * ~91 = 10,000
        uint256 expected = 9e18;

        pool.swapExactInput(
            poolToken,
            10e18,
            weth,
            expected,
            uint64(block.timestamp)
        );
        assert(weth.balanceOf(user) >= expected);
    }

    function testWithdraw() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));

        pool.approve(address(pool), 100e18);
        pool.withdraw(100e18, 100e18, 100e18, uint64(block.timestamp));

        assertEq(pool.totalSupply(), 0);
        assertEq(weth.balanceOf(liquidityProvider), 200e18);
        assertEq(poolToken.balanceOf(liquidityProvider), 200e18);
    }

    function testCollectFees() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        vm.startPrank(user);
        uint256 expected = 9e18;
        poolToken.approve(address(pool), 10e18);
        pool.swapExactInput(
            poolToken,
            10e18,
            weth,
            expected,
            uint64(block.timestamp)
        );
        vm.stopPrank();

        vm.startPrank(liquidityProvider);
        pool.approve(address(pool), 100e18);
        pool.withdraw(100e18, 90e18, 100e18, uint64(block.timestamp));
        assertEq(pool.totalSupply(), 0);
        assert(
            weth.balanceOf(liquidityProvider) +
                poolToken.balanceOf(liquidityProvider) >
                400e18
        );
    }

    // proof of code
    function testFlawedSwapExactOutput() public {
        uint256 initialLiquidity = 100e18;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);

        pool.deposit({
            wethToDeposit: initialLiquidity,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: 100e18,
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        // User has 11 pool tokens
        address someUser = makeAddr("someUser");
        uint256 userInitialPoolTokenBalance = 11e18;
        poolToken.mint(someUser, userInitialPoolTokenBalance);
        vm.startPrank(someUser);

        // User buys 1 WETH from the pool, paying with pool tokens
        poolToken.approve(address(pool), type(uint256).max);
        pool.swapExactOutput(poolToken, weth, 1 ether, uint64(block.timestamp));
        // Initial liquidity was 1:1 so user should have paid ~1 pool token
        // However, the user spent much more than they should. The user started with 11 tokens but now has less than 1
        assert(poolToken.balanceOf(someUser) < 1 ether);
        vm.stopPrank();

        // The liquidity provider can rug all funds from the pool now,
        // including those deposited by the user.
        vm.startPrank(liquidityProvider);
        pool.withdraw(
            pool.balanceOf(liquidityProvider),
            1, // minWethToWithdraw
            1, // minPoolTokensToWithdraw
            uint64(block.timestamp)
        );

        assert(weth.balanceOf(address(pool)) == 0);
        assert(poolToken.balanceOf(address(pool)) == 0);
    }

    function testFlawedSwapExactInputReturnsZero() public {
        uint256 initialLiquidity = 100e18;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);

        pool.deposit({
            wethToDeposit: initialLiquidity,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: 100e18,
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        // User has 50 pool tokens
        address someUser = makeAddr("someUser");
        uint256 userInitialPoolTokenBalance = 50e18;
        poolToken.mint(someUser, userInitialPoolTokenBalance);
        vm.startPrank(someUser);

        // User Weth balance before swap is 0
        assert(weth.balanceOf(someUser) == 0);

        // User buys 1 WETH from the pool, paying with pool tokens
        poolToken.approve(address(pool), type(uint256).max);

        // first swap returns 0
        uint256 firstSwapReturnedValue = pool.swapExactInput(
            poolToken,
            2 ether,
            weth,
            0.1 ether,
            uint64(block.timestamp)
        );

        uint256 newWethBalanceAfterSwap1 = weth.balanceOf(someUser);
        assert(firstSwapReturnedValue == 0);
        assert(newWethBalanceAfterSwap1 > 0);

        // second swap returns 0
        uint256 secondSwapReturnedValue = pool.swapExactInput(
            poolToken,
            1.5 ether,
            weth,
            0.1 ether,
            uint64(block.timestamp)
        );
        uint256 newWethBalanceAfterSwap2 = weth.balanceOf(someUser);

        assert(secondSwapReturnedValue == 0);
        assert(newWethBalanceAfterSwap2 - newWethBalanceAfterSwap1 > 0);

        vm.stopPrank();
    }

    function testFlawedDepositDoesNotRespectSetDeadline() public {
        assert(weth.balanceOf(address(pool)) == 0);
        assert(poolToken.balanceOf(address(pool)) == 0);
        uint256 liquidityValue = 100e18;
        uint64 invalidDeadline = uint64(block.timestamp - 1);
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), liquidityValue);
        poolToken.approve(address(pool), liquidityValue);

        // Calling the deposit function with a deadline in the past should fail but passes
        pool.deposit({
            wethToDeposit: liquidityValue,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: 100e18,
            deadline: invalidDeadline
        });
        vm.stopPrank();

        assert(weth.balanceOf(address(pool)) == liquidityValue);
        assert(poolToken.balanceOf(address(pool)) == liquidityValue);
    }

    function testSellPoolTokensMiscalculatesSwaps() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenAmount = 1e18;

        // Provide liquidity
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);

        pool.deposit({
            wethToDeposit: initialLiquidity,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: initialLiquidity,
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        // User has 100 pool tokens
        address someUser = makeAddr("someUser");
        uint256 userInitialPoolTokenBalance = 100e18;
        uint256 someUserWethInitialBalance = weth.balanceOf(someUser);
        poolToken.mint(someUser, userInitialPoolTokenBalance);

        // User sells 1 pool token using sellPoolTokens
        vm.startPrank(someUser);
        poolToken.approve(address(pool), type(uint256).max);
        pool.sellPoolTokens(tokenAmount);
        vm.stopPrank();

        uint256 someUserWethBalance1 = weth.balanceOf(someUser);
        uint256 changeInWethAfter1stSwap = someUserWethBalance1 -
            someUserWethInitialBalance;

        // Returning the Pool to the initial state
        vm.startPrank(liquidityProvider);
        // Removing the liquidity from the pool
        pool.withdraw(
            pool.balanceOf(liquidityProvider),
            1, // minWethToWithdraw
            1, // minPoolTokensToWithdraw
            uint64(block.timestamp)
        );

        assert(weth.balanceOf(address(pool)) == 0);
        assert(poolToken.balanceOf(address(pool)) == 0);

        // Returning the exact amount of initial liquidity
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);
        pool.deposit({
            wethToDeposit: initialLiquidity,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: initialLiquidity,
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        // User sells 1 pool token using swapExactInput
        vm.startPrank(someUser);
        poolToken.approve(address(pool), type(uint256).max);
        pool.swapExactInput(
            poolToken,
            tokenAmount,
            weth,
            0,
            uint64(block.timestamp)
        );
        vm.stopPrank();

        uint256 someUserWethBalance2 = weth.balanceOf(someUser);
        uint256 changeInWethAfter2ndSwap = someUserWethBalance2 -
            someUserWethBalance1;

        // The Weth tokens received from the swaps should be the same but they are different
        assert(changeInWethAfter1stSwap != changeInWethAfter2ndSwap);
    }
}
