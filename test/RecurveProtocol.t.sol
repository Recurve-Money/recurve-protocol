// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RecurveVault} from "../src/RecurveVault.sol";
import {RecurveGovernor} from "../src/RecurveGovernor.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";

contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockArc is ERC20 {
    constructor() ERC20("Recurve", "ARC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for a strategy venue. Returns the funded assets plus whatever
///      profit the test seeded it with.
contract MockStrategy {
    IERC20 public immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function unwind(address to, uint256 amount) external {
        asset.transfer(to, amount);
    }
}

contract RecurveProtocolTest is Test {
    MockUSD internal usd;
    MockArc internal arc;
    RecurveVault internal vault;
    RecurveGovernor internal governor;
    GuardianRegistry internal registry;
    MockStrategy internal strategy;

    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal guardian1 = makeAddr("guardian1");
    address internal guardian2 = makeAddr("guardian2");
    address internal treasury = makeAddr("treasury");
    address internal admin = makeAddr("admin");

    uint256 internal constant VETO_WINDOW = 6 hours;
    uint256 internal constant VETO_THRESHOLD_BPS = 3000;
    uint256 internal constant BLOCK_THRESHOLD = 2;
    uint256 internal constant PERF_FEE_BPS = 1500;
    uint256 internal constant MIN_STAKE = 1_000e18;
    uint256 internal constant UNSTAKE_DELAY = 7 days;

    function setUp() public {
        usd = new MockUSD();
        arc = new MockArc();

        registry = new GuardianRegistry(IERC20(address(arc)), MIN_STAKE, UNSTAKE_DELAY, admin);

        // The vault and governor reference each other, so precompute the governor
        // address and deploy in a fixed order.
        address governorAddr =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new RecurveVault(IERC20(address(usd)), "Recurve Fund", "rvFUND", governorAddr);
        governor = new RecurveGovernor(
            vault,
            registry,
            agent,
            VETO_WINDOW,
            VETO_THRESHOLD_BPS,
            BLOCK_THRESHOLD,
            PERF_FEE_BPS,
            treasury
        );
        assertEq(address(governor), governorAddr, "governor address prediction");

        vm.prank(admin);
        registry.setGovernor(address(governor));

        strategy = new MockStrategy(IERC20(address(usd)));

        usd.mint(alice, 1_000_000e18);
        usd.mint(bob, 1_000_000e18);
        usd.mint(carol, 1_000_000e18);
        usd.mint(agent, 1_000_000e18);
        arc.mint(guardian1, 100_000e18);
        arc.mint(guardian2, 100_000e18);

        // The agent pays the performance fee out of its own balance on settle.
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

    function _stakeGuardian(address who, uint256 amount) internal {
        vm.startPrank(who);
        arc.approve(address(registry), amount);
        registry.stake(amount);
        vm.stopPrank();
    }

    /// @dev Rolls a block first so the proposal snapshot (block.number - 1) sees every
    ///      deposit made so far. Without this, a holder from an earlier block reads as a
    ///      far larger share of supply than they actually own.
    function _propose(uint256 assets) internal returns (bytes32) {
        vm.roll(block.number + 1);
        vm.prank(agent);
        return governor.propose(address(strategy), assets, "");
    }

    // ---------------------------------------------------------------- vault

    function test_deposit_mintsSharesOneToOneOnEmptyVault() public {
        _deposit(alice, 1_000e18);
        assertEq(vault.balanceOf(alice), 1_000e18);
        assertEq(vault.totalAssets(), 1_000e18);
        assertEq(vault.float(), 1_000e18);
    }

    function test_totalAssets_countsDeployedCapital() public {
        _deposit(alice, 1_000e18);

        bytes32 id = _propose(600e18);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(id);

        // Assets left the vault but are still owed to depositors.
        assertEq(usd.balanceOf(address(vault)), 400e18);
        assertEq(vault.deployedAssets(), 600e18);
        assertEq(vault.totalAssets(), 1_000e18, "deployed capital must stay counted");
        assertEq(vault.float(), 400e18);
    }

    function test_redeem_instantWhenFloatCovers() public {
        _deposit(alice, 1_000e18);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);

        assertEq(id, type(uint256).max, "should not queue");
        assertEq(usd.balanceOf(alice), 1_000_000e18 - 600e18);
        assertEq(vault.balanceOf(alice), 600e18);
    }

    function test_redeem_queuesWhenFloatShort() public {
        _deposit(alice, 1_000e18);

        bytes32 pid = _propose(900e18);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(pid);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e18, alice, alice);

        assertEq(id, 0, "should take queue slot 0");
        assertEq(vault.queueLength(), 1);
        // Shares are escrowed by the vault while queued.
        assertEq(vault.balanceOf(alice), 500e18);
        assertEq(vault.balanceOf(address(vault)), 500e18);
    }

    function test_queuedRedemption_claimableAfterSettlement() public {
        _deposit(alice, 1_000e18);

        bytes32 pid = _propose(900e18);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(pid);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e18, alice, alice);

        vm.expectRevert(RecurveVault.RequestNotReady.selector);
        vm.prank(alice);
        vault.claimRedeem(id);

        // Strategy unwinds flat and the agent settles.
        strategy.unwind(address(vault), 900e18);
        vm.prank(agent);
        governor.settle(pid, 900e18);

        vm.prank(alice);
        uint256 assets = vault.claimRedeem(id);

        assertEq(assets, 500e18);
        assertEq(vault.balanceOf(address(vault)), 0, "escrowed shares must burn");
    }

    function test_queuedRedemption_pricesAtClaimNotRequest() public {
        _deposit(alice, 1_000e18);

        bytes32 pid = _propose(900e18);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(pid);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e18, alice, alice);

        // Strategy returns a 20% gain; the queued exit should share in it.
        usd.mint(address(strategy), 180e18);
        strategy.unwind(address(vault), 1_080e18);
        vm.prank(agent);
        governor.settle(pid, 1_080e18);

        vm.prank(alice);
        uint256 assets = vault.claimRedeem(id);

        assertGt(assets, 500e18, "queued exit should capture the gain");
    }

    function test_claimRedeem_rejectsNonOwner() public {
        _deposit(alice, 1_000e18);
        bytes32 pid = _propose(900e18);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(pid);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e18, alice, alice);

        strategy.unwind(address(vault), 900e18);
        vm.prank(agent);
        governor.settle(pid, 900e18);

        vm.expectRevert(RecurveVault.NotRequestOwner.selector);
        vm.prank(bob);
        vault.claimRedeem(id);
    }

    function test_fundStrategy_onlyGovernor() public {
        _deposit(alice, 1_000e18);
        vm.expectRevert(RecurveVault.OnlyGovernor.selector);
        vm.prank(agent);
        vault.fundStrategy(address(strategy), 100e18);
    }

    function test_fundStrategy_cannotExceedFloat() public {
        _deposit(alice, 1_000e18);
        bytes32 id = _propose(1_500e18);
        skip(VETO_WINDOW + 1);

        vm.expectRevert(RecurveVault.FloatTooLow.selector);
        vm.prank(agent);
        governor.execute(id);
    }

    // ---------------------------------------------------------------- governance

    function test_propose_onlyAgent() public {
        vm.expectRevert(RecurveGovernor.OnlyAgent.selector);
        vm.prank(alice);
        governor.propose(address(strategy), 1e18, "");
    }

    function test_execute_blockedWhileVetoWindowOpen() public {
        _deposit(alice, 1_000e18);
        bytes32 id = _propose(100e18);

        vm.expectRevert(RecurveGovernor.VetoWindowOpen.selector);
        vm.prank(agent);
        governor.execute(id);
    }

    function test_veto_killsProposalAtThreshold() public {
        _deposit(alice, 700e18);
        _deposit(bob, 300e18);

        bytes32 id = _propose(100e18);

        // Alice alone holds 70% — well past the 30% veto threshold.
        vm.prank(alice);
        governor.veto(id);

        assertEq(uint256(governor.stateOf(id)), uint256(RecurveGovernor.State.Vetoed));

        skip(VETO_WINDOW + 1);
        vm.expectRevert(RecurveGovernor.WrongState.selector);
        vm.prank(agent);
        governor.execute(id);
    }

    function test_veto_belowThresholdDoesNotStopExecution() public {
        _deposit(alice, 100e18);
        _deposit(bob, 900e18);

        bytes32 id = _propose(100e18);

        // Alice holds 10%, under the 30% bar.
        vm.prank(alice);
        governor.veto(id);

        assertEq(uint256(governor.stateOf(id)), uint256(RecurveGovernor.State.Pending));

        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(id);
        assertEq(uint256(governor.stateOf(id)), uint256(RecurveGovernor.State.Executed));
    }

    function test_veto_usesSnapshotWeightNotCurrent() public {
        _deposit(alice, 1_000e18);
        bytes32 id = _propose(100e18);

        // Bob buys in after the proposal was posted; his weight must not count.
        _deposit(bob, 5_000e18);

        vm.expectRevert(RecurveGovernor.NoVotingWeight.selector);
        vm.prank(bob);
        governor.veto(id);
    }

    function test_veto_cannotDoubleVote() public {
        _deposit(alice, 1_000e18);
        bytes32 id = _propose(100e18);

        vm.prank(alice);
        governor.veto(id);

        // First veto already tipped it past threshold, so state moved on.
        vm.expectRevert(RecurveGovernor.WrongState.selector);
        vm.prank(alice);
        governor.veto(id);
    }

    function test_veto_rejectedAfterWindowCloses() public {
        _deposit(alice, 400e18);
        _deposit(bob, 600e18);
        bytes32 id = _propose(100e18);

        skip(VETO_WINDOW + 1);

        vm.expectRevert(RecurveGovernor.VetoWindowClosed.selector);
        vm.prank(alice);
        governor.veto(id);
    }

    // ---------------------------------------------------------------- guardians

    function test_guardianBlocks_stopExecution() public {
        _deposit(alice, 1_000e18);
        _stakeGuardian(guardian1, MIN_STAKE);
        _stakeGuardian(guardian2, MIN_STAKE);

        bytes32 id = _propose(100e18);

        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Block);
        vm.prank(guardian2);
        registry.castVerdict(id, GuardianRegistry.Verdict.Block);

        skip(VETO_WINDOW + 1);
        vm.expectRevert(RecurveGovernor.GuardiansBlocked.selector);
        vm.prank(agent);
        governor.execute(id);
    }

    function test_guardianBlocks_belowThresholdDoNotStop() public {
        _deposit(alice, 1_000e18);
        _stakeGuardian(guardian1, MIN_STAKE);

        bytes32 id = _propose(100e18);

        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Block);

        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(id);
        assertEq(uint256(governor.stateOf(id)), uint256(RecurveGovernor.State.Executed));
    }

    function test_castVerdict_requiresMinStake() public {
        _stakeGuardian(guardian1, MIN_STAKE - 1);
        bytes32 id = keccak256("proposal");

        vm.expectRevert(GuardianRegistry.BelowMinStake.selector);
        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Approve);
    }

    function test_castVerdict_isFinal() public {
        _stakeGuardian(guardian1, MIN_STAKE);
        bytes32 id = keccak256("proposal");

        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Approve);

        vm.expectRevert(GuardianRegistry.AlreadyVoted.selector);
        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Block);
    }

    function test_convict_burnsApproverStakeOnly() public {
        _stakeGuardian(guardian1, MIN_STAKE);
        _stakeGuardian(guardian2, MIN_STAKE);

        bytes32 id = keccak256("malicious");

        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Approve);
        vm.prank(guardian2);
        registry.castVerdict(id, GuardianRegistry.Verdict.Block);

        vm.prank(address(governor));
        registry.convict(id);

        (uint256 stake1,,, bool active1) = registry.guardians(guardian1);
        (uint256 stake2,,, bool active2) = registry.guardians(guardian2);

        assertEq(stake1, 0, "approver must be wiped out");
        assertFalse(active1);
        assertEq(stake2, MIN_STAKE, "blocker must be untouched");
        assertTrue(active2);
        assertEq(registry.totalBurned(), MIN_STAKE);
    }

    function test_convict_burnsRatherThanRedistributes() public {
        _stakeGuardian(guardian1, MIN_STAKE);
        _stakeGuardian(guardian2, MIN_STAKE);

        bytes32 id = keccak256("malicious");
        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Approve);
        vm.prank(guardian2);
        registry.castVerdict(id, GuardianRegistry.Verdict.Block);

        uint256 blockerBefore = arc.balanceOf(guardian2);

        vm.prank(address(governor));
        registry.convict(id);

        // Nobody profits from a conviction — otherwise convicting becomes an attack.
        assertEq(arc.balanceOf(guardian2), blockerBefore);
        assertEq(arc.balanceOf(address(0xdead)), MIN_STAKE);
    }

    function test_convict_cannotReplay() public {
        _stakeGuardian(guardian1, MIN_STAKE);
        bytes32 id = keccak256("malicious");
        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Approve);

        vm.prank(address(governor));
        registry.convict(id);

        vm.expectRevert(GuardianRegistry.AlreadyConvicted.selector);
        vm.prank(address(governor));
        registry.convict(id);
    }

    function test_convict_onlyGovernor() public {
        bytes32 id = keccak256("malicious");
        vm.expectRevert(GuardianRegistry.OnlyGovernor.selector);
        vm.prank(alice);
        registry.convict(id);
    }

    function test_unstake_requiresDelay() public {
        _stakeGuardian(guardian1, MIN_STAKE);

        vm.prank(guardian1);
        registry.requestUnstake(MIN_STAKE);

        vm.expectRevert(GuardianRegistry.UnstakeNotReady.selector);
        vm.prank(guardian1);
        registry.unstake();

        skip(UNSTAKE_DELAY + 1);
        vm.prank(guardian1);
        registry.unstake();

        (uint256 remaining,,,) = registry.guardians(guardian1);
        assertEq(remaining, 0);
    }

    function test_unstake_stakeStaysSlashableDuringDelay() public {
        _stakeGuardian(guardian1, MIN_STAKE);
        bytes32 id = keccak256("malicious");

        vm.prank(guardian1);
        registry.castVerdict(id, GuardianRegistry.Verdict.Approve);

        // Guardian tries to exit right after approving.
        vm.prank(guardian1);
        registry.requestUnstake(MIN_STAKE);

        vm.prank(address(governor));
        registry.convict(id);

        skip(UNSTAKE_DELAY + 1);

        // Conviction wiped the stake and the pending request with it — there is
        // nothing left to withdraw.
        vm.expectRevert(GuardianRegistry.NoPendingUnstake.selector);
        vm.prank(guardian1);
        registry.unstake();

        assertEq(arc.balanceOf(guardian1), 100_000e18 - MIN_STAKE, "nothing should come back");
    }

    // ---------------------------------------------------------------- fees

    function test_settle_chargesFeeOnProfitOnly() public {
        _deposit(alice, 1_000e18);

        bytes32 id = _propose(1_000e18);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(id);

        usd.mint(address(strategy), 200e18);
        strategy.unwind(address(vault), 1_200e18);

        vm.prank(agent);
        governor.settle(id, 1_200e18);

        // 15% of the 200 profit.
        assertEq(usd.balanceOf(treasury), 30e18);
    }

    function test_settle_noFeeOnLoss() public {
        _deposit(alice, 1_000e18);

        bytes32 id = _propose(1_000e18);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(id);

        strategy.unwind(address(vault), 800e18);

        vm.prank(agent);
        governor.settle(id, 800e18);

        assertEq(usd.balanceOf(treasury), 0, "a losing strategy pays nothing");
    }

    function test_constructor_rejectsFeeAboveCap() public {
        vm.expectRevert(RecurveGovernor.FeeTooHigh.selector);
        new RecurveGovernor(
            vault, registry, agent, VETO_WINDOW, VETO_THRESHOLD_BPS, BLOCK_THRESHOLD, 1501, treasury
        );
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Share price must never fall out from under a depositor who did nothing.
    function testFuzz_shareValueMonotonicUnderProfit(uint96 deposit_, uint96 profit_) public {
        uint256 deposited = bound(uint256(deposit_), 1e18, 500_000e18);
        uint256 profit = bound(uint256(profit_), 0, 500_000e18);

        _deposit(alice, deposited);
        uint256 before = vault.convertToAssets(1e18);

        bytes32 id = _propose(deposited);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(id);

        usd.mint(address(strategy), profit);
        strategy.unwind(address(vault), deposited + profit);
        vm.prank(agent);
        governor.settle(id, deposited + profit);

        assertGe(vault.convertToAssets(1e18), before);
    }

    /// @dev Whatever the split of deposits, the vault must owe exactly what it holds.
    function testFuzz_totalAssetsMatchesHoldings(uint96 a, uint96 b, uint96 c) public {
        uint256 da = bound(uint256(a), 1e18, 100_000e18);
        uint256 db = bound(uint256(b), 1e18, 100_000e18);
        uint256 dc = bound(uint256(c), 1e18, 100_000e18);

        _deposit(alice, da);
        _deposit(bob, db);
        _deposit(carol, dc);

        assertEq(vault.totalAssets(), da + db + dc);
        assertEq(vault.totalAssets(), usd.balanceOf(address(vault)) + vault.deployedAssets());
    }
}
