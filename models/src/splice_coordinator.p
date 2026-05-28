// splice_coordinator.p — orchestrates splice attempts end-to-end.
// BOLT 2 §"Channel Splicing", 02-peer-protocol.md:1558–2043.
//
// Phase 2: happy-path single splice (no RBF, no reconnect, no fork).
// Phase 3: + RBF flow (tx_init_rbf / tx_ack_rbf) with strict feerate rule
//          and multiple concurrently-pending splice candidates.
// Phase 4+ will add reconnect, blockchain non-determinism, gossip, close.

// ---------------------------------------------------------------------------
// Setup + user-trigger events.
// ---------------------------------------------------------------------------

event eSetupSplice: (
  pid: tPeerId,
  peerCoord: machine,
  quiescence: machine,
  blockchain: machine,
  initialBalance: tBalanceSats,
  peerInitialBalance: tBalanceSats,
  cfg: tModelConfig
);

// User triggers initial splice.
event eUserInitiateSplice: (contribution: tContributionSats);

// User triggers RBF on the latest in-flight splice.
// Phase 3. BOLT 2 §1903–1942.
event eUserInitiateRbf: (newFeerate: int);

// Phase 4: test triggers for disconnect / reconnect lifecycle.
event eUserDisconnect;
event eUserReconnect;

// Monitor-observed: emitted whenever we resume normal operation after a
// channel_reestablish exchange. Spec_NoLostStateAcrossReconnect observes.
event eReconnectResumed: (
  peer:               tPeerId,
  resumedTo:          tReconnectMarker,
  retransmittedCommit: bool,
  retransmittedTxSigs: bool
);

// Phase 5 announcements.
event eSpliceLockedMismatchIgnored: (
  peer:     tPeerId,
  received: tTxid,
  ours:     tTxid
);
event eReorgSwitched: (
  peer:      tPeerId,
  from_txid: tTxid,
  to_txid:   tTxid
);

// Phase 6: channel close + gossip.
event eUserInitiateShutdown;
event eRecvShutdown: (channel_id: tChannelId);

// Per BOLT 2 §2155: shutdown is blocked when a splice is unlocked.
// Modelled as an assertion that fires if the user requests shutdown
// while pendingSpliceTxids is non-empty.
event eShutdownBlockedByPendingSplice: (peer: tPeerId);

// Phase 6: BOLT 7 §85–114 — announcement_signatures emitted after both
// peers have exchanged splice_locked AND the tx has acceptable depth.
event eAnnouncementSignaturesEmitted: (
  peer:      tPeerId,
  scid_txid: tTxid
);

// ---------------------------------------------------------------------------
// Monitor-observed announcements.
// ---------------------------------------------------------------------------

event eSpliceTxConstructed: (
  peer:                     tPeerId,
  oldCapacity:              tBalanceSats,
  newCapacity:              tBalanceSats,
  initiatorContribution:    tContributionSats,
  nonInitiatorContribution: tContributionSats
);

event eSpliceLockedComplete: (
  peer:         tPeerId,
  txid:         tTxid,
  finalBalance: tBalanceSats
);

event eCommitSigEmitted: (
  peer:              tPeerId,
  funding_txid:      tTxid,
  commitment_number: tCommitmentNumber
);

// Emitted whenever we broadcast an RBF replacement.
// Spec_RbfFeerateMonotonic checks the §488–491 rule.
event eRbfBroadcast: (
  peer:        tPeerId,
  txid:        tTxid,
  prevFeerate: int,
  newFeerate:  int
);

// ---------------------------------------------------------------------------
// SpliceCoordinator state machine.
// ---------------------------------------------------------------------------

