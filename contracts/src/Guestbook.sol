// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Guestbook — Phase 1 demo contract for ForteL2
/// @notice Learning-only; unbounded storage growth is intentional for a local demo.
contract Guestbook {
    uint256 public constant MAX_TEXT_BYTES = 280;
    uint256 public constant MAX_PAGE = 50;

    error EmptyMessage();
    error MessageTooLong(uint256 length);
    error IndexOutOfBounds(uint256 index, uint256 length);
    error InvalidRange(uint256 offset, uint256 limit);

    event MessageSigned(
        address indexed author,
        string text,
        uint256 indexed index,
        uint64 timestamp
    );

    struct Entry {
        address author;
        string text;
        uint64 timestamp;
    }

    Entry[] private _entries;
    mapping(address => uint256) public messageCount;

    function sign(string calldata text) external {
        uint256 len = bytes(text).length;
        if (len == 0) revert EmptyMessage();
        if (len > MAX_TEXT_BYTES) revert MessageTooLong(len);

        uint256 index = _entries.length;
        _entries.push(
            Entry({
                author: msg.sender,
                text: text,
                timestamp: uint64(block.timestamp)
            })
        );
        unchecked {
            messageCount[msg.sender] += 1;
        }
        emit MessageSigned(msg.sender, text, index, uint64(block.timestamp));
    }

    function count() external view returns (uint256) {
        return _entries.length;
    }

    /// @notice Legacy helper — returns text only.
    function getMessage(uint256 index) external view returns (string memory) {
        if (index >= _entries.length) {
            revert IndexOutOfBounds(index, _entries.length);
        }
        return _entries[index].text;
    }

    function getEntry(uint256 index) external view returns (Entry memory) {
        if (index >= _entries.length) {
            revert IndexOutOfBounds(index, _entries.length);
        }
        return _entries[index];
    }

    /// @notice Returns up to `limit` entries starting at `offset` (ascending index).
    function getEntries(uint256 offset, uint256 limit)
        external
        view
        returns (Entry[] memory page)
    {
        if (limit == 0 || limit > MAX_PAGE) revert InvalidRange(offset, limit);
        uint256 total = _entries.length;
        if (offset >= total) {
            return new Entry[](0);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        page = new Entry[](n);
        for (uint256 i = 0; i < n; ) {
            page[i] = _entries[offset + i];
            unchecked {
                ++i;
            }
        }
    }
}
