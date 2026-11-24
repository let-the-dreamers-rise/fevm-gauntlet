# USDFC PriceFeed: seeded bugs (Secured-Finance/stablecoin-contracts ea5e205)

`test/PriceFeedStateMachine.t.sol` drives the real `PriceFeed.sol` (behind a proxy, mainnet timeouts: ORACLE_TIMEOUT 16 h, LAST_GOOD_PRICE_TIMEOUT 2 days) with a primary oracle and a fallback oracle that go fresh, stale, broken, reverting, future-dated, jump, and agree. Checked on every fetch: the only revert is a stale last good price after 2 days; a price labelled "primary" or "fallback" is that oracle's current, non-frozen price; a stale last good price is never served; returning to the primary oracle needs both oracles live and within 5%; two live, agreeing oracles always restore the primary (otherwise borrowing stays blocked by BorrowerOperations' primary-price gate).

| id | seeded bug | result | caught by |
|---|---|---|---|
| P1 | primary timestamp in the future not treated as broken | killed | fetch reverted for a reason other than a stale price |
| P2 | primary frozen only after 17 h instead of 16 h | killed | primary price older than ORACLE_TIMEOUT |
| P3 | oracles treated as agreeing within 50% instead of 5% | killed | returned to primary while oracles disagree by more than 5% |
| P4 | "both untrusted" never returns to the primary | killed | agree: primary not restored |
| P5 | stale last good price allowed | killed | stale lastGoodPrice served |
| P6 | fallback frozen check ignored | killed | fallback price older than ORACLE_TIMEOUT |

No finding in the unmodified PriceFeed so far (128 runs x depth 100). `test/MainnetPriceFeed.t.sol` (set FORK_URL) checks the deployed feed on mainnet state: on 24 Nov 2026 it used the primary (RedStone) price, updated 4 minutes earlier; the Tellor fallback was 3.8 h old.