machine SpliceCoordinator {
  var pid: tPeerId;
  var peerCoord: machine;
  var quiescence: machine;
  var blockchain: machine;
  var cfg: tModelConfig;

  // Persistent channel state.
  var myBalance: tBalanceSats;
  var peerBalance: tBalanceSats;
  var activeFundingTxids: set[tTxid];   // includes locked + all pending.
  var lockedFundingTxid: tTxid;
  var pendingSpliceTxids: set[tTxid];   // unlocked candidates.
  var nextSpliceTxid: tTxid;

  // Phase 6: gossip / close state.
  var announceChannel: bool;             // BOLT 2 open_channel.announce bit.
  var weSentShutdown: bool;
  var weReceivedShutdown: bool;

  // Most recent splice negotiation's feerate. Used for RBF feerate rule.
  var lastFeerate: int;

  // Per-attempt state.
  var negotiation: tNegotiationKind;
  var role: tSpliceRole;
  var myContribution: tContributionSats;
  var peerContribution: tContributionSats;
  var attemptTxid: tTxid;
  var attemptFeerate: int;
  var attemptPrevFeerate: int;
  var iSignFirst: bool;
  var sentCommitSig: bool;
  var receivedCommitSig: bool;
  var sentTxSigs: bool;
  var receivedTxSigs: bool;

  // Phase 4: state used across disconnect/reconnect.
  var lastActive: tReconnectMarker;

  start state Init {
    on eSetupSplice do (e: (
      pid: tPeerId, peerCoord: machine, quiescence: machine,
      blockchain: machine, initialBalance: tBalanceSats,
      peerInitialBalance: tBalanceSats, cfg: tModelConfig
    )) {
      pid = e.pid;
      peerCoord = e.peerCoord;
      quiescence = e.quiescence;
      blockchain = e.blockchain;
      cfg = e.cfg;
      myBalance = e.initialBalance;
      peerBalance = e.peerInitialBalance;
      activeFundingTxids = default(set[tTxid]);
      activeFundingTxids += (1);
      lockedFundingTxid = 1;
      pendingSpliceTxids = default(set[tTxid]);
      nextSpliceTxid = 2;
      lastFeerate = 0;
      negotiation = NegNone;
      role = RoleNone;
      sentCommitSig = false;
      receivedCommitSig = false;
      sentTxSigs = false;
      receivedTxSigs = false;
      lastActive = MarkerNone;
      announceChannel = true;
      weSentShutdown = false;
      weReceivedShutdown = false;
      goto Operating;
    }
  }

  // No splice in flight, none pending.
  state Operating {
    ignore eQuiescenceClearedAt, eConfirmation;
    defer eUserDisconnect, eUserReconnect;
    // Same race as Phase 2: defer wire init until local quiescence noted.
    defer eRecvSpliceInit, eUserInitiateRbf, eRecvTxInitRbf;

    // Phase 6: channel close. Per BOLT 2 §2155, shutdown is only safe
    // when no splice is pending. We're in Operating here so by definition
    // pendingSpliceTxids is empty (completeSpliceLock cleared it).
    on eUserInitiateShutdown do {
      weSentShutdown = true;
      // Announce visibility for monitor.
      // (Mutual close protocol beyond §2155 is not modeled here.)
    }
    on eRecvShutdown do (e: (channel_id: tChannelId)) {
      weReceivedShutdown = true;
    }

    on eUserInitiateSplice do (e: (contribution: tContributionSats)) {
      // BOLT 2 §1673: MUST NOT send splice_init if it has previously sent
      // `shutdown`.
      assert !weSentShutdown,
        "BOLT 2 sec1673: splice_init attempted after sending shutdown";
      assert !weReceivedShutdown,
        "BOLT 2 sec1699: splice_init attempted after receiving shutdown";
      negotiation = NegSplice;
      role = RoleInitiator;
      myContribution = e.contribution;
      attemptFeerate = 253;          // arbitrary Phase 2-compat feerate
      attemptPrevFeerate = 0;
      send quiescence, eOpenStfu;
      goto WaitingForQuiescenceAsInitiator;
    }

    on eQuiescenceAchievedAt do (e: (
      pid: tPeerId, iSentInitiator: int, iReceivedInitiator: int
    )) {
      negotiation = NegSplice;
      role = RoleNonInitiator;
      goto AwaitingNegotiationInit;
    }
  }

  state WaitingForQuiescenceAsInitiator {
    ignore eQuiescenceClearedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    defer eUserDisconnect, eUserReconnect;
    defer eUserInitiateRbf, eConfirmation, eRecvSpliceLocked, eRecvTxInitRbf;

    on eQuiescenceAchievedAt do (e: (
      pid: tPeerId, iSentInitiator: int, iReceivedInitiator: int
    )) {
      if (negotiation == NegSplice) {
        send peerCoord, eRecvSpliceInit,
          (channel_id = 0, contribution = myContribution,
           feerate_perkw = attemptFeerate, locktime = 0);
        goto AwaitingNegotiationAck;
      } else {
        // NegRbf: send tx_init_rbf.
        send peerCoord, eRecvTxInitRbf,
          (channel_id = 0, feerate_perkw = attemptFeerate,
           funding_output_contribution = myContribution);
        goto AwaitingNegotiationAck;
      }
    }
  }

  state AwaitingNegotiationInit {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    defer eUserDisconnect, eUserReconnect;
    defer eUserInitiateRbf, eConfirmation, eRecvSpliceLocked;

    on eRecvSpliceInit do (e: (
      channel_id: tChannelId, contribution: tContributionSats,
      feerate_perkw: int, locktime: int
    )) {
      assert negotiation == NegSplice,
        "Phase 3: received splice_init mid-RBF (should have been tx_init_rbf)";
      handlePeerNegotiationInit(e.contribution, e.feerate_perkw);
    }

    on eRecvTxInitRbf do (e: (
      channel_id: tChannelId, feerate_perkw: int,
      funding_output_contribution: tContributionSats
    )) {
      var minMultiplicative: int;
      var minAdditive: int;
      var minRequired: int;
      assert negotiation == NegRbf,
        "Phase 3: received tx_init_rbf mid-splice (should have been splice_init)";
      // BOLT 2 §488–491: RBF feerate rule. Receiver checks.
      minMultiplicative = (lastFeerate * 25) / 24;
      minAdditive = lastFeerate + 25;
      minRequired = minMultiplicative;
      if (minAdditive > minRequired) { minRequired = minAdditive; }
      assert e.feerate_perkw >= minRequired,
        "BOLT 2 sec488: RBF feerate below max(prev*25/24, prev+25)";
      handlePeerNegotiationInit(e.funding_output_contribution, e.feerate_perkw);
    }
  }

  state AwaitingNegotiationAck {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    defer eUserDisconnect, eUserReconnect;
    defer eUserInitiateRbf, eConfirmation, eRecvSpliceLocked, eRecvTxInitRbf;

    on eRecvSpliceAck do (e: (
      channel_id: tChannelId, contribution: tContributionSats
    )) {
      assert negotiation == NegSplice,
        "Phase 3: received splice_ack mid-RBF";
      handlePeerNegotiationAck(e.contribution);
    }

    on eRecvTxAckRbf do (e: (
      channel_id: tChannelId, funding_output_contribution: tContributionSats
    )) {
      assert negotiation == NegRbf,
        "Phase 3: received tx_ack_rbf mid-splice";
      handlePeerNegotiationAck(e.funding_output_contribution);
    }
  }

  state InItxInitiator {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    defer eUserDisconnect, eUserReconnect;
    defer eUserInitiateRbf, eConfirmation, eRecvSpliceLocked, eRecvTxInitRbf;

    entry {
      // Non-initiator signs first (BOLT 2 §1856–1859, see SPEC_QUESTIONS Q8).
      iSignFirst = false;
      activeFundingTxids += (attemptTxid);
      pendingSpliceTxids += (attemptTxid);
      sentCommitSig = false;
      receivedCommitSig = false;
      sentTxSigs = false;
      receivedTxSigs = false;
      announce eCommitSigEmitted,
        (peer = pid, funding_txid = attemptTxid, commitment_number = 0);
      send peerCoord, eRecvCommitSig,
        (channel_id = 0, funding_txid = attemptTxid, commitment_number = 0);
      sentCommitSig = true;
      goto AwaitingPeerCommitSig;
    }
  }

  state InItxNonInitiator {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    defer eUserDisconnect, eUserReconnect;
    defer eUserInitiateRbf, eConfirmation, eRecvSpliceLocked, eRecvTxInitRbf;

    entry {
      iSignFirst = true;
      activeFundingTxids += (attemptTxid);
      pendingSpliceTxids += (attemptTxid);
      sentCommitSig = false;
      receivedCommitSig = false;
      sentTxSigs = false;
      receivedTxSigs = false;
      announce eCommitSigEmitted,
        (peer = pid, funding_txid = attemptTxid, commitment_number = 0);
      send peerCoord, eRecvCommitSig,
        (channel_id = 0, funding_txid = attemptTxid, commitment_number = 0);
      sentCommitSig = true;
      goto AwaitingPeerCommitSig;
    }
  }

  state AwaitingPeerCommitSig {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    // Phase 8: a retransmitted tx_signatures (per §3520–3526) may arrive
    // before our own commit_sig if peer reestablishes faster than us.
    // Defer until we've processed commit_sig.
    defer eRecvTxSignatures;

    defer eUserInitiateRbf, eConfirmation, eRecvSpliceLocked, eRecvTxInitRbf;

    on eRecvCommitSig do (e: (
      channel_id: tChannelId, funding_txid: tTxid,
      commitment_number: tCommitmentNumber
    )) {
      assert e.funding_txid == attemptTxid,
        "Phase 3: commit_sig for unexpected funding_txid";
      receivedCommitSig = true;
      if (iSignFirst) {
        sendOurTxSignatures();
      }
      goto AwaitingTxSigs;
    }

    on eUserDisconnect do { onDisconnect(MarkerAwaitingPeerCommitSig); }
  }

  state AwaitingTxSigs {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    ignore eRecvCommitSig;
    defer eUserInitiateRbf, eConfirmation, eRecvSpliceLocked, eRecvTxInitRbf;

    on eRecvTxSignatures do (e: (
      channel_id: tChannelId, txid: tTxid, has_shared_input_sig: bool
    )) {
      assert e.txid == attemptTxid, "tx_signatures for unexpected txid";
      if (role == RoleNonInitiator) {
        assert e.has_shared_input_sig,
          "BOLT 2 sec1882: missing shared_input_signature from initiator";
      }
      receivedTxSigs = true;
      if (!sentTxSigs) {
        sendOurTxSignatures();
      }
      // BOLT 2 §1886: lift quiescence.
      send quiescence, eDependentProtocolTerminated;
      announceConstructed();
      if (negotiation == NegRbf) {
        announce eRbfBroadcast,
          (peer = pid, txid = attemptTxid,
           prevFeerate = attemptPrevFeerate, newFeerate = attemptFeerate);
      }
      lastFeerate = attemptFeerate;
      send blockchain, eBroadcastRequest, (peer = pid, txid = attemptTxid);
      goto AwaitingConfirmation;
    }

    on eUserDisconnect do { onDisconnect(MarkerAwaitingTxSigs); }
  }

  state AwaitingConfirmation {
    ignore eQuiescenceClearedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    ignore eRecvCommitSig, eRecvTxSignatures;
    // Defer peer-initiated RBF wire init until our QP signals quiescence.
    defer eRecvTxInitRbf;

    on eConfirmation do (e: (peer: tPeerId, txid: tTxid, depth: int)) {
      if (e.peer == pid && e.txid in pendingSpliceTxids && e.depth >= 6) {
        send peerCoord, eRecvSpliceLocked,
          (channel_id = 0, splice_txid = e.txid);
        attemptTxid = e.txid;  // remember which one we locked
        goto AwaitingPeerSpliceLocked;
      }
    }
    on eRecvSpliceLocked do (e: (
      channel_id: tChannelId, splice_txid: tTxid
    )) {
      assert e.splice_txid in pendingSpliceTxids,
        "BOLT 2 sec2020: splice_locked for unknown txid";
      attemptTxid = e.splice_txid;
      goto BufferedSpliceLocked;
    }

    on eUserInitiateRbf do (e: (newFeerate: int)) {
      var minMultiplicative: int;
      var minAdditive: int;
      var minRequired: int;
      // BOLT 2 §488–491: enforce feerate rule on the sender side too.
      minMultiplicative = (lastFeerate * 25) / 24;
      minAdditive = lastFeerate + 25;
      minRequired = minMultiplicative;
      if (minAdditive > minRequired) { minRequired = minAdditive; }
      assert e.newFeerate >= minRequired,
        "BOLT 2 sec488: requested RBF feerate too low";
      // Begin a new RBF round.
      negotiation = NegRbf;
      role = RoleInitiator;
      myContribution = 0;            // for Phase 3 simplicity: 0 contribution
      attemptFeerate = e.newFeerate;
      attemptPrevFeerate = lastFeerate;
      send quiescence, eOpenStfu;
      goto WaitingForQuiescenceAsInitiator;
    }

    on eQuiescenceAchievedAt do (e: (
      pid: tPeerId, iSentInitiator: int, iReceivedInitiator: int
    )) {
      // Peer is initiating RBF.
      negotiation = NegRbf;
      role = RoleNonInitiator;
      goto AwaitingNegotiationInit;
    }

    on eUserDisconnect do { onDisconnect(MarkerAwaitingConfirmation); }
  }

  state BufferedSpliceLocked {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    ignore eRecvCommitSig, eRecvTxSignatures;
    ignore eUserInitiateRbf, eRecvTxInitRbf;

    on eConfirmation do (e: (peer: tPeerId, txid: tTxid, depth: int)) {
      if (e.peer == pid && e.txid == attemptTxid && e.depth >= 6) {
        completeSpliceLock();
        send peerCoord, eRecvSpliceLocked,
          (channel_id = 0, splice_txid = attemptTxid);
        goto Operating;
      }
    }

    on eUserDisconnect do { onDisconnect(MarkerBufferedSpliceLocked); }
  }

  state AwaitingPeerSpliceLocked {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt, eConfirmation;
    ignore eRecvShutdown;
    defer eUserInitiateShutdown;
    
    ignore eRecvCommitSig, eRecvTxSignatures;
    ignore eUserInitiateRbf, eRecvTxInitRbf;

    on eRecvSpliceLocked do (e: (
      channel_id: tChannelId, splice_txid: tTxid
    )) {
      if (e.splice_txid == attemptTxid) {
        completeSpliceLock();
        goto Operating;
      } else {
        // BOLT 2 §2032: mismatched splice_locked — SHOULD ignore. Phase 5
        // exercises this via divergent chain views.
        announce eSpliceLockedMismatchIgnored,
          (peer = pid, received = e.splice_txid, ours = attemptTxid);
      }
    }

    // Phase 5: reorg may rewrite our locked candidate. If the gained txid
    // is one we signed for, switch.
    on eReorg do (e: (
      peer: tPeerId, lost_txid: tTxid, gained_txid: tTxid
    )) {
      if (e.peer == pid && e.gained_txid in pendingSpliceTxids) {
        announce eReorgSwitched,
          (peer = pid, from_txid = attemptTxid, to_txid = e.gained_txid);
        attemptTxid = e.gained_txid;
        send peerCoord, eRecvSpliceLocked,
          (channel_id = 0, splice_txid = e.gained_txid);
      }
    }

    on eUserDisconnect do { onDisconnect(MarkerAwaitingPeerSpliceLocked); }
  }

  // ---------------------------------------------------------------------------
  // Phase 4: disconnect / reconnect states.
  // ---------------------------------------------------------------------------

  // Disconnected: no peer connection. Wait for eUserReconnect.
  // Ignore everything that requires a live connection.
  state Disconnected {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt, eConfirmation;
    ignore eUserInitiateSplice, eUserInitiateRbf;
    ignore eRecvSpliceInit, eRecvSpliceAck, eRecvCommitSig, eRecvTxSignatures;
    ignore eRecvTxInitRbf, eRecvTxAckRbf, eRecvSpliceLocked;
    // Peer might also reconnect first and send reestablish — defer until we
    // are eUserReconnect'd ourselves.
    defer eRecvChannelReestablish;

    on eUserReconnect do {
      // BOLT 2 §3431: send channel_reestablish on reconnection.
      send peerCoord, eRecvChannelReestablish, buildReestablishTlvs();
      goto Reconnecting;
    }
  }

  // Reconnecting: we have sent our channel_reestablish; awaiting peer's.
  state Reconnecting {
    ignore eQuiescenceClearedAt, eQuiescenceAchievedAt;
    ignore eUserInitiateSplice, eUserInitiateRbf;
    defer eConfirmation;
    // Stale wire messages until we have processed reestablish.
    defer eRecvCommitSig, eRecvTxSignatures, eRecvSpliceLocked;

    on eRecvChannelReestablish do (e: (
      channel_id:                          tChannelId,
      next_commitment_number:              tCommitmentNumber,
      next_revocation_number:              tCommitmentNumber,
      next_funding_txid:                   tTxid,
      next_funding_commit_sig_bit:         bool,
      my_current_funding_locked_txid:      tTxid,
      my_current_funding_locked_ann_sig:   bool
    )) {
      processReestablish(e.next_funding_txid, e.next_funding_commit_sig_bit,
                         e.my_current_funding_locked_txid);
      announce eReconnectResumed, (
        peer = pid,
        resumedTo = lastActive,
        retransmittedCommit = false,    // monitor-only; not strictly tracked
        retransmittedTxSigs = false
      );
      resumeToLastActive();
    }
  }

  // ---- helper functions ----

  fun handlePeerNegotiationInit(contrib: tContributionSats, feerate: int) {
    peerContribution = contrib;
    if (contrib < 0 && (0 - contrib) > peerBalance) {
      assert false,
        "BOLT 2 sec1704: peer contribution exceeds peer balance";
    }
    myContribution = 0;
    attemptFeerate = feerate;
    if (negotiation == NegSplice) {
      send peerCoord, eRecvSpliceAck, (channel_id = 0, contribution = 0);
    } else {
      send peerCoord, eRecvTxAckRbf,
        (channel_id = 0, funding_output_contribution = 0);
    }
    attemptTxid = nextSpliceTxid;
    nextSpliceTxid = nextSpliceTxid + 1;
    goto InItxNonInitiator;
  }

  fun handlePeerNegotiationAck(contrib: tContributionSats) {
    peerContribution = contrib;
    if (contrib < 0 && (0 - contrib) > peerBalance) {
      assert false,
        "BOLT 2 sec1738: peer contribution exceeds peer balance";
    }
    attemptTxid = nextSpliceTxid;
    nextSpliceTxid = nextSpliceTxid + 1;
    goto InItxInitiator;
  }

  fun sendOurTxSignatures() {
    var hasShared: bool;
    hasShared = (role == RoleInitiator);
    send peerCoord, eRecvTxSignatures,
      (channel_id = 0, txid = attemptTxid, has_shared_input_sig = hasShared);
    sentTxSigs = true;
  }

  fun announceConstructed() {
    var initContrib: tContributionSats;
    var nonInitContrib: tContributionSats;
    var oldCap: tBalanceSats;
    var newCap: tBalanceSats;
    if (role == RoleInitiator) {
      initContrib = myContribution;
      nonInitContrib = peerContribution;
    } else {
      initContrib = peerContribution;
      nonInitContrib = myContribution;
    }
    oldCap = myBalance + peerBalance;
    newCap = oldCap + initContrib + nonInitContrib;
    announce eSpliceTxConstructed, (
      peer = pid,
      oldCapacity = oldCap,
      newCapacity = newCap,
      initiatorContribution = initContrib,
      nonInitiatorContribution = nonInitContrib
    );
  }

  // Phase 4 helpers.

  fun onDisconnect(m: tReconnectMarker) {
    lastActive = m;
    send quiescence, eDisconnect;
    goto Disconnected;
  }

  fun buildReestablishTlvs(): (
    channel_id:                          tChannelId,
    next_commitment_number:              tCommitmentNumber,
    next_revocation_number:              tCommitmentNumber,
    next_funding_txid:                   tTxid,
    next_funding_commit_sig_bit:         bool,
    my_current_funding_locked_txid:      tTxid,
    my_current_funding_locked_ann_sig:   bool
  ) {
    var nextFunding: tTxid;
    var commitSigBit: bool;
    // BOLT 2 §3445–3452: include next_funding TLV iff we sent commit_sig for
    // an interactive tx and haven't received tx_signatures.
    nextFunding = 0;
    commitSigBit = false;
    if (lastActive == MarkerAwaitingPeerCommitSig ||
        lastActive == MarkerAwaitingTxSigs) {
      if (sentCommitSig && !receivedTxSigs) {
        nextFunding = attemptTxid;
        // §3449: bit set iff we haven't received their commit_sig.
        commitSigBit = !receivedCommitSig;
      }
    }
    return (
      channel_id = 0,
      next_commitment_number = 0,
      next_revocation_number = 0,
      next_funding_txid = nextFunding,
      next_funding_commit_sig_bit = commitSigBit,
      // §3453–3461: include my_current_funding_locked of latest locked tx.
      my_current_funding_locked_txid = lockedFundingTxid,
      my_current_funding_locked_ann_sig = false
    );
  }

  fun processReestablish(nf_txid: tTxid, nf_commit_bit: bool, mcfl_txid: tTxid) {
    // BOLT 2 §3517–§3526.
    if (nf_txid == attemptTxid && nf_txid != 0) {
      if (!receivedTxSigs) {
        if (nf_commit_bit) {
          // Peer hasn't seen our commit_sig. Retransmit.
          send peerCoord, eRecvCommitSig,
            (channel_id = 0, funding_txid = attemptTxid,
             commitment_number = 0);
        }
        if (iSignFirst && receivedCommitSig) {
          // We should sign first and we have their commit_sig. Send tx_sigs.
          if (!sentTxSigs) {
            sendOurTxSignatures();
          } else {
            // Already sent; retransmit.
            sendOurTxSignatures();
          }
        }
      } else {
        // We received their tx_sigs; they didn't get ours. Retransmit.
        if (sentTxSigs) {
          sendOurTxSignatures();
        }
      }
    }
    // BOLT 2 §3535: my_current_funding_locked retransmit logic deferred to
    // Phase 6 (gossip + close).
  }

  fun resumeToLastActive() {
    if (lastActive == MarkerAwaitingPeerCommitSig) { goto AwaitingPeerCommitSig; }
    if (lastActive == MarkerAwaitingTxSigs) { goto AwaitingTxSigs; }
    if (lastActive == MarkerAwaitingConfirmation) { goto AwaitingConfirmation; }
    if (lastActive == MarkerAwaitingPeerSpliceLocked) { goto AwaitingPeerSpliceLocked; }
    if (lastActive == MarkerBufferedSpliceLocked) { goto BufferedSpliceLocked; }
    goto Operating;
  }

  fun completeSpliceLock() {
    // BOLT 2 §2024–2028: discard RBF attempts and ancestors.
    lockedFundingTxid = attemptTxid;
    activeFundingTxids = default(set[tTxid]);
    activeFundingTxids += (attemptTxid);
    pendingSpliceTxids = default(set[tTxid]);
    myBalance = myBalance + myContribution;
    peerBalance = peerBalance + peerContribution;
    announce eSpliceLockedComplete,
      (peer = pid, txid = attemptTxid, finalBalance = myBalance);
    // BOLT 7 §85–90: announcement_signatures is emitted after both
    // exchanged splice_locked AND acceptable depth. In our model
    // completeSpliceLock() is the moment both conditions are met for this
    // peer's view, so emit here.
    if (announceChannel) {
      announce eAnnouncementSignaturesEmitted,
        (peer = pid, scid_txid = attemptTxid);
    }
    negotiation = NegNone;
    role = RoleNone;
    sentTxSigs = false;
    receivedTxSigs = false;
  }
}
