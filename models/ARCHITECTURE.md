# Model Architecture

The splicing model is decomposed by sub-protocol, mirroring the BOLT
structure. Each sub-protocol gets its own machine (P state machine) and its
own spec monitor(s). Cross-component invariants live in dedicated whole-system
monitors.

This file is the single source of truth for "which machine owns what."
When in doubt, citation lines from [`SPEC_SURVEY.md`](./SPEC_SURVEY.md)
disambiguate.

## Machines

There is one instance of each per peer (`PeerId = {A, B}`), with the exception
of `Blockchain` and `Network`, which are global.

### `Quiescence` (BOLT 2 §"Channel Quiescence", `02:1490–1556`)

States: `Idle → Quiescing → Quiescent → Idle` (on disconnect or on dependent-
protocol's explicit terminal event).

Events in:
- `eOpenStfu` — user/coordinator wants to enter quiescence as initiator.
- `eRecvStfu(initiator: int)` — peer sent `stfu`.
- `eDisconnect` — link dropped.
- `eDependentProtocolTerminated` — splice/dependent finished its terminal step.

Events out:
- `eQuiescenceAchieved(initiator: tPeerId)` — both sides have exchanged `stfu`.

Spec monitor: `Spec_Quiescence`.

### `InteractiveTx` (BOLT 2 §"Interactive Transaction Construction",
`02:100–627`)

Generic, parameterized by `(role, shared_input: option<tOutpoint>, my_contribution, require_confirmed)`.

States: `Idle → Inputting → Outputting → Completing → Done | Aborted`.

Events in:
- `eItxStart(params)` — coordinator kicks off the session.
- `eRecvTxAddInput`, `eRecvTxAddOutput`, `eRecvTxRemoveInput`,
  `eRecvTxRemoveOutput`, `eRecvTxComplete`, `eRecvTxAbort`.

Events out:
- `eItxConstructed(funding_outpoint, capacity, fees)`.
- `eItxAborted(reason)`.

Spec monitor: `Spec_InteractiveTx`.

### `SpliceCoordinator` (BOLT 2 §"Channel Splicing", `02:1558–2043`)

The glue. Drives the other machines for one splice attempt and its RBFs.

States: `Idle → ReqQuiescence → AwaitingSpliceAck → InItx → SigningCommitments
→ ExchangingTxSignatures → AwaitingConfirmation → Locked | Aborted`.

Events in:
- `eSpliceStart(contribution, feerate)` from user.
- `eRbfStart(...)` from user.
- `eRecvSpliceInit`, `eRecvSpliceAck`, `eRecvSpliceLocked`,
  `eRecvTxInitRbf`, `eRecvTxAckRbf`.
- `eRecvCommitSig`, `eRecvTxSignatures`.
- `eConfirmation(splice_txid, depth)` from `Blockchain`.

Events out:
- `eSendStfu`, `eSendSpliceInit`, `eSendSpliceAck`, `eSendSpliceLocked`.
- `eSendCommitSig`, `eSendTxSignatures`.
- `eDependentProtocolTerminated → Quiescence`.

Spec monitors: `Spec_CapacityConservation`, `Spec_LockMonotonicity`,
`Spec_ShutdownSpliceExclusion`.

### `Channel` (multi-commitment + reconnect)

Owns the set of active commitments, batched commit_sig, HTLC update validity
across all active commitments, and `channel_reestablish` semantics.

States: `Open ↔ Disconnected → Reestablishing → Open`.

Events in:
- `eHtlcAddOrFulfillOrFail` from user.
- `eRecvUpdateAddHtlc`, `eRecvCommitSig`, `eRecvRevokeAndAck`,
  `eRecvChannelReestablish`.
- `eSpliceLocked(splice_txid)` from `SpliceCoordinator` (causes pruning of
  RBF / ancestor commitments).

Events out:
- `eSendUpdate*`, `eSendCommitSig`, `eSendRevokeAndAck`,
  `eSendChannelReestablish`.

Spec monitors: `Spec_ActiveCommitmentsAgreement`, `Spec_HtlcValidAcrossAll`.

### `Blockchain` (global)

Non-deterministic confirmation oracle. Can confirm any pending splice
candidate on any peer's view; can fork peers' views; can reorg.

Events out:
- `eConfirmation(peer, txid, depth)`.
- `eReorg(peer, lost_txid, gained_txid)`.

