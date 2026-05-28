#!/usr/bin/env bash
# Compile both .pproj files and run the full P checker suite.
#
# Phase 0: placeholder — the .pproj files exist but only declare scaffold
# types. The first real test cases land in Phase 1 (quiescence machine).

set -euo pipefail

cd "$(dirname "$0")/.."

echo ">>> Compiling splicing.pproj"
p compile splicing.pproj

echo ">>> Compiling infra.pproj"
p compile infra.pproj

# Phase 1+ will add:
#
#   p check PGenerated/PChecker/net8.0/Splicing.dll \
#     --testcase tcQuiescenceClean       --schedules 5000 --max-steps 200
#   p check PGenerated/PChecker/net8.0/Splicing.dll \
#     --testcase tcQuiescenceTied        --schedules 5000 --max-steps 200
#   ... etc.
#
# Until then, this script is a build-only sanity check.

echo "OK"
