# Mutation table: FilecoinPayV1 at 04ded6a

Each mutant is one seeded bug in `src/FilecoinPayV1.sol` (definitions: `mutants.py`). "Existing" is the project's own test suite (169 tests, invariant suite excluded). "v1" is the first version of this suite; "v2" adds exact per-call checks, an exact top-up action and a wind-down action; "v3" (current) adds settlement-bound checks (no live rail paid past the payer's funded epoch, no rail paid more than its highest rate for the epochs it was open) and refuses payer termination while in debt. Runs are 64 x depth 200 with random seeds. Run 23-25 Nov 2026.

| id | seeded bug | existing | v1 | v2 | v3 | how v3 caught it |
|---|---|---|---|---|---|---|
| M01 | termination endEpoch one epoch short | killed | killed | killed | killed | windDown: funds stay locked |
| M02 | network fee rounds down instead of up | **survived** | killed | killed | killed | settle: fee below 0.5% |
| M03 | one-time payment not taken out of rail fixed lockup | killed | killed | killed | killed | contract reverts on a valid call |
| M04 | one-time payment does not consume lockupAllowance | killed | survived | killed | killed | one-time payment must consume allowance |
| M05 | rate change on a terminated rail re-locks over the full period | **survived** | survived | killed | killed | operator lockupUsage delta |
| M06 | validator-withheld funds stay locked | killed | survived | killed | killed | windDown: funds stay locked |
| M07 | exactly-funded account treated as short | survived | survived | survived | survived | equivalent mutant: the fallback branch computes the same result when funds are exact, so no test can tell them apart |
| M08 | partial account settlement rounds epochs up | killed | killed | killed | killed | lockup exceeds funds |
| M09 | finalization unlocks only half the fixed lockup | killed | survived | killed | killed | windDown: funds stay locked |
| M10 | live-rail settlement not capped at payer's settled epoch | killed | survived | **survived** | killed | settle: live rail settled past payer's funded epoch |
| M11 | terminated-rail settlement not capped at endEpoch | killed | killed | **survived** | killed | contract rejects a payout the cap should have stopped |
| M12 | rate decrease frees only half the rate usage | killed | killed | killed | killed | I5 rateUsage |
| M13 | commission credited twice | killed | killed | killed | killed | I1 solvency |
| M14 | payer can terminate while in debt | killed | survived | **survived** | killed | terminate: payer terminated while in debt |

Summary: the existing tests miss M02 and M05; this suite catches both. The current suite (v3) catches 13 of 14 on its own. The one it misses, M07, is equivalent: no test can tell it from the original code.
