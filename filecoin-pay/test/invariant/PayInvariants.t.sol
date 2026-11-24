// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FilecoinPayV1} from "../../src/FilecoinPayV1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockValidator} from "../mocks/MockValidator.sol";
import {PayHandler} from "./PayHandler.sol";
import {console} from "forge-std/console.sol";

/// Stateful invariants for FilecoinPayV1, written from SPEC.md and the README rather than from the code.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail-on-revert = true
contract PayInvariants is StdInvariant, MockFVMTest {
    FilecoinPayV1 pay;
    MockERC20 token;
    MockValidator validator;
    PayHandler h;
    IERC20 t;

    function setUp() public override {
        super.setUp();
        vm.roll(1000);
        vm.warp(1_700_000_000);
        pay = new FilecoinPayV1();
        token = new MockERC20("USDFC-like", "USDFC");
        validator = new MockValidator(MockValidator.ValidatorMode.STANDARD);
        h = new PayHandler(pay, token, validator);
        t = IERC20(address(token));
        targetContract(address(h));
    }

    /// I1 solvency: the contract holds exactly the tokens its accounts say it holds.
    function invariant_I1_solvency() public view {
        assertEq(token.balanceOf(address(pay)), h.sumFunds(), "I1: token balance != sum of account funds");
    }

    /// I2 conservation against the independent ledger.
    function invariant_I2_conservation() public view {
        assertEq(
            h.sumFunds(), h.ghostDeposited() - h.ghostWithdrawn() - h.ghostFeesBought(), "I2: funds != deposits - out"
        );
    }

    /// I3 locked funds are always backed (SPEC: "account locked funds are always covered by account balance").
    function invariant_I3_lockupBacked() public view {
        for (uint256 i = 0; i < h.holdersLength(); i++) {
            (uint256 funds, uint256 lockupCurrent,,) = pay.accounts(t, h.holders(i));
            assertLe(lockupCurrent, funds, "I3: lockupCurrent > funds");
        }
    }

    struct Sums {
        uint256 rate; // live (not terminated) rails' rates
        uint256 opRate; // per payer/operator
        uint256 opLockup; // fixed + streaming lockup still owed to payees
        uint256 guaranteed; // what the payer's lockupCurrent must at least cover
    }

    /// I4 account lockupRate == sum of live rail rates; I5 operator rateUsage == sum of its live rail rates;
    /// I6 operator lockupUsage == sum of (fixed + rate * period) over unfinalized rails (except #274 pairs);
    /// I7 payee guarantee: payer lockupCurrent covers every unfinalized rail's fixed + remaining streaming lockup.
    function invariant_I4_to_I7_railAccounting() public view {
        for (uint256 pi = 0; pi < h.payersLength(); pi++) {
            address payer = h.payers(pi);
            (uint256 funds, uint256 lockupCurrent, uint256 lockupRate, uint256 settledAt) = pay.accounts(t, payer);
            funds;
            uint256 sumRate;
            uint256 guaranteed;
            for (uint256 oi = 0; oi < h.operatorsLength(); oi++) {
                address op = h.operators(oi);
                Sums memory s;
                for (uint256 ri = 0; ri < h.railsLength(); ri++) {
                    uint256 id = h.railIds(ri);
                    if (h.finalized(id)) continue;
                    FilecoinPayV1.RailView memory r;
                    try pay.getRail(id) returns (FilecoinPayV1.RailView memory rv) {
                        r = rv;
                    } catch {
                        continue;
                    }
                    if (r.from != payer || r.operator != op) continue;
                    if (r.endEpoch == 0) {
                        s.rate += r.paymentRate;
                        s.opLockup += r.lockupFixed + r.paymentRate * r.lockupPeriod;
                        s.guaranteed += r.lockupFixed + r.paymentRate * r.lockupPeriod;
                    } else {
                        s.opLockup += r.lockupFixed + r.paymentRate * r.lockupPeriod;
                        // lower bound: epochs after now all flow at the current rate
                        uint256 left = r.endEpoch > r.settledUpTo ? r.endEpoch - r.settledUpTo : 0;
                        uint256 fromNow = r.endEpoch > block.number ? r.endEpoch - block.number : 0;
                        s.guaranteed += r.lockupFixed + r.paymentRate * (fromNow < left ? fromNow : left);
                    }
                }
                (,, uint256 lockupAllowance, uint256 rateUsage, uint256 lockupUsage,) =
                    pay.operatorApprovals(t, payer, op);
                lockupAllowance;
                assertEq(rateUsage, s.rate, "I5: operator rateUsage != sum of live rail rates");
                if (!h.pairTouchedBy274(payer, op)) {
                    assertEq(lockupUsage, s.opLockup, "I6: operator lockupUsage != sum of rail lockups");
                } else {
                    assertGe(lockupUsage, s.opLockup, "I6(#274): lockupUsage below rail lockups");
                }
                sumRate += s.rate;
                guaranteed += s.guaranteed;
            }
            assertEq(lockupRate, sumRate, "I4: account lockupRate != sum of live rail rates");
            settledAt;
            assertGe(lockupCurrent, guaranteed, "I7: payee guarantee not backed by lockupCurrent");
        }
    }

    /// I8 nothing stays locked once every rail of a payer is finalized (SPEC: finalization releases the rail's lockup).
    function invariant_I8_noLockupWithoutRails() public view {
        for (uint256 pi = 0; pi < h.payersLength(); pi++) {
            address payer = h.payers(pi);
            bool open;
            for (uint256 ri = 0; ri < h.railsLength() && !open; ri++) {
                uint256 id = h.railIds(ri);
                if (h.finalized(id)) continue;
                try pay.getRail(id) returns (FilecoinPayV1.RailView memory rv) {
                    if (rv.from == payer) open = true;
                } catch {}
            }
            if (open) continue;
            (, uint256 lockupCurrent, uint256 lockupRate,) = pay.accounts(t, payer);
            assertEq(lockupRate, 0, "I8: lockupRate with no open rails");
            assertEq(lockupCurrent, 0, "I8: funds stay locked with no open rails");
        }
    }

    function afterInvariant() external view {
        string[17] memory names = [
            "deposit", "exactTopUp", "withdraw", "approve", "createRail", "modifyLockup", "modifyLockup.revert", "modifyRate",
            "modifyRate.revert", "terminate", "terminate.revert", "settle", "settle.revert", "forceSettle",
            "burnForFees", "roll", "windDown"
        ];
        string memory line = "coverage";
        for (uint256 i = 0; i < names.length; i++) {
            line = string.concat(line, " ", names[i], "=", vm.toString(h.calls(keccak256(bytes(names[i])))));
        }
        console.log(line);
    }
}
