// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {U20DelegateExecutor} from "../src/U20DelegateExecutor.sol";

contract Echo {
    function who() external view returns (address) {
        return address(this);
    }
}

contract Boom {
    error Exploded(uint256 code);

    function fail() external pure {
        revert Exploded(7);
    }
}

contract U20DelegateExecutorTest is Test {
    U20DelegateExecutor internal exec;
    Echo internal echo;
    Boom internal boom;
    address internal alice = address(0xA11CE);

    function setUp() public {
        exec = new U20DelegateExecutor();
        echo = new Echo();
        boom = new Boom();
    }

    function test_otherCallerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(U20DelegateExecutor.NotSelf.selector, alice));
        exec.execute(address(echo), abi.encodeCall(Echo.who, ()));
    }

    function test_selfCallDelegatecalls() public {
        vm.prank(address(exec));
        bytes memory ret = exec.execute(address(echo), abi.encodeCall(Echo.who, ()));
        assertEq(abi.decode(ret, (address)), address(exec));
    }

    function test_selfCallBubblesRevert() public {
        vm.prank(address(exec));
        vm.expectRevert(abi.encodeWithSelector(Boom.Exploded.selector, uint256(7)));
        exec.execute(address(boom), abi.encodeCall(Boom.fail, ()));
    }

    function test_executorWritesNoStorage() public {
        vm.record();
        vm.prank(address(exec));
        exec.execute(address(echo), abi.encodeCall(Echo.who, ()));
        (, bytes32[] memory writes) = vm.accesses(address(exec));
        assertEq(writes.length, 0);

        // A failed self-call must not leave a write behind either.
        vm.record();
        vm.prank(address(exec));
        (bool ok,) = address(exec).call(abi.encodeCall(U20DelegateExecutor.execute, (address(boom), abi.encodeCall(Boom.fail, ()))));
        assertFalse(ok);
        (, bytes32[] memory writesAfterRevert) = vm.accesses(address(exec));
        assertEq(writesAfterRevert.length, 0);
    }
}
