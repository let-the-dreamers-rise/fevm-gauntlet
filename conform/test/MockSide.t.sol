// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Probe} from "../src/Probe.sol";
import {MockFVMTest as MockUpstream} from "../src/fvm-upstream/mocks/MockFVMTest.sol";
import {MockFVMTest as MockV1Pin} from "../src/fvm-v1pin/mocks/MockFVMTest.sol";

/// Runs scenarios.json against fvm-solidity's own forge mocks and writes what they report.
abstract contract MockSide is Test {
    struct S {
        uint256 id;
        uint256 kind;
        string name;
        address observe;
        address target;
    }

    function _run(string memory outFile) internal {
        S[] memory ss = abi.decode(vm.parseJson(vm.readFile("scenarios.json")), (S[]));
        string memory all = "[";
        vm.deal(address(this), 1 ether);
        for (uint256 i = 0; i < ss.length; i++) {
            bytes memory ret;
            try new Probe{value: 1}(uint8(ss[i].kind), ss[i].target, uint64(ss[i].id), ss[i].observe) {
                ret = "";
            } catch (bytes memory r) {
                ret = r;
            }
            string memory row;
            if (ret.length >= 192) {
                (bool ok, uint256 b0, uint256 b1, bool found,, uint256 extra) =
                    abi.decode(ret, (bool, uint256, uint256, bool, uint256, uint256));
                row = string.concat(
                    '{"name":"', ss[i].name, '","ok":', ok ? "true" : "false", ',"credited":', vm.toString(b1 - b0),
                    ',"f410_actor_exists":', found ? "true" : "false", ',"extra":', vm.toString(extra), "}"
                );
            } else {
                row = string.concat('{"name":"', ss[i].name, '","error":"', vm.toString(ret), '"}');
            }
            all = string.concat(all, i == 0 ? "" : ",", row);
        }
        vm.writeFile(outFile, string.concat(all, "]"));
    }
}

contract MockUpstreamSide is MockSide, MockUpstream {
    function test_mock_upstream() public {
        _run("results/mock-upstream.json");
    }
}

contract MockV1PinSide is MockSide, MockV1Pin {
    function test_mock_filecoinpay_v1_pin() public {
        _run("results/mock-v1pin.json");
    }
}
