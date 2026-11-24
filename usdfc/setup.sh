#!/usr/bin/env bash
# Fetch USDFC (Secured-Finance/stablecoin-contracts) at a pinned commit and forge-std, then run with `forge test`.
set -euo pipefail
cd "$(dirname "$0")"
REV=ea5e2053455f7febae0167ab2c4376856d493525 # main, 2 Nov 2026
[ -d upstream ] || git clone -q https://github.com/Secured-Finance/stablecoin-contracts upstream
git -C upstream checkout -q "$REV"
[ -d lib/forge-std ] || { git clone -q https://github.com/foundry-rs/forge-std lib/forge-std; git -C lib/forge-std checkout -q 3b20d60d14b343ee4f908cb8079495c07f5e8981; }
