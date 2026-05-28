// quiescence_test.p — test drivers for the QuiescencePeer machine.
// Each test creates two peers and exercises a scenario from
// BOLT 2 §"Channel Quiescence", 02-peer-protocol.md:1490–1556.
//
// Each test driver passes itself as the coordinator and ignores the
// upward signals (`eQuiescenceAchievedAt`, `eQuiescenceClearedAt`), since
// Phase 1 doesn't model the splice coordinator.

// ---------------------------------------------------------------------------
// Helper: a default model config. Tests override fields as needed.
// ---------------------------------------------------------------------------

fun defaultConfig(): tModelConfig {
  return (
    quiescenceTiedFunderWins   = true,
    rbfRequiresReQuiescence    = true,
    spliceLockedMismatchBuffer = false,
    liftQuiescenceOnSend       = false
  );
}

// ---------------------------------------------------------------------------
// tcQuiescenceClean: Alice initiates, Bob replies, both reach Quiescent.
// Reference: BOLT 2 §"Rationale" 1539–1542 happy path.
// ---------------------------------------------------------------------------

machine TestQuiescenceClean {


  start state Init {
    ignore eQuiescenceAchievedAt, eQuiescenceClearedAt;

    entry {
      var alice: machine;
      var bob: machine;
      alice = new QuiescencePeer();
      bob = new QuiescencePeer();
      send alice, eSetupQuiescence,
        (pid = PeerA, peer = bob, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send bob, eSetupQuiescence,
        (pid = PeerB, peer = alice, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send alice, eOpenStfu;
    }
  }
}

test tcQuiescenceClean [main=TestQuiescenceClean]:
  assert Spec_Quiescence in
  (union { TestQuiescenceClean }, { QuiescencePeer });

// ---------------------------------------------------------------------------
// tcQuiescenceTied: both sides send stfu at the same time, both set
// initiator=1, both still reach Quiescent.
// Reference: BOLT 2 §1544–1548.
// ---------------------------------------------------------------------------

machine TestQuiescenceTied {


  start state Init {
    ignore eQuiescenceAchievedAt, eQuiescenceClearedAt;

    entry {
      var alice: machine;
      var bob: machine;
      alice = new QuiescencePeer();
      bob = new QuiescencePeer();
      send alice, eSetupQuiescence,
        (pid = PeerA, peer = bob, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send bob, eSetupQuiescence,
        (pid = PeerB, peer = alice, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send alice, eOpenStfu;
      send bob, eOpenStfu;
    }
  }
}

test tcQuiescenceTied [main=TestQuiescenceTied]:
  assert Spec_Quiescence in
  (union { TestQuiescenceTied }, { QuiescencePeer });

// ---------------------------------------------------------------------------
// tcStfuWithPending: peer with pending HTLC updates attempts eOpenStfu —
// should NOT send stfu (BOLT 2 §1508–1509).
// ---------------------------------------------------------------------------

machine TestStfuWithPending {


  start state Init {
    ignore eQuiescenceAchievedAt, eQuiescenceClearedAt;

    entry {
      var alice: machine;
      var bob: machine;
      alice = new QuiescencePeer();
      bob = new QuiescencePeer();
      send alice, eSetupQuiescence,
        (pid = PeerA, peer = bob, coordinator = this,
         hasPendingUpdates = true, cfg = defaultConfig());
      send bob, eSetupQuiescence,
        (pid = PeerB, peer = alice, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send alice, eOpenStfu;  // Should be a no-op: pending updates.
    }
  }
}

test tcStfuWithPending [main=TestStfuWithPending]:
  assert Spec_Quiescence in
  (union { TestStfuWithPending }, { QuiescencePeer });

// ---------------------------------------------------------------------------
// tcQuiescenceDisconnect: Alice initiates, Bob replies, then disconnect.
// Reference: BOLT 2 §1529–1530.
// ---------------------------------------------------------------------------

machine TestQuiescenceDisconnect {


  start state Init {
    ignore eQuiescenceAchievedAt, eQuiescenceClearedAt;

    entry {
      var alice: machine;
      var bob: machine;
      alice = new QuiescencePeer();
      bob = new QuiescencePeer();
      send alice, eSetupQuiescence,
        (pid = PeerA, peer = bob, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send bob, eSetupQuiescence,
        (pid = PeerB, peer = alice, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send alice, eOpenStfu;
      send alice, eDisconnect;
      send bob, eDisconnect;
    }
  }
}

test tcQuiescenceDisconnect [main=TestQuiescenceDisconnect]:
  assert Spec_Quiescence in
  (union { TestQuiescenceDisconnect }, { QuiescencePeer });

// ---------------------------------------------------------------------------
// tcQuiescenceTerminateResume: full session lifecycle.
// ---------------------------------------------------------------------------

machine TestQuiescenceTerminateResume {


  start state Init {
    ignore eQuiescenceAchievedAt, eQuiescenceClearedAt;

    entry {
      var alice: machine;
      var bob: machine;
      alice = new QuiescencePeer();
      bob = new QuiescencePeer();
      send alice, eSetupQuiescence,
        (pid = PeerA, peer = bob, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send bob, eSetupQuiescence,
        (pid = PeerB, peer = alice, coordinator = this,
         hasPendingUpdates = false, cfg = defaultConfig());
      send alice, eOpenStfu;
      send alice, eDependentProtocolTerminated;
      send bob, eDependentProtocolTerminated;
      send bob, eOpenStfu;
    }
  }
}

test tcQuiescenceTerminateResume [main=TestQuiescenceTerminateResume]:
  assert Spec_Quiescence in
  (union { TestQuiescenceTerminateResume }, { QuiescencePeer });
