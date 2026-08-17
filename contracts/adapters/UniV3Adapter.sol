// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {SafeERC20} from "../lib/SafeERC20.sol";

interface IUniV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Source-compatible reconstruction from deployed runtime bytecode.
/// @dev poolParams = abi.encode(uint24 feeTier).
contract UniV3Adapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    address public immutable router;
    error UnexpectedETH();

    constructor(address _router) { router = _router; }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        bytes calldata poolParams,
        uint256
    ) external payable override {
        if (msg.value != 0) revert UnexpectedETH();
        uint24 fee = abi.decode(poolParams, (uint24));

        uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - beforeIn;

        IERC20(tokenIn).forceApprove(router, received);
        IUniV3SwapRouter(router).exactInputSingle(
            IUniV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: received,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(router, 0);
    }
}
