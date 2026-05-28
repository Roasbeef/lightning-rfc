// channel_test.p — drivers for the base commitment FSM.
// The headline test is tcConcurrentCommitSig: both peers add an update and
// send commit_sig CONCURRENTLY, and we check both converge (F9).

// ---------------------------------------------------------------------------
// tcOneDirectional: only A originates an update. Full single-update cycle.
// Both peers must converge to {1} irrevocable.
// ---------------------------------------------------------------------------

machine TestChannelOneDirectional {
  start state Init {
    entry {
      var a: machine; var b: machine;
      a = new ChannelPeer(); b = new ChannelPeer();
      send a, eSetupChannel, (pid = PeerA, peer = b);
      send b, eSetupChannel, (pid = PeerB, peer = a);

      // A adds update 1 and signs; B will reply R&A, then B signs, A replies R&A.
      send a, eUserAddUpdate, (id = 1,);
      send a, eUserSendCommitSig;
      send b, eUserSendCommitSig;
    }
  }
}

test tcOneDirectional [main=TestChannelOneDirectional]:
  assert Spec_CommitmentConvergence, Spec_NoPhantomCommit,
         Spec_ForwardOnlyIrrevocable in
  (union { TestChannelOneDirectional }, { ChannelPeer });

// ---------------------------------------------------------------------------
// tcConcurrentCommitSig: BOTH sides originate an update and send commit_sig
// concurrently — the full-duplex case the spec calls "not concerning"
// (§2568). The checker explores all interleavings; the liveness monitor
// requires both peers to converge to {1,2}.
// ---------------------------------------------------------------------------

machine TestChannelConcurrent {
  start state Init {
    entry {
      var a: machine; var b: machine;
      a = new ChannelPeer(); b = new ChannelPeer();
      send a, eSetupChannel, (pid = PeerA, peer = b);
      send b, eSetupChannel, (pid = PeerB, peer = a);

      send a, eUserAddUpdate, (id = 1,);
      send b, eUserAddUpdate, (id = 2,);
      // Concurrent commit_sig from both directions.
      send a, eUserSendCommitSig;
      send b, eUserSendCommitSig;
    }
  }
}

test tcConcurrentCommitSig [main=TestChannelConcurrent]:
  assert Spec_CommitmentConvergence, Spec_NoPhantomCommit,
         Spec_ForwardOnlyIrrevocable in
  (union { TestChannelConcurrent }, { ChannelPeer });

// ---------------------------------------------------------------------------
// tcSecondRound: an update is added AFTER the first commit_sig, requiring a
// second commit_sig round. Exercises pipelining + convergence.
// ---------------------------------------------------------------------------

machine TestChannelSecondRound {
  start state Init {
    entry {
      var a: machine; var b: machine;
      a = new ChannelPeer(); b = new ChannelPeer();
      send a, eSetupChannel, (pid = PeerA, peer = b);
      send b, eSetupChannel, (pid = PeerB, peer = a);

      send a, eUserAddUpdate, (id = 1,);
      send a, eUserSendCommitSig;
      send b, eUserSendCommitSig;
      // Second round: B adds an update later, both re-sign.
      send b, eUserAddUpdate, (id = 2,);
      send b, eUserSendCommitSig;
      send a, eUserSendCommitSig;
    }
  }
}

test tcSecondRound [main=TestChannelSecondRound]:
  assert Spec_CommitmentConvergence, Spec_NoPhantomCommit,
         Spec_ForwardOnlyIrrevocable in
  (union { TestChannelSecondRound }, { ChannelPeer });

// ---------------------------------------------------------------------------
// tcForwardSafe: POSITIVE test. B forwards update 1 the CONFORMANT way
// (eager=false): the request is held until update 1 is irrevocably committed,
// then acted on. Spec_ForwardOnlyIrrevocable must hold under every interleaving.
// ---------------------------------------------------------------------------

machine TestChannelForwardSafe {
  start state Init {
    entry {
      var a: machine; var b: machine;
      a = new ChannelPeer(); b = new ChannelPeer();
      send a, eSetupChannel, (pid = PeerA, peer = b);
      send b, eSetupChannel, (pid = PeerB, peer = a);

      send a, eUserAddUpdate, (id = 1,);
      send a, eUserSendCommitSig;
      send b, eUserSendCommitSig;
      // Conformant forward: held until irrevocable, then fires safely.
      send b, eUserForward, (id = 1, eager = false);
    }
  }
}

test tcForwardSafe [main=TestChannelForwardSafe]:
  assert Spec_ForwardOnlyIrrevocable, Spec_NoPhantomCommit,
         Spec_CommitmentConvergence in
  (union { TestChannelForwardSafe }, { ChannelPeer });

// ---------------------------------------------------------------------------
// tcForwardTooEarly: NEGATIVE / counterexample test. B forwards update 1 the
// UNSAFE way (eager=true) before the commitment cycle completes, so the update
// is not yet irrevocable. Spec_ForwardOnlyIrrevocable MUST catch it. This is
// EXPECTED TO FIND A BUG — it is the fund-loss demonstration: a node that
// forwards an incoming HTLC before its outgoing update is irrevocably committed
// has paid downstream but cannot claim upstream (BOLT 2 §3173–3176). Excluded
// from the green suite (see scripts/check.sh); run directly to see it fire.
// ---------------------------------------------------------------------------

machine TestChannelForwardTooEarly {
  start state Init {
    entry {
      var a: machine; var b: machine;
      a = new ChannelPeer(); b = new ChannelPeer();
      send a, eSetupChannel, (pid = PeerA, peer = b);
      send b, eSetupChannel, (pid = PeerB, peer = a);

      send a, eUserAddUpdate, (id = 1,);
      // UNSAFE: B forwards immediately, before update 1 is irrevocable.
      send b, eUserForward, (id = 1, eager = true);
      send a, eUserSendCommitSig;
      send b, eUserSendCommitSig;
    }
  }
}

test tcForwardTooEarly [main=TestChannelForwardTooEarly]:
  assert Spec_ForwardOnlyIrrevocable, Spec_NoPhantomCommit in
  (union { TestChannelForwardTooEarly }, { ChannelPeer });
