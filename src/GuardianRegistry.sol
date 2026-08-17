// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title GuardianRegistry
/// @notice Stake, verdicts, and slashing for the guardian network.
/// @dev The asymmetry is the whole mechanism: blocking a proposal costs a guardian
///      nothing but that round's reward, while approving calldata that later gets
///      convicted burns their stake. Being careful is cheap; being negligent is not.
///
///      Burned stake is sent to address(0) rather than redistributed. If slashed stake
///      paid out to other guardians, a majority could profit by convicting a minority,
///      and the incentive to review honestly would invert.
contract GuardianRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The token guardians stake.
    IERC20 public immutable stakeToken;

    /// @notice Minimum stake required to cast a verdict.
    uint256 public minStake;

    /// @notice Delay between requesting an unstake and being able to withdraw.
    /// @dev Long enough that a guardian cannot approve a malicious call and exit
    ///      before the conviction window closes.
    uint256 public unstakeDelay;

    /// @notice Address allowed to record verdicts and convictions.
    address public governor;

    enum Verdict {
        None,
        Approve,
        Block
    }

    struct Guardian {
        uint256 stake;
        uint256 unstakeRequestedAt;
        uint256 pendingUnstake;
        bool active;
    }

    mapping(address => Guardian) public guardians;

    /// @notice Verdict cast by a guardian on a given proposal.
    mapping(bytes32 => mapping(address => Verdict)) public verdicts;

    /// @notice Guardians who approved a proposal, for reward and slashing lookup.
    mapping(bytes32 => address[]) public approvers;

    /// @notice Guardians who blocked a proposal.
    mapping(bytes32 => address[]) public blockers;

    /// @notice Proposals already convicted, so a conviction cannot be replayed.
    mapping(bytes32 => bool) public convicted;

    uint256 public totalStaked;
    uint256 public totalBurned;

    event Staked(address indexed guardian, uint256 amount, uint256 newStake);
    event UnstakeRequested(address indexed guardian, uint256 amount, uint256 claimableAt);
    event Unstaked(address indexed guardian, uint256 amount);
    event VerdictCast(bytes32 indexed proposalId, address indexed guardian, Verdict verdict);
    event Convicted(bytes32 indexed proposalId, uint256 guardiansSlashed, uint256 stakeBurned);
    event GovernorUpdated(address indexed governor);
    event ParametersUpdated(uint256 minStake, uint256 unstakeDelay);

    error OnlyGovernor();
    error BelowMinStake();
    error NothingStaked();
    error UnstakeNotReady();
    error NoPendingUnstake();
    error AlreadyVoted();
    error AlreadyConvicted();
    error ZeroAmount();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor();
        _;
    }

    constructor(IERC20 stakeToken_, uint256 minStake_, uint256 unstakeDelay_, address owner_)
        Ownable(owner_)
    {
        stakeToken = stakeToken_;
        minStake = minStake_;
        unstakeDelay = unstakeDelay_;
    }

    // ---------------------------------------------------------------- staking

    /// @notice Add to your stake. Becoming active requires clearing `minStake`.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);

        Guardian storage g = guardians[msg.sender];
        g.stake += amount;
        g.active = g.stake >= minStake;
        totalStaked += amount;

        emit Staked(msg.sender, amount, g.stake);
    }

    /// @notice Start the exit clock. Stake stays slashable until it is withdrawn.
    function requestUnstake(uint256 amount) external {
        Guardian storage g = guardians[msg.sender];
        if (g.stake == 0) revert NothingStaked();
        if (amount == 0 || amount > g.stake) revert ZeroAmount();

        g.pendingUnstake = amount;
        g.unstakeRequestedAt = block.timestamp;

        emit UnstakeRequested(msg.sender, amount, block.timestamp + unstakeDelay);
    }

    /// @notice Withdraw once the delay has passed.
    function unstake() external nonReentrant {
        Guardian storage g = guardians[msg.sender];
        uint256 amount = g.pendingUnstake;
        if (amount == 0) revert NoPendingUnstake();
        if (block.timestamp < g.unstakeRequestedAt + unstakeDelay) revert UnstakeNotReady();

        // A slash between request and claim can leave the pending amount stale.
        if (amount > g.stake) amount = g.stake;

        g.stake -= amount;
        g.pendingUnstake = 0;
        g.unstakeRequestedAt = 0;
        g.active = g.stake >= minStake;
        totalStaked -= amount;

        stakeToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    // ---------------------------------------------------------------- verdicts

    /// @notice Record a verdict on a proposal.
    /// @dev Called by the guardian, gated on active stake. One verdict per proposal;
    ///      there is no changing your mind once your stake is behind a call.
    function castVerdict(bytes32 proposalId, Verdict verdict) external {
        Guardian storage g = guardians[msg.sender];
        if (!g.active || g.stake < minStake) revert BelowMinStake();
        if (verdicts[proposalId][msg.sender] != Verdict.None) revert AlreadyVoted();

        verdicts[proposalId][msg.sender] = verdict;

        if (verdict == Verdict.Approve) {
            approvers[proposalId].push(msg.sender);
        } else {
            blockers[proposalId].push(msg.sender);
        }

        emit VerdictCast(proposalId, msg.sender, verdict);
    }

    /// @notice Slash and burn the stake of everyone who approved a malicious proposal.
    /// @dev Iterating approvers is bounded in practice by `minStake` — the registry is
    ///      not designed for an unbounded guardian set, and a conviction that ran out
    ///      of gas would be worse than a cap.
    function convict(bytes32 proposalId) external onlyGovernor {
        if (convicted[proposalId]) revert AlreadyConvicted();
        convicted[proposalId] = true;

        address[] storage list = approvers[proposalId];
        uint256 burned;

        for (uint256 i; i < list.length; ++i) {
            Guardian storage g = guardians[list[i]];
            uint256 amount = g.stake;
            if (amount == 0) continue;

            g.stake = 0;
            g.active = false;
            g.pendingUnstake = 0;
            burned += amount;
        }

        if (burned > 0) {
            totalStaked -= burned;
            totalBurned += burned;
            stakeToken.safeTransfer(address(0xdead), burned);
        }

        emit Convicted(proposalId, list.length, burned);
    }

    // ---------------------------------------------------------------- views

    function isActive(address guardian) external view returns (bool) {
        Guardian storage g = guardians[guardian];
        return g.active && g.stake >= minStake;
    }

    function approversOf(bytes32 proposalId) external view returns (address[] memory) {
        return approvers[proposalId];
    }

    function blockersOf(bytes32 proposalId) external view returns (address[] memory) {
        return blockers[proposalId];
    }

    function blockCount(bytes32 proposalId) external view returns (uint256) {
        return blockers[proposalId].length;
    }

    // ---------------------------------------------------------------- admin

    function setGovernor(address governor_) external onlyOwner {
        governor = governor_;
        emit GovernorUpdated(governor_);
    }

    function setParameters(uint256 minStake_, uint256 unstakeDelay_) external onlyOwner {
        minStake = minStake_;
        unstakeDelay = unstakeDelay_;
        emit ParametersUpdated(minStake_, unstakeDelay_);
    }
}
