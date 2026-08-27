// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter, PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {RecurveVault} from "../src/RecurveVault.sol";
import {RecurveGovernor} from "../src/RecurveGovernor.sol";
import {WatcherRegistry} from "../src/WatcherRegistry.sol";

contract Token is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev Router stub with a settable price, so tests can drive a swap to a bad
///      fill and check the slippage guard actually bites.
contract MockRouter is ISwapRouter {
    /// @notice out per 1e18 in, per (tokenIn, tokenOut) pair.
    mapping(address => mapping(address => uint256)) public rate;

    function setRate(address i, address o, uint256 r) external {
        rate[i][o] = r;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = p.amountIn * rate[p.tokenIn][p.tokenOut] / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        Token(p.tokenOut).mint(p.recipient, amountOut);
    }
}

contract PortfolioStrategyTest is Test {
    Token internal usd;
    Token internal tokenA;
    Token internal tokenB;
    MockRouter internal router;
    PortfolioStrategy internal strategy;

    RecurveVault internal vault;
    RecurveGovernor internal governor;
    WatcherRegistry internal registry;
    Token internal reve;

    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal alice = makeAddr("alice");
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        usd = new Token("Mock USD", "mUSD");
        tokenA = new Token("Alpha", "ALPHA");
        tokenB = new Token("Beta", "BETA");
        reve = new Token("Recurve", "REVE");
        router = new MockRouter();

        registry = new WatcherRegistry(IERC20(address(reve)), 1_000e18, 7 days, admin);

        vault = new RecurveVault(IERC20(address(usd)), "Fund", "rvF", type(uint256).max);
        governor = new RecurveGovernor(vault, registry, agent, 6 hours, 3000, 2, 1500, treasury);
        vault.setGovernor(address(governor));

        vm.prank(admin);
        registry.setGovernor(address(governor));

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        uint24[] memory fees = new uint24[](2);
        fees[0] = 3000;
        fees[1] = 3000;

        strategy = new PortfolioStrategy(
            address(vault), address(governor), IERC20(address(usd)), router, tokens, fees, 100
        );

        // 1 usd buys 2 ALPHA, 1 usd buys 4 BETA
        router.setRate(address(usd), address(tokenA), 2e18);
        router.setRate(address(usd), address(tokenB), 4e18);
        router.setRate(address(tokenA), address(usd), 0.5e18);

        usd.mint(alice, 1_000_000e18);
        usd.mint(address(strategy), 10_000e18);
    }

    // ---------------------------------------------------------------- weights

    function test_setWeights_requiresFullAllocation() public {
        uint256[] memory w = new uint256[](2);
        w[0] = 5000;
        w[1] = 4000; // 90%

        vm.expectRevert(PortfolioStrategy.WeightsMustSumToBps.selector);
        vm.prank(address(governor));
        strategy.setWeights(w);
    }

    function test_setWeights_rejectsOverAllocation() public {
        uint256[] memory w = new uint256[](2);
        w[0] = 6000;
        w[1] = 6000; // 120%

        vm.expectRevert(PortfolioStrategy.WeightsMustSumToBps.selector);
        vm.prank(address(governor));
        strategy.setWeights(w);
    }

    function test_setWeights_acceptsExactAllocation() public {
        uint256[] memory w = new uint256[](2);
        w[0] = 7000;
        w[1] = 3000;

        vm.prank(address(governor));
        strategy.setWeights(w);

        assertEq(strategy.weights(0), 7000);
        assertEq(strategy.weights(1), 3000);
    }

    function test_setWeights_onlyGovernor() public {
        uint256[] memory w = new uint256[](2);
        w[0] = 5000;
        w[1] = 5000;

        vm.expectRevert(PortfolioStrategy.OnlyGovernor.selector);
        vm.prank(agent);
        strategy.setWeights(w);
    }

    function test_setWeights_rejectsWrongLength() public {
        uint256[] memory w = new uint256[](3);
        w[0] = 10_000;

        vm.expectRevert(PortfolioStrategy.WeightCountMismatch.selector);
        vm.prank(address(governor));
        strategy.setWeights(w);
    }

    // ---------------------------------------------------------------- token set

    function test_buy_rejectsTokenOutsideBasket() public {
        Token rogue = new Token("Rogue", "RGE");

        vm.expectRevert(PortfolioStrategy.TokenNotAllowed.selector);
        vm.prank(address(governor));
        strategy.buy(address(rogue), 100e18, 1e18, 2e18);
    }

    function test_constructor_rejectsDuplicateToken() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenA);
        uint24[] memory fees = new uint24[](2);

        vm.expectRevert(PortfolioStrategy.DuplicateToken.selector);
        new PortfolioStrategy(
            address(vault), address(governor), IERC20(address(usd)), router, tokens, fees, 100
        );
    }

    function test_constructor_capsSlippageSetting() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint24[] memory fees = new uint24[](1);

        vm.expectRevert(PortfolioStrategy.SlippageTooHigh.selector);
        new PortfolioStrategy(
            address(vault), address(governor), IERC20(address(usd)), router, tokens, fees, 1001
        );
    }

    // ---------------------------------------------------------------- swaps

    function test_buy_executesAndHoldsTheLeg() public {
        vm.prank(address(governor));
        uint256 out = strategy.buy(address(tokenA), 1_000e18, 1_990e18, 2_000e18);

        assertEq(out, 2_000e18);
        assertEq(tokenA.balanceOf(address(strategy)), 2_000e18);
    }

    function test_buy_rejectsLooseSlippageFloor() public {
        // Quote says 2000 out; a 1% cap means the floor is 1980. Asking for 1500
        // hands 25% to whoever is watching the mempool.
        vm.expectRevert(PortfolioStrategy.SlippageTooHigh.selector);
        vm.prank(address(governor));
        strategy.buy(address(tokenA), 1_000e18, 1_500e18, 2_000e18);
    }

    function test_buy_rejectsMissingQuote() public {
        vm.expectRevert(PortfolioStrategy.SlippageTooHigh.selector);
        vm.prank(address(governor));
        strategy.buy(address(tokenA), 1_000e18, 0, 0);
    }

    function test_buy_revertsWhenFillIsWorseThanFloor() public {
        // Price moves against the trade between quote and execution.
        router.setRate(address(usd), address(tokenA), 1.5e18);

        vm.expectRevert("Too little received");
        vm.prank(address(governor));
        strategy.buy(address(tokenA), 1_000e18, 1_990e18, 2_000e18);
    }

    function test_buy_leavesNoStandingAllowance() public {
        vm.prank(address(governor));
        strategy.buy(address(tokenA), 1_000e18, 1_990e18, 2_000e18);

        assertEq(usd.allowance(address(strategy), address(router)), 0);
    }

    function test_sell_returnsToBaseAsset() public {
        vm.startPrank(address(governor));
        strategy.buy(address(tokenA), 1_000e18, 1_990e18, 2_000e18);
        uint256 before = usd.balanceOf(address(strategy));
        strategy.sell(address(tokenA), 2_000e18, 995e18, 1_000e18);
        vm.stopPrank();

        assertGt(usd.balanceOf(address(strategy)), before);
        assertEq(tokenA.balanceOf(address(strategy)), 0);
    }

    function test_swaps_onlyGovernor() public {
        vm.expectRevert(PortfolioStrategy.OnlyGovernor.selector);
        vm.prank(agent);
        strategy.buy(address(tokenA), 100e18, 199e18, 200e18);

        vm.expectRevert(PortfolioStrategy.OnlyGovernor.selector);
        vm.prank(alice);
        strategy.sell(address(tokenA), 100e18, 49e18, 50e18);
    }

    // ---------------------------------------------------------------- exit

    function test_returnToVault_paysOnlyTheVault() public {
        uint256 held = usd.balanceOf(address(strategy));

        vm.prank(address(governor));
        uint256 sent = strategy.returnToVault();

        assertEq(sent, held);
        assertEq(usd.balanceOf(address(vault)), held);
        assertEq(usd.balanceOf(address(strategy)), 0);
    }

    function test_returnToVault_onlyGovernor() public {
        vm.expectRevert(PortfolioStrategy.OnlyGovernor.selector);
        vm.prank(agent);
        strategy.returnToVault();
    }

    function test_holdings_reportsBaseAndLegs() public {
        vm.prank(address(governor));
        strategy.buy(address(tokenA), 1_000e18, 1_990e18, 2_000e18);

        (uint256 base, address[] memory tokens, uint256[] memory balances) = strategy.holdings();

        assertEq(base, 9_000e18);
        assertEq(tokens.length, 2);
        assertEq(balances[0], 2_000e18);
        assertEq(balances[1], 0);
    }

    // ---------------------------------------------------------------- agents

    function test_agents_startsWithTheDeployedOne() public view {
        assertTrue(governor.isAgent(agent));
        assertEq(governor.agentCount(), 1);
    }

    function test_addAgent_lettsTheNewOnePropose() public {
        vm.prank(agent);
        governor.addAgent(agent2);

        assertTrue(governor.isAgent(agent2));
        assertEq(governor.agentCount(), 2);

        vm.roll(block.number + 1);
        vm.prank(agent2);
        governor.propose(address(strategy), 0, "");
    }

    function test_addAgent_onlyAdmin() public {
        vm.expectRevert(RecurveGovernor.OnlyAgentAdmin.selector);
        vm.prank(alice);
        governor.addAgent(agent2);
    }

    function test_addAgent_rejectsDuplicate() public {
        vm.expectRevert(RecurveGovernor.AlreadyAgent.selector);
        vm.prank(agent);
        governor.addAgent(agent);
    }

    function test_removeAgent_revokesProposalRights() public {
        vm.startPrank(agent);
        governor.addAgent(agent2);
        governor.removeAgent(agent2);
        vm.stopPrank();

        assertFalse(governor.isAgent(agent2));
        assertEq(governor.agentCount(), 1);

        vm.roll(block.number + 1);
        vm.expectRevert(RecurveGovernor.OnlyAgent.selector);
        vm.prank(agent2);
        governor.propose(address(strategy), 0, "");
    }

    function test_removeAgent_leavesItsPendingProposalsAlive() public {
        vm.prank(agent);
        governor.addAgent(agent2);

        vm.roll(block.number + 1);
        vm.prank(agent2);
        bytes32 id = governor.propose(address(strategy), 0, "");

        vm.prank(agent);
        governor.removeAgent(agent2);

        // Revoking a key is not a back door around the depositor vote.
        assertEq(uint256(governor.stateOf(id)), uint256(RecurveGovernor.State.Pending));
    }

    function test_removeAgent_rejectsUnknown() public {
        vm.expectRevert(RecurveGovernor.NotAnAgent.selector);
        vm.prank(agent);
        governor.removeAgent(alice);
    }
}
