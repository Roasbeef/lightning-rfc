// quiescence.p — model of the `stfu` / channel-quiescence protocol.
// BOLT 2 §"Channel Quiescence", 02-peer-protocol.md:1490–1556.
//
// This is the first dependent-protocol-agnostic building block. It models a
// single peer's quiescence state machine. Two instances run in parallel,
// wired via direct `send` to each other's machine reference. In later phases
// the wire goes through a `Network` machine that can drop / reorder /
// disconnect.

// ---------------------------------------------------------------------------
// Coordinator-facing events (driven by tests or by SpliceCoordinator).
// ---------------------------------------------------------------------------

// User/coordinator wants to begin quiescence as the initiator.
event eOpenStfu;

// (Note: eDependentProtocolTerminated is declared in events.p — BOLT 2 §1532–1535
// for the dependent-protocol termination contract and §1886–1899 for the
// splice case in particular.)

// User attempts to send an HTLC update. The Channel machine in later phases
// will refuse this during quiescence; in Phase 1 the QuiescencePeer asserts
// the spec rule directly.
// BOLT 2 §1517: MUST NOT send update_* after stfu.
event eUpdateAttempted;

// User signals pending updates have all been ack'd. Used to leave the
// WaitingToReply state.
event eUpdatesCleared;

// ---------------------------------------------------------------------------
// Setup wiring event.
// ---------------------------------------------------------------------------

event eSetupQuiescence: (
  pid: tPeerId,
  peer: machine,
  coordinator: machine,
  hasPendingUpdates: bool,
  cfg: tModelConfig
);

// Sent from QuiescencePeer up to its SpliceCoordinator (or test driver) when
// the channel reaches Quiescent. Carries the resolved initiator tag.
event eQuiescenceAchievedAt: (
  pid: tPeerId,
  iSentInitiator: int,
  iReceivedInitiator: int
);

// Sent from QuiescencePeer up to its coordinator when quiescence is cleared
// (disconnect or dependent-protocol terminated).
event eQuiescenceClearedAt: (pid: tPeerId);

// ---------------------------------------------------------------------------
// Monitor-observed announcements. Machines `announce` these alongside their
// wire-level `send`s so Spec_Quiescence sees a clean event stream.
// ---------------------------------------------------------------------------

event eStfuSent: (peer: tPeerId, initiator: int);
event eStfuReceived: (peer: tPeerId, senderInitiator: int);
event eQuiescentReached: (peer: tPeerId);
event eQuiescenceCleared: (peer: tPeerId);

// ---------------------------------------------------------------------------
// QuiescencePeer state machine.
// ---------------------------------------------------------------------------

