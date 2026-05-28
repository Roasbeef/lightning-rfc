// channel_commit.p — the base full-duplex commitment state machine.
// BOLT 2 §"Normal Operation", 02-peer-protocol.md:2531–2571,
// §"Committing Updates": 3083, §"revoke_and_ack": 3192.
//
// This is the foundation the splice model abstracts (see FINDINGS F9/F10).
// It models the per-update lifecycle (§2558–2566) explicitly so we can
// CHECK the convergence property the spec only asserts (§2568–2571: "the
// two commitment transactions may be out of sync indefinitely ... this is
// not concerning").
//
// Abstraction: updates are opaque integer ids (an `update_add_htlc`,
// `update_fulfill_htlc`, ... — direction-tagged by originator). We model the
// lifecycle and the commit_sig/revoke_and_ack handshake, not HTLC amounts or
// signatures. The point is to pin down: under ANY interleaving of concurrent
// bidirectional commit_sig, do both peers converge to the same
// irrevocably-committed set?

type tUpdateId = int;

// ---------------------------------------------------------------------------
// Wire + control events.
// ---------------------------------------------------------------------------

// Wiring.
event eSetupChannel: (pid: tPeerId, peer: machine);

// User/driver triggers.
event eUserAddUpdate: (id: tUpdateId);   // originate an update (update_add_*)
event eUserSendCommitSig;                // sign the peer's commitment now
// Attempt to "forward" (act on) an update. `eager` models implementation
// behavior: eager=false is the CONFORMANT node (hold the forward until the
// update is irrevocably committed); eager=true is the UNSAFE node (forward
// immediately). The unsafe path is how we DEMONSTRATE the fund-loss safety
// property — see Spec_ForwardOnlyIrrevocable and BOLT 2 §3173–3176.
event eUserForward: (id: tUpdateId, eager: bool);

// Wire messages.
event eRecvUpdateAdd: (id: tUpdateId);
event eRecvCommitSig: (covered: set[tUpdateId]);
event eRecvRevokeAndAck: (acked: set[tUpdateId]);

// ---------------------------------------------------------------------------
// Monitor-observed announcements.
// ---------------------------------------------------------------------------

// Fired once, by the originator, when an update enters the system.
event eUpdateProposed: (id: tUpdateId);
// Fired by a peer when an update becomes irrevocably committed in ITS view.
event eIrrevocable: (peer: tPeerId, id: tUpdateId);
// Fired when a peer "forwards"/acts on an update — must be irrevocable first.
event eForwardAttempt: (peer: tPeerId, id: tUpdateId, isIrrevocable: bool);

// ---------------------------------------------------------------------------
// ChannelPeer — one per side; wired directly to the other.
// ---------------------------------------------------------------------------

