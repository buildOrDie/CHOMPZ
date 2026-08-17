// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface every CHOMPZ venue adapter implements.
interface IVenueAdapter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        bytes calldata poolParams,
        uint256 deadline
    ) external payable;
}
