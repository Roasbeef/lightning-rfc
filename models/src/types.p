// types.p — shared types for the splicing P-model.
//
// Phase 0 stub: declarations only. Machines and events land in later phases.
// Every type is anchored to a BOLT clause from `SPEC_SURVEY.md`.

// Peer identities. The model is a two-party protocol.
// BOLT 2 throughout — `02-peer-protocol.md`.
enum tPeerId {
  PeerA,
  PeerB
}

// Channel id. Abstracted to a small symbolic alphabet — concrete bytes do not
// affect protocol behavior in the model.
// BOLT 2 §"The channel_id and short_channel_id", `02-peer-protocol.md`.
type tChannelId = int;

// Bitcoin transaction id, abstracted symbolically.
type tTxid = int;

// A funding outpoint = (txid, vout). For splice models, vout is almost always
// 0 (the channel funding output), but we keep it explicit for clarity.
type tOutpoint = (txid: tTxid, vout: int);

// Channel-side balance, in satoshis. Abstracted to a small bounded range in
// test cases so the checker can enumerate.
type tBalanceSats = int;

// Commitment number. Counters are independent per peer, start at 0.
// BOLT 2 §"channel_reestablish", `02-peer-protocol.md:3379–3383`.
type tCommitmentNumber = int;

// Splice contribution. Negative = splice-out. Positive = splice-in.
// BOLT 2 §"The splice_init Message", `02-peer-protocol.md:1661–1680`.
type tContributionSats = int;

// Quiescence-initiator tag, including the tied case.
// BOLT 2 §"Channel Quiescence", `02-peer-protocol.md:1490–1556`.
enum tInitiatorTag {
  InitiatorA,
  InitiatorB,
  InitiatorTied  // both sent stfu(initiator=1); funder-wins is settled later.
}

// Sub-protocol enum for trace tagging (used by the bridge in Phase 7).
enum tSubProtocol {
  SpQuiescence,
  SpInteractiveTx,
  SpSplice,
  SpChannel,
  SpGossip
}

// Role within a single splice attempt. Determines who sends splice_init.
// BOLT 2 §"The splice_init Message", `02-peer-protocol.md:1666–1668`.
enum tSpliceRole {
  RoleNone,
  RoleInitiator,
  RoleNonInitiator
}

// Which kind of negotiation we're currently in. Phase 3+.
// Splice = initial splice (splice_init/ack).
// Rbf = RBF attempt (tx_init_rbf/tx_ack_rbf).
enum tNegotiationKind {
  NegNone,
  NegSplice,
  NegRbf
}

// Marker recording what state we were in when disconnected, so reconnect
// can resume properly per channel_reestablish semantics
// (BOLT 2 §3445–3540). Phase 4+.
enum tReconnectMarker {
  MarkerNone,
  MarkerAwaitingPeerCommitSig,   // sent commit_sig, awaiting peer's
  MarkerAwaitingTxSigs,          // exchanged commit_sigs, in tx_sigs phase
  MarkerAwaitingConfirmation,    // post tx_sigs, pre splice_locked
  MarkerAwaitingPeerSpliceLocked,// sent our splice_locked
  MarkerBufferedSpliceLocked     // received peer's splice_locked, not yet confirmed
}

// Model-config flags for ambiguity modes. Each flag picks one of several
// plausible spec readings. Test cases set the config and check the ideal
// invariant against the chosen mode.
// See `SPEC_QUESTIONS.md` for the matching seeded ambiguities.
type tModelConfig = (
  // Q1 + tied-initiator resolution.
  quiescenceTiedFunderWins:    bool,
  // Q9: must we re-stfu before tx_init_rbf?
  rbfRequiresReQuiescence:     bool,
  // Q6: do we buffer mismatched splice_locked for later, or drop?
  spliceLockedMismatchBuffer:  bool,
  // Q14: lift quiescence on send or on receive of tx_signatures?
  liftQuiescenceOnSend:        bool
);
