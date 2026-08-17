// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {SafeERC20} from "../lib/SafeERC20.sol";

interface IUniV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Source-compatible reconstruction from deployed runtime bytecode.
contract UniV2Adapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    address public immutable router;
    error UnexpectedETH();

    constructor(address _router) { router = _router; }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        bytes calldata,
        uint256 deadline
    ) external payable override {
        if (msg.value != 0) revert UnexpectedETH();

        uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - beforeIn;

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        IERC20(tokenIn).forceApprove(router, received);
        IUniV2Router(router).swapExactTokensForTokens(received, 0, path, recipient, deadline);
        IERC20(tokenIn).forceApprove(router, 0);
    }
}
