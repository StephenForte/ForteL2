// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Guestbook — Phase 1 demo contract for ForteL2
contract Guestbook {
    event MessageSigned(address indexed author, string text, uint256 index);

    string[] public messages;
    mapping(address => uint256) public messageCount;

    function sign(string calldata text) external {
        require(bytes(text).length > 0, "empty");
        require(bytes(text).length <= 280, "too long");
        messages.push(text);
        messageCount[msg.sender] += 1;
        emit MessageSigned(msg.sender, text, messages.length - 1);
    }

    function count() external view returns (uint256) {
        return messages.length;
    }

    function getMessage(uint256 index) external view returns (string memory) {
        return messages[index];
    }
}
