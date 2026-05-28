# Splicing Spec — Seeded Questions / Possible Ambiguities

Pre-model questions raised during the Phase 0 survey. Each is a hypothesis
that the model should either resolve, confirm as a real ambiguity, or close
as a mis-reading. As the model matures these migrate either:

- to `FINDINGS.md` (real ambiguity, with trace evidence), or
- get crossed out here (closed as "modeled, no ambiguity").

Format per item: short title, citation, the question, why it matters.

---

## Q1. "Funder" identity for tied quiescence in v2-opened channels

**Citation:** `02-peer-protocol.md:1544–1548`.

The tied-`stfu` rule says "the initiator is arbitrarily considered to be the
channel funder (the sender of `open_channel`)." For v2 dual-funded channels
(`open_channel2`), there is no single funder in the v1 sense — both peers
contribute. Does "funder" here mean the sender of `open_channel2`? Both peers?
The peer with the larger initial contribution?

**Why it matters:** Affects which side controls subsequent splice initiation in
tied-race scenarios on v2 channels.

---

## Q2. `stfu` and pending `revoke_and_ack`

**Citation:** `02-peer-protocol.md:1508–1509`.

The MUST forbids `stfu` while "HTLC additions, HTLC removals or fee updates
are pending for either peer", but does not explicitly forbid `stfu` while a
`commitment_signed` is outstanding (awaiting `revoke_and_ack` from the peer)
or while the sender owes a `revoke_and_ack`. The Rationale at `02:1539–1542`
hints these are implicitly excluded ("cease sending updates, then wait for all
the current updates to be acknowledged by both peers, then start
quiescence"), but the normative MUST does not name these states.

**Why it matters:** Two implementations might disagree on when it's legal to
send `stfu`. Modeling the difference could expose state-machine corner cases.

---

## Q3. Quiescence state on reconnect

**Citation:** `02-peer-protocol.md:1529–1530`, `02:3360–3543`.

"Upon disconnection: the channel is no longer considered quiescent." No
field in `channel_reestablish` describes quiescence. If a splice is mid-flight
(e.g., `next_funding` set in reestablish), implementations must reconstruct
that they were in a splice without going through `stfu` again. Is the
reestablished mid-splice state implicitly still "quiescent enough" to resume
signing? The test vectors don't re-exchange `stfu` after reconnect.

**Why it matters:** Cleanly defining what "quiescent" means post-reconnect is
a load-bearing precondition for `commit_sig` and `tx_signatures` retransmit
rules.

---

## Q4. "Recently" for RBF rate-limiting

**Citation:** `02-peer-protocol.md:1926–1927`.

"If another RBF attempt has been created recently: SHOULD send `tx_abort` ..."
— "recently" has no time bound. Implementations could plausibly use anything
from one block to one hour.

**Why it matters:** Inter-op risk: A sends RBF #2, B aborts because it
considers #1 "recent" by its definition, A doesn't.

---

## Q5. "Acceptable depth" for `splice_locked`

**Citation:** `02-peer-protocol.md:2014`.

`splice_locked` MUST be sent when "any splice transaction reaches acceptable
depth". Is "acceptable depth" the channel's negotiated `minimum_depth`? Or
something separately negotiable for splices? The original `channel_ready` rule
uses `minimum_depth`; the splice section does not say so explicitly.

**Why it matters:** Two implementations using different depth thresholds will
have a window where peer A is sending `splice_locked` but peer B is not yet
acknowledging.

---

## Q6. `splice_locked` mismatch — ignored *until when*?

**Citation:** `02-peer-protocol.md:2032–2034`, rationale `02:2036–2043`.

If peers send `splice_locked` for different RBF candidates: "SHOULD ignore the
message. MAY send an `error` and fail the channel." If ignored, the spec
implies waiting for the chain to converge. But: must the receiver buffer the
mismatched `splice_locked` for later processing (in case the fork resolves in
the other peer's favor)? Or drop it? Re-sent only on reconnect? Spec is silent.

**Why it matters:** The right behavior preserves liveness during natural
reorgs but a naive drop loses information.

---

## Q7. `my_current_funding_locked` for an unknown splice txid on reconnect

**Citation:** `02-peer-protocol.md:3534–3538`.

The rule handles the case where the txid matches a pending splice. It does
NOT explicitly handle the case where the txid is for a splice the receiver
has never seen (e.g., a different RBF candidate that confirmed on the
sender's chain view but the receiver doesn't have that RBF locally yet).
Default behavior? Warn? Ignore? Fail?

**Why it matters:** This is exactly the splice_locked-mismatch case dressed in
reconnect clothing.

---

## Q8. `tx_signatures` ordering with shared input

**Citation:** `02-peer-protocol.md:1854–1859` vs `02:431–436`.

The generic interactive-tx rule says the lowest total `tx_add_input` value
signs first; ties broken by lowest node_id. The splice addendum says the
shared input attributes 100% of previous capacity to the initiator.

Two corner cases the spec does not spell out:

- Splice-out where the non-initiator contributes 0 to the new funding output.
  Initiator's total input = previous capacity (100%) + maybe extra inputs.
  Non-initiator's total input = whatever they added (often 0).
  → Non-initiator signs first.
- The exact arithmetic when both sides add inputs and the initiator's
  contribution is negative.

**Why it matters:** Test-vector validation: two implementations must agree
on signing order or they deadlock at `tx_signatures`.

---

## Q9. RBF initiator vs quiescence initiator

**Citation:** `02-peer-protocol.md:1908–1910`.

"MUST NOT send `tx_init_rbf` if it is not the quiescence initiator" combined
with "MAY send `tx_init_rbf` even if it is not the splice initiator" implies
each RBF round needs its own quiescence session (the second test vector at
`splicing-test.md:215–217` confirms this with a second `stfu` pair). But the
spec does not explicitly mandate "re-quiesce before RBF". Is it just implied
by "MUST NOT send if not quiescent" (`02:1908`)?

**Why it matters:** Implementation that keeps quiescence latched between splice
and RBF could deadlock against one that requires re-quiescence.

---

## Q10. Reserve check at `tx_complete` for splice-out without extra outputs

**Citation:** `02-peer-protocol.md:1818–1820`.

Reserve check applies if "either side has added an output other than the
channel funding output and the balance for that side is less than the channel
reserve". So a pure splice-out (funds come out via the change in the funding
output, no extra output) bypasses the reserve check at `tx_complete`. The
balance check at `splice_init` receive (`02:1704–1707`) only enforces that
|negative contribution| ≤ current balance — not that resulting balance ≥
reserve.

**Why it matters:** Possible to splice yourself below reserve on the new
commitment. Was this intended?

---

## Q11. Capacity computation race between `splice_init` and `splice_ack`

**Citation:** `02-peer-protocol.md:1731–1741`, `02:1971–1974`.

`splice_ack` (and `tx_ack_rbf`) MAY set its contribution to a different value
than the initiator's. Is the initiator allowed to send `tx_abort` if the ack's
contribution makes the splice economically unfavorable? Spec does not name
this explicitly, but `tx_abort` is generic so presumably yes.

**Why it matters:** Mostly cosmetic, but worth modeling because incentive races
here could be exploited.

---

## Q12. `batch_size` of `start_batch` for splices

**Citation:** `bolt02/splicing-test.md:115`, no normative rule in `02-peer-protocol.md`.

The test vectors imply `batch_size == |active_commitments|`, but no normative
clause in BOLT 2 says so. This rule shows up only by example.

**Why it matters:** Implementations might compute `batch_size` differently
under exotic states (e.g., a partially-aborted RBF where one tx is mid-discard).

---

## Q13. Drop semantics for late `commit_sig` after `splice_locked`

**Citation:** `02-peer-protocol.md:2024–2028`, `bolt02/splicing-test.md:291–297`.

After both sides exchanged `splice_locked` for the same txid: "MAY discard
RBF attempts and ancestor transactions". For commit_sigs in flight for those
discarded txids: the test vectors say they "can be ignored". MUST or MAY?
Inter-op risk if one side warns/fails on an ignorable message.

**Why it matters:** Concurrent-locked scenarios are common in normal
operation; both sides must agree on what's harmless.

---

## Q14. Order of operations at tx_signatures: lift quiescence, then resume, then announce

**Citation:** `02-peer-protocol.md:1886–1901`.

"MUST consider the channel no longer quiescent" on receiving `tx_signatures`
without `shared_input_signature` errors. But what about the sender — when do
they lift quiescence on their side? On send? On receiving peer's
`tx_signatures`? The rationale at `02:1898–1901` implies both sides see
resume after "tx_signatures have been exchanged" but does not name a single
exact moment per side.

**Why it matters:** A race where peer A starts a new `update_add_htlc` after
sending `tx_signatures` but before peer B receives it could surprise peer B.

---

## Q15. Forgetting old `short_channel_id`s post-splice

**Citation:** `07-routing-gossip.md:184–185, 281–285`.

"SHOULD keep relaying payments that use the `short_channel_id`s of its
previous channel_announcements" + "SHOULD forget a channel after a 72-block
delay". When can a node hard-forget the old SCID? Right at 72 blocks? Or only
after the new SCID has been gossiped and accepted by the network?

**Why it matters:** Premature forgetting black-holes in-flight HTLCs that
chose the old SCID.

---

## Q16. Concurrent `splice_locked` with one peer behind on commit_sig

**Citation:** `bolt02/splicing-test.md:285–311`.

In the worked example, Alice sends `splice_locked` and then a `commit_sig`
for the old funding tx in the same batch. Bob is supposed to ignore that
`commit_sig`. But Alice doesn't yet know Bob will lock the same tx — she only
sees Bob's `splice_locked` later. So her decision to keep the old funding
active for one more batch is correct from her POV. Is it OK for Bob to drop
the old funding before Alice does? The spec implies yes, but the symmetry is
non-trivial.

**Why it matters:** Spec invariant "both peers agree on active commitments" is
weaker than it looks — there's a window during concurrent locks where they
disagree.

---

## Q18. Race: peer's `splice_locked` arriving during our RBF setup

**Found in:** Phase 3 modeling.

**Citation:** BOLT 2 §1913 (sender of `tx_init_rbf` MUST NOT have sent
`splice_locked`); §527–528 (RBF must be abandoned if previous tx confirms);
§2032 (mismatched `splice_locked` SHOULD ignore / MAY fail).

If peer A initiates an RBF while peer B's chain view has already lit up the
original splice's confirmation depth, peer B will send `splice_locked` for
the original splice exactly when peer A is in mid-`tx_init_rbf` setup. The
spec's symmetric rules tell A "you shouldn't have sent `tx_init_rbf` after
sending `splice_locked`" but A hasn't sent `splice_locked`. The spec is
silent on what A does when receiving B's `splice_locked` for an older splice
during A's RBF setup:

- Buffer and abandon the RBF after locking the original (per §527–528
  abandon-on-confirm).
- Continue the RBF setup; lock applies later.
- Treat as a mismatched `splice_locked` (§2032 — but the txid here is for a
  legitimate splice, not a different RBF candidate).

The model defers `eRecvSpliceLocked` in all pre-confirmation RBF states,
buffering until back in `AwaitingConfirmation`. That's *a* defensible
choice; the spec doesn't endorse one.

**Why it matters:** A wins/B wins race — implementations could disagree on
which splice ultimately lands.

---

## Q17a. Implementation race between local quiescence-tracker and splice-coordinator

**Found in:** Phase 2 modeling (`models/src/splice_coordinator.p`, state Operating).

**Citation:** Inferred — not addressed by BOLT 2.

In implementations that decouple the quiescence-state module from the splice
state machine, the local "we are now quiescent" notification and an incoming
`splice_init` from the peer arrive via different paths. Naively, a node could
process the incoming wire message *before* having locally registered its own
quiescence transition, then either:

- incorrectly hit the §1687 "received splice_init while not quiescent" branch
  and tear down the channel, or
- trust the wire and proceed — but this means §1687 is unenforceable as
  written.

The model resolves this with `defer eRecvSpliceInit` in the SpliceCoordinator's
`Operating` state, so the local quiescence notification is always processed
first. The spec does not name this race or recommend a resolution.

**Why it matters:** Two implementations could disagree on whether splice_init
is "valid" depending on their internal queuing.

---

## Q17. Acceptable depth for `option_zeroconf` splices

**Citation:** `02-peer-protocol.md:2016–2017`.

Under `option_zeroconf`, "SHOULD send splice_locked immediately after exchanging
`tx_signatures`". But also "MUST NOT send tx_init_rbf if option_zeroconf has
been negotiated" (`02:1914`). What if the zeroconf splice tx is double-spent
on chain anyway (no RBF, but a malicious peer's pre-signed double-spend)?
The non-RBF rule under zeroconf is documented at `02:1956–1959` but the
recovery path is not.

**Why it matters:** Funds-loss vector — likely an open issue worth a finding.
