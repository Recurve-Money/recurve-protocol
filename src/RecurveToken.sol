// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title RecurveToken
/// @notice $RECURVE. Fixed supply, minted once at deployment. No owner, no mint
///         function left behind — nothing to govern later because there is nothing
///         left that a key can do.
/// @dev This is the token WatcherRegistry takes as `stakeToken`. The registry names
///      it once, in its constructor or with `setStakeToken`, so whatever address
///      this contract gets deployed to is permanent for that registry's lifetime.
contract RecurveToken is ERC20 {
    constructor(uint256 totalSupply_, address recipient_) ERC20("Recurve", "RECURVE") {
        _mint(recipient_, totalSupply_);
    }
}
