# fevm-gauntlet

Security tests for Filecoin EVM contracts that check two things the usual suites leave out:

1. **Are the test mocks true?** FEVM contracts are tested on forge with mocks of Filecoin's precompiles and actors (fvm-solidity's `MockFVMTest`, Solstice's f02 mock). `conform/` runs the same probe contract on mainnet state (inside `eth_call`, so it spends nothing and deploys nothing) and on the forge mock, and reports every place they disagree.
2. **Do the contracts keep their own promises?** `filecoin-pay/` is a stateful invariant suite for FilecoinPayV1, written from its SPEC.md, with an independent ghost ledger. `filecoin-pay/MUTATION.md` shows which seeded bugs it catches next to the project's own 169 tests, including the ones it misses.

Targets are the ones named in Filecoin ProPGF RFP 1: Filecoin Pay (V1, and V2 before it deploys), USDFC and Solstice. Vulnerabilities go to the maintainers privately first. A scenario stays out of this repo until its maintainer has fixed it or agreed to publish.

## Run it

Needs Foundry and Python 3. No keys, no funds.

```sh
# chain vs mock, against mainnet through Glif's public RPC
cd conform
bash setup.sh                 # fetches the two fvm-solidity revisions being compared
forge test                    # mock side  -> results/mock-*.json
python3 chain.py              # chain side -> results/chain.json (pass another RPC URL as arg 1)
python3 compare.py --baseline baseline.json   # table in results/table.md; exit 1 if anything changed

# FilecoinPayV1 invariants, at the commit deployed on mainnet (0x23b1e018F08BB982348b15a86ee926eEBf7F4DAa)
cd ../filecoin-pay
bash setup.sh
cd upstream && forge test --match-path 'test/invariant/*' -vv
```

CI runs both on every push and nightly. The nightly conform job fails if the chain or a mock starts behaving differently from `baseline.json`.

## What is in the baseline today

12 public scenarios, 4 of which differ between mainnet and the fvm-solidity mocks:

| scenario | mainnet | mock |
|---|---|---|
| `FVMPay.pay(uint64 id)` to an existing f3 account | delivered | fails unless the test first calls `mockResolveAddress` |
| `call{value}` to a miner actor | fails (miners reject plain value) | succeeds |
| `transfer()` to a miner actor | fails | succeeds |
| `extcodesize` of a miner actor | 1 | 0 |

These are mock setup gaps rather than bugs, but each one is a place where a test can pass and mainnet can do something else. More scenarios are being added for every precompile and actor method that Filecoin Pay, FWSS, USDFC and Solstice call.

## How the probes work

`conform/src/Probe.sol` does one action in its constructor (pay by address, pay by id, plain call, transfer, burn, or codesize) and reverts with what it observed: success, the recipient's balance before and after, and whether the recipient's f410 address resolves to an actor afterwards. `chain.py` sends the creation bytecode in `eth_call`; `test/MockSide.t.sol` deploys the same bytecode on top of each mock. Native-account behaviour that EVM tests cannot simulate (an f1/f3 wallet as `msg.sender`) is checked with `Filecoin.StateCall` and its execution trace.

## The invariants (FilecoinPayV1)

| id | property |
|---|---|
| I1 | the contract's token balance equals the sum of account funds |
| I2 | sum of funds equals deposits minus withdrawals minus fee-auction payouts (independent ledger) |
| I3 | locked funds never exceed funds |
| I4 | an account's lockupRate equals the sum of its live rails' rates |
| I5 | an operator's rateUsage equals the sum of its live rails' rates |
| I6 | an operator's lockupUsage equals the fixed plus streaming lockup of its open rails (relaxed to a lower bound where the known FilOzone/filecoin-pay#274 applies) |
| I7 | a payee's guarantee holds: the payer's lockup covers every open rail's fixed lockup and the streaming lockup still owed |
| I8 | a payer with no open rails has nothing locked |

Checked at the moment of each call: settlement splits (`total == net + commission + fee`, fee at least 0.5%), one-time payments consume the operator's lockup allowance, operator lockup usage moves by exactly the streaming lockup still owed, an exactly-funded account settles to the current epoch, a withdrawal of the amount `getAccountInfoIfSettled` reports as available never reverts, a terminated rail past its end epoch always finalizes, and `windDown` (terminate everything, let time pass, finalize) leaves nothing locked and lets the payer withdraw everything.

Actions: deposit, exact top-up, withdraw, approve, create rail, modify lockup, modify rate with one-time payments, terminate (by payer or operator), settle with a validator that can withhold, force-settle, fee auction, wind-down, and epoch jumps of up to 6000 (null rounds).

## USDFC PriceFeed

`usdfc/` fuzzes the real `PriceFeed.sol` from Secured-Finance/stablecoin-contracts with the mainnet timeouts, driving the primary and fallback oracles through fresh, stale, broken, reverting, future-dated and agreeing states. It checks that the feed only reverts on a stale price after 2 days, that a price labelled primary or fallback really is that oracle's current price, and that two live, agreeing oracles always bring the primary back. That last one matters because BorrowerOperations blocks risk-increasing actions unless the price came from the primary. `usdfc/MUTATION.md` shows it catches 6 of 6 seeded oracle bugs. `MainnetPriceFeed.t.sol` runs the same checks on the deployed feed through a mainnet fork.

```sh
cd usdfc && bash setup.sh && FORK_URL=https://api.node.glif.io/rpc/v1 forge test -vv
```

## Licence

MIT or Apache-2.0, at your option.
