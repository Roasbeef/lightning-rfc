// splice_test.p — happy-path single splice test cases (Phase 2).
//
// Each test driver wires:
//   - 2 QuiescencePeer machines
//   - 2 SpliceCoordinator machines
//   - 1 Blockchain
// and triggers exactly one splice attempt from PeerA.

// ---------------------------------------------------------------------------
// Helper to build a full Phase 2 harness. The test driver creates everything,
// wires it up, and triggers a splice.
// ---------------------------------------------------------------------------

fun spliceConfig(): tModelConfig {
  return (
    quiescenceTiedFunderWins   = true,
    rbfRequiresReQuiescence    = true,
    spliceLockedMismatchBuffer = false,
    liftQuiescenceOnSend       = false
  );
}

// ---------------------------------------------------------------------------
// tcSpliceInHappy: PeerA splices in 100k sats. Both peers reach Locked with
// updated balances. Spec_CapacityConservation + Spec_LockMonotonicity +
// Spec_Quiescence all hold.
// ---------------------------------------------------------------------------

machine TestSpliceInHappy {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain, (alice = aliceSc, bob = bobSc, autoConfirm = true);

      // Trigger: Alice splices in 100k.
      send aliceSc, eUserInitiateSplice, (contribution = 100000,);
    }
  }
}

test tcSpliceInHappy [main=TestSpliceInHappy]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity in
  (union { TestSpliceInHappy },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// ---------------------------------------------------------------------------
// tcSpliceOutHappy: PeerA splices OUT 100k sats. Same flow, negative
// contribution. Capacity check + balance check still pass.
// ---------------------------------------------------------------------------

machine TestSpliceOutHappy {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain, (alice = aliceSc, bob = bobSc, autoConfirm = true);

      // Splice-out: negative contribution.
      send aliceSc, eUserInitiateSplice, (contribution = -100000,);
    }
  }
}

test tcSpliceOutHappy [main=TestSpliceOutHappy]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity in
  (union { TestSpliceOutHappy },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// ---------------------------------------------------------------------------
// tcSpliceZeroContribution: PeerA initiates a "0 splice" — odd corner of
// the spec where the initiator's contribution is 0 and the non-initiator's
// is also 0. The negotiation should still go through (capacity unchanged).
// (See SPEC_QUESTIONS.md Q11.)
// ---------------------------------------------------------------------------

machine TestSpliceZeroContribution {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain, (alice = aliceSc, bob = bobSc, autoConfirm = true);

      send aliceSc, eUserInitiateSplice, (contribution = 0,);
    }
  }
}

test tcSpliceZeroContribution [main=TestSpliceZeroContribution]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity in
  (union { TestSpliceZeroContribution },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// ---------------------------------------------------------------------------
// Phase 3
// ---------------------------------------------------------------------------

// tcSpliceWithRbf: PeerA splices in, then immediately RBFs at higher feerate
// before the original confirms. Final lock picks one of the candidates.
//
// Note: a Phase 3 limitation — our Blockchain confirms the *first* broadcast
// (deduped). To force the RBF to be the locked one, we'd need Phase 5's
// chain non-determinism. For Phase 3 we just confirm that the RBF flow
// completes without Spec_* violations.

machine TestSpliceWithRbf {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain, (alice = aliceSc, bob = bobSc, autoConfirm = true);

      send aliceSc, eUserInitiateSplice, (contribution = 100000,);
      // After original splice completes tx_signatures, RBF.
      // (We don't wait — the queues handle ordering. tx_init_rbf is deferred
      //  until AwaitingConfirmation.)
      send aliceSc, eUserInitiateRbf, (newFeerate = 300,);
    }
  }
}

test tcSpliceWithRbf [main=TestSpliceWithRbf]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity,
         Spec_RbfFeerateMonotonic in
  (union { TestSpliceWithRbf },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// tcSpliceMultiRbf: two RBFs in sequence; each must satisfy feerate rule.
// The Phase 3 Blockchain confirms the first-broadcast tx (the original
// splice), so both RBFs ultimately get discarded by completeSpliceLock().

machine TestSpliceMultiRbf {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain, (alice = aliceSc, bob = bobSc, autoConfirm = true);

      send aliceSc, eUserInitiateSplice, (contribution = 100000,);
      send aliceSc, eUserInitiateRbf, (newFeerate = 300,);
      send aliceSc, eUserInitiateRbf, (newFeerate = 500,);
    }
  }
}

test tcSpliceMultiRbf [main=TestSpliceMultiRbf]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity,
         Spec_RbfFeerateMonotonic in
  (union { TestSpliceMultiRbf },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// tcSpliceRbfFromNonInitiator: BOLT 2 §1910 — non-splice-initiator MAY
// initiate RBF. Alice splices, Bob RBFs.

machine TestSpliceRbfFromNonInitiator {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain, (alice = aliceSc, bob = bobSc, autoConfirm = true);

      send aliceSc, eUserInitiateSplice, (contribution = 100000,);
      // Bob (the non-splice-initiator) triggers RBF.
      send bobSc, eUserInitiateRbf, (newFeerate = 300,);
    }
  }
}

