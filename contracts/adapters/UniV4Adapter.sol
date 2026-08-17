// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {IAllowanceTransfer} from "../interfaces/IPermit2.sol";
import {SafeERC20} from "../lib/SafeERC20.sol";

/// @notice Functional source reconstruction of the deployed V4 adapter.
/// @dev poolParams = abi.encode(uint24 fee, int24 tickSpacing, address hooks).
contract UniV4Adapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    address internal constant NATIVE_ETH = address(0);
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;
    uint48 internal constant APPROVAL_TTL = 300;

    address public immutable permit2;
    address public immutable universalRouter;
    address public immutable WETH;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    error SameToken();
    error AmountTooLarge();
    error InvalidPoolKey();
    error IncorrectETHAmount();
    error UnexpectedETH();
    error ETHTransferFailed();

    constructor(address _permit2, address _universalRouter, address _weth) {
        permit2 = _permit2;
        universalRouter = _universalRouter;
        WETH = _weth;
    }

    receive() external payable {}

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        bytes calldata poolParams,
        uint256 deadline
    ) external payable override {
        if (tokenIn == tokenOut) revert SameToken();
        if (amountIn > type(uint128).max) revert AmountTooLarge();

        (uint24 fee, int24 tickSpacing, address hooks) = abi.decode(poolParams, (uint24, int24, address));

        // Modular core normally supplies WETH, but preserve native-aware behavior for compatibility.
        address currencyIn = tokenIn == WETH ? NATIVE_ETH : tokenIn;
        address currencyOut = tokenOut == WETH ? NATIVE_ETH : tokenOut;
        if (currencyIn == currencyOut) revert SameToken();

        (address currency0, address currency1) = uint160(currencyIn) < uint160(currencyOut)
            ? (currencyIn, currencyOut)
            : (currencyOut, currencyIn);
        if (uint160(currency0) >= uint160(currency1)) revert InvalidPoolKey();
        bool zeroForOne = currencyIn == currency0;

        uint256 actualIn;
        uint256 nativeValue;
        if (currencyIn == NATIVE_ETH) {
            if (msg.value == amountIn) {
                actualIn = amountIn;
                nativeValue = amountIn;
            } else {
                if (msg.value != 0) revert IncorrectETHAmount();
                uint256 beforeIn = IERC20(WETH).balanceOf(address(this));
                IERC20(WETH).safeTransferFrom(msg.sender, address(this), amountIn);
                actualIn = IERC20(WETH).balanceOf(address(this)) - beforeIn;
                IWETH(WETH).withdraw(actualIn);
                nativeValue = actualIn;
            }
        } else {
            if (msg.value != 0) revert UnexpectedETH();
            uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            actualIn = IERC20(tokenIn).balanceOf(address(this)) - beforeIn;
            if (actualIn > type(uint128).max) revert AmountTooLarge();
            IERC20(tokenIn).forceApprove(permit2, actualIn);
            IAllowanceTransfer(permit2).approve(tokenIn, universalRouter, uint160(actualIn), uint48(block.timestamp + APPROVAL_TTL));
        }

        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: PoolKey(currency0, currency1, fee, tickSpacing, hooks),
                zeroForOne: zeroForOne,
                amountIn: uint128(actualIn),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(currencyIn, actualIn);
        params[2] = abi.encode(currencyOut, uint256(0));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        IUniversalRouter(universalRouter).execute{value: nativeValue}(abi.encodePacked(V4_SWAP), inputs, deadline);

        if (currencyIn != NATIVE_ETH) {
            IAllowanceTransfer(permit2).approve(tokenIn, universalRouter, 0, 0);
            IERC20(tokenIn).forceApprove(permit2, 0);
        }

        if (currencyOut == NATIVE_ETH) {
            uint256 ethOut = address(this).balance;
            IWETH(WETH).deposit{value: ethOut}();
            IERC20(WETH).safeTransfer(recipient, ethOut);
        } else {
            uint256 out = IERC20(tokenOut).balanceOf(address(this));
            IERC20(tokenOut).safeTransfer(recipient, out);
        }
    }
}
