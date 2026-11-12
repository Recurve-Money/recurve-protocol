// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter, PortfolioStrategyV2} from "../src/strategies/PortfolioStrategyV2.sol";
import {RecurveVault} from "../src/RecurveVault.sol";
import {RecurveGovernor} from "../src/RecurveGovernor.sol";
import {WatcherRegistry} from "../src/WatcherRegistry.sol";

contract Coin is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev A router with a settable price, in the shape SwapRouter02 has.
contract Router is ISwapRouter {
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
        Coin(p.tokenOut).mint(p.recipient, amountOut);
    }
}

/// @dev A venue that pays back with a plain transfer, as any contract can.
contract Venue {
    function payBack(IERC20 asset, address to, uint256 amount) external {
        asset.transfer(to, amount);
    }
}

/// The way capital comes back: through the vault, so the deployment closes in the
/// transaction that returns the assets and no exit is ever priced with them
/// counted twice. Runs the mainnet strategy through the governor, the way an agent
/// does: every step a proposal that waits out its veto window.
contract ReturnPathTest is Test {
    Coin internal usd;
    Coin internal leg;
    Coin internal reve;
    Router internal router;
    RecurveVault internal vault;
    RecurveGovernor internal governor;
    WatcherRegistry internal registry;
    PortfolioStrategyV2 internal strategy;

    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant WINDOW = 6 hours;
    uint256 internal constant FEE_BPS = 500;

    event StrategySettled(uint256 assetsReturned, int256 pnl);

    function setUp() public {
        usd = new Coin("Mock USD", "mUSD");
        leg = new Coin("Leg", "LEG");
        reve = new Coin("Recurve", "RECURVE");
        router = new Router();

        registry = new WatcherRegistry(IERC20(address(reve)), 1_000e18, 7 days, admin);
        vault = new RecurveVault(IERC20(address(usd)), "Recurve Fund", "rvFUND", type(uint256).max);
        governor = new RecurveGovernor(vault, registry, agent, WINDOW, 3000, 2, FEE_BPS, treasury);
        vault.setGovernor(address(governor));
        vm.prank(admin);
        registry.setGovernor(address(governor));

        address[] memory tokens = new address[](1);
        tokens[0] = address(leg);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        strategy = new PortfolioStrategyV2(
            address(vault), address(governor), IERC20(address(usd)), router, tokens, fees, 300
        );

        // One usd buys two LEG, and two LEG sell for one usd, until a test moves it.
        router.setRate(address(usd), address(leg), 2e18);
        router.setRate(address(leg), address(usd), 0.5e18);

        usd.mint(alice, 1_000_000e18);
        usd.mint(bob, 1_000_000e18);
        usd.mint(agent, 1_000_000e18);
        usd.mint(stranger, 1_000_000e18);
        vm.prank(agent);
        usd.approve(address(governor), type(uint256).max);
        vm.roll(block.number + 1);
    }

    // ---------------------------------------------------------------- helpers

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        usd.approve(address(vault), amount);
        vault.deposit(amount, who);
        vault.delegate(who);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Post a proposal to the strategy and wait out its window.
    function _post(uint256 assets, bytes memory callData) internal returns (bytes32 id) {
        vm.roll(block.number + 1);
        vm.prank(agent);
        id = governor.propose(address(strategy), assets, callData);
        skip(WINDOW + 1);
    }

    /// @dev Post a proposal to the strategy and execute it once its window has closed.
    function _run(uint256 assets, bytes memory callData) internal returns (bytes32 id) {
        id = _post(assets, callData);
        vm.prank(agent);
        governor.execute(id);
    }

    /// @dev The return, expecting the vault to say what came back and what it made.
    function _returnExpecting(uint256 assets, int256 pnl) internal {
        bytes32 id = _post(0, abi.encodeCall(strategy.returnToVault, ()));
        vm.expectEmit(address(vault));
        emit StrategySettled(assets, pnl);
        vm.prank(agent);
        governor.execute(id);
    }

    /// @dev A whole cycle up to and including the return: 9,000 out, bought, sold, back.
    function _cycleUntilReturned() internal returns (bytes32 funding) {
        funding = _run(
            9_000e18, abi.encodeCall(strategy.buy, (address(leg), 9_000e18, 17_500e18, 18_000e18))
        );
        uint256 held = leg.balanceOf(address(strategy));
        uint256 quote = held * router.rate(address(leg), address(usd)) / 1e18;
        _run(0, abi.encodeCall(strategy.sell, (address(leg), held, quote * 98 / 100, quote)));
        _run(0, abi.encodeCall(strategy.returnToVault, ()));
    }

    // ---------------------------------------------------------------- the window

    function test_return_closesTheDeploymentInTheSameTransaction() public {
        _deposit(alice, 5_000e18);
        _deposit(bob, 5_000e18);
        _cycleUntilReturned();

        // Not settled yet, and already nothing is counted twice.
        assertEq(vault.deployedAssets(), 0);
        assertEq(vault.deployedTo(address(strategy)), 0);
        assertEq(usd.balanceOf(address(vault)), 10_000e18);
        assertEq(vault.totalAssets(), 10_000e18);
    }

    function test_exitBetweenReturnAndSettle_isPaidItsShareAndNoMore() public {
        _deposit(alice, 5_000e18);
        _deposit(bob, 5_000e18);
        bytes32 funding = _cycleUntilReturned();

        // Alice leaves in the gap. With a plain transfer back she was paid 9,499 here
        // and Bob was left with 500.
        uint256 before = usd.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(usd.balanceOf(alice) - before, 5_000e18, 1);

        vm.prank(agent);
        governor.settle(funding, 9_000e18);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(bob)), 5_000e18, 1);
    }

    function test_depositBetweenReturnAndSettle_buysAtTheTruePrice() public {
        _deposit(alice, 10_000e18);
        bytes32 funding = _cycleUntilReturned();

        // With the returned assets counted twice, 5,000 used to buy about half the
        // shares it should have.
        _deposit(bob, 5_000e18);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(bob)), 5_000e18, 1);

        vm.prank(agent);
        governor.settle(funding, 9_000e18);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(bob)), 5_000e18, 1);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(alice)), 10_000e18, 1);
    }

    // ---------------------------------------------------------------- gain and loss

    function test_return_booksAGainAtOnce() public {
        _deposit(alice, 10_000e18);
        _run(9_000e18, abi.encodeCall(strategy.buy, (address(leg), 9_000e18, 17_500e18, 18_000e18)));
        router.setRate(address(leg), address(usd), 0.55e18); // the leg is up ten percent
        _run(0, abi.encodeCall(strategy.sell, (address(leg), 18_000e18, 9_800e18, 9_900e18)));

        _returnExpecting(9_900e18, 900e18);

        assertEq(vault.totalAssets(), 10_900e18);
        assertEq(vault.deployedAssets(), 0);
    }

    function test_return_booksALossAtOnce() public {
        _deposit(alice, 10_000e18);
        _run(9_000e18, abi.encodeCall(strategy.buy, (address(leg), 9_000e18, 17_500e18, 18_000e18)));
        router.setRate(address(leg), address(usd), 0.4e18); // the leg is down twenty percent
        _run(0, abi.encodeCall(strategy.sell, (address(leg), 18_000e18, 7_100e18, 7_200e18)));

        _returnExpecting(7_200e18, -1_800e18);

        assertEq(vault.totalAssets(), 8_200e18);
    }

    function test_settle_afterAReturn_takesTheFeeAndMovesNoBooks() public {
        _deposit(alice, 10_000e18);
        bytes32 funding = _run(
            9_000e18, abi.encodeCall(strategy.buy, (address(leg), 9_000e18, 17_500e18, 18_000e18))
        );
        router.setRate(address(leg), address(usd), 0.55e18);
        _run(0, abi.encodeCall(strategy.sell, (address(leg), 18_000e18, 9_800e18, 9_900e18)));
        _run(0, abi.encodeCall(strategy.returnToVault, ()));

        uint256 total = vault.totalAssets();
        uint256 price = vault.previewRedeem(1e18);

        vm.recordLogs();
        vm.prank(agent);
        governor.settle(funding, 9_900e18);

        // Five percent of the 900 profit, out of the agent's own wallet.
        assertEq(usd.balanceOf(treasury), 45e18);
        assertEq(vault.totalAssets(), total);
        assertEq(vault.previewRedeem(1e18), price);
        // The vault said what happened once, when it happened. Settle adds nothing.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != StrategySettled.selector);
        }
        (,,,,,, RecurveGovernor.State state) = governor.proposals(funding);
        assertEq(uint8(state), uint8(RecurveGovernor.State.Settled));
    }

    // ---------------------------------------------------------------- who can do what

    function test_returnToVault_withNothingToSend_changesNothing() public {
        _deposit(alice, 10_000e18);
        _run(9_000e18, abi.encodeCall(strategy.buy, (address(leg), 9_000e18, 17_500e18, 18_000e18)));

        // Returned too early: the strategy holds the leg and no base asset. The
        // deployment stays on the books at cost instead of being written off.
        _run(0, abi.encodeCall(strategy.returnToVault, ()));
        assertEq(vault.deployedAssets(), 9_000e18);
        assertEq(vault.totalAssets(), 10_000e18);
    }

    function test_returnFromStrategy_fromAStranger_isOnlyAGift() public {
        _deposit(alice, 10_000e18);
        _run(9_000e18, abi.encodeCall(strategy.buy, (address(leg), 9_000e18, 17_500e18, 18_000e18)));

        vm.startPrank(stranger);
        usd.approve(address(vault), 100e18);
        vault.returnFromStrategy(100e18);
        vault.returnFromStrategy(0);
        vm.stopPrank();

        // The strategy's deployment is untouched; the vault is 100 richer.
        assertEq(vault.deployedTo(address(strategy)), 9_000e18);
        assertEq(vault.deployedAssets(), 9_000e18);
        assertEq(vault.totalAssets(), 10_100e18);
    }

    function test_aSecondReturn_isAPlainInflow() public {
        _deposit(alice, 10_000e18);
        _cycleUntilReturned();

        // Something reaches the strategy after the cycle closed, and is sent on.
        usd.mint(address(strategy), 7e18);
        _returnExpecting(7e18, 7e18);

        assertEq(vault.deployedAssets(), 0);
        assertEq(vault.totalAssets(), 10_007e18);
    }

    function test_twoTargets_areBookedApart() public {
        _deposit(alice, 10_000e18);
        Venue venue = new Venue();

        // 3,000 to a venue that will pay back by transfer, 6,000 to the strategy.
        vm.roll(block.number + 1);
        vm.prank(agent);
        bytes32 toVenue = governor.propose(address(venue), 3_000e18, "");
        skip(WINDOW + 1);
        vm.prank(agent);
        governor.execute(toVenue);
        _run(6_000e18, abi.encodeCall(strategy.buy, (address(leg), 6_000e18, 11_700e18, 12_000e18)));
        assertEq(vault.deployedAssets(), 9_000e18);

        _run(0, abi.encodeCall(strategy.sell, (address(leg), 12_000e18, 5_900e18, 6_000e18)));
        _run(0, abi.encodeCall(strategy.returnToVault, ()));

        // The strategy's return closed the strategy's 6,000 and left the venue's 3,000.
        assertEq(vault.deployedTo(address(strategy)), 0);
        assertEq(vault.deployedTo(address(venue)), 3_000e18);
        assertEq(vault.deployedAssets(), 3_000e18);
        assertEq(vault.totalAssets(), 10_000e18);

        // The venue pays back the old way, and settle closes what is left.
        venue.payBack(IERC20(address(usd)), address(vault), 3_000e18);
        vm.prank(agent);
        governor.settle(toVenue, 3_000e18);
        assertEq(vault.deployedAssets(), 0);
        assertEq(vault.totalAssets(), 10_000e18);
    }

    function test_settleStrategy_onlyTheGovernor() public {
        vm.expectRevert(RecurveVault.OnlyGovernor.selector);
        vm.prank(agent);
        vault.settleStrategy(address(strategy), 0);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Whatever the cycle earned or lost, the moment it is back the vault holds
    ///      exactly what its books say, and a holder's claim is their share of it.
    function testFuzz_afterAReturn_booksMatchTheBalance(uint96 deposit_, uint16 moveBps) public {
        uint256 amount = bound(uint256(deposit_), 1_000e18, 500_000e18);
        uint256 sellRate = 0.5e18 * bound(uint256(moveBps), 2_000, 30_000) / 10_000; // -80% .. +200%
        _deposit(alice, amount);
        _deposit(bob, amount);

        uint256 out = amount; // half of the two deposits goes to work
        _run(out, abi.encodeCall(strategy.buy, (address(leg), out, out * 2 * 98 / 100, out * 2)));
        router.setRate(address(leg), address(usd), sellRate);
        uint256 held = leg.balanceOf(address(strategy));
        uint256 quote = held * sellRate / 1e18;
        _run(0, abi.encodeCall(strategy.sell, (address(leg), held, quote * 98 / 100, quote)));
        _run(0, abi.encodeCall(strategy.returnToVault, ()));

        assertEq(vault.deployedAssets(), 0);
        assertEq(vault.totalAssets(), usd.balanceOf(address(vault)));
        assertEq(vault.totalAssets(), amount + quote);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(alice)), (amount + quote) / 2, 2);
    }
}
