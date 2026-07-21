// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Guestbook} from "../src/Guestbook.sol";

contract GuestbookTest is Test {
    Guestbook internal book;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        book = new Guestbook();
    }

    function test_SignStoresEntryAndIncrementsCount() public {
        vm.prank(alice);
        book.sign("hello forte");

        assertEq(book.count(), 1);
        assertEq(book.messageCount(alice), 1);
        assertEq(book.getMessage(0), "hello forte");

        Guestbook.Entry memory e = book.getEntry(0);
        assertEq(e.author, alice);
        assertEq(e.text, "hello forte");
        assertEq(e.timestamp, uint64(block.timestamp));
    }

    function test_SignEmitsMessageSigned() public {
        vm.expectEmit(true, true, false, true);
        emit Guestbook.MessageSigned(alice, "yo", 0, uint64(block.timestamp));
        vm.prank(alice);
        book.sign("yo");
    }

    function test_RevertEmptyMessage() public {
        vm.prank(alice);
        vm.expectRevert(Guestbook.EmptyMessage.selector);
        book.sign("");
    }

    function test_RevertTooLong() public {
        string memory longText = _repeat("a", 281);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, 281));
        book.sign(longText);
    }

    function test_AcceptMaxLength() public {
        string memory maxText = _repeat("b", 280);
        vm.prank(alice);
        book.sign(maxText);
        assertEq(bytes(book.getMessage(0)).length, 280);
    }

    function test_AcceptMultibyteUtf8AtMaxBytes() public {
        // "é" is 2 UTF-8 bytes; 140 × 2 = 280.
        string memory text = _repeatUtf8(unicode"é", 140);
        assertEq(bytes(text).length, 280);
        vm.prank(alice);
        book.sign(text);
        assertEq(bytes(book.getMessage(0)).length, 280);
    }

    function test_RevertMultibyteUtf8OverMaxBytes() public {
        // 141 × 2 = 282 UTF-8 bytes — must reject even though char count < 280.
        string memory text = _repeatUtf8(unicode"é", 141);
        assertEq(bytes(text).length, 282);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, 282));
        book.sign(text);
    }

    function test_AcceptEmojiAtMaxBytes() public {
        // U+1F4A9 (pile of poo) is 4 UTF-8 bytes; 70 × 4 = 280.
        string memory text = _repeatUtf8(unicode"💩", 70);
        assertEq(bytes(text).length, 280);
        vm.prank(alice);
        book.sign(text);
        assertEq(bytes(book.getMessage(0)).length, 280);
    }

    function test_GetMessageOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(Guestbook.IndexOutOfBounds.selector, 0, 0));
        book.getMessage(0);
    }

    function test_GetEntryOutOfBounds() public {
        vm.prank(alice);
        book.sign("one");
        vm.expectRevert(abi.encodeWithSelector(Guestbook.IndexOutOfBounds.selector, 3, 1));
        book.getEntry(3);
    }

    function test_GetEntriesPaging() public {
        vm.prank(alice);
        book.sign("a");
        vm.prank(bob);
        book.sign("b");
        vm.prank(alice);
        book.sign("c");

        Guestbook.Entry[] memory page = book.getEntries(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0].text, "b");
        assertEq(page[0].author, bob);
        assertEq(page[1].text, "c");
        assertEq(page[1].author, alice);
    }

    function test_GetEntriesOffsetPastEndReturnsEmpty() public {
        vm.prank(alice);
        book.sign("only");
        Guestbook.Entry[] memory page = book.getEntries(5, 10);
        assertEq(page.length, 0);
    }

    function test_GetEntriesInvalidLimit() public {
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidRange.selector, 0, 0));
        book.getEntries(0, 0);

        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidRange.selector, 0, 51));
        book.getEntries(0, 51);
    }

    function test_MultipleAuthorsTrackedSeparately() public {
        vm.prank(alice);
        book.sign("from alice");
        vm.prank(bob);
        book.sign("from bob");
        vm.prank(alice);
        book.sign("alice again");

        assertEq(book.messageCount(alice), 2);
        assertEq(book.messageCount(bob), 1);
        assertEq(book.count(), 3);
    }

    function testFuzz_SignAcceptsValidLength(uint8 len) public {
        len = uint8(bound(len, 1, 280));
        string memory text = _repeat("x", len);
        vm.prank(alice);
        book.sign(text);
        assertEq(bytes(book.getMessage(0)).length, len);
    }

    function _repeat(string memory ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        bytes1 c = bytes(ch)[0];
        for (uint256 i = 0; i < n; ) {
            b[i] = c;
            unchecked {
                ++i;
            }
        }
        return string(b);
    }

    function _repeatUtf8(string memory ch, uint256 n) internal pure returns (string memory out) {
        out = "";
        for (uint256 i = 0; i < n; ) {
            out = string.concat(out, ch);
            unchecked {
                ++i;
            }
        }
    }
}