machine ChannelPeer {
  var pid: tPeerId;
  var peerRef: machine;

  // Updates I originated and announced (sent update_add). Pending on peer.
  var ownProposed: set[tUpdateId];
  // Updates the peer originated and I received (their update_add).
  var theirReceived: set[tUpdateId];
  // Updates I have already signed into the peer's commitment (sent commit_sig
  // covering them) — so I don't double-sign.
  var remoteSigned: set[tUpdateId];
  // Updates in MY current local commitment (peer signed them in, I revoked old).
  var localCommitted: set[tUpdateId];
  // Updates the peer has revoked-old for (sent me revoke_and_ack) — i.e., they
  // are in the peer's current local commitment.
  var peerAcked: set[tUpdateId];
  // Updates I have already announced as irrevocable (dedup).
  var announcedIrrevocable: set[tUpdateId];
  // Updates a forward was requested for, but which were not yet irrevocable;
  // held until they are (a conformant node MUST NOT forward early, §3173–3176).
  var pendingForwards: set[tUpdateId];

  start state Init {
    on eSetupChannel do (e: (pid: tPeerId, peer: machine)) {
      pid = e.pid;
      peerRef = e.peer;
      ownProposed = default(set[tUpdateId]);
      theirReceived = default(set[tUpdateId]);
      remoteSigned = default(set[tUpdateId]);
      localCommitted = default(set[tUpdateId]);
      peerAcked = default(set[tUpdateId]);
      announcedIrrevocable = default(set[tUpdateId]);
      pendingForwards = default(set[tUpdateId]);
      goto Operating;
    }
  }

  state Operating {
    on eUserAddUpdate do (e: (id: tUpdateId)) {
      // §3105: a node applies changes to the remote commitment by first
      // sending update_add, then commit_sig.
      ownProposed += (e.id);
      announce eUpdateProposed, (id = e.id,);
      send peerRef, eRecvUpdateAdd, (id = e.id,);
    }

    on eRecvUpdateAdd do (e: (id: tUpdateId)) {
      theirReceived += (e.id);
      // Liveness assumption (see FINDINGS F9): a conformant node eventually
      // signs the updates it has received onto the peer's commitment. We model
      // this by flushing on receipt rather than relying on a perfectly-timed
      // external eUserSendCommitSig — a node that signed too early (empty
      // cover) and never retried would stall convergence, which the spec's
      // §2569 "not concerning" assertion implicitly rules out.
      flushCommit();
    }

    on eUserSendCommitSig do {
      flushCommit();
    }

    on eRecvCommitSig do (e: (covered: set[tUpdateId])) {
      var u: tUpdateId;
      // §3130–3163: validate, apply to my local commitment, and reply with a
      // single revoke_and_ack (§3219). These updates are now in MY commitment.
      foreach (u in e.covered) {
        localCommitted += (u);
        // A covered update the peer originated but I never saw via update_add
        // would be a phantom — record receipt defensively.
        if (!(u in theirReceived) && !(u in ownProposed)) {
          theirReceived += (u);
        }
      }
      send peerRef, eRecvRevokeAndAck, (acked = e.covered,);
      checkIrrevocable();
      tryForward();   // a held (conformant) forward may now be safe
      // After acking, sign back any updates not yet on the peer's commitment.
      flushCommit();
    }

    on eRecvRevokeAndAck do (e: (acked: set[tUpdateId])) {
      var u: tUpdateId;
      // §3192–3202: peer revoked its previous commitment; these updates are now
      // committed on the peer's side.
      foreach (u in e.acked) { peerAcked += (u); }
      checkIrrevocable();
      tryForward();   // a held (conformant) forward may now be safe
      flushCommit();
    }

    on eUserForward do (e: (id: tUpdateId, eager: bool)) {
      // §3173–3176 (rationale): once committed, a node is bound; forwarding is
      // only safe for irrevocably-committed updates.
      if (e.eager) {
        // UNSAFE node: forward NOW, regardless of commitment status. We
        // announce the TRUE irrevocability so Spec_ForwardOnlyIrrevocable can
        // catch the premature forward (= fund-loss vector). A node that
        // forwards an incoming HTLC before its outgoing update is irrevocably
        // committed has paid downstream but cannot claim upstream.
        announce eForwardAttempt,
          (peer = pid, id = e.id,
           isIrrevocable = (e.id in localCommitted) && (e.id in peerAcked));
      } else {
        // CONFORMANT node: hold the request until the update is irrevocable.
        pendingForwards += (e.id);
        tryForward();
      }
    }
  }

  // Act on any held forward request whose update is now irrevocable. The
  // conformant node only ever announces a forward once it is irrevocable.
  fun tryForward() {
    var u: tUpdateId;
    var ready: set[tUpdateId];
    ready = default(set[tUpdateId]);
    foreach (u in pendingForwards) {
      if ((u in localCommitted) && (u in peerAcked)) {
        ready += (u);
      }
    }
    foreach (u in ready) {
      pendingForwards -= (u);
      announce eForwardAttempt, (peer = pid, id = u, isIrrevocable = true);
    }
  }

  // Sign all updates owed to the peer's commitment that I haven't signed yet.
  // §3106: MUST NOT send commit_sig with no updates (empty cover => no-op).
  // Idempotent: once everything known is in remoteSigned, this is a no-op, so
  // it terminates rather than looping.
  fun flushCommit() {
    var cover: set[tUpdateId];
    var u: tUpdateId;
    cover = default(set[tUpdateId]);
    foreach (u in ownProposed) {
      if (!(u in remoteSigned)) { cover += (u); }
    }
    foreach (u in theirReceived) {
      if (!(u in remoteSigned)) { cover += (u); }
    }
    if (sizeof(cover) == 0) { return; }
    foreach (u in cover) { remoteSigned += (u); }
    send peerRef, eRecvCommitSig, (covered = cover,);
  }

  // An update is irrevocably committed in my view when it is in my current
  // local commitment AND the peer has acked it (it's in the peer's current
  // local commitment too). BOLT 2 §2570.
  fun checkIrrevocable() {
    var u: tUpdateId;
    foreach (u in localCommitted) {
      if ((u in peerAcked) && !(u in announcedIrrevocable)) {
        announcedIrrevocable += (u);
        announce eIrrevocable, (peer = pid, id = u);
      }
    }
    // A held forward request may now be safe to act on.
    tryForward();
  }
}
