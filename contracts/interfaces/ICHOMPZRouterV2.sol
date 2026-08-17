// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICHOMPZRouterV2 {
    struct SwapRoute {
        address router;
        uint256 amountIn;
        bytes data;
    }

    struct Leg {
        uint8 venueId;
        address expectedAdapter;
        address tokenIn;
        address tokenOut;
        bytes poolParams;
    }

    event Swap(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event FeeCollected(address indexed token, uint256 amount);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeVaultUpdated(address indexed oldVault, address indexed newVault);
    event RouterApproved(address indexed router);
    event RouterRevoked(address indexed router);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);
    event VenueManagerSet(address indexed venueManager);
    event VenueRegistered(uint8 indexed venueId, address indexed adapter);
    event VenueRemoved(uint8 indexed venueId);

    function swap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata routerData
    ) external payable returns (uint256 amountOut);

    function swapMultiHop(
        address router,
        address[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata routerData
    ) external payable returns (uint256 amountOut);

    function swapSplit(
        SwapRoute[] calldata routes,
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        uint256 totalAmountOutMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 totalAmountOut);

    function swapModular(
        Leg[] calldata legs,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}