test tcSpliceRbfFromNonInitiator [main=TestSpliceRbfFromNonInitiator]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity,
         Spec_RbfFeerateMonotonic in
  (union { TestSpliceRbfFromNonInitiator },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// ---------------------------------------------------------------------------
// Phase 4 — disconnect / channel_reestablish
// ---------------------------------------------------------------------------

// tcDisconnectMidSplice: disconnect during AwaitingTxSigs, both sides have
// sent commit_sig. After reestablish, the tx_sigs exchange resumes.
// Mirrors bolt02/splicing-test.md:377.

machine TestDisconnectMidSplice {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain, (alice = aliceSc, bob = bobSc, autoConfirm = true);

      send aliceSc, eUserInitiateSplice, (contribution = 100000,);
      // Disconnect interleaves with the in-flight splice; depending on
      // schedule, disconnect lands at any of the active states.
      send aliceSc, eUserDisconnect;
      send bobSc, eUserDisconnect;
      send aliceSc, eUserReconnect;
      send bobSc, eUserReconnect;
    }
  }
}

test tcDisconnectMidSplice [main=TestDisconnectMidSplice]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity,
         Spec_NoLostStateAcrossReconnect in
  (union { TestDisconnectMidSplice },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// ---------------------------------------------------------------------------
// Phase 5 — blockchain non-determinism (forks, reorgs, divergent peer views).
// ---------------------------------------------------------------------------

// tcDivergentConfirmation: blockchain confirms tx2 on Alice and tx2 on Bob
// at different times. Models the simplest divergent-confirmation case.
// (Phase 5 model is minimal; Phase 8 will add real fork-and-converge.)

machine TestDivergentConfirmation {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      // Manual confirmation mode.
      send chain, eSetupBlockchain,
        (alice = aliceSc, bob = bobSc, autoConfirm = false);

      send aliceSc, eUserInitiateSplice, (contribution = 100000,);
      // After both peers broadcast tx2, confirm it on both peers explicitly.
      // (Phase 5 sanity check: the manual-confirmation pipeline works.)
      send chain, eUserConfirmTx, (peer = PeerA, txid = 2, depth = 6);
      send chain, eUserConfirmTx, (peer = PeerB, txid = 2, depth = 6);
    }
  }
}

test tcDivergentConfirmation [main=TestDivergentConfirmation]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity,
         Spec_ReorgSafety in
  (union { TestDivergentConfirmation },
   { QuiescencePeer, SpliceCoordinator, Blockchain });

// ---------------------------------------------------------------------------
// Phase 6 — channel close + gossip post-splice.
// ---------------------------------------------------------------------------

// tcSpliceThenShutdown: splice completes (locked), then user requests
// shutdown. shutdown should be allowed and announcement_signatures should
// have been emitted post-lock.

machine TestSpliceThenShutdown {
  start state Init {
    entry {
      var aliceQp: machine;
      var bobQp: machine;
      var aliceSc: machine;
      var bobSc: machine;
      var chain: machine;

      aliceQp = new QuiescencePeer();
      bobQp = new QuiescencePeer();
      aliceSc = new SpliceCoordinator();
      bobSc = new SpliceCoordinator();
      chain = new Blockchain();

      send aliceQp, eSetupQuiescence,
        (pid = PeerA, peer = bobQp, coordinator = aliceSc,
         hasPendingUpdates = false, cfg = spliceConfig());
      send bobQp, eSetupQuiescence,
        (pid = PeerB, peer = aliceQp, coordinator = bobSc,
         hasPendingUpdates = false, cfg = spliceConfig());

      send aliceSc, eSetupSplice,
        (pid = PeerA, peerCoord = bobSc, quiescence = aliceQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());
      send bobSc, eSetupSplice,
        (pid = PeerB, peerCoord = aliceSc, quiescence = bobQp,
         blockchain = chain,
         initialBalance = 500000, peerInitialBalance = 500000,
         cfg = spliceConfig());

      send chain, eSetupBlockchain,
        (alice = aliceSc, bob = bobSc, autoConfirm = true);

      send aliceSc, eUserInitiateSplice, (contribution = 100000,);
      // After splice lock, request shutdown.
      send aliceSc, eUserInitiateShutdown;
    }
  }
}

test tcSpliceThenShutdown [main=TestSpliceThenShutdown]:
  assert Spec_Quiescence, Spec_CapacityConservation, Spec_LockMonotonicity,
         Spec_GossipOrdering, Spec_ShutdownSpliceExclusion in
  (union { TestSpliceThenShutdown },
   { QuiescencePeer, SpliceCoordinator, Blockchain });
