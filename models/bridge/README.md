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

## Canonical traces

Under `../traces/`:

- `splice_in_happy.json` — Phase 2 reference flow.
- `disconnect_mid_splice.json` — Phase 4 reconnect flow.

Each is hand-authored from `models/SPEC_SURVEY.md` and the
`bolt02/splicing-test.md` scenarios. Future iterations will have the P
model auto-emit these via a logger spec (see `pobserve.go`).

## How to add a new trace

1. Write a P test case that exercises the scenario (under
   `models/test/*.p`).
2. Run `p check ... --testcase tcX` and confirm Spec_* monitors pass.
3. Translate the schedule into a JSON file under `traces/`.
4. Add a `TestReplayX` to `replay_test.go`.

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
