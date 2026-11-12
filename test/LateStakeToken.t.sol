// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RecurveVault} from "../src/RecurveVault.sol";
import {RecurveGovernor} from "../src/RecurveGovernor.sol";
import {WatcherRegistry} from "../src/WatcherRegistry.sol";
import {MockUSD, MockReve, MockStrategy} from "./RecurveProtocol.t.sol";

/// @dev A fund that opens before its token exists: the registry is deployed without
///      a stake token and the owner names it once, later.
contract LateStakeTokenTest is Test {
    MockUSD internal usd;
    MockReve internal reve;
    RecurveVault internal vault;
    RecurveGovernor internal governor;
    WatcherRegistry internal registry;
    MockStrategy internal strategy;

    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal watcher1 = makeAddr("watcher1");
    address internal watcher2 = makeAddr("watcher2");
    address internal treasury = makeAddr("treasury");
    address internal owner = makeAddr("owner");

    uint256 internal constant VETO_WINDOW = 24 hours;
    uint256 internal constant MIN_STAKE = 1_000e18;

    function setUp() public {
        usd = new MockUSD();
        reve = new MockReve();
        registry = new WatcherRegistry(IERC20(address(0)), MIN_STAKE, 7 days, owner);
        vault = new RecurveVault(IERC20(address(usd)), "Recurve Fund", "rvFUND", type(uint256).max);
        governor = new RecurveGovernor(vault, registry, agent, VETO_WINDOW, 2000, 2, 500, treasury);
        vault.setGovernor(address(governor));
        vm.prank(owner);
        registry.setGovernor(address(governor));
        strategy = new MockStrategy(IERC20(address(usd)));

        usd.mint(alice, 1_000e18);
        reve.mint(watcher1, MIN_STAKE);
        reve.mint(watcher2, MIN_STAKE);

        vm.startPrank(alice);
        usd.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, alice);
        vault.delegate(alice);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _propose() internal returns (bytes32) {
        vm.roll(block.number + 1);
        vm.prank(agent);
        return governor.propose(address(strategy), 100e18, "");
    }

    function _stake(address who) internal {
        vm.startPrank(who);
        reve.approve(address(registry), MIN_STAKE);
        registry.stake(MIN_STAKE);
        vm.stopPrank();
    }

    function test_theFundRunsBeforeTheTokenExists() public {
        bytes32 id = _propose();
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        governor.execute(id);
        assertEq(vault.deployedAssets(), 100e18);
    }

    function test_theVetoWorksBeforeTheTokenExists() public {
        bytes32 id = _propose();
        vm.prank(alice);
        governor.veto(id);
        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        vm.expectRevert(RecurveGovernor.WrongState.selector);
        governor.execute(id);
    }

    function test_nobodyCanStakeOrRuleBeforeTheToken() public {
        vm.prank(watcher1);
        vm.expectRevert();
        registry.stake(MIN_STAKE);

        vm.prank(watcher1);
        vm.expectRevert(WatcherRegistry.BelowMinStake.selector);
        registry.castVerdict(bytes32(uint256(1)), WatcherRegistry.Verdict.Block);
    }

    function test_onlyTheOwnerNamesTheToken() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setStakeToken(reve);
    }

    function test_theTokenCannotBeZero() public {
        vm.prank(owner);
        vm.expectRevert(WatcherRegistry.ZeroToken.selector);
        registry.setStakeToken(IERC20(address(0)));
    }

    function test_theTokenIsNamedOnce() public {
        vm.startPrank(owner);
        registry.setStakeToken(reve);
        assertEq(address(registry.stakeToken()), address(reve));
        vm.expectRevert(WatcherRegistry.StakeTokenAlreadySet.selector);
        registry.setStakeToken(IERC20(address(usd)));
        vm.stopPrank();
    }

    function test_aTokenFromTheConstructorIsFinal() public {
        WatcherRegistry fixedToken = new WatcherRegistry(reve, MIN_STAKE, 7 days, owner);
        vm.prank(owner);
        vm.expectRevert(WatcherRegistry.StakeTokenAlreadySet.selector);
        fixedToken.setStakeToken(IERC20(address(usd)));
    }

    function test_watchersStopProposalsOnceTheTokenIsNamed() public {
        vm.prank(owner);
        registry.setStakeToken(reve);
        _stake(watcher1);
        _stake(watcher2);

        bytes32 id = _propose();
        vm.prank(watcher1);
        registry.castVerdict(id, WatcherRegistry.Verdict.Block);
        vm.prank(watcher2);
        registry.castVerdict(id, WatcherRegistry.Verdict.Block);

        skip(VETO_WINDOW + 1);
        vm.prank(agent);
        vm.expectRevert(RecurveGovernor.WatchersBlocked.selector);
        governor.execute(id);
    }

    function test_stakeComesBackInTheSameToken() public {
        vm.prank(owner);
        registry.setStakeToken(reve);
        _stake(watcher1);

        vm.prank(watcher1);
        registry.requestUnstake(MIN_STAKE);
        skip(7 days + 1);
        vm.prank(watcher1);
        registry.unstake();
        assertEq(reve.balanceOf(watcher1), MIN_STAKE);
    }
}
