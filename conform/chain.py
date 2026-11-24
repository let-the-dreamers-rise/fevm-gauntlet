"""Run every scenario in scenarios.json inside eth_call on a real Filecoin node. No funds are spent."""
import json, sys, urllib.request
RPC = sys.argv[1] if len(sys.argv) > 1 else "https://api.node.glif.io/rpc/v1"
FROM = sys.argv[2] if len(sys.argv) > 2 else "0x2001578a55876ca7f4ddc1cddf354cddfbae5024"
bc = json.load(open("out/Probe.sol/Probe.json"))["bytecode"]["object"]
def w(x): return format(x, "064x")
def a(x): return x.lower().replace("0x", "").rjust(64, "0")
def rpc(method, params):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), {"content-type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=90))
def decode(h):
    v = [int(h[i:i + 64], 16) for i in range(0, 6 * 64, 64)]
    return {"ok": bool(v[0]), "credited": v[2] - v[1], "f410_actor_exists": bool(v[3]), "f410_id": v[4], "extra": v[5]}
head = rpc("eth_blockNumber", [])["result"]
out = {"rpc": RPC, "block": int(head, 16), "results": []}
for s in json.load(open("scenarios.json")):
    data = bc + w(s["kind"]) + a(s["target"]) + w(s["id"]) + a(s["observe"])
    r = rpc("eth_call", [{"from": FROM, "data": data, "value": "0x1"}, head])
    h = (r.get("error", {}).get("data") or "0x")[2:] if "error" in r else r["result"][2:]
    msg = r.get("error", {}).get("message", "")
    if len(h) < 384 and "revert reason=[0x" in msg:
        h = msg.split("revert reason=[0x")[1].split("]")[0]
    res = decode(h) if len(h) >= 384 else {"error": msg[:300]}
    out["results"].append({"name": s["name"], **res})
    print(s["name"], "->", res)
json.dump(out, open("results/chain.json", "w"), indent=1)
