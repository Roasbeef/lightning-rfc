# Bridge — P trace replay against real Lightning implementations

This is the Phase 7 bridge between the P model in `../src/*.p` and any
real Lightning implementation that wants to validate its splicing
behavior against the model. A trace is a sequence of structured events
the model emitted (or that an engineer hand-authored from
`models/SPEC_SURVEY.md` scenarios); the bridge feeds them to the
implementation and asserts the implementation's observable state matches
the model's `expected_post_state`.

## Files

| File                  | Purpose                                                  |
|-----------------------|----------------------------------------------------------|
| `trace.go`            | JSON schema (Trace, Event) + LoadTrace/Save.             |
| `implementation.go`   | `Implementation` interface; param structs per BOLT msg.  |
| `mock.go`             | `MockImplementation` — passes every canonical trace.     |
| `replay.go`           | `Replay(ctx, trace, alice, bob)` engine + Mismatch type. |
| `pobserve.go`         | (Phase 8) skeleton for the P→JSON trace emitter.         |
| `replay_test.go`      | Tests over the canonical traces under `../traces/`.      |

## Plugging in a real implementation

1. Implement the `Implementation` interface for your client (e.g., over
   that client's gRPC, RPC, or in-process API).
2. Call `bridge.Replay(ctx, trace, yourAliceImpl, yourBobImpl)`.
3. Inspect the returned `*Mismatch`.

Each `Mismatch` includes the trace event index, peer, field that
diverged, expected vs observed value, and the BOLT citation the event
exercises.

## Canonical traces (auto-generated from the model)

Under `../traces/`:

- `splice_in_happy.json` — Phase 2 reference flow.
- `disconnect_mid_splice.json` — Phase 4 reconnect flow.

These are **generated from the P model**, not hand-authored. The
`TraceObserver` spec machine in `../src/observer.p` records every
protocol step the machines announce via `eWireTrace` and `print`s a
`PTRACE|...` marker line. `../scripts/generate.sh` runs each `tcGen*`
test case under `p check --schedules 1 --verbose`, scrapes those
markers, and feeds them to `cmd/gentrace`, which assembles the JSON
trace matching the schema in `trace.go`.

Because the traces are model-derived, a spec/model change regenerates
them and any drift is caught by `go test ./...` (the replay tests run
against the regenerated files).

## How to add a new trace

1. Write a P test driver that exercises the scenario
   (`models/test/*.p`) and a `tcGen<Name>` test that attaches
   `TraceObserver`.
2. Add `emitTrace(...)` calls at the new wire-send points (or rely on
   existing ones).
3. Add a `gen tcGen<Name> <scenario>` line to `scripts/generate.sh`.
4. Run `./scripts/generate.sh` to emit `traces/<scenario>.json`.
5. Add a `TestReplay<Name>` to `replay_test.go`.

## Implementation contract notes

- **Quiescence**: `SendQuiescenceStfu(ctx, initiator)` — `initiator==1`
  for the initiator (Idle→Quiescing), `initiator==0` for the reply
  (Idle→Quiescent).
- **Shutdown vs. unlocked splice**: `SendShutdown` MUST return
  `ErrShutdownBlocked` if pending splices exist (BOLT 2 §2155). The
  bridge uses this contract as part of its post-state assertions.
- **State observation**: `Observe(ctx)` returns the full `State` snapshot
  used for post-condition comparison. Implementations should expose
  enough state to populate it accurately.

## Running

```bash
cd models/bridge
go test ./...
```
