// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FVMPay} from "./fvm-upstream/FVMPay.sol";

/// One FEVM behaviour per construction. Never deployed: it runs inside eth_call (on a real
/// Filecoin node) or inside forge (on fvm-solidity's mocks) and reverts with what it saw, so the
/// two can be diffed. Needs no funds beyond the 1 attoFIL `value` of the simulated call.
contract Probe {
    address constant RESOLVE_ADDRESS = 0xFE00000000000000000000000000000000000001;

    uint8 constant PAY_ADDRESS = 1; // FVMPay.pay(address)  (FilecoinPayV1.withdraw*, FilecoinPayV2._withdrawTo)
    uint8 constant PAY_ID = 2; // FVMPay.pay(uint64)
    uint8 constant EVM_CALL = 3; // address.call{value}("")
    uint8 constant EVM_TRANSFER = 4; // address.transfer (2300 gas stipend)
    uint8 constant BURN = 5; // FVMPay.burn
    uint8 constant CODESIZE = 6; // extcodesize(target)

    constructor(uint8 kind, address target, uint64 id, address observe) payable {
        uint256 before = observe.balance;
        bool ok;
        uint256 extra;
        if (kind == PAY_ADDRESS) {
            ok = FVMPay.pay(target, msg.value);
        } else if (kind == PAY_ID) {
            ok = FVMPay.pay(id, msg.value);
        } else if (kind == EVM_CALL) {
            (ok,) = payable(target).call{value: msg.value}("");
        } else if (kind == EVM_TRANSFER) {
            // what Solidity's transfer() does: forward 0 gas, callee runs on the 2300 stipend
            (ok,) = payable(target).call{value: msg.value, gas: 0}("");
        } else if (kind == BURN) {
            ok = FVMPay.burn(msg.value);
        } else if (kind == CODESIZE) {
            uint256 s;
            assembly {
                s := extcodesize(target)
            }
            extra = s;
            ok = true;
        }
        uint256 afterBal = observe.balance;
        // Does a delegated (f410) actor now exist for `target`'s 20 bytes?
        (bool found, bytes memory rid) = RESOLVE_ADDRESS.staticcall(abi.encodePacked(hex"040a", target));
        uint256 f410id = found && rid.length >= 32 ? abi.decode(rid, (uint256)) : 0;
        bytes memory out = abi.encode(ok, before, afterBal, found && rid.length >= 32, f410id, extra);
        assembly {
            revert(add(out, 32), mload(out))
        }
    }
}
