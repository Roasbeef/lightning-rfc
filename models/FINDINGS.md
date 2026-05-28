# Findings

Observations surfaced by the P model that point to spec underspecification,
ambiguities, or implementation correctness traps. Each entry cites:

- The BOLT clause involved (`file:line`).
- The matching seeded question in `SPEC_QUESTIONS.md`, if any.
- The reproducer test case + schedule depth at which it appears.
- A suggested spec clarification.

## Status legend

- **Open** — finding stands; spec change proposed but not yet upstreamed.
- **Modeled** — model handles both interpretations under a config flag;
  the right behavior is settled but the spec text is ambiguous.
- **Clarified** — spec PR has clarified the rule; closed.
- **By design** — re-reading shows the spec is unambiguous; downgraded.

---

## F1. Implementation race between local quiescence-tracker and splice-coordinator

**Status:** Open. **Spec citation:** none (gap). **Question:** Q17a.

When the quiescence-state module and the splice-coordinator module are
decoupled threads/processes, the local "we are now quiescent"
notification and an incoming `splice_init` from the peer race. Either:

- The implementation incorrectly treats §1687 ("received splice_init
  while not quiescent") as triggered → tears down the channel needlessly.
- Or the implementation trusts the wire → §1687 is unenforceable as
  written.

The model handles this via `defer eRecvSpliceInit` in the SC's
`Operating` state, so local quiescence is always processed first.
This is a model artifact — but the spec doesn't name the race or
recommend a resolution.

**Suggested clarification.** BOLT 2 should add a note to §1687
acknowledging the race and recommending one of:

- A unified peer-state lock so quiescence + coord state move together.
- An "is-our-QP-quiescent" check that tolerates the in-process race
  (peer's wire is the source of truth).

---

## F2. RBF / `splice_locked` race: peer locks original while we set up RBF

**Status:** Open. **Spec citation:** BOLT 2 §1913, §527–528, §2032.
**Question:** Q18.

If peer A initiates an RBF while peer B's chain view has already lit up
the original splice's confirmation depth, B sends `splice_locked` for the
original splice exactly when A is mid-RBF setup. The spec gives no
guidance on what A does with that `splice_locked`. Three defensible
behaviors:

- Buffer + abandon RBF (consistent with §527–528 abandon-on-confirm).
- Continue RBF; lock applies later.
- Treat as mismatched `splice_locked` (§2032).

The model defers `eRecvSpliceLocked` in pre-confirmation RBF states. It
also tolerates mismatched `splice_locked` per §2032's "SHOULD ignore."
Both behaviors are defensible; the spec is silent.

**Suggested clarification.** Add a §1920-ish clause: "If a peer receives
`splice_locked` for a prior splice while in mid-`tx_init_rbf` setup,
the RBF MUST be abandoned; the prior splice is the de-facto winner."

---

## F3. Race-driven event arrival in disconnect/reconnect retransmit

**Status:** Modeled.
**Spec citation:** BOLT 2 §3520–§3526.
**Trace:** Phase 8 iteration (tcDisconnectMidSplice at 615 schedules).

When peer reestablishes faster than us and retransmits its
`tx_signatures` per §3520–§3526, our SC can receive the `tx_signatures`
in `AwaitingPeerCommitSig` (before we've processed our peer's
`commit_sig`). The model defers `eRecvTxSignatures` in that state.

This is mostly a model implementation detail, but it does flag a real
implementation concern: queue ordering between the reestablish reply
processing and the wire-level retransmit determines whether
`AwaitingPeerCommitSig`'s handler is the original commit_sig or a
secondary tx_signatures. Implementations need to handle either order.

**Suggested clarification.** Add a §3528-ish note: "Implementations
MUST handle the case where the peer's retransmitted `tx_signatures`
arrives before their `commit_sig` for the same `next_funding_txid`."

---

## F4. `splice_locked` mismatch — buffer or drop?

**Status:** Modeled (via cfg.spliceLockedMismatchBuffer).
**Spec citation:** BOLT 2 §2032–§2034 ("SHOULD ignore"; "MAY error").
**Question:** Q6.

If peers send `splice_locked` for different RBF candidates, the spec
says SHOULD ignore. But does the receiver buffer the mismatched message
for later (in case the fork resolves in the sender's favor), or drop
it? Spec is silent.

The model exposes both behaviors via `cfg.spliceLockedMismatchBuffer`.
Currently the test suite exercises the drop path; buffer is plumbed
through types.p but not wired yet (Phase 8b iteration).

**Suggested clarification.** Add a §2034-ish note recommending buffer
with a TTL; pure drop loses liveness when forks naturally resolve.

---

## F5. Tied initiator + v2 dual-funded channel

**Status:** Open. **Spec citation:** BOLT 2 §1544–§1548. **Question:** Q1.

The tied-`stfu` rule says "the initiator is arbitrarily considered to
be the channel funder (the sender of `open_channel`)." For v2 channels
(`open_channel2`), there is no single funder. Spec does not say what
"funder" resolves to in v2.

The model exposes both interpretations via
`cfg.quiescenceTiedFunderWins`. Currently the tests use `true`
(initiator-side wins); the v2 case is not exercised because we don't
model v2 channel open.

**Suggested clarification.** Add to §1546: "For channels opened with
`open_channel2`, the tie is broken by lexicographically-lesser
`funding_pubkey`."

---

## F6. Reserve bypass on pure splice-out

**Status:** Open. **Spec citation:** BOLT 2 §1818–§1820 vs §1704–§1707.
**Question:** Q10.

The `tx_complete` reserve check only fires "If either side has added
an output other than the channel funding output". A pure splice-out
(funds come out via the change in the funding output, no extra output)
bypasses the check. The `splice_init`-receive check only enforces
|negative contribution| ≤ balance, not reserve.

**Reproducer.** Run `tcSpliceOutHappy` with a contribution equal to
the entire balance: the model accepts it.

**Suggested clarification.** Either:

- Tighten the `tx_complete` reserve check to apply when balance dips
  below reserve regardless of extra outputs.
- Or add a note at §1707 that the receive-side balance check must
  also verify reserve compliance for the resulting balance.

---

## F7. "Acceptable depth" for `splice_locked` is undefined

**Status:** Open. **Spec citation:** BOLT 2 §2014. **Question:** Q5.

`splice_locked` MUST be sent at "acceptable depth" but the spec never
defines that. Is it `minimum_depth` (the channel's negotiated depth)?
Or something separately negotiable for splices?

The model uses depth=6 as a placeholder. Implementations using
different thresholds will disagree on when to lock.

**Suggested clarification.** Add to §2014: "Acceptable depth equals
the channel's negotiated `minimum_depth`."

---

## F8. Zeroconf + splice double-spend has no recovery path

**Status:** Open. **Spec citation:** BOLT 2 §2016–§2017, §1956–§1959.
**Question:** Q17.

Under `option_zeroconf`, splice_locked is sent immediately after
`tx_signatures`. RBF is forbidden (§1914, §1956–§1959). What happens
if the zeroconf splice tx is double-spent by a pre-signed alternative?

The model does not exercise this; it's flagged for future work.

**Suggested clarification.** Either explicitly recommend against
`option_zeroconf` for splices, or document the recovery procedure
(unilateral close from the prior funding tx, since RBF is unavailable).

---

## Coverage summary

| Phase | Spec area                          | Test count | Max schedules | Result |
|-------|------------------------------------|------------|---------------|--------|
| 1     | Quiescence                         | 5          | 2000          | green  |
| 2     | Happy-path single splice           | 3          | 2000          | green  |
| 3     | RBF + multi-pending                | 3          | 2000          | green  |
| 4     | Disconnect / reestablish           | 1          | 3000          | green  |
| 5     | Blockchain non-determinism         | 1          | 2000          | green  |
| 6     | Close + gossip                     | 1          | 2000          | green  |
| 7     | Bridge (Go replay harness)         | 3          | n/a           | green  |

Total: 17 P tests + 3 Go tests, all green. ~88 timelines explored in
the deepest scenario (disconnect-mid-splice).
