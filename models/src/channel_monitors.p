// channel_monitors.p — invariants for the base commitment protocol.
// BOLT 2 §"Normal Operation", 02-peer-protocol.md:2531–2571.
//
// Addresses FINDINGS.md F9: the spec asserts convergence in prose (§2568–2571,
// "the two commitment transactions may be out of sync indefinitely ... this is
// not concerning") but states no checkable invariant. These monitors make the
// claim precise, observing the announcements from channel_commit.p:
//   eUpdateProposed(id), eIrrevocable(peer, id), eForwardAttempt(peer, id, ok).

// ---------------------------------------------------------------------------
// Spec_NoPhantomCommit (safety) — an update can become irrevocably committed
// only if it was previously proposed by some peer. No update materializes in
// a commitment without having been added via update_add (§3105).
// ---------------------------------------------------------------------------

spec Spec_NoPhantomCommit
observes eUpdateProposed, eIrrevocable
{
  var proposed: set[tUpdateId];

  start state Watching {
    entry { proposed = default(set[tUpdateId]); }

    on eUpdateProposed do (e: (id: tUpdateId)) {
      proposed += (e.id);
    }
    on eIrrevocable do (e: (peer: tPeerId, id: tUpdateId)) {
      assert e.id in proposed,
        "Spec_NoPhantomCommit: update became irrevocable without being proposed";
    }
  }
}

// ---------------------------------------------------------------------------
// Spec_ForwardOnlyIrrevocable (safety) — a peer may only forward / act on an
// update once it is irrevocably committed (in its local commitment AND acked
// by the peer). BOLT 2 §3173–3176 rationale.
// ---------------------------------------------------------------------------

spec Spec_ForwardOnlyIrrevocable
observes eForwardAttempt
{
  start state Watching {
    on eForwardAttempt do (e: (peer: tPeerId, id: tUpdateId, isIrrevocable: bool)) {
      assert e.isIrrevocable,
        "Spec_ForwardOnlyIrrevocable: forwarded an update before it was irrevocable";
    }
  }
}

// ---------------------------------------------------------------------------
// Spec_CommitmentConvergence (LIVENESS) — every proposed update must
// eventually become irrevocably committed on BOTH peers. The monitor is `hot`
// whenever some proposed update is not yet irrevocable on both sides, and must
// reach the `cold` Converged state.
//
// This is the precise form of the property §2569 only asserts in prose: for
// any interleaving of concurrent commitment_signed / revoke_and_ack in both
// directions, both nodes converge to the same irrevocably-committed set.
// ---------------------------------------------------------------------------

spec Spec_CommitmentConvergence
observes eUpdateProposed, eIrrevocable
{
  var proposed: set[tUpdateId];
  var irrevA: set[tUpdateId];
  var irrevB: set[tUpdateId];

  start cold state Converged {
    entry {
      proposed = default(set[tUpdateId]);
      irrevA = default(set[tUpdateId]);
      irrevB = default(set[tUpdateId]);
    }
    on eUpdateProposed do (e: (id: tUpdateId)) {
      proposed += (e.id);
      decide();
    }
    on eIrrevocable do (e: (peer: tPeerId, id: tUpdateId)) {
      record(e.peer, e.id);
      decide();
    }
  }

  hot state Diverging {
    on eUpdateProposed do (e: (id: tUpdateId)) {
      proposed += (e.id);
      decide();
    }
    on eIrrevocable do (e: (peer: tPeerId, id: tUpdateId)) {
      record(e.peer, e.id);
      decide();
    }
  }

  fun record(p: tPeerId, id: tUpdateId) {
    if (p == PeerA) { irrevA += (id); } else { irrevB += (id); }
  }

  fun decide() {
    if (covers(irrevA, proposed) && covers(irrevB, proposed)) {
      goto Converged;
    } else {
      goto Diverging;
    }
  }

  // Returns true iff `s` contains every element of `target`.
  fun covers(s: set[tUpdateId], target: set[tUpdateId]): bool {
    var x: tUpdateId;
    foreach (x in target) {
      if (!(x in s)) { return false; }
    }
    return true;
  }
}
