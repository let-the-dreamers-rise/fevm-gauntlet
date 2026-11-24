"""Diff real-FEVM behaviour (results/chain.json) against fvm-solidity's forge mocks.
Writes results/table.md. With --baseline FILE, exits 1 if any row differs from the stored baseline
(a chain or mock behaviour changed). --write-baseline FILE stores the current rows."""
import json, sys
args = sys.argv[1:]
chain = json.load(open("results/chain.json"))
mocks = {"mock (fvm-solidity upstream)": json.load(open("results/mock-upstream.json")),
         "mock (pin used by FilecoinPayV1)": json.load(open("results/mock-v1pin.json"))}
def summ(r):
    if "error" in r: return "revert"
    s = ("ok" if r["ok"] else "fail") + (", credited" if r["credited"] else ", not credited")
    if r.get("extra"): s += f", codesize={r['extra']}"
    return s
rows, keyrows, div = [], [], 0
for i, c in enumerate(chain["results"]):
    cells = [summ(c)]
    note = ""
    if "pay(uint64) to the f3" in c["name"]:
        note = "mock needs the id registered first (mockResolveAddress); chain needs nothing"
    elif "miner" in c["name"]:
        note = "mock has no miner here unless the test calls mockMiner(); a real miner actor rejects plain value sends and has codesize 1"
    d = False
    for k, m in mocks.items():
        s = summ(m[i]); cells.append(s); d |= (s != cells[0])
    div += d
    keyrows.append({"name": c["name"], "cells": cells})
    rows.append(f"| {c['name']} | " + " | ".join(cells) + f" | {'**DIVERGES**' if d else 'same'} | {note} |")
print(f"Real FEVM: {chain['rpc']} at block {chain['block']}\n")
print("| scenario | real FEVM (mainnet state) | " + " | ".join(mocks) + " | verdict | note |")
print("|---" * (4 + len(mocks)) + "|")
print("\n".join(rows))
print(f"\n{div} of {len(rows)} scenarios diverge.")

with open("results/table.md", "w") as t:
    t.write("\n".join(rows) + "\n")
if "--write-baseline" in args:
    json.dump(keyrows, open(args[args.index("--write-baseline") + 1], "w"), indent=1)
if "--baseline" in args:
    base = {r["name"]: r["cells"] for r in json.load(open(args[args.index("--baseline") + 1]))}
    now = {r["name"]: r["cells"] for r in keyrows}
    changed = sorted(n for n in set(base) | set(now) if base.get(n) != now.get(n))
    for n in changed:
        print(f"CHANGED: {n}: baseline {base.get(n)} -> now {now.get(n)}")
    sys.exit(1 if changed else 0)
sys.exit(1 if div else 0)  # no baseline given: any divergence fails
