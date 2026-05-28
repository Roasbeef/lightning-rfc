#!/usr/bin/env bash
# Compile every P project and run the full checker suite, then the Go bridge.
#
# Projects:
#   splicing.pproj  — quiescence + splice + RBF + reconnect + close + gossip
#   channel.pproj   — base full-duplex commitment FSM (F9/F10 follow-up)
#   infra.pproj     — shared types (compile-only sanity)

set -euo pipefail

cd "$(dirname "$0")/.."

SPLICING_DLL="PGenerated/PChecker/net8.0/Splicing.dll"
CHANNEL_DLL="PGeneratedChannel/PChecker/net8.0/Channel.dll"

SCHEDULES="${SCHEDULES:-2000}"
MAX_STEPS="${MAX_STEPS:-5000}"

run() {
  local dll="$1"; local tc="$2"; local steps="$3"
  local out
  out=$(p check "$dll" --testcase "$tc" --schedules "$SCHEDULES" \
        --max-steps "$steps" 2>&1 | grep -E "Found .* bug" || true)
  if echo "$out" | grep -q "Found 0 bugs"; then
    printf "  ok   %s\n" "$tc"
  else
    printf "  FAIL %s -> %s\n" "$tc" "$out"
    return 1
  fi
}

echo ">>> Compiling splicing.pproj"
p compile -pproj splicing.pproj >/dev/null

echo ">>> Compiling channel.pproj"
p compile -pproj channel.pproj >/dev/null

echo ">>> Compiling infra.pproj"
p compile -pproj infra.pproj >/dev/null

echo ">>> Splicing suite"
run "$SPLICING_DLL" tcQuiescenceClean            200
run "$SPLICING_DLL" tcQuiescenceTied             200
run "$SPLICING_DLL" tcStfuWithPending            200
run "$SPLICING_DLL" tcQuiescenceDisconnect       200
run "$SPLICING_DLL" tcQuiescenceTerminateResume  200
run "$SPLICING_DLL" tcSpliceInHappy              "$MAX_STEPS"
run "$SPLICING_DLL" tcSpliceOutHappy             "$MAX_STEPS"
run "$SPLICING_DLL" tcSpliceZeroContribution     "$MAX_STEPS"
run "$SPLICING_DLL" tcSpliceWithRbf              "$MAX_STEPS"
run "$SPLICING_DLL" tcSpliceMultiRbf             "$MAX_STEPS"
run "$SPLICING_DLL" tcSpliceRbfFromNonInitiator  "$MAX_STEPS"
run "$SPLICING_DLL" tcDisconnectMidSplice        "$MAX_STEPS"
run "$SPLICING_DLL" tcDivergentConfirmation      "$MAX_STEPS"
run "$SPLICING_DLL" tcSpliceThenShutdown         "$MAX_STEPS"

echo ">>> Channel suite (base commitment FSM)"
run "$CHANNEL_DLL" tcOneDirectional      3000
run "$CHANNEL_DLL" tcConcurrentCommitSig 3000
run "$CHANNEL_DLL" tcSecondRound         3000
run "$CHANNEL_DLL" tcForwardSafe         3000

# Negative / counterexample test: tcForwardTooEarly MUST find the fund-loss
# safety violation (forwarding before irrevocable commitment). We invert the
# pass/fail sense here.
echo ">>> Channel negative test (expected to find a bug)"
neg=$(p check "$CHANNEL_DLL" --testcase tcForwardTooEarly --schedules 200 \
      --max-steps 500 2>&1 | grep -E "Found .* bug" || true)
if echo "$neg" | grep -q "Found 0 bugs"; then
  printf "  FAIL tcForwardTooEarly -> expected a violation, found none\n"
  exit 1
else
  printf "  ok   tcForwardTooEarly (fund-loss safety violation correctly caught)\n"
fi

echo ">>> Go bridge"
( cd bridge && go test ./... )

echo "OK"
