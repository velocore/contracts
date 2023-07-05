// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IPairFactory.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IWETH.sol";

import {WrappedBribeFactory, WrappedBribe} from "./factories/WrappedBribeFactory.sol";
import {Pair} from "./Pair.sol";
import {WrappedExternalBribe} from "./WrappedExternalBribe.sol";

contract Router is IRouter, ReentrancyGuard {
    struct route {
        address from;
        address to;
        bool stable;
    }

    address public immutable factory;
    IWETH public immutable weth;
    uint256 internal constant MINIMUM_LIQUIDITY = 10 ** 3;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _weth) {
        factory = _factory;
        weth = IWETH(_weth);
    }

    receive() external payable {
        assert(msg.sender == address(weth)); // only accept ETH via fallback from the WETH contract
    }

    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Router: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Router: ZERO_ADDRESS");
    }

    // calculates the CREATE2 address for a pair without making any external         nonReentrant calls
    function pairFor(address tokenA, address tokenB, bool stable) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);
        require(pair != address(0), "pair na");
        return pair;
    }

    function unsafePairFor(address tokenA, address tokenB, bool stable) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);
        return pair;
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quoteLiquidity(uint256 amountA, uint256 reserveA, uint256 reserveB)
        internal
        pure
        returns (uint256 amountB)
    {
        require(amountA > 0, "Router: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "Router: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address tokenA, address tokenB, bool stable)
        public
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1,) = IPair(unsafePairFor(tokenA, tokenB, stable)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountOut(uint256 amountIn, address tokenIn, address tokenOut)
        external
        view
        returns (uint256 amount, bool stable)
    {
        address pair = unsafePairFor(tokenIn, tokenOut, true);
        uint256 amountStable;
        uint256 amountVolatile;
        if (IPairFactory(factory).isPair(pair)) {
            amountStable = IPair(pair).getAmountOut(amountIn, tokenIn);
        }
        pair = unsafePairFor(tokenIn, tokenOut, false);
        if (IPairFactory(factory).isPair(pair)) {
            amountVolatile = IPair(pair).getAmountOut(amountIn, tokenIn);
        }
        return amountStable > amountVolatile ? (amountStable, true) : (amountVolatile, false);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(uint256 amountIn, route[] memory routes) public view returns (uint256[] memory amounts) {
        require(routes.length >= 1, "Router: INVALID_PATH");
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < routes.length; i++) {
            address pair = unsafePairFor(routes[i].from, routes[i].to, routes[i].stable);
            if (IPairFactory(factory).isPair(pair)) {
                amounts[i + 1] = IPair(pair).getAmountOut(amounts[i], routes[i].from);
            }
        }
    }

    function isPair(address pair) external view returns (bool) {
        return IPairFactory(factory).isPair(pair);
    }

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);
        (uint256 reserveA, uint256 reserveB) = (0, 0);
        uint256 _totalSupply = 0;
        if (_pair != address(0)) {
            _totalSupply = IERC20(_pair).totalSupply();
            (reserveA, reserveB) = getReserves(tokenA, tokenB, stable);
        }
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
            liquidity = Math.sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
        } else {
            uint256 amountBOptimal = quoteLiquidity(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
                liquidity = Math.min((amountA * _totalSupply) / reserveA, (amountB * _totalSupply) / reserveB);
            } else {
                uint256 amountAOptimal = quoteLiquidity(amountBDesired, reserveB, reserveA);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
                liquidity = Math.min((amountA * _totalSupply) / reserveA, (amountB * _totalSupply) / reserveB);
            }
        }
    }

    function quoteRemoveLiquidity(address tokenA, address tokenB, bool stable, uint256 liquidity)
        external
        view
        returns (uint256 amountA, uint256 amountB)
    {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);

        if (_pair == address(0)) {
            return (0, 0);
        }

        (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB, stable);
        uint256 _totalSupply = IERC20(_pair).totalSupply();

        amountA = (liquidity * reserveA) / _totalSupply; // using balances ensures pro-rata distribution
        amountB = (liquidity * reserveB) / _totalSupply; // using balances ensures pro-rata distribution
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        require(amountADesired >= amountAMin);
        require(amountBDesired >= amountBMin);
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);

        if (_pair == address(0)) {
            _pair = IPairFactory(factory).createPair(tokenA, tokenB, stable);
        }
        (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB, stable);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quoteLiquidity(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "Router: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quoteLiquidity(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "Router: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) =
            _addLiquidity(tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = pairFor(tokenA, tokenB, stable);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IPair(pair).mint(to);
    }

    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        (amountToken, amountETH) =
            _addLiquidity(token, address(weth), stable, amountTokenDesired, msg.value, amountTokenMin, amountETHMin);
        address pair = pairFor(token, address(weth), stable);
        _safeTransferFrom(token, msg.sender, pair, amountToken);
        weth.deposit{value: amountETH}();
        assert(weth.transfer(pair, amountETH));
        liquidity = IPair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) {
            _safeTransferETH(msg.sender, msg.value - amountETH);
        }
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = pairFor(tokenA, tokenB, stable);
        require(IPair(pair).transferFrom(msg.sender, pair, liquidity)); // send liquidity to pair

        uint256 balanceBeforeA = IERC20(tokenA).balanceOf(to);
        uint256 balanceBeforeB = IERC20(tokenB).balanceOf(to);
        IPair(pair).burn(to);
        amountA = IERC20(tokenA).balanceOf(to) - balanceBeforeA;
        amountB = IERC20(tokenB).balanceOf(to) - balanceBeforeB;
        require(amountA >= amountAMin, "Router: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "Router: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidityETH(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token, address(weth), stable, liquidity, amountTokenMin, amountETHMin, address(this), deadline
        );
        _safeTransfer(token, to, amountToken);
        weth.withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        address pair = pairFor(tokenA, tokenB, stable);
        {
            uint256 value = approveMax ? type(uint256).max : liquidity;
            IPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        }

        (amountA, amountB) = removeLiquidity(tokenA, tokenB, stable, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityETHWithPermit(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 amountToken, uint256 amountETH) {
        address pair = pairFor(token, address(weth), stable);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        IPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) =
            removeLiquidityETH(token, stable, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(route[] memory routes, address _to) internal virtual {
        for (uint256 i = 0; i < routes.length; i++) {
            (address token0,) = sortTokens(routes[i].from, routes[i].to);
            IPair pair = IPair(pairFor(routes[i].from, routes[i].to, routes[i].stable));

            (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
            (uint256 reserveInput,) = routes[i].from == token0 ? (reserve0, reserve1) : (reserve1, reserve0);

            uint256 amountIn = IERC20(routes[i].from).balanceOf(address(pair)) - reserveInput;
            uint256 amountOut = pair.getAmountOut(amountIn, routes[i].from);

            (uint256 amount0Out, uint256 amount1Out) =
                routes[i].from == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to =
                i < routes.length - 1 ? pairFor(routes[i + 1].from, routes[i + 1].to, routes[i + 1].stable) : _to;
            IPair(pairFor(routes[i].from, routes[i].to, routes[i].stable)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }

    function swapExactTokensForTokensSimple(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256) {
        route[] memory routes = new route[](1);
        routes[0].from = tokenFrom;
        routes[0].to = tokenTo;
        routes[0].stable = stable;

        uint256 balanceBefore = IERC20(tokenTo).balanceOf(to);

        address pair = pairFor(routes[0].from, routes[0].to, routes[0].stable);

        WrappedExternalBribe weBribe = WrappedExternalBribe(Pair(pair).externalBribe());

        if (address(weBribe) != address(0)) {
            uint256 fee = (routes[0].stable ? 2 : 25) * amountIn / 10000;
            amountIn -= fee;
            _safeTransferFrom(routes[0].from, msg.sender, address(this), fee);
            uint256 bribeAmount = IERC20(routes[0].from).balanceOf(address(this));

            WrappedBribe bribe = WrappedBribe(
                WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).oldBribeToNew(
                    address(weBribe.underlying_bribe())
                )
            );
            if (address(bribe) == address(0)) {
                bribe = WrappedBribe(
                    WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).createBribe(
                        address(weBribe.underlying_bribe())
                    )
                );
            }
            IERC20(routes[0].from).approve(address(bribe), bribeAmount);
            bribe.notifyRewardAmount(routes[0].from, bribeAmount);
        }

        _safeTransferFrom(routes[0].from, msg.sender, pair, amountIn);

        _swap(routes, to);
        uint256 amountOut = IERC20(tokenTo).balanceOf(to) - balanceBefore;
        require(amountOut >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");
        return amountOut;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        route[] calldata routes,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256) {
        address tokenOut = routes[routes.length - 1].to;
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(to);

        address pair = pairFor(routes[0].from, routes[0].to, routes[0].stable);

        WrappedExternalBribe weBribe = WrappedExternalBribe(Pair(pair).externalBribe());

        if (address(weBribe) != address(0)) {
            uint256 fee = (routes[0].stable ? 2 : 25) * amountIn / 10000;
            amountIn -= fee;
            _safeTransferFrom(routes[0].from, msg.sender, address(this), fee);
            uint256 bribeAmount = IERC20(routes[0].from).balanceOf(address(this));

            WrappedBribe bribe = WrappedBribe(
                WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).oldBribeToNew(
                    address(weBribe.underlying_bribe())
                )
            );
            if (address(bribe) == address(0)) {
                bribe = WrappedBribe(
                    WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).createBribe(
                        address(weBribe.underlying_bribe())
                    )
                );
            }
            IERC20(routes[0].from).approve(address(bribe), bribeAmount);
            bribe.notifyRewardAmount(routes[0].from, bribeAmount);
        }

        _safeTransferFrom(routes[0].from, msg.sender, pairFor(routes[0].from, routes[0].to, routes[0].stable), amountIn);
        _swap(routes, to);
        uint256 amountOut = IERC20(tokenOut).balanceOf(to) - balanceBefore;
        require(amountOut >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");
        return amountOut;
    }

    function swapExactETHForTokens(uint256 amountOutMin, route[] calldata routes, address to, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256)
    {
        require(routes[0].from == address(weth), "Router: INVALID_PATH");
        address tokenOut = routes[routes.length - 1].to;
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(to);
        weth.deposit{value: msg.value}();

        address pair = pairFor(routes[0].from, routes[0].to, routes[0].stable);

        WrappedExternalBribe weBribe = WrappedExternalBribe(Pair(pair).externalBribe());
        uint256 amountIn = msg.value;

        if (address(weBribe) != address(0)) {
            uint256 fee = (routes[0].stable ? 2 : 25) * amountIn / 10000;
            amountIn -= fee;
            uint256 bribeAmount = fee;

            WrappedBribe bribe = WrappedBribe(
                WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).oldBribeToNew(
                    address(weBribe.underlying_bribe())
                )
            );
            if (address(bribe) == address(0)) {
                bribe = WrappedBribe(
                    WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).createBribe(
                        address(weBribe.underlying_bribe())
                    )
                );
            }
            IERC20(routes[0].from).approve(address(bribe), bribeAmount);
            bribe.notifyRewardAmount(routes[0].from, bribeAmount);
        }

        assert(weth.transfer(pairFor(routes[0].from, routes[0].to, routes[0].stable), amountIn));
        _swap(routes, to);
        uint256 amountOut = IERC20(tokenOut).balanceOf(to) - balanceBefore;
        require(amountOut >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");
        return amountOut;
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        route[] calldata routes,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256) {
        require(routes[routes.length - 1].to == address(weth), "Router: INVALID_PATH");
        uint256 balanceBefore = IERC20(address(weth)).balanceOf(address(this));
        address pair = pairFor(routes[0].from, routes[0].to, routes[0].stable);

        WrappedExternalBribe weBribe = WrappedExternalBribe(Pair(pair).externalBribe());
        if (address(weBribe) != address(0)) {
            uint256 fee = (routes[0].stable ? 2 : 25) * amountIn / 10000;
            amountIn -= fee;
            _safeTransferFrom(routes[0].from, msg.sender, address(this), fee);
            uint256 bribeAmount = IERC20(routes[0].from).balanceOf(address(this));

            WrappedBribe bribe = WrappedBribe(
                WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).oldBribeToNew(
                    address(weBribe.underlying_bribe())
                )
            );
            if (address(bribe) == address(0)) {
                bribe = WrappedBribe(
                    WrappedBribeFactory(0xe490695Fafe699E85ff4b23bC9986cFE454B65F4).createBribe(
                        address(weBribe.underlying_bribe())
                    )
                );
            }
            IERC20(routes[0].from).approve(address(bribe), bribeAmount);
            bribe.notifyRewardAmount(routes[0].from, bribeAmount);
        }
        _safeTransferFrom(routes[0].from, msg.sender, pairFor(routes[0].from, routes[0].to, routes[0].stable), amountIn);
        _swap(routes, address(this));
        uint256 amountOut = IERC20(address(weth)).balanceOf(address(this)) - balanceBefore;
        weth.withdraw(amountOut);
        _safeTransferETH(to, amountOut);
        require(amountOut >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");
        return amountOut;
    }

    function UNSAFE_swapExactTokensForTokens(
        uint256[] memory amounts,
        route[] calldata routes,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory) {
        _safeTransferFrom(
            routes[0].from, msg.sender, pairFor(routes[0].from, routes[0].to, routes[0].stable), amounts[0]
        );
        _swap(routes, to);
        return amounts;
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
