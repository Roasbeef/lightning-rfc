// blockchain.p — Bitcoin confirmation oracle.
//
// Phase 2: deterministic — on broadcast, confirms on both peers immediately
//          (autoConfirm=true).
// Phase 5: non-deterministic. Broadcasts accumulate; confirmations are
//          triggered explicitly by the test driver, optionally with divergent
//          views between the two peers (autoConfirm=false). Models the
//          RBF-chain-disagreement case admitted by BOLT 2 §2036–2043.

// ---------------------------------------------------------------------------
// Events.
// ---------------------------------------------------------------------------

event eSetupBlockchain: (alice: machine, bob: machine, autoConfirm: bool);
event eBroadcastRequest: (peer: tPeerId, txid: tTxid);

// Phase 5: explicit confirmation and reorg triggers.
event eUserConfirmTx: (peer: tPeerId, txid: tTxid, depth: int);
event eUserReorgTx: (peer: tPeerId, lost_txid: tTxid, gained_txid: tTxid);

// ---------------------------------------------------------------------------
// Blockchain machine.
// ---------------------------------------------------------------------------

machine Blockchain {
  var alice: machine;
  var bob: machine;
  var autoConfirm: bool;
  var broadcasts: set[tTxid];
  var confirmedToAlice: set[tTxid];   // tracks which we've already confirmed,
  var confirmedToBob: set[tTxid];     // for dedup.

  start state Init {
    on eSetupBlockchain do (e: (alice: machine, bob: machine, autoConfirm: bool)) {
      alice = e.alice;
      bob = e.bob;
      autoConfirm = e.autoConfirm;
      broadcasts = default(set[tTxid]);
      confirmedToAlice = default(set[tTxid]);
      confirmedToBob = default(set[tTxid]);
      goto Watching;
    }
  }

  state Watching {
    on eBroadcastRequest do (e: (peer: tPeerId, txid: tTxid)) {
      var alreadyBroadcast: bool;
      alreadyBroadcast = e.txid in broadcasts;
      broadcasts += (e.txid);
      if (autoConfirm && !alreadyBroadcast) {
        // BOLT 2 §"acceptable depth" — Phase 2 uses depth=6 placeholder.
        send alice, eConfirmation, (peer = PeerA, txid = e.txid, depth = 6);
        send bob, eConfirmation, (peer = PeerB, txid = e.txid, depth = 6);
        confirmedToAlice += (e.txid);
        confirmedToBob += (e.txid);
      }
    }

    on eUserConfirmTx do (e: (peer: tPeerId, txid: tTxid, depth: int)) {
      // Phase 5: explicit confirmation. The test may schedule this BEFORE
      // the broadcast event; we simply send and let the receiver match.
      // (In real life, confirmations arrive after broadcast.)
      if (e.peer == PeerA && !(e.txid in confirmedToAlice)) {
        send alice, eConfirmation,
          (peer = PeerA, txid = e.txid, depth = e.depth);
        confirmedToAlice += (e.txid);
      } else if (e.peer == PeerB && !(e.txid in confirmedToBob)) {
        send bob, eConfirmation,
          (peer = PeerB, txid = e.txid, depth = e.depth);
        confirmedToBob += (e.txid);
      }
    }

    on eUserReorgTx do (e: (
      peer: tPeerId, lost_txid: tTxid, gained_txid: tTxid
    )) {
      if (e.peer == PeerA) {
        send alice, eReorg,
          (peer = PeerA, lost_txid = e.lost_txid,
           gained_txid = e.gained_txid);
      } else {
        send bob, eReorg,
          (peer = PeerB, lost_txid = e.lost_txid,
           gained_txid = e.gained_txid);
      }
    }
  }
}
