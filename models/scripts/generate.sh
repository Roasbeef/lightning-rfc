#!/usr/bin/env bash
# Regenerate the canonical JSON traces from the P model.
#
# For each generation test case (tcGen*), run the checker with a single
# schedule under --verbose, scrape the TraceObserver's `PTRACE|...` marker
# lines, and feed them to the gentrace tool to produce a JSON trace under
# traces/.
#
# This is the "auto-generation path": traces are derived from the model
# rather than hand-authored, so a spec/model change regenerates them and
# any drift is caught by `go test ./bridge`.

set -euo pipefail

cd "$(dirname "$0")/.."

DLL="PGenerated/PChecker/net8.0/Splicing.dll"

echo ">>> Compiling splicing.pproj"
p compile -pproj splicing.pproj >/dev/null

gen() {
  local testcase="$1"
  local scenario="$2"
  echo ">>> Generating traces/${scenario}.json from ${testcase}"
  # gentrace lives in the bridge Go module; run it from there and write to
  # ../traces so the absolute output lands under models/traces/.
  p check "$DLL" --testcase "$testcase" --schedules 1 --verbose 2>&1 \
    | ( cd bridge && go run ./cmd/gentrace \
          -scenario "$scenario" \
          -out "../traces/${scenario}.json" )
}

gen tcGenSpliceInHappy       splice_in_happy
gen tcGenDisconnectMidSplice disconnect_mid_splice

echo ">>> Verifying generated traces replay cleanly"
( cd bridge && go test ./... )

echo "OK"
