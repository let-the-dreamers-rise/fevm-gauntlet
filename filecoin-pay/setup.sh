#!/usr/bin/env bash
# Drop the invariant suite into FilecoinPayV1 at the exact mainnet commit and run it.
set -euo pipefail
cd "$(dirname "$0")"
REV=04ded6af6c15c4b5d98545f393dc656004d4aede # FilOzone/filecoin-pay main = v1.0.0 deployed at 0x23b1e018F08BB982348b15a86ee926eEBf7F4DAa
[ -d upstream ] || git clone -q https://github.com/FilOzone/filecoin-pay upstream
git -C upstream checkout -q "$REV"
git -C upstream submodule update --init --recursive -q
mkdir -p upstream/test/invariant
cp test/invariant/*.sol upstream/test/invariant/
