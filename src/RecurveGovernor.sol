// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {RecurveVault} from "./RecurveVault.sol";
import {GuardianRegistry} from "./GuardianRegistry.sol";

/// @title RecurveGovernor
/// @notice Proposal lifecycle for a single vault: propose, veto window, guardian
///         review, execute, settle.
/// @dev Governance here is optimistic. A proposal passes unless depositors vote it
///      down inside the window, because an agent that has to wait for a quorum to
///      say yes cannot trade. The safety comes from the veto plus guardian review,
///      not from an approval gate.
///
///      One governor per vault. Sharing a governor across vaults would let a large
///      holder in one fund influence the schedule of another.
contract RecurveGovernor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The vault this governor controls.
    RecurveVault public immutable vault;

    /// @notice Guardian network that reviews calldata before execution.
    GuardianRegistry public immutable guardians;

    /// @notice Agents allowed to propose on this vault.
    /// @dev A set rather than a single address. A fund often wants a signal
    ///      agent, an execution agent, and a fallback, and forcing them to
    ///      share one key means a compromise of any of them is a compromise of
    ///      all. Adding and removing is governance-gated.
    mapping(address => bool) public isAgent;

    /// @notice Registered agents, for enumeration off chain.
    address[] public agents;

    /// @notice Address allowed to change the agent set.
    address public agentAdmin;

    /// @notice How long depositors have to veto after a proposal is posted.
    uint256 public vetoWindow;

    /// @notice Share of vote weight that must veto to kill a proposal, in basis points.
    uint256 public vetoThresholdBps;

    /// @notice Blocks from guardians required to stop execution.
    uint256 public guardianBlockThreshold;

    /// @notice Performance fee on profit, in basis points. Never charged on principal.
    uint256 public performanceFeeBps;

    address public feeRecipient;

    uint256 internal constant BPS = 10_000;

    enum State {
        None,
        Pending,
        Vetoed,
        Blocked,
        Executed,
        Settled
    }

    struct Proposal {
        address target;
        uint256 assets;
        bytes callData;
        uint256 postedAt;
        uint256 snapshot;
        uint256 vetoWeight;
        State state;
    }

    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVetoed;

    event ProposalPosted(
        bytes32 indexed proposalId, address indexed target, uint256 assets, uint256 executableAt
    );
    event VetoCast(bytes32 indexed proposalId, address indexed voter, uint256 weight);
    event ProposalVetoed(bytes32 indexed proposalId, uint256 vetoWeight);
    event ProposalBlocked(bytes32 indexed proposalId, uint256 blocks_);
    event ProposalExecuted(bytes32 indexed proposalId, address indexed target, uint256 assets);
    event ProposalSettled(bytes32 indexed proposalId, uint256 returned, uint256 fee);
    event AgentAdded(address indexed agent);
    event AgentRemoved(address indexed agent);
    event AgentAdminUpdated(address indexed admin);

    error OnlyAgent();
    error OnlyAgentAdmin();
    error AlreadyAgent();
    error NotAnAgent();
    error UnknownProposal();
    error WrongState();
    error VetoWindowOpen();
    error VetoWindowClosed();
    error AlreadyVetoed();
    error NoVotingWeight();
    error GuardiansBlocked();
    error ExecutionFailed();
    error FeeTooHigh();

    modifier onlyAgent() {
        if (!isAgent[msg.sender]) revert OnlyAgent();
        _;
    }

    modifier onlyAgentAdmin() {
        if (msg.sender != agentAdmin) revert OnlyAgentAdmin();
        _;
    }

    constructor(
        RecurveVault vault_,
        GuardianRegistry guardians_,
        address agent_,
        uint256 vetoWindow_,
        uint256 vetoThresholdBps_,
        uint256 guardianBlockThreshold_,
        uint256 performanceFeeBps_,
        address feeRecipient_
    ) {
        if (performanceFeeBps_ > 1500) revert FeeTooHigh();

        vault = vault_;
        guardians = guardians_;
        agentAdmin = agent_;
        isAgent[agent_] = true;
        agents.push(agent_);
        vetoWindow = vetoWindow_;
        vetoThresholdBps = vetoThresholdBps_;
        guardianBlockThreshold = guardianBlockThreshold_;
        performanceFeeBps = performanceFeeBps_;
        feeRecipient = feeRecipient_;
    }

    // ---------------------------------------------------------------- propose

    /// @notice Post a strategy for review. Calldata is committed here, in full, before
    ///         anyone decides — what guardians simulate is what will run.
    function propose(address target, uint256 assets, bytes calldata callData)
        external
        onlyAgent
        returns (bytes32 proposalId)
    {
        proposalId = keccak256(abi.encode(target, assets, callData, block.timestamp, address(this)));

        // Snapshot one block back so weight cannot be acquired in the same block the
        // proposal lands in.
        uint256 snapshot = block.number - 1;

        proposals[proposalId] = Proposal({
            target: target,
            assets: assets,
            callData: callData,
            postedAt: block.timestamp,
            snapshot: snapshot,
            vetoWeight: 0,
            state: State.Pending
        });

        emit ProposalPosted(proposalId, target, assets, block.timestamp + vetoWindow);
    }

    // ---------------------------------------------------------------- veto

    /// @notice Vote against a pending proposal, weighted by shares at the snapshot.
    function veto(bytes32 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.state == State.None) revert UnknownProposal();
        if (p.state != State.Pending) revert WrongState();
        if (block.timestamp >= p.postedAt + vetoWindow) revert VetoWindowClosed();
        if (hasVetoed[proposalId][msg.sender]) revert AlreadyVetoed();

        uint256 weight = IVotes(address(vault)).getPastVotes(msg.sender, p.snapshot);
        if (weight == 0) revert NoVotingWeight();

        hasVetoed[proposalId][msg.sender] = true;
        p.vetoWeight += weight;

        emit VetoCast(proposalId, msg.sender, weight);

        uint256 supply = IVotes(address(vault)).getPastTotalSupply(p.snapshot);
        if (supply > 0 && p.vetoWeight * BPS >= supply * vetoThresholdBps) {
            p.state = State.Vetoed;
            emit ProposalVetoed(proposalId, p.vetoWeight);
        }
    }

    // ---------------------------------------------------------------- execute

    /// @notice Execute a proposal that survived the veto window and guardian review.
    function execute(bytes32 proposalId) external onlyAgent nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.state == State.None) revert UnknownProposal();
        if (p.state != State.Pending) revert WrongState();
        if (block.timestamp < p.postedAt + vetoWindow) revert VetoWindowOpen();

        uint256 blocks_ = guardians.blockCount(proposalId);
        if (blocks_ >= guardianBlockThreshold) {
            p.state = State.Blocked;
            emit ProposalBlocked(proposalId, blocks_);
            revert GuardiansBlocked();
        }

        p.state = State.Executed;

        if (p.assets > 0) vault.fundStrategy(p.target, p.assets);

        // A proposal may be pure funding — a venue that pulls rather than being
        // pushed needs no call, and forcing empty calldata through would revert on
        // any target without a fallback.
        if (p.callData.length > 0) {
            (bool ok,) = p.target.call(p.callData);
            if (!ok) revert ExecutionFailed();
        }

        emit ProposalExecuted(proposalId, p.target, p.assets);
    }

    // ---------------------------------------------------------------- settle

    /// @notice Book the result of an executed strategy and take the performance fee.
    /// @param returned Assets the strategy handed back, already sitting in the vault.
    /// @dev Fee applies to profit only. A losing strategy pays nothing — there is no
    ///      management fee to collect for losing money.
    function settle(bytes32 proposalId, uint256 returned) external onlyAgent nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.state != State.Executed) revert WrongState();

        p.state = State.Settled;

        uint256 fee;
        if (returned > p.assets) {
            uint256 profit = returned - p.assets;
            fee = profit * performanceFeeBps / BPS;
        }

        vault.settleStrategy(returned);

        if (fee > 0 && feeRecipient != address(0)) {
            IERC20(vault.asset()).safeTransferFrom(msg.sender, feeRecipient, fee);
        }

        emit ProposalSettled(proposalId, returned, fee);
    }

    // ---------------------------------------------------------------- views

    function stateOf(bytes32 proposalId) external view returns (State) {
        return proposals[proposalId].state;
    }

    function executableAt(bytes32 proposalId) external view returns (uint256) {
        return proposals[proposalId].postedAt + vetoWindow;
    }

    /// @notice Registered agents.
    function allAgents() external view returns (address[] memory) {
        return agents;
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    // ---------------------------------------------------------------- agents

    function addAgent(address agent_) external onlyAgentAdmin {
        if (isAgent[agent_]) revert AlreadyAgent();
        isAgent[agent_] = true;
        agents.push(agent_);
        emit AgentAdded(agent_);
    }

    /// @notice Revoke an agent.
    /// @dev Proposals it already posted stay live. Removing an agent is not a
    ///      way to cancel its pending work, and pretending otherwise would give
    ///      the admin a silent veto that bypasses the depositor vote.
    function removeAgent(address agent_) external onlyAgentAdmin {
        if (!isAgent[agent_]) revert NotAnAgent();
        isAgent[agent_] = false;

        for (uint256 i; i < agents.length; ++i) {
            if (agents[i] == agent_) {
                agents[i] = agents[agents.length - 1];
                agents.pop();
                break;
            }
        }

        emit AgentRemoved(agent_);
    }

    function setAgentAdmin(address admin) external onlyAgentAdmin {
        agentAdmin = admin;
        emit AgentAdminUpdated(admin);
    }
}