machine QuiescencePeer {
  var pid: tPeerId;
  var peerRef: machine;
  var coordinator: machine;
  var hasPendingUpdates: bool;
  var sentStfu: bool;
  var receivedStfu: bool;
  var iSentInitiator: int;
  var iReceivedInitiator: int;
  var cfg: tModelConfig;

  start state Init {
    on eSetupQuiescence do (e: (pid: tPeerId, peer: machine, coordinator: machine, hasPendingUpdates: bool, cfg: tModelConfig)) {
      pid = e.pid;
      peerRef = e.peer;
      coordinator = e.coordinator;
      hasPendingUpdates = e.hasPendingUpdates;
      cfg = e.cfg;
      sentStfu = false;
      receivedStfu = false;
      iSentInitiator = -1;
      iReceivedInitiator = -1;
      goto Idle;
    }
  }

  // Idle: channel is operating normally, no stfu in flight.
  state Idle {
    // Stale events from a previous session can land here after a reset.
    ignore eDependentProtocolTerminated, eUpdatesCleared;

    on eOpenStfu do {
      // BOLT 2 §1508–1509: MUST NOT send stfu while HTLC adds / removals /
      // fee updates are pending.
      if (hasPendingUpdates) { return; }
      // BOLT 2 §1510: MUST NOT send stfu twice.
      assert !sentStfu, "BOLT 2 sec1510: stfu sent twice from Idle on eOpenStfu";
      sentStfu = true;
      iSentInitiator = 1;
      announce eStfuSent, (peer = pid, initiator = 1);
      send peerRef, eRecvStfu, (channel_id = 0, initiator = 1);
      goto Quiescing;
    }

    on eRecvStfu do (e: (channel_id: tChannelId, initiator: int)) {
      receivedStfu = true;
      iReceivedInitiator = e.initiator;
      announce eStfuReceived, (peer = pid, senderInitiator = e.initiator);
      // BOLT 2 §1519–1524: receiver must reply with stfu once it can.
      if (hasPendingUpdates) {
        // Cease sending updates, defer reply until cleared.
        goto WaitingToReply;
      }
      assert !sentStfu, "BOLT 2 sec1510: stfu sent twice from Idle on eRecvStfu";
      sentStfu = true;
      iSentInitiator = 0;
      announce eStfuSent, (peer = pid, initiator = 0);
      send peerRef, eRecvStfu, (channel_id = 0, initiator = 0);
      announce eQuiescentReached, (peer = pid,);
      send coordinator, eQuiescenceAchievedAt,
        (pid = pid, iSentInitiator = iSentInitiator, iReceivedInitiator = iReceivedInitiator);
      goto Quiescent;
    }

    on eUpdateAttempted do {
      // Updates allowed pre-stfu. No-op.
    }

    on eDisconnect do {
      goto Reset;
    }
  }

  // WaitingToReply: received peer's stfu but had pending updates of our own.
  // BOLT 2 §1523: SHOULD NOT send further update_* messages.
  // BOLT 2 §1524: MUST reply once we can.
  state WaitingToReply {
    // We've already received peer's stfu and haven't yet replied. eOpenStfu
    // is moot (we're going to reply, not initiate). eDependentProtocolTerminated
    // is stale (dependent protocol can't have run — we're not quiescent yet).
    ignore eOpenStfu, eDependentProtocolTerminated;

    on eUpdatesCleared do {
      hasPendingUpdates = false;
      assert !sentStfu, "BOLT 2 sec1510: stfu sent twice from WaitingToReply";
      sentStfu = true;
      iSentInitiator = 0;
      announce eStfuSent, (peer = pid, initiator = 0);
      send peerRef, eRecvStfu, (channel_id = 0, initiator = 0);
      announce eQuiescentReached, (peer = pid,);
      send coordinator, eQuiescenceAchievedAt,
        (pid = pid, iSentInitiator = iSentInitiator, iReceivedInitiator = iReceivedInitiator);
      goto Quiescent;
    }
    on eUpdateAttempted do {
      // BOLT 2 §1523: SHOULD NOT send updates after receiving stfu.
      // We treat SHOULD as a soft assertion for Phase 1.
      assert false, "BOLT 2 sec1523: update attempted after receiving stfu";
    }
    on eDisconnect do {
      goto Reset;
    }
  }

  // Quiescing: we have sent stfu, awaiting peer's stfu.
  state Quiescing {
    // We've already sent our stfu, so eOpenStfu is moot. eDependentProtocolTerminated
    // and eUpdatesCleared are stale here — dependent protocol hasn't run yet,
    // and pending-updates-cleared is only meaningful in WaitingToReply.
    ignore eOpenStfu, eDependentProtocolTerminated, eUpdatesCleared;

    on eRecvStfu do (e: (channel_id: tChannelId, initiator: int)) {
      receivedStfu = true;
      iReceivedInitiator = e.initiator;
      announce eStfuReceived, (peer = pid, senderInitiator = e.initiator);
      announce eQuiescentReached, (peer = pid,);
      send coordinator, eQuiescenceAchievedAt,
        (pid = pid, iSentInitiator = iSentInitiator, iReceivedInitiator = iReceivedInitiator);
      goto Quiescent;
    }
    on eUpdateAttempted do {
      // BOLT 2 §1517: MUST NOT send an update message after stfu.
      assert false, "BOLT 2 sec1517: update sent after our stfu (Quiescing)";
    }
    on eDisconnect do {
      announce eQuiescenceCleared, (peer = pid,);
      send coordinator, eQuiescenceClearedAt, (pid = pid,);
      goto Reset;
    }
  }

  // Quiescent: both sides have exchanged stfu. Channel is paused.
  state Quiescent {
    // Already quiescent — eOpenStfu is moot. A late eRecvStfu can arrive if
    // the peer is racing our reply (caught by sentStfu==true assertion if it
    // attempted a second send, but P delivers each send exactly once).
    // eUpdatesCleared is stale (we're already quiescent, no updates pending).
    ignore eOpenStfu, eRecvStfu, eUpdatesCleared;

    on eDependentProtocolTerminated do {
      announce eQuiescenceCleared, (peer = pid,);
      send coordinator, eQuiescenceClearedAt, (pid = pid,);
      goto Reset;
    }
    on eDisconnect do {
      // BOLT 2 §1529–1530: disconnect clears quiescence.
      announce eQuiescenceCleared, (peer = pid,);
      send coordinator, eQuiescenceClearedAt, (pid = pid,);
      goto Reset;
    }
    on eUpdateAttempted do {
      // BOLT 2 §1517: still applies until quiescence cleared.
      assert false, "BOLT 2 sec1517: update sent during Quiescent";
    }
  }

  // Reset: clear state and return to Idle.
  state Reset {
    entry {
      sentStfu = false;
      receivedStfu = false;
      iSentInitiator = -1;
      hasPendingUpdates = false;
      goto Idle;
    }
  }
}
