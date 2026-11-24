#!/usr/bin/env bash
# Fetch the two fvm-solidity revisions whose forge mocks are compared against the real chain.
set -euo pipefail
cd "$(dirname "$0")"
FVM_UPSTREAM_REV=91a27a8c0c4443f0b21bd1afbf0dca6b836a85a9 # fvm-solidity main, 22 Oct 2026
FVM_V1PIN_REV=346eccf2f4daf5ad2aaab3d576f5c5d8955199f7    # the pin FilecoinPayV1 is built and tested with
FORGE_STD_REV=3b20d60d14b343ee4f908cb8079495c07f5e8981
fetch() { # repo rev dir subdir
  rm -rf "$3.tmp" "$3"; git clone -q "$1" "$3.tmp"; git -C "$3.tmp" checkout -q "$2"
  mkdir -p "$3"; cp -r "$3.tmp/$4/." "$3"; rm -rf "$3.tmp"; }
fetch https://github.com/filecoin-project/fvm-solidity "$FVM_UPSTREAM_REV" src/fvm-upstream src
fetch https://github.com/filecoin-project/fvm-solidity "$FVM_V1PIN_REV" src/fvm-v1pin src
[ -d lib/forge-std ] || { git clone -q https://github.com/foundry-rs/forge-std lib/forge-std; git -C lib/forge-std checkout -q "$FORGE_STD_REV"; }
