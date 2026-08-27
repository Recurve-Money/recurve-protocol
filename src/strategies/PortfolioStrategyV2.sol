// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal swap surface a strategy needs. Matches Uniswap V3's
///         `ISwapRouter.exactInputSingle` so a real router can be dropped in
///         without an adapter in between.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @title PortfolioStrategy
/// @notice A weighted basket the agent can rebalance, and nothing else.
///
/// @dev This exists to close the gap between what the docs promise and what the
///      governor can enforce. `RecurveGovernor.execute` forwards arbitrary
///      calldata to an arbitrary target, which means the only thing standing
///      between an agent and a drained vault is the veto plus watcher review.
///      Those are real, but they are social defences on a hot path.
///
///      A strategy contract narrows the surface to something a reviewer can
///      check in seconds: the token set is fixed at construction, weights must
///      sum to 100%, and the only outbound call is a swap between two tokens
///      already in that set. An agent proposing against this cannot invent a
///      transfer, cannot reach a token nobody approved, and cannot move value
///      anywhere except back into the vault.
contract PortfolioStrategyV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Vault this strategy serves. The only address funds return to.
    address public immutable vault;

    /// @notice Governor allowed to drive this strategy.
    address public immutable governor;

    /// @notice Denomination asset. Everything is bought from and sold back into it.
    IERC20 public immutable baseAsset;

    /// @notice Swap venue. Fixed at construction so a proposal cannot redirect it.
    ISwapRouter public immutable router;

    /// @notice Tokens this strategy may ever hold. Fixed at construction.
    address[] public tokens;
    mapping(address => bool) public isAllowed;

    /// @notice Target weight per token in basis points, in `tokens` order.
    uint256[] public weights;

    /// @notice Pool fee tier used for each token against the base asset.
    mapping(address => uint24) public feeTier;

    /// @notice Cap on how far a swap may move against the caller, in bps.
    /// @dev Bounded at construction. A proposal that could set this freely could
    ///      set it to 100% and sandwich the vault legally.
    uint256 public immutable maxSlippageBps;

    uint256 internal constant BPS = 10_000;

    event WeightsSet(uint256[] weights);
    event Rebalanced(address indexed token, uint256 amountIn, uint256 amountOut);
    event Liquidated(uint256 returnedToVault);

    error OnlyGovernor();
    error TokenNotAllowed();
    error WeightsMustSumToBps();
    error WeightCountMismatch();
    error SlippageTooHigh();
    error NoTokens();
    error DuplicateToken();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor();
        _;
    }

    constructor(
        address vault_,
        address governor_,
        IERC20 baseAsset_,
        ISwapRouter router_,
        address[] memory tokens_,
        uint24[] memory feeTiers_,
        uint256 maxSlippageBps_
    ) {
        if (tokens_.length == 0) revert NoTokens();
        if (tokens_.length != feeTiers_.length) revert WeightCountMismatch();
        if (maxSlippageBps_ > 1000) revert SlippageTooHigh();

        vault = vault_;
        governor = governor_;
        baseAsset = baseAsset_;
        router = router_;
        maxSlippageBps = maxSlippageBps_;

        for (uint256 i; i < tokens_.length; ++i) {
            address t = tokens_[i];
            if (isAllowed[t]) revert DuplicateToken();
            isAllowed[t] = true;
            tokens.push(t);
            feeTier[t] = feeTiers_[i];
            weights.push(0);
        }
    }

    // ---------------------------------------------------------------- weights

    /// @notice Set target weights. This is the entire decision surface an agent has.
    /// @dev Weights must sum to exactly 100%. Allowing less would leave an
    ///      unallocated remainder with no owner; allowing more would silently
    ///      truncate on the last leg.
    function setWeights(uint256[] calldata newWeights) external onlyGovernor {
        if (newWeights.length != tokens.length) revert WeightCountMismatch();

        uint256 sum;
        for (uint256 i; i < newWeights.length; ++i) {
            sum += newWeights[i];
        }
        if (sum != BPS) revert WeightsMustSumToBps();

        for (uint256 i; i < newWeights.length; ++i) {
            weights[i] = newWeights[i];
        }

        emit WeightsSet(newWeights);
    }

    // ---------------------------------------------------------------- rebalance

    /// @notice Buy one basket leg with base asset held by this strategy.
    /// @param token Which leg. Must be in the allowed set.
    /// @param amountIn Base asset to spend.
    /// @param minAmountOut Caller's floor, checked against the slippage cap.
    /// @dev The agent supplies `minAmountOut` because it has the price context;
    ///      the contract refuses anything looser than `maxSlippageBps` so a
    ///      careless or hostile floor cannot be used to hand value to a sandwich.
    function buy(address token, uint256 amountIn, uint256 minAmountOut, uint256 quotedOut)
        external
        onlyGovernor
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!isAllowed[token]) revert TokenNotAllowed();
        _requireWithinSlippage(minAmountOut, quotedOut);

        baseAsset.forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(baseAsset),
                tokenOut: token,
                fee: feeTier[token],
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Leave no standing allowance behind. A router that later turns
        // malicious should find nothing left to pull.
        baseAsset.forceApprove(address(router), 0);

        emit Rebalanced(token, amountIn, amountOut);
    }

    /// @notice Sell one basket leg back into the base asset.
    function sell(address token, uint256 amountIn, uint256 minAmountOut, uint256 quotedOut)
        external
        onlyGovernor
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!isAllowed[token]) revert TokenNotAllowed();
        _requireWithinSlippage(minAmountOut, quotedOut);

        IERC20(token).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(baseAsset),
                fee: feeTier[token],
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(token).forceApprove(address(router), 0);

        emit Rebalanced(token, amountIn, amountOut);
    }

    // ---------------------------------------------------------------- exit

    /// @notice Send every base asset held back to the vault.
    /// @dev The destination is immutable and set to the vault at construction,
    ///      so there is no version of this call that pays anyone else. Legs must
    ///      be sold first; whatever is unsold stays put rather than being
    ///      valued at a guess.
    function returnToVault() external onlyGovernor nonReentrant returns (uint256 amount) {
        amount = baseAsset.balanceOf(address(this));
        if (amount > 0) baseAsset.safeTransfer(vault, amount);
        emit Liquidated(amount);
    }

    // ---------------------------------------------------------------- views

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function allTokens() external view returns (address[] memory) {
        return tokens;
    }

    function allWeights() external view returns (uint256[] memory) {
        return weights;
    }

    /// @notice Base asset plus every leg's raw balance.
    /// @dev Balances only. Valuing the legs needs a price, and a strategy that
    ///      priced itself would be the thing deciding what the vault is worth.
    function holdings()
        external
        view
        returns (uint256 base, address[] memory tokens_, uint256[] memory balances)
    {
        base = baseAsset.balanceOf(address(this));
        tokens_ = tokens;
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    // ---------------------------------------------------------------- internal

    function _requireWithinSlippage(uint256 minOut, uint256 quotedOut) internal view {
        // A quote of zero means the caller declined to state one, which is the
        // same as declining to bound the trade.
        if (quotedOut == 0) revert SlippageTooHigh();
        uint256 floor = quotedOut * (BPS - maxSlippageBps) / BPS;
        if (minOut < floor) revert SlippageTooHigh();
    }
}
