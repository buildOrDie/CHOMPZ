// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ICHOMPZRouterV2} from "./interfaces/ICHOMPZRouterV2.sol";
import {IVenueAdapter} from "./interfaces/IVenueAdapter.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {IAllowanceTransfer} from "./interfaces/IPermit2.sol";
import {Ownable2Step} from "./lib/Ownable2Step.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";
import {SafeERC20} from "./lib/SafeERC20.sol";

/// @title CHOMPZRouterV2
/// @notice Modular, venue-adapter DEX aggregator router for CHOMPZ on Robinhood Chain. Evolves
///         chompzRouter: keeps the proven money-safety core (swap / swapMultiHop / swapSplit /
///         swapV4Single, balance-diff accounting, aggregate min-out, protocol fee, feeExempt,
///         pause, rescue, Ownable2Step, ReentrancyGuard, SafeERC20, MAX_FEE_BPS cap) VERBATIM, and
///         replaces the hardcoded-venue `swapMultiRouter` with `swapModular`.
///
///         `swapModular` dispatches each leg to a registered VENUE ADAPTER (IVenueAdapter). New
///         DEX venues are added POST-DEPLOY by registering an adapter — one tx, no core redeploy,
///         no proxy, no delegatecall. The money-touching core is immutable and its safety rules
///         never change; only the venue registry is mutable (there is intentionally NO seal on it,
///         mirroring the already-unsealed `approvedRouters` allowlist trust surface).
///
/// @dev SAFETY SPINE (identical discipline to the kept paths):
///      - No delegatecall anywhere. Adapters are plain external CALLS.
///      - Every output is measured by balance-diff; the core NEVER trusts an adapter/router return.
///      - Per leg, the core approves the adapter for EXACTLY that leg's input, then resets to 0
///        after the call. A malicious adapter can waste at most one leg's input; the swap then
///        reverts on the aggregate amountOutMin (or on a zero leg output). It can never drain the
///        core or a user's standing approval, and never touches the user directly.
///      - Fee-on-transfer safe on the input (balance-diff pull in _pullTokenIn).
///
///      NOTE ON via_ir: as with chompzRouter, this contract is deliberately structured with
///      small internal helpers + memory structs to stay under the 16-slot stack limit WITHOUT
///      enabling via_ir (a known footgun for balance-diff/timestamp-sensitive contracts).
contract CHOMPZRouterV2 is ICHOMPZRouterV2, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Sentinel used in tokenIn/tokenOut positions to mean "native ETH".
    address internal constant NATIVE_ETH = address(0);

    uint256 public constant MAX_FEE_BPS = 100; // 1.00% hard cap
    uint256 internal constant MAX_LEGS = 10; // swapModular hop cap (gas + sandwich-surface bound)
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable WETH;

    address public feeVault;
    uint256 public feeBps = 30; // 0.30% default, overwritten by constructor arg

    /// @notice Output tokens exempt from the protocol fee (keyed on the user-facing output token;
    ///         NATIVE_ETH sentinel for native out). Owner-settable, not frozen.
    mapping(address => bool) public feeExempt;

    mapping(address => bool) public approvedRouters;

    bool public paused;

    // --- modular venue-adapter registry -----------------------------------------
    // venueId -> adapter address. Reserve stable ids: 2 = UniV2, 3 = UniV3, 4 = UniV4; new venues
    // get new ids. There is NO seal: `venueManager` (or owner) can register/replace/remove adapters
    // forever. Adapter isolation (scoped approve + reset, no trusted return values) means the
    // registry can NEVER drain principal, touch fees, pause, ownership, or rescue — those stay
    // onlyOwner.
    //
    // HONEST BLAST RADIUS: a rogue/compromised venueManager CAN, however, skim a modular swap DOWN
    // TO each user's own aggregate slippage tolerance (amountOutMin) — by registering a hostile
    // adapter and letting the swap complete just above the floor. It cannot exceed that: the
    // aggregate min-out is enforced on the recipient's real balance-diff, so anything below the
    // user's tolerance reverts atomically. Per-leg adapter pinning (Leg.expectedAdapter, see
    // _validateModularChain) hardens this further: a SILENT mid-flight substitution (front-running
    // setVenueAdapter after a user's tx is in the mempool) now REVERTS with AdapterMismatch rather
    // than skimming — a user pins the exact adapter they quoted against.
    mapping(uint8 => address) public venueAdapter;

    /// @notice Hot dev wallet allowed to register/replace/remove venue adapters ONLY. Cannot move
    ///         funds, change fee, pause, transfer ownership, or approve legacy routers — those stay
    ///         onlyOwner. Owner can change or revoke the venueManager at any time. See the registry
    ///         comment above for the honest skim-to-slippage blast radius and the expectedAdapter pin.
    address public venueManager;

    // --- v4 wiring (owner-settable until sealed) --------------------------------
    address public universalRouter; // v4 execution via UniversalRouter + Permit2
    address public permit2; // canonical Permit2 singleton (input approvals)
    address public poolManager; // v4 PoolManager (reference / monitoring)
    bool public wiringSealed;

    /// @dev false = 5-field v4 ExactInputSingleParams; true = 6-field with minHopPriceX36.
    bool public v4UseMinHopPrice;

    // --- v4 UniversalRouter command + action bytes (verified live on chain 4663) ---
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;
    uint48 internal constant PERMIT2_APPROVAL_TTL = 300;

    /// @dev v4 PoolKey. currency0 < currency1; native ETH = address(0) sorts lowest.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @dev v4 IV4Router.ExactInputSingleParams — 5-field layout (RH mainnet).
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    /// @dev Newer 6-field v4-periphery layout (RH testnet 46630) with minHopPriceX36 before hookData.
    struct ExactInputSingleParamsV6 {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev Common single-route swap params bundled to keep entrypoints under the stack limit.
    struct SwapParams {
        address router;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        address to;
    }

    error Expired();
    error ContractPaused();
    error AlreadyPaused();
    error AlreadyUnpaused();
    error RouterNotApproved(address router);
    error InsufficientOutput(uint256 amountOut, uint256 amountOutMin);
    error AmountMismatch();
    error SwapCallFailed();
    error FeeTooHigh();
    error InvalidPath();
    error ZeroAmount();
    error UnexpectedETH();
    error IncorrectETHAmount();
    error ETHTransferFailed();
    error EmptyRoutes();
    error NothingToRescue();
    error SameToken();
    error InvalidRouter();
    error WiringNotSet();
    error WiringIsSealed();
    error AmountTooLarge();
    error InvalidPoolKey();
    error NotVenueManager();
    error VenueNotRegistered(uint8 venueId);
    error AdapterMismatch(uint8 venueId);

    event UniversalRouterSet(address indexed universalRouter);
    event Permit2Set(address indexed permit2);
    event PoolManagerSet(address indexed poolManager);
    event V4ParamsVersionSet(bool useMinHopPrice);
    event FeeExemptSet(address indexed token, bool exempt);
    event WiringSealed();

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier notSealed() {
        if (wiringSealed) revert WiringIsSealed();
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @dev venueManager OR owner may register/replace/remove venue adapters. Owner is always
    ///      permitted so the cold key can operate the registry without a hot venueManager set.
    modifier onlyVenueManager() {
        if (msg.sender != venueManager && msg.sender != owner) revert NotVenueManager();
        _;
    }

    constructor(address _weth, address _feeVault, uint256 _feeBps) Ownable2Step(msg.sender) {
        if (_weth == address(0)) revert ZeroAddress();
        if (_feeVault == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        WETH = _weth;
        feeVault = _feeVault;
        feeBps = _feeBps;
    }

    /// @dev Required so this contract can receive ETH unwrapped from WETH.withdraw() and native
    ///      output forwarded back by the v4 adapter.
    receive() external payable {}

    // ---------------------------------------------------------------------
    // Swaps (external entrypoints)
    // ---------------------------------------------------------------------

    /// @inheritdoc ICHOMPZRouterV2
    function swap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata routerData
    ) external payable nonReentrant whenNotPaused checkDeadline(deadline) returns (uint256 amountOut) {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == tokenOut) revert SameToken();
        if (!approvedRouters[router]) revert RouterNotApproved(router);

        amountOut = _executeSwap(
            SwapParams({
                router: router,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                amountOutMin: amountOutMin,
                to: to
            }),
            routerData
        );
    }

    /// @inheritdoc ICHOMPZRouterV2
    function swapMultiHop(
        address router,
        address[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata routerData
    ) external payable nonReentrant whenNotPaused checkDeadline(deadline) returns (uint256 amountOut) {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (path.length < 2) revert InvalidPath();
        if (!approvedRouters[router]) revert RouterNotApproved(router);

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        if (tokenIn == tokenOut) revert SameToken();

        amountOut = _executeSwap(
            SwapParams({
                router: router,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                amountOutMin: amountOutMin,
                to: to
            }),
            routerData
        );
    }

    /// @inheritdoc ICHOMPZRouterV2
    /// @dev Balance-diff accounting is measured ONCE around the whole batch of legs (a single
    ///      balanceOf before the loop, a single balanceOf after), not per-leg. Only the aggregate
    ///      `totalAmountOutMin` is enforced on-chain.
    function swapSplit(
        SwapRoute[] calldata routes,
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        uint256 totalAmountOutMin,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused checkDeadline(deadline) returns (uint256 totalAmountOut) {
        if (to == address(0)) revert ZeroAddress();
        if (totalAmountIn == 0) revert ZeroAmount();
        if (routes.length == 0) revert EmptyRoutes();
        if (tokenIn == tokenOut) revert SameToken();

        totalAmountOut = _executeSplit(routes, tokenIn, tokenOut, totalAmountIn, totalAmountOutMin, to);
    }

    /// @inheritdoc ICHOMPZRouterV2
    /// @notice Sequential modular multi-venue swap: each leg runs through the ADAPTER registered
    ///         for its venueId, the output of leg N feeding leg N+1. Adds/routes any venue
    ///         (including v4) post-deploy without a core redeploy.
    /// @dev SECURITY: (1) The leg chain is validated CEI-first (connected resolvedTokenIn -> ... ->
    ///      actualTokenOut, every venueId registered) BEFORE any funds move. (2) Input is pulled by
    ///      balance-diff (FOT-safe). (3) Per-leg adapter approvals are scoped to the exact running
    ///      amount and reset to 0 after each call. (4) Output is balance-diffed per leg (adapter
    ///      return values are never trusted); a zero leg output reverts. (5) The ONLY value
    ///      guarantee is the aggregate `amountOutMin`, enforced on the recipient's REAL balance-diff
    ///      in _settleOutput — a misrouted/hostile adapter can only make the final output fall short,
    ///      reverting the whole tx atomically. No funds are custodied between transactions.
    function swapModular(
        Leg[] calldata legs,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused checkDeadline(deadline) returns (uint256 amountOut) {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (legs.length == 0) revert EmptyRoutes();
        if (legs.length > MAX_LEGS) revert InvalidPath();
        if (tokenIn == tokenOut) revert SameToken();

        amountOut = _executeModular(legs, tokenIn, tokenOut, amountIn, amountOutMin, to, deadline);
    }

    // ---------------------------------------------------------------------
    // Modular orchestration (kept small & single-purpose to avoid stack-too-deep)
    // ---------------------------------------------------------------------

    function _executeModular(
        Leg[] calldata legs,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        address actualTokenOut = tokenOut == NATIVE_ETH ? WETH : tokenOut;
        address resolvedTokenIn = tokenIn == NATIVE_ETH ? WETH : tokenIn;
        if (resolvedTokenIn == actualTokenOut) revert SameToken();

        // CEI: fully validate the leg chain (connectivity + every venueId registered) BEFORE
        // pulling funds or making any external call.
        _validateModularChain(legs, resolvedTokenIn, actualTokenOut);

        (address actualTokenIn, uint256 receivedIn) = _pullTokenIn(tokenIn, amountIn);

        uint256 grossOut = _runModularLegs(legs, actualTokenIn, receivedIn, deadline);

        uint256 fee;
        (amountOut, fee) = _settleOutput(tokenOut, actualTokenOut, grossOut, amountOutMin, to);

        emit Swap(msg.sender, to, tokenIn, tokenOut, amountIn, amountOut, fee);
    }

    /// @dev Validate the legs form a single connected path resolvedTokenIn -> ... -> actualTokenOut
    ///      and that every leg's venueId has a registered adapter. View + pre-funds (CEI): a bad
    ///      chain or unregistered venue reverts before anything is pulled or approved.
    function _validateModularChain(Leg[] calldata legs, address resolvedTokenIn, address actualTokenOut)
        internal
        view
    {
        if (legs[0].tokenIn != resolvedTokenIn) revert InvalidPath();
        if (legs[legs.length - 1].tokenOut != actualTokenOut) revert InvalidPath();
        for (uint256 i = 0; i < legs.length; ++i) {
            address registered = venueAdapter[legs[i].venueId];
            // Keep the registered check first: an unregistered/removed venue reverts VenueNotRegistered
            // (even if the caller pinned address(0) as expectedAdapter).
            if (registered == address(0)) revert VenueNotRegistered(legs[i].venueId);
            // FIX 2 (anti-substitution): pin the adapter per leg. A hot venueManager that front-runs
            // setVenueAdapter to reroute this leg makes the swap REVERT here (pre-funds) instead of
            // silently skimming through a substituted adapter.
            if (registered != legs[i].expectedAdapter) revert AdapterMismatch(legs[i].venueId);
            if (legs[i].tokenIn == legs[i].tokenOut) revert SameToken();
            if (i + 1 < legs.length && legs[i].tokenOut != legs[i + 1].tokenIn) revert InvalidPath();
        }
    }

    /// @dev Run the legs in order via their registered adapters (execution model B — pull). Each leg:
    ///      measure tokenOut balance before -> scope-approve the adapter for the REAL running amount
    ///      (leg N-1's measured output) -> call adapter.swap (recipient forced to this contract) ->
    ///      reset the approval to 0 -> balance-diff the output token to get the amount feeding the
    ///      next leg. NEVER trusts an adapter return value; per-leg minOut is 0 (only the aggregate
    ///      is enforced). A zero leg output dooms the chain (SwapCallFailed).
    function _runModularLegs(Leg[] calldata legs, address actualTokenIn, uint256 amountIn, uint256 deadline)
        internal
        returns (uint256 grossOut)
    {
        address currentToken = actualTokenIn;
        uint256 currentAmount = amountIn;

        for (uint256 i = 0; i < legs.length; ++i) {
            Leg calldata leg = legs[i];
            // leg.tokenIn == currentToken is guaranteed by _validateModularChain.
            address adapter = venueAdapter[leg.venueId]; // non-zero (validated pre-funds)
            uint256 outBefore = IERC20(leg.tokenOut).balanceOf(address(this));

            // Scope-approve exactly this leg's input to the adapter, call it (adapter pulls via
            // transferFrom and sends output back here), then hard-reset the approval to 0. This
            // bounds a hostile/buggy adapter to at most one leg's input.
            IERC20(currentToken).forceApprove(adapter, currentAmount);
            IVenueAdapter(adapter).swap(currentToken, leg.tokenOut, currentAmount, address(this), leg.poolParams, deadline);
            IERC20(currentToken).forceApprove(adapter, 0);

            // Checked math: reverts if the adapter somehow decreased our balance of the output token.
            uint256 legOut = IERC20(leg.tokenOut).balanceOf(address(this)) - outBefore;
            if (legOut == 0) revert SwapCallFailed(); // a leg producing nothing dooms the chain
            currentToken = leg.tokenOut;
            currentAmount = legOut;
        }
        grossOut = currentAmount;
    }

    // ---------------------------------------------------------------------
    // Internal swap orchestration (legacy paths — ported verbatim)
    // ---------------------------------------------------------------------

    function _executeSwap(SwapParams memory p, bytes calldata routerData) internal returns (uint256 amountOut) {
        // M1 fix: compare the RESOLVED tokens (native sentinel -> WETH) before touching any funds.
        address actualTokenOut = p.tokenOut == NATIVE_ETH ? WETH : p.tokenOut;
        address resolvedTokenIn = p.tokenIn == NATIVE_ETH ? WETH : p.tokenIn;
        if (resolvedTokenIn == actualTokenOut) revert SameToken();

        (address actualTokenIn, uint256 receivedIn) = _pullTokenIn(p.tokenIn, p.amountIn);

        // Approve/execute only what we actually received (F1: FOT input safe-reverts, never drains).
        uint256 grossOut = _executeRouterSwap(p.router, actualTokenIn, actualTokenOut, receivedIn, routerData);

        uint256 fee;
        (amountOut, fee) = _settleOutput(p.tokenOut, actualTokenOut, grossOut, p.amountOutMin, p.to);

        emit Swap(msg.sender, p.to, p.tokenIn, p.tokenOut, p.amountIn, amountOut, fee);
    }

    function _executeSplit(
        SwapRoute[] calldata routes,
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        uint256 totalAmountOutMin,
        address to
    ) internal returns (uint256 totalAmountOut) {
        uint256 sumIn = _validateRoutes(routes);
        if (sumIn != totalAmountIn) revert AmountMismatch();

        // M1 fix: same resolved-token guard as _executeSwap.
        address actualTokenOut = tokenOut == NATIVE_ETH ? WETH : tokenOut;
        address resolvedTokenIn = tokenIn == NATIVE_ETH ? WETH : tokenIn;
        if (resolvedTokenIn == actualTokenOut) revert SameToken();

        (address actualTokenIn, uint256 receivedIn) = _pullTokenIn(tokenIn, totalAmountIn);
        // Split routes commit fixed per-branch amounts summing to totalAmountIn; reject FOT input. F1.
        if (receivedIn != totalAmountIn) revert AmountMismatch();

        uint256 grossOut = _executeRouterLegs(routes, actualTokenIn, actualTokenOut);

        uint256 fee;
        (totalAmountOut, fee) = _settleOutput(tokenOut, actualTokenOut, grossOut, totalAmountOutMin, to);

        emit Swap(msg.sender, to, tokenIn, tokenOut, totalAmountIn, totalAmountOut, fee);
    }

    /// @dev First pass over routes: validate each router is approved and amounts non-zero, sum
    ///      amountIn. Done before any external calls (CEI).
    function _validateRoutes(SwapRoute[] calldata routes) internal view returns (uint256 sumIn) {
        for (uint256 i = 0; i < routes.length; ++i) {
            if (!approvedRouters[routes[i].router]) revert RouterNotApproved(routes[i].router);
            if (routes[i].amountIn == 0) revert ZeroAmount();
            sumIn += routes[i].amountIn;
        }
    }

    /// @dev Second pass over routes: execute each leg's router call. Output is measured once, by
    ///      the caller, around this whole function (balance-diff over the batch).
    function _executeRouterLegs(SwapRoute[] calldata routes, address actualTokenIn, address actualTokenOut)
        internal
        returns (uint256 grossOut)
    {
        uint256 balanceBefore = IERC20(actualTokenOut).balanceOf(address(this));

        for (uint256 i = 0; i < routes.length; ++i) {
            SwapRoute calldata route = routes[i];
            IERC20(actualTokenIn).forceApprove(route.router, route.amountIn);
            (bool success,) = route.router.call(route.data);
            if (!success) revert SwapCallFailed();
            IERC20(actualTokenIn).forceApprove(route.router, 0);
        }

        uint256 balanceAfter = IERC20(actualTokenOut).balanceOf(address(this));
        grossOut = balanceAfter - balanceBefore;
    }

    /// @dev Pulls `amountIn` of `tokenIn` into this contract. Native sentinel wraps msg.value to
    ///      WETH (exact match). Returns the actual ERC20 held AND the REAL amount received (F1:
    ///      balance-diffed, so a FOT input never bleeds resting balance).
    function _pullTokenIn(address tokenIn, uint256 amountIn)
        internal
        returns (address actualTokenIn, uint256 receivedIn)
    {
        if (tokenIn == NATIVE_ETH) {
            if (msg.value != amountIn) revert IncorrectETHAmount();
            IWETH(WETH).deposit{value: amountIn}();
            return (WETH, amountIn); // WETH deposit is exact 1:1
        }
        if (msg.value != 0) revert UnexpectedETH();
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        receivedIn = IERC20(tokenIn).balanceOf(address(this)) - balBefore;
        return (tokenIn, receivedIn);
    }

    /// @dev Approves `router` for exactly `amountIn` of `actualTokenIn`, forwards `routerData`
    ///      verbatim, resets approval to 0, then balance-diffs `actualTokenOut`. NEVER trusts a
    ///      return value from the router call.
    function _executeRouterSwap(
        address router,
        address actualTokenIn,
        address actualTokenOut,
        uint256 amountIn,
        bytes calldata routerData
    ) internal returns (uint256 grossOut) {
        uint256 balanceBefore = IERC20(actualTokenOut).balanceOf(address(this));

        IERC20(actualTokenIn).forceApprove(router, amountIn);
        (bool success,) = router.call(routerData);
        if (!success) revert SwapCallFailed();
        IERC20(actualTokenIn).forceApprove(router, 0);

        uint256 balanceAfter = IERC20(actualTokenOut).balanceOf(address(this));
        grossOut = balanceAfter - balanceBefore;
    }

    /// @dev Deducts the protocol fee from `grossOut`, enforces `amountOutMin` against the recipient's
    ///      REAL received amount (M2 discipline), sends the fee to feeVault, and delivers the net to
    ///      `to` — unwrapping WETH to ETH if the caller requested NATIVE_ETH. Fee is always paid in
    ///      `actualTokenOut` (WETH, not ETH, for ETH-out swaps).
    function _settleOutput(
        address tokenOutRequested,
        address actualTokenOut,
        uint256 grossOut,
        uint256 amountOutMin,
        address to
    ) internal returns (uint256 netOut, uint256 fee) {
        fee = feeExempt[tokenOutRequested] ? 0 : (grossOut * feeBps) / BPS_DENOMINATOR;
        netOut = grossOut - fee;

        if (tokenOutRequested == NATIVE_ETH) {
            // WETH is never FOT, so unwrapping `netOut` 1:1 to ETH means the recipient's received
            // amount equals netOut — checking netOut against amountOutMin is exact here.
            if (netOut < amountOutMin) revert InsufficientOutput(netOut, amountOutMin);

            if (fee > 0) {
                IERC20(actualTokenOut).safeTransfer(feeVault, fee);
                emit FeeCollected(actualTokenOut, fee);
            }

            IWETH(WETH).withdraw(netOut);
            (bool ok,) = to.call{value: netOut}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            if (fee > 0) {
                IERC20(actualTokenOut).safeTransfer(feeVault, fee);
                emit FeeCollected(actualTokenOut, fee);
            }

            // M2 fix: never trust `netOut` as what `to` receives — actualTokenOut may be FOT.
            // Measure the recipient's real balance-diff and enforce amountOutMin against that.
            uint256 toBalanceBefore = IERC20(actualTokenOut).balanceOf(to);
            IERC20(actualTokenOut).safeTransfer(to, netOut);
            uint256 received = IERC20(actualTokenOut).balanceOf(to) - toBalanceBefore;
            if (received < amountOutMin) revert InsufficientOutput(received, amountOutMin);
        }
    }

    // ---------------------------------------------------------------------
    // Uniswap v4 (hardened UniversalRouter + Permit2 adapter) — ported verbatim
    // ---------------------------------------------------------------------

    /// @notice Swap through a Uniswap v4 pool (exact-in, single hop) via the UniversalRouter.
    /// @dev SECURITY MODEL: builds the UniversalRouter command/action bytes itself from the TYPED
    ///      PoolKey params (never forwards arbitrary caller calldata). Funds are pulled via a
    ///      per-swap-scoped Permit2 approval, output lands here via TAKE_ALL, and the real received
    ///      amount is balance-diffed, fee'd, and forwarded to `to`.
    function swapV4Single(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused checkDeadline(deadline) returns (uint256 amountOut) {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (universalRouter == address(0) || permit2 == address(0)) revert WiringNotSet();
        if (amountIn > type(uint128).max || amountOutMin > type(uint128).max) revert AmountTooLarge();
        if (uint160(key.currency0) >= uint160(key.currency1)) revert InvalidPoolKey();

        address outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 grossOut = _pullExecuteV4(key, zeroForOne, amountIn, amountOutMin, deadline);

        uint256 fee;
        (amountOut, fee) = _settleV4Output(outputCurrency, grossOut, amountOutMin, to);

        emit Swap(
            msg.sender, to, zeroForOne ? key.currency0 : key.currency1, outputCurrency, amountIn, amountOut, fee
        );
    }

    function _pullExecuteV4(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 grossOut) {
        address inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        address outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        if (inputCurrency == outputCurrency) revert SameToken();

        (bool inputIsNative, uint256 actualIn) = _pullV4Input(inputCurrency, amountIn);
        // FIX 4: re-check the uint128 bound on the RECEIVED amount (balance-diffed), not just the
        // requested amountIn, before the uint128 cast in _executeV4.
        if (actualIn > type(uint128).max) revert AmountTooLarge();
        bool outputIsNative = outputCurrency == NATIVE_ETH;

        uint256 balanceBefore =
            outputIsNative ? address(this).balance : IERC20(outputCurrency).balanceOf(address(this));

        _executeV4(key, zeroForOne, uint128(actualIn), uint128(amountOutMin), inputIsNative ? actualIn : 0, deadline);

        uint256 balanceAfter =
            outputIsNative ? address(this).balance : IERC20(outputCurrency).balanceOf(address(this));
        grossOut = balanceAfter - balanceBefore;

        if (!inputIsNative) {
            IAllowanceTransfer(permit2).approve(inputCurrency, universalRouter, 0, 0);
            IERC20(inputCurrency).forceApprove(permit2, 0);
        }
    }

    function _pullV4Input(address inputCurrency, uint256 amountIn)
        internal
        returns (bool inputIsNative, uint256 actualIn)
    {
        if (inputCurrency == NATIVE_ETH) {
            if (msg.value != amountIn) revert IncorrectETHAmount();
            return (true, amountIn);
        }
        if (msg.value != 0) revert UnexpectedETH();
        uint256 balBefore = IERC20(inputCurrency).balanceOf(address(this));
        IERC20(inputCurrency).safeTransferFrom(msg.sender, address(this), amountIn);
        actualIn = IERC20(inputCurrency).balanceOf(address(this)) - balBefore;
        IERC20(inputCurrency).forceApprove(permit2, actualIn);
        IAllowanceTransfer(permit2).approve(
            inputCurrency, universalRouter, uint160(actualIn), uint48(block.timestamp + PERMIT2_APPROVAL_TTL)
        );
        return (false, actualIn);
    }

    function _executeV4(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMin,
        uint256 nativeValue,
        uint256 deadline
    ) internal {
        address inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        address outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = v4UseMinHopPrice
            ? abi.encode(
                ExactInputSingleParamsV6({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin,
                    minHopPriceX36: 0,
                    hookData: bytes("")
                })
            )
            : abi.encode(
                ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin,
                    hookData: bytes("")
                })
            );
        params[1] = abi.encode(inputCurrency, uint256(amountIn)); // SETTLE_ALL(currency, maxAmount)
        params[2] = abi.encode(outputCurrency, uint256(amountOutMin)); // TAKE_ALL(currency, minAmount)

        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        IUniversalRouter(universalRouter).execute{value: nativeValue}(commands, inputs, deadline);
    }

    function _settleV4Output(address outputCurrency, uint256 grossOut, uint256 amountOutMin, address to)
        internal
        returns (uint256 netOut, uint256 fee)
    {
        fee = feeExempt[outputCurrency] ? 0 : (grossOut * feeBps) / BPS_DENOMINATOR;
        netOut = grossOut - fee;

        if (outputCurrency == NATIVE_ETH) {
            if (netOut < amountOutMin) revert InsufficientOutput(netOut, amountOutMin);
            if (fee > 0) {
                // L-2: pay native-out fee in WETH so feeVault never needs a payable receive().
                IWETH(WETH).deposit{value: fee}();
                IERC20(WETH).safeTransfer(feeVault, fee);
                emit FeeCollected(WETH, fee);
            }
            (bool ok,) = to.call{value: netOut}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            if (fee > 0) {
                IERC20(outputCurrency).safeTransfer(feeVault, fee);
                emit FeeCollected(outputCurrency, fee);
            }
            uint256 toBalanceBefore = IERC20(outputCurrency).balanceOf(to);
            IERC20(outputCurrency).safeTransfer(to, netOut);
            uint256 received = IERC20(outputCurrency).balanceOf(to) - toBalanceBefore;
            if (received < amountOutMin) revert InsufficientOutput(received, amountOutMin);
        }
    }

    // ---------------------------------------------------------------------
    // Modular venue registry admin
    // ---------------------------------------------------------------------

    /// @notice Set the hot venueManager allowed to register/replace/remove venue adapters. Owner-
    ///         only. Pass address(0) to disable delegation (only owner can then operate the registry).
    function setVenueManager(address _venueManager) external onlyOwner {
        venueManager = _venueManager;
        emit VenueManagerSet(_venueManager);
    }

    /// @notice Register (or replace) the adapter for `venueId`. venueManager or owner. NO seal.
    /// @dev Drain-safe by construction: the core hands an adapter at most one leg's input (scoped
    ///      approve + reset), trusts no return value (balance-diff), and enforces aggregate min-out.
    function setVenueAdapter(uint8 venueId, address adapter) external onlyVenueManager {
        if (adapter == address(0)) revert ZeroAddress();
        // FIX 5: mirror approveRouter's guard — the core must never point a venue at itself (would
        // let the registry re-enter money-touching paths) or at WETH (a value-bearing contract).
        if (adapter == address(this) || adapter == WETH) revert InvalidRouter();
        venueAdapter[venueId] = adapter;
        emit VenueRegistered(venueId, adapter);
    }

    /// @notice Remove the adapter for `venueId`. venueManager or owner. Subsequent legs on that
    ///         venueId revert VenueNotRegistered.
    function removeVenueAdapter(uint8 venueId) external onlyVenueManager {
        delete venueAdapter[venueId];
        emit VenueRemoved(venueId);
    }

    // ---------------------------------------------------------------------
    // v4 wiring admin (owner-only, sealable) — ported verbatim
    // ---------------------------------------------------------------------

    function setUniversalRouter(address _universalRouter) external onlyOwner notSealed {
        if (_universalRouter == address(0)) revert ZeroAddress();
        universalRouter = _universalRouter;
        emit UniversalRouterSet(_universalRouter);
    }

    function setPermit2(address _permit2) external onlyOwner notSealed {
        if (_permit2 == address(0)) revert ZeroAddress();
        permit2 = _permit2;
        emit Permit2Set(_permit2);
    }

    function setPoolManager(address _poolManager) external onlyOwner notSealed {
        if (_poolManager == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        emit PoolManagerSet(_poolManager);
    }

    function setV4UseMinHopPrice(bool on) external onlyOwner notSealed {
        v4UseMinHopPrice = on;
        emit V4ParamsVersionSet(on);
    }

    /// @notice One-way lock: permanently freezes universalRouter/permit2/poolManager. Does NOT
    ///         touch the venue registry (which has no seal by design).
    function sealWiring() external onlyOwner {
        if (universalRouter == address(0) || permit2 == address(0)) revert WiringNotSet();
        wiringSealed = true;
        emit WiringSealed();
    }

    // ---------------------------------------------------------------------
    // Fee / router / pause / rescue admin (owner-only) — ported verbatim
    // ---------------------------------------------------------------------

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeBpsUpdated(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    /// @notice Exempt (or un-exempt) an OUTPUT token from the protocol fee. Swaps into `token` pay
    ///         0 fee. Use the NATIVE_ETH sentinel (address(0)) to exempt native-ETH-out swaps.
    function setFeeExempt(address token, bool exempt) external onlyOwner {
        feeExempt[token] = exempt;
        emit FeeExemptSet(token, exempt);
    }

    function setFeeVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        emit FeeVaultUpdated(feeVault, _vault);
        feeVault = _vault;
    }

    /// @notice Approve a legacy swap router that arbitrary caller `routerData` may be forwarded to
    ///         (used by swap / swapMultiHop / swapSplit). NEVER approve UniversalRouter / Permit2 /
    ///         Multicall or any "execute arbitrary commands" contract (audit H1).
    function approveRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        if (router == address(this) || router == WETH) revert InvalidRouter();
        approvedRouters[router] = true;
        emit RouterApproved(router);
    }

    function revokeRouter(address router) external onlyOwner {
        approvedRouters[router] = false;
        emit RouterRevoked(router);
    }

    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert AlreadyUnpaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Emergency ERC20 recovery. Explicit destination, onlyOwner. Works even while paused.
    function rescueTokens(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToRescue();
        IERC20(token).safeTransfer(to, balance);
        emit TokensRescued(token, to, balance);
    }

    /// @notice Emergency native ETH recovery. Explicit destination, onlyOwner.
    function rescueETH(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToRescue();
        (bool ok,) = to.call{value: balance}("");
        if (!ok) revert ETHTransferFailed();
        emit ETHRescued(to, balance);
    }
}
