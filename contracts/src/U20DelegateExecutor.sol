// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title U20DelegateExecutor
/// @notice Temporary EIP-7702 delegation target for the U20 upgrade.
/// @dev This contract has no state variables and never writes storage itself.
///      Under EIP-7702 the code runs in ADMIN's storage context, and the
///      following `delegatecall` keeps that context. OPCM v8 stores its own
///      addresses in immutables and mutates the chain by CALL, so a storage
///      layout here would be the only thing that could occupy a slot in
///      ADMIN's context during the call. The entry point delegatecalls only
///      when `msg.sender == address(this)`, which means only ADMIN calling
///      itself succeeds.
contract U20DelegateExecutor {
    error NotSelf(address caller);

    function execute(address target, bytes calldata data) external payable returns (bytes memory result) {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        bool ok;
        (ok, result) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
