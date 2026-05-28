#!/usr/bin/env bash
# CI-sized subset of the P checker suite.
#
# Phase 0: placeholder. In later phases this runs `infra.pproj` checks plus a
# smoke subset of `splicing.pproj`.

set -euo pipefail

cd "$(dirname "$0")/.."

echo ">>> Compiling infra.pproj"
p compile infra.pproj

# Phase 1+ will add the smoke test cases here. Keep this under ~60 seconds.

echo "OK"