Spec monitor: `Spec_ReorgSafety`.

### `Network` (global)

Explicit message broker that can drop, reorder, or block messages, and
signal `eDisconnect(peer)` to both ends. This is necessary for the
disconnect scenarios in `splicing-test.md:313+`.

Spec monitor: `Spec_NoLostStateAcrossReconnect`.

### `Gossip` (BOLT 7 §"announcement_signatures")

Models the `announcement_signatures` exchange after `splice_locked`.

Spec monitor: `Spec_GossipOrdering` — no `announcement_signatures` emitted
before lock + acceptable depth.

## Event Naming Conventions

- `e<Verb><Object>` for events the actor receives or emits.
- `eSend<Msg>` for messages a peer wants to send through `Network`.
- `eRecv<Msg>` for messages `Network` delivers to a peer.
- `e<Subject><Outcome>` for upward events to coordinators
  (e.g., `eQuiescenceAchieved`, `eItxConstructed`).

## Composition Diagram

```
              ┌─────────────────────────────────────────────────────────────┐
              │                          Peer A                              │
              │                                                              │
   user ────► │ SpliceCoordinator ◄──► Channel                               │
              │       │                  │                                   │
              │       ▼                  ▼                                   │
              │   Quiescence       (active commitments,                      │
              │       │              batched commit_sig,                     │
              │       ▼              reestablish)                            │
              │   InteractiveTx ────────┴─► Gossip                           │
              │       │                                                      │
              └───────┼──────────────────────────────────────────────────────┘
                      │ eSend* / eRecv*
                      ▼
              ┌───────────────────────┐         ┌───────────────────────┐
              │       Network         │         │      Blockchain       │
              │   (drop / disconnect) │         │  (confirm / fork)     │
              └───────────────────────┘         └───────────────────────┘
                      ▲
                      │
              ┌───────┼──────────────────────────────────────────────────────┐
              │                          Peer B                              │
              │             (same shape, mirrored)                           │
              └──────────────────────────────────────────────────────────────┘
```

## Why this decomposition

- **It mirrors the BOLTs.** A spec PR can target one section; the
  corresponding model file is the smallest change-blast-radius.
- **Each sub-protocol can be checked in isolation.** Phase 1 only needs
  `Quiescence` + a stub `SpliceCoordinator` that emits the trigger events.
  Phase 2 plugs in the real `SpliceCoordinator`. Phase 3 plugs in the real
  `InteractiveTx`.
- **Interactive-tx is shared with dual-funded v2 channel open.** Keeping it a
  reusable machine, parameterized rather than splice-specific, means the
  invariants we prove transfer.
- **The bridge (Phase 7) traces events by sub-protocol.** A real implementation
  can be tested against just `InteractiveTx` first; conformance to the splice
  glue is a separate test plane.
- **Whole-system invariants stay in dedicated monitors,** not buried in machine
  code. This makes the spec claims grep-able.

## Two `.pproj` split

Following the inspiration template:

- **`splicing.pproj`** — `Quiescence`, `InteractiveTx`, `SpliceCoordinator`,
  `Channel`, `Gossip` + protocol-level monitors.
- **`infra.pproj`** — `Network`, `Blockchain` + their monitors.
  Independently checkable so reorg/disconnect logic can be exercised without
  the full protocol harness.

`scripts/check-quick.sh` checks `infra.pproj` and a smoke subset of
`splicing.pproj`. `scripts/check.sh` runs the full suite.

## Where ambiguity goes

If a spec clause has multiple plausible readings, we model both. Each is a
configurable mode (`tModelConfig`), and a test case checks the "ideal" property
against each mode. The mode that violates the ideal becomes a counterexample
written up in [`FINDINGS.md`](./FINDINGS.md), citing back to
[`SPEC_QUESTIONS.md`](./SPEC_QUESTIONS.md).

Example pattern (lifted from `lightninglabs/darepo#216`):

```p
type tModelConfig = (
  quiescenceTiedInitiatorRule: tTiedInitiatorRule, // funder-wins | refuse
  rbfRequiresReQuiescence:     bool,
  spliceLockedMismatchBuffer:  bool,
  ...
);
```

Test cases pick the mode and check the ideal monitor. This keeps disagreements
explicit and discoverable.
