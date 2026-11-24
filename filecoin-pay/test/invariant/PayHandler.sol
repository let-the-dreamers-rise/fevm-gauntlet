// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FilecoinPayV1} from "../../src/FilecoinPayV1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockValidator} from "../mocks/MockValidator.sol";

/// Drives FilecoinPayV1 with random sequences of real user/operator/payee actions and keeps an
/// independent ledger (ghost state) of what the contract *should* hold. Invariants live in
/// PayInvariants.t.sol; anything that can be checked only at the moment of a call is asserted here.
contract PayHandler is Test {
    FilecoinPayV1 public pay;
    MockERC20 public token;
    MockValidator public validator;

    address[] public payers;
    address[] public payees;
    address[] public operators;
    address public feeRecipient = address(0xFEE);

    // every address that can ever hold an account (for sums)
    address[] public holders;

    uint256[] public railIds;
    mapping(uint256 => bool) public finalized;
    mapping(uint256 => bool) public terminated;
    // rails where the operator lowered the rate after termination (FilOzone/filecoin-pay#274: known phantom lockupUsage)
    mapping(uint256 => bool) public reducedAfterTermination;
    mapping(address => mapping(address => bool)) public pairTouchedBy274; // payer => operator

    mapping(uint256 => uint256) public ghostMaxRate; // highest rate a rail has ever had

    // ghost ledger
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostFeesBought; // fee tokens taken out through burnForFees

    // coverage counters
    mapping(bytes32 => uint256) internal _calls;

    function calls(bytes32 k) external view returns (uint256) {
        return _calls[k];
    }

    uint256 constant MAX_PERIOD = 2880 * 30; // 30 days of epochs

    constructor(FilecoinPayV1 _pay, MockERC20 _token, MockValidator _validator) {
        pay = _pay;
        token = _token;
        validator = _validator;
        for (uint256 i = 0; i < 3; i++) {
            payers.push(address(uint160(0x1000 + i)));
            payees.push(address(uint160(0x2000 + i)));
        }
        operators.push(address(0x3000));
        operators.push(address(0x3001));
        for (uint256 i = 0; i < 3; i++) {
            holders.push(payers[i]);
            holders.push(payees[i]);
        }
        holders.push(operators[0]);
        holders.push(operators[1]);
        holders.push(feeRecipient);
        holders.push(address(pay));
        for (uint256 i = 0; i < payers.length; i++) {
            token.mint(payers[i], 1e30);
            vm.prank(payers[i]);
            token.approve(address(pay), type(uint256).max);
        }
    }

    function holdersLength() external view returns (uint256) {
        return holders.length;
    }

    function railsLength() external view returns (uint256) {
        return railIds.length;
    }

    function payersLength() external view returns (uint256) {
        return payers.length;
    }

    function operatorsLength() external view returns (uint256) {
        return operators.length;
    }

    // ------------------------------------------------------------------ time

    /// Filecoin has null rounds: block.number can jump by more than one between tipsets.
    function roll(uint256 epochs) external {
        epochs = bound(epochs, 1, 6000);
        vm.roll(block.number + epochs);
        vm.warp(block.timestamp + epochs * 30);
        _calls[keccak256("roll")]++;
    }

    // ------------------------------------------------------------------ funds

    /// Deposit exactly what the payer needs to be settled up to now. The account must then be fully settled
    /// (SPEC: lockup is settled "up to and including the current epoch" when funds cover it).
    function exactTopUp(uint256 who) external {
        address p = payers[who % payers.length];
        (uint256 funds, uint256 lc, uint256 lr, uint256 ls) = pay.accounts(IERC20(address(token)), p);
        if (lr == 0 || ls >= block.number) return;
        uint256 need = lc + lr * (block.number - ls);
        if (need <= funds || need - funds > 1e24) return;
        uint256 amount = need - funds;
        vm.prank(p);
        pay.deposit(IERC20(address(token)), p, amount);
        ghostDeposited += amount;
        (uint256 f2, uint256 lc2,, uint256 ls2) = pay.accounts(IERC20(address(token)), p);
        assertEq(ls2, block.number, "exactly funded account must settle to now");
        assertEq(lc2, f2, "exactly funded account: lockupCurrent == funds");
        _calls[keccak256("exactTopUp")]++;
    }

    function deposit(uint256 who, uint256 amount) external {
        address p = payers[who % payers.length];
        amount = bound(amount, 1, 1e24);
        vm.prank(p);
        pay.deposit(IERC20(address(token)), p, amount);
        ghostDeposited += amount;
        _calls[keccak256("deposit")]++;
    }

    function withdrawAll(uint256 who) external {
        address h = holders[who % (holders.length - 1)]; // never the contract's own fee account
        // settle first through a no-op deposit-free path: getAccountInfoIfSettled is a view, so use it
        (uint256 fundedUntil,, uint256 available,) = pay.getAccountInfoIfSettled(IERC20(address(token)), h);
        if (available == 0) return;
        if (fundedUntil < block.number) return; // in debt: withdraw needs a fully settled account (by design)
        (uint256 funds,,,) = pay.accounts(IERC20(address(token)), h);
        vm.prank(h);
        try pay.withdraw(IERC20(address(token)), available) {
            ghostWithdrawn += available;
            _calls[keccak256("withdraw")]++;
        } catch (bytes memory err) {
            // Liveness: the view says `available` is free; withdrawing it must not revert.
            emit log_named_bytes("withdraw reverted", err);
            emit log_named_uint("funds", funds);
            emit log_named_uint("available", available);
            revert("LIVENESS: withdraw of getAccountInfoIfSettled.availableFunds reverted");
        }
    }

    // ------------------------------------------------------------------ approvals and rails

    function approve(uint256 who, uint256 op, uint256 rateAllow, uint256 lockAllow, uint256 period) external {
        address p = payers[who % payers.length];
        address o = operators[op % operators.length];
        rateAllow = bound(rateAllow, 0, 1e21);
        lockAllow = bound(lockAllow, 0, 1e26);
        period = bound(period, 1, 2880 * 3);
        vm.prank(p);
        pay.setOperatorApproval(IERC20(address(token)), o, true, rateAllow, lockAllow, period);
        _calls[keccak256("approve")]++;
    }

    function createRail(uint256 who, uint256 to, uint256 op, bool withValidator, uint256 commission) external {
        address p = payers[who % payers.length];
        address q = payees[to % payees.length];
        address o = operators[op % operators.length];
        commission = bound(commission, 0, 10000);
        (bool approved,,,,,) = pay.operatorApprovals(IERC20(address(token)), p, o);
        if (!approved) return;
        vm.prank(o);
        uint256 id = pay.createRail(
            IERC20(address(token)), p, q, withValidator ? address(validator) : address(0), commission, feeRecipient
        );
        railIds.push(id);
        _calls[keccak256("createRail")]++;
    }

    function _rail(uint256 idx) internal view returns (bool ok, uint256 id, FilecoinPayV1.RailView memory r) {
        if (railIds.length == 0) return (false, 0, r);
        id = railIds[idx % railIds.length];
        if (finalized[id]) return (false, id, r);
        try pay.getRail(id) returns (FilecoinPayV1.RailView memory rv) {
            return (true, id, rv);
        } catch {
            return (false, id, r);
        }
    }

    function modifyLockup(uint256 idx, uint256 period, uint256 fixedLockup, bool feasible) external {
        (bool ok, uint256 id, FilecoinPayV1.RailView memory r) = _rail(idx);
        if (!ok) return;
        if (feasible) {
            // aim inside what the payer approved and can afford, so the happy path is explored deeply
            (, , uint256 lockAllow,, uint256 lockUse, uint256 maxP) = pay.operatorApprovals(IERC20(address(token)), r.from, r.operator);
            period = r.endEpoch != 0 ? r.lockupPeriod : bound(period, 0, maxP);
            (, , uint256 avail,) = pay.getAccountInfoIfSettled(IERC20(address(token)), r.from);
            uint256 oldL = r.lockupFixed + r.paymentRate * r.lockupPeriod;
            uint256 room = lockAllow > lockUse ? lockAllow - lockUse : 0;
            if (avail < room) room = avail;
            uint256 streaming = r.paymentRate * period;
            uint256 cap = oldL + room > streaming ? oldL + room - streaming : 0;
            fixedLockup = bound(fixedLockup, 0, cap);
        } else {
            period = bound(period, 0, MAX_PERIOD);
            fixedLockup = bound(fixedLockup, 0, 1e24);
            if (r.endEpoch != 0) period = r.lockupPeriod; // period is frozen after termination
        }
        vm.prank(r.operator);
        try pay.modifyRailLockup(id, period, fixedLockup) {
            _calls[keccak256("modifyLockup")]++;
        } catch {
            _calls[keccak256("modifyLockup.revert")]++;
        }
    }

    function modifyRate(uint256 idx, uint256 rate, uint256 oneTime, bool feasible) external {
        (bool ok, uint256 id, FilecoinPayV1.RailView memory r) = _rail(idx);
        if (!ok) return;
        if (feasible && r.endEpoch == 0) {
            (, uint256 rateAllow, uint256 lockAllow, uint256 rateUse, uint256 lockUse,) =
                pay.operatorApprovals(IERC20(address(token)), r.from, r.operator);
            (, , uint256 avail,) = pay.getAccountInfoIfSettled(IERC20(address(token)), r.from);
            uint256 maxRate = r.paymentRate + (rateAllow > rateUse ? rateAllow - rateUse : 0);
            if (r.lockupPeriod > 0) {
                uint256 room = lockAllow > lockUse ? lockAllow - lockUse : 0;
                if (avail < room) room = avail;
                uint256 byLock = r.paymentRate + room / r.lockupPeriod;
                if (byLock < maxRate) maxRate = byLock;
            }
            rate = bound(rate, 0, maxRate);
        } else {
            rate = bound(rate, 0, 1e18);
        }
        oneTime = bound(oneTime, 0, r.lockupFixed);
        (,, uint256 allowBefore,, uint256 usageBefore,) =
            pay.operatorApprovals(IERC20(address(token)), r.from, r.operator);
        vm.prank(r.operator);
        try pay.modifyRailPayment(id, rate, oneTime) {
            if (rate > ghostMaxRate[id]) ghostMaxRate[id] = rate;
            (,, uint256 allowAfter,, uint256 usageAfter,) =
                pay.operatorApprovals(IERC20(address(token)), r.from, r.operator);
            // SPEC: a one-time payment is paid out of the operator's lockup allowance.
            assertEq(allowAfter, oneTime > allowBefore ? 0 : allowBefore - oneTime, "one-time payment must consume lockupAllowance");
            // Operator lockup usage moves by the change in streaming lockup over the period still owed, minus the one-time payment.
            // For a terminated rail the period still owed is endEpoch - now, not the full lockupPeriod.
            uint256 eff = r.endEpoch == 0 ? r.lockupPeriod : (r.endEpoch > block.number ? r.endEpoch - block.number : 0);
            assertEq(usageAfter, (usageBefore + rate * eff) - (r.paymentRate * eff + oneTime), "operator lockupUsage delta");
            if (r.endEpoch != 0 && rate < r.paymentRate) {
                reducedAfterTermination[id] = true;
                pairTouchedBy274[r.from][r.operator] = true;
            }
            _calls[keccak256("modifyRate")]++;
        } catch {
            _calls[keccak256("modifyRate.revert")]++;
        }
    }

    function terminate(uint256 idx, bool byPayer) external {
        (bool ok, uint256 id, FilecoinPayV1.RailView memory r) = _rail(idx);
        if (!ok || r.endEpoch != 0) return;
        (uint256 fundedUntil,,,) = pay.getAccountInfoIfSettled(IERC20(address(token)), r.from);
        bool inDebt = fundedUntil < block.number;
        vm.prank(byPayer ? r.from : r.operator);
        try pay.terminateRail(id) {
            // SPEC: a payer may terminate only while fully funded; otherwise only the operator can.
            assertFalse(byPayer && inDebt, "terminate: payer terminated while in debt");
            terminated[id] = true;
            _calls[keccak256("terminate")]++;
        } catch {
            _calls[keccak256("terminate.revert")]++;
        }
    }

    /// Settle and check per-call conservation: whatever leaves the payer arrives at payee + commission + fee account.
    function settle(uint256 idx, uint256 until) external {
        (bool ok, uint256 id, FilecoinPayV1.RailView memory r) = _rail(idx);
        if (!ok) return;
        until = bound(until, r.settledUpTo, block.number);
        IERC20 t = IERC20(address(token));
        uint256 sumBefore = _sumFunds();
        (uint256 payerBefore,,,) = pay.accounts(t, r.from);
        (uint256 payeeBefore,,,) = pay.accounts(t, r.to);
        vm.prank(r.from);
        try pay.settleRail(id, until) returns (uint256 total, uint256 net, uint256 comm, uint256 fee, uint256, string memory) {
            (uint256 payerAfter,,,) = pay.accounts(t, r.from);
            (uint256 payeeAfter,,,) = pay.accounts(t, r.to);
            assertEq(total, net + comm + fee, "settle: total != net + commission + fee");
            assertEq(payerBefore - payerAfter, total, "settle: payer debit != total settled");
            if (r.to != feeRecipient) assertEq(payeeAfter - payeeBefore, net, "settle: payee credit != net");
            assertEq(_sumFunds(), sumBefore, "settle: internal funds not conserved");
            assertGe(fee * 200, total, "settle: network fee below 0.5%");
            _checkPayoutBound(id, r.endEpoch, r.settledUpTo, until, total);
            _checkSettledUpTo(id, r.from, r.settledUpTo, r.paymentRate);
            _noteFinal(id);
            _calls[keccak256("settle")]++;
        } catch {
            _calls[keccak256("settle.revert")]++;
        }
    }

    /// After endEpoch the payer can always force settlement without the validator, and it must finalize.
    function forceSettleTerminated(uint256 idx) external {
        (bool ok, uint256 id, FilecoinPayV1.RailView memory r) = _rail(idx);
        if (!ok || r.endEpoch == 0 || block.number <= r.endEpoch) return;
        vm.prank(r.from);
        try pay.settleTerminatedRailWithoutValidation(id) {
            _noteFinal(id);
            assertTrue(finalized[id], "LIVENESS: terminated rail past endEpoch did not finalize");
            _calls[keccak256("forceSettle")]++;
        } catch (bytes memory err) {
            emit log_named_bytes("forceSettle reverted", err);
            revert("LIVENESS: settleTerminatedRailWithoutValidation reverted past endEpoch");
        }
    }

    function setValidatorMode(uint256 mode, uint256 factor) external {
        mode = bound(mode, 0, 2); // STANDARD, REDUCE_AMOUNT, REDUCE_DURATION
        validator.setMode(MockValidator.ValidatorMode(mode));
        validator.configure(bound(factor, 0, 100));
        _calls[keccak256("validatorMode")]++;
    }

    function buyFees(uint256 amount) external {
        IERC20 t = IERC20(address(token));
        (uint256 avail,,,) = pay.accounts(t, address(pay));
        if (avail == 0) return;
        amount = bound(amount, 1, avail);
        address bidder = address(0xB1D);
        vm.deal(bidder, 1e30);
        vm.prank(bidder);
        try pay.burnForFees{value: 1e24}(t, bidder, amount) {
            ghostFeesBought += amount;
            _calls[keccak256("burnForFees")]++;
        } catch {
            _calls[keccak256("burnForFees.revert")]++;
        }
    }

    // ------------------------------------------------------------------ helpers

    /// Wind a payer down: the operator terminates every live rail, time passes beyond every endEpoch, every rail is
    /// settled and finalized. Afterwards nothing may stay locked and the payer must be able to withdraw everything left.
    /// (SPEC: lockup only backs rails; once a rail is finalized its lockup is released.)
    function windDown(uint256 who) external {
        address p = payers[who % payers.length];
        uint256 maxEnd = block.number;
        for (uint256 i = 0; i < railIds.length; i++) {
            uint256 id = railIds[i];
            if (finalized[id]) continue;
            FilecoinPayV1.RailView memory r;
            try pay.getRail(id) returns (FilecoinPayV1.RailView memory rv) { r = rv; } catch { continue; }
            if (r.from != p) continue;
            if (r.endEpoch == 0) {
                vm.prank(r.operator);
                pay.terminateRail(id); // the operator may always terminate
                terminated[id] = true;
                r = pay.getRail(id);
            }
            if (r.endEpoch > maxEnd) maxEnd = r.endEpoch;
        }
        vm.roll(maxEnd + 1);
        vm.warp(block.timestamp + (maxEnd + 1 - block.number) * 30);
        for (uint256 i = 0; i < railIds.length; i++) {
            uint256 id = railIds[i];
            if (finalized[id]) continue;
            FilecoinPayV1.RailView memory r;
            try pay.getRail(id) returns (FilecoinPayV1.RailView memory rv) { r = rv; } catch { continue; }
            if (r.from != p) continue;
            vm.prank(p);
            pay.settleTerminatedRailWithoutValidation(id);
            _noteFinal(id);
            assertTrue(finalized[id], "windDown: rail not finalized past endEpoch");
        }
        (uint256 funds, uint256 lc, uint256 lr,) = pay.accounts(IERC20(address(token)), p);
        assertEq(lr, 0, "windDown: lockupRate left after all rails finalized");
        assertEq(lc, 0, "windDown: funds stay locked after all rails finalized");
        if (funds > 0) {
            vm.prank(p);
            pay.withdraw(IERC20(address(token)), funds);
            ghostWithdrawn += funds;
        }
        _calls[keccak256("windDown")]++;
    }

    function _checkSettledUpTo(uint256 id, address from, uint256 prevSettled, uint256 prevRate) internal view {
        try pay.getRail(id) returns (FilecoinPayV1.RailView memory ra) {
            (,,, uint256 payerSettledAt) = pay.accounts(IERC20(address(token)), from);
            if (ra.endEpoch == 0 && ra.settledUpTo > prevSettled && prevRate > 0) {
                // SPEC: a live rail is paid only for epochs the payer's lockup has been settled (funded) for.
                assertLe(ra.settledUpTo, payerSettledAt, "settle: live rail settled past payer's funded epoch");
            } else if (ra.endEpoch != 0) {
                assertLe(ra.settledUpTo, ra.endEpoch, "settle: terminated rail settled past endEpoch");
            }
        } catch {}
    }

    /// A rail can never pay more than its highest rate times the epochs it was open for,
    /// and a terminated rail pays nothing for epochs after endEpoch.
    function _checkPayoutBound(uint256 id, uint256 endEpoch, uint256 settledUpTo, uint256 until, uint256 total) internal view {
        uint256 upTo = endEpoch != 0 && endEpoch < until ? endEpoch : until;
        uint256 epochs = upTo > settledUpTo ? upTo - settledUpTo : 0;
        assertLe(total, ghostMaxRate[id] * epochs, "settle: paid more than max rate x payable epochs");
    }

    function _noteFinal(uint256 id) internal {
        try pay.getRail(id) returns (FilecoinPayV1.RailView memory) {}
        catch {
            finalized[id] = true;
        }
    }

    function _sumFunds() internal view returns (uint256 s) {
        for (uint256 i = 0; i < holders.length; i++) {
            (uint256 f,,,) = pay.accounts(IERC20(address(token)), holders[i]);
            s += f;
        }
    }

    function sumFunds() external view returns (uint256) {
        return _sumFunds();
    }
}
