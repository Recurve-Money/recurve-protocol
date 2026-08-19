// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RecurveVault
/// @notice The onchain identity of a fund. Holds every position, mints shares that
///         double as voting weight, and refuses to move capital except through the
///         governor that owns it.
/// @dev Shares are `ERC20Votes` so the governor can snapshot weight at proposal time
///      and a depositor cannot buy votes after seeing what is being proposed.
///
///      Liquidity model: redemptions clear instantly against the idle float. When the
///      float is short, the request is queued and settles at the price realized when
///      the agent unwinds — the vault never guesses at the value of a live position.
contract RecurveVault is ERC4626, ERC20Votes, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The governor allowed to move capital out of this vault.
    /// @dev Not a constructor argument: vault and governor each need the other's
    ///      address, so one of the two has to be settable after deploy. This is
    ///      the one — set once, by whoever deployed this vault, before anyone
    ///      has deposited. `deployGovernorTogether` in the deploy script still
    ///      predicts the address and passes it in for a single-transaction
    ///      setup; `setGovernor` exists for deploying by hand, one contract at
    ///      a time, with no address prediction required.
    address public governor;

    /// @notice Whoever deployed this vault. Allowed to call `setGovernor` once.
    address private immutable _deployer;

    /// @notice Assets currently committed to a live strategy, denominated in `asset()`.
    /// @dev Carried explicitly rather than inferred, because a position mid-unwind is
    ///      neither in the float nor visible to `balanceOf`.
    uint256 public deployedAssets;

    /// @notice Total assets owed to depositors whose redemption is waiting on an unwind.
    uint256 public pendingWithdrawalAssets;

    struct WithdrawalRequest {
        uint256 shares;
        uint256 requestedAt;
        address receiver;
        bool claimed;
    }

    /// @notice Queued redemptions, in request order.
    WithdrawalRequest[] public withdrawalQueue;

    /// @notice Requests belonging to an owner, by queue index.
    mapping(address => uint256[]) public requestsOf;

    event StrategyFunded(address indexed target, uint256 assets);
    event StrategySettled(uint256 assetsReturned, int256 pnl);
    event WithdrawalQueued(address indexed owner, uint256 indexed requestId, uint256 shares);
    event WithdrawalClaimed(address indexed owner, uint256 indexed requestId, uint256 assets);

    error OnlyGovernor();
    error OnlyDeployer();
    error GovernorAlreadySet();
    error NothingToSettle();
    error FloatTooLow();
    error RequestNotReady();
    error RequestAlreadyClaimed();
    error NotRequestOwner();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor();
        _;
    }

    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC4626(asset_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _deployer = msg.sender;
    }

    /// @notice Set the governor. Callable once, only by whoever deployed this
    ///         vault, and only before it has ever been set.
    /// @dev No further access control is needed beyond "once" - once set, this
    ///      function is permanently dead code (governor != address(0) forever
    ///      after), so there is no window where it could be called again by
    ///      anyone, deployer included.
    function setGovernor(address governor_) external {
        if (msg.sender != _deployer) revert OnlyDeployer();
        if (governor != address(0)) revert GovernorAlreadySet();
        if (governor_ == address(0)) revert GovernorAlreadySet();
        governor = governor_;
    }

    // ---------------------------------------------------------------- accounting

    /// @inheritdoc ERC4626
    /// @dev Float plus deployed capital. `pendingWithdrawalAssets` is deliberately not
    ///      subtracted: those shares are still outstanding until the claim burns them,
    ///      so netting them here would double-count the exit.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + deployedAssets;
    }

    /// @notice Assets sitting idle and immediately redeemable.
    function float() public view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        return balance > pendingWithdrawalAssets ? balance - pendingWithdrawalAssets : 0;
    }

    // ---------------------------------------------------------------- strategy

    /// @notice Move assets out to a strategy target. Governor-only, and only ever
    ///         called after a proposal has cleared both the vote and watcher review.
    function fundStrategy(address target, uint256 assets) external onlyGovernor nonReentrant {
        if (assets > float()) revert FloatTooLow();
        deployedAssets += assets;
        IERC20(asset()).safeTransfer(target, assets);
        emit StrategyFunded(target, assets);
    }

    /// @notice Book the result of an unwind and clear the deployed balance.
    /// @param assetsReturned Assets actually received back from the strategy.
    /// @dev The caller transfers assets in before calling. `pnl` is reported rather
    ///      than derived by callers so indexers do not have to reconstruct it.
    function settleStrategy(uint256 assetsReturned) external onlyGovernor nonReentrant {
        uint256 deployed = deployedAssets;
        if (deployed == 0) revert NothingToSettle();

        deployedAssets = 0;
        // Both operands are bounded by the vault's asset balance, which cannot reach
        // 2**255 for any ERC-20 with a sane supply.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 pnl = int256(assetsReturned) - int256(deployed);
        emit StrategySettled(assetsReturned, pnl);
    }

    // ---------------------------------------------------------------- redemption

    /// @notice Redeem instantly if the float covers it, otherwise join the queue.
    /// @return requestId Queue position, or `type(uint256).max` when the redemption
    ///         cleared immediately.
    function requestRedeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        uint256 assets = previewRedeem(shares);

        if (assets <= float()) {
            _withdraw(_msgSender(), receiver, owner, assets, shares);
            return type(uint256).max;
        }

        if (_msgSender() != owner) _spendAllowance(owner, _msgSender(), shares);
        _transfer(owner, address(this), shares);

        requestId = withdrawalQueue.length;
        withdrawalQueue.push(
            WithdrawalRequest({
                shares: shares, requestedAt: block.timestamp, receiver: receiver, claimed: false
            })
        );
        requestsOf[owner].push(requestId);

        emit WithdrawalQueued(owner, requestId, shares);
    }

    /// @notice Claim a queued redemption once the float can cover it.
    /// @dev Priced at claim time, not request time — the queue exists precisely because
    ///      the exit price was unknown when the request was made.
    function claimRedeem(uint256 requestId) external nonReentrant returns (uint256 assets) {
        WithdrawalRequest storage request = withdrawalQueue[requestId];
        if (request.claimed) revert RequestAlreadyClaimed();

        bool owned;
        uint256[] storage mine = requestsOf[_msgSender()];
        for (uint256 i; i < mine.length; ++i) {
            if (mine[i] == requestId) {
                owned = true;
                break;
            }
        }
        if (!owned) revert NotRequestOwner();

        assets = previewRedeem(request.shares);
        if (assets > float()) revert RequestNotReady();

        request.claimed = true;
        _burn(address(this), request.shares);
        IERC20(asset()).safeTransfer(request.receiver, assets);

        emit WithdrawalClaimed(_msgSender(), requestId, assets);
    }

    /// @notice Queue positions belonging to `owner`.
    function requestIdsOf(address owner) external view returns (uint256[] memory) {
        return requestsOf[owner];
    }

    /// @notice Number of redemption requests ever created.
    function queueLength() external view returns (uint256) {
        return withdrawalQueue.length;
    }

    // ---------------------------------------------------------------- overrides

    function decimals() public view override(ERC4626, ERC20) returns (uint8) {
        return ERC4626.decimals();
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
