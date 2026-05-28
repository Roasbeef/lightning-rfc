// events.p — event surface for the splicing P-model.
//
// Phase 0 stub: declarations of the wire-level events. Machine implementations
// arrive in later phases. Every event is anchored to its BOLT message in
// `SPEC_SURVEY.md`.

// --- Quiescence (BOLT 2 §"Channel Quiescence", 02-peer-protocol.md:1490) ---

// `stfu` message.
// BOLT 2, `02-peer-protocol.md:1497–1502`.
event eRecvStfu : (channel_id: tChannelId, initiator: int);
event eSendStfu : (channel_id: tChannelId, initiator: int);

// Upward signal: both sides have exchanged stfu.
event eQuiescenceAchieved : (initiator: tInitiatorTag);

// Dependent protocol signals it's done with the quiescent phase (e.g.,
// SpliceCoordinator finished tx_signatures exchange).
// BOLT 2, `02-peer-protocol.md:1886–1901`.
event eDependentProtocolTerminated;

// --- Splice (BOLT 2 §"Channel Splicing", 02-peer-protocol.md:1558) ---

// `splice_init` (type 80).
// BOLT 2, `02-peer-protocol.md:1646`.
event eRecvSpliceInit : (
  channel_id:    tChannelId,
  contribution:  tContributionSats,
  feerate_perkw: int,
  locktime:      int
);
event eSendSpliceInit : (
  channel_id:    tChannelId,
  contribution:  tContributionSats,
  feerate_perkw: int,
  locktime:      int
);

// `splice_ack` (type 81).
// BOLT 2, `02-peer-protocol.md:1713`.
event eRecvSpliceAck : (
  channel_id:   tChannelId,
  contribution: tContributionSats
);
event eSendSpliceAck : (
  channel_id:   tChannelId,
  contribution: tContributionSats
);

// `splice_locked` (type 77).
// BOLT 2, `02-peer-protocol.md:2004`.
event eRecvSpliceLocked : (channel_id: tChannelId, splice_txid: tTxid);
event eSendSpliceLocked : (channel_id: tChannelId, splice_txid: tTxid);

// --- Interactive Tx (BOLT 2 §"Interactive Transaction Construction") ---
// 02-peer-protocol.md:100–627.

// `tx_add_input` (type 66) — with the splice-specific shared_input_txid TLV.
// BOLT 2, `02-peer-protocol.md:197`, splice overlay `02-peer-protocol.md:1756`.
event eRecvTxAddInput : (
  channel_id:        tChannelId,
  serial_id:         int,
  shared_input_txid: tTxid  // 0 sentinel = unset (non-shared input).
);
event eSendTxAddInput : (
  channel_id:        tChannelId,
  serial_id:         int,
  shared_input_txid: tTxid
);

// `tx_add_output` (type 67).
// BOLT 2, `02-peer-protocol.md:289`.
event eRecvTxAddOutput : (channel_id: tChannelId, serial_id: int, sats: int);
event eSendTxAddOutput : (channel_id: tChannelId, serial_id: int, sats: int);

// `tx_remove_input` (type 68) and `tx_remove_output` (type 69).
// BOLT 2, `02-peer-protocol.md:338–365`.
event eRecvTxRemoveInput  : (channel_id: tChannelId, serial_id: int);
event eSendTxRemoveInput  : (channel_id: tChannelId, serial_id: int);
event eRecvTxRemoveOutput : (channel_id: tChannelId, serial_id: int);
event eSendTxRemoveOutput : (channel_id: tChannelId, serial_id: int);

// `tx_complete` (type 70). BOLT 2, `02-peer-protocol.md:367`.
event eRecvTxComplete : (channel_id: tChannelId);
event eSendTxComplete : (channel_id: tChannelId);

// `tx_signatures` (type 71) — with splice-specific shared_input_signature.
// BOLT 2, `02-peer-protocol.md:408`, splice overlay `02-peer-protocol.md:1871`.
event eRecvTxSignatures : (
  channel_id:             tChannelId,
  txid:                   tTxid,
  has_shared_input_sig:   bool
);
event eSendTxSignatures : (
  channel_id:             tChannelId,
  txid:                   tTxid,
  has_shared_input_sig:   bool
);

// `tx_init_rbf` (type 72). BOLT 2, `02-peer-protocol.md:466`, splice overlay
// `02-peer-protocol.md:1903`.
event eRecvTxInitRbf : (
  channel_id:                  tChannelId,
  feerate_perkw:               int,
  funding_output_contribution: tContributionSats
);
event eSendTxInitRbf : (
  channel_id:                  tChannelId,
  feerate_perkw:               int,
  funding_output_contribution: tContributionSats
);

// `tx_ack_rbf` (type 73). BOLT 2, `02-peer-protocol.md:537`, splice overlay
// `02-peer-protocol.md:1961`.
event eRecvTxAckRbf : (
  channel_id:                  tChannelId,
  funding_output_contribution: tContributionSats
);
event eSendTxAckRbf : (
  channel_id:                  tChannelId,
  funding_output_contribution: tContributionSats
);

// `tx_abort` (type 74). BOLT 2, `02-peer-protocol.md:583`.
event eRecvTxAbort : (channel_id: tChannelId);
event eSendTxAbort : (channel_id: tChannelId);

// --- Commitment (subset relevant to splice) ---
// BOLT 2 §"Normal Operation", `02-peer-protocol.md`.

// `start_batch` precedes a batched commit_sig sequence.
// `bolt02/splicing-test.md:115`.
event eRecvStartBatch : (channel_id: tChannelId, batch_size: int);
event eSendStartBatch : (channel_id: tChannelId, batch_size: int);

// `commitment_signed` (132), tagged with funding_txid for the splice case.
// BOLT 2 splice overlay, `02-peer-protocol.md:1830`.
event eRecvCommitSig : (
  channel_id:        tChannelId,
  funding_txid:      tTxid,
  commitment_number: tCommitmentNumber
);
event eSendCommitSig : (
  channel_id:        tChannelId,
  funding_txid:      tTxid,
  commitment_number: tCommitmentNumber
);

// `revoke_and_ack` (133).
event eRecvRevokeAndAck : (channel_id: tChannelId);
event eSendRevokeAndAck : (channel_id: tChannelId);

// --- Reconnection (BOLT 2 §"Message Retransmission") ---
// 02-peer-protocol.md:3360.

// `channel_reestablish` (type 136), with the splice-relevant TLVs.
// BOLT 2, `02-peer-protocol.md:3360–3543`.
event eRecvChannelReestablish : (
  channel_id:                          tChannelId,
  next_commitment_number:              tCommitmentNumber,
  next_revocation_number:              tCommitmentNumber,
  next_funding_txid:                   tTxid,   // 0 = unset
  next_funding_commit_sig_bit:         bool,
  my_current_funding_locked_txid:      tTxid,   // 0 = unset
  my_current_funding_locked_ann_sig:   bool
);
event eSendChannelReestablish : (
  channel_id:                          tChannelId,
  next_commitment_number:              tCommitmentNumber,
  next_revocation_number:              tCommitmentNumber,
  next_funding_txid:                   tTxid,
  next_funding_commit_sig_bit:         bool,
  my_current_funding_locked_txid:      tTxid,
  my_current_funding_locked_ann_sig:   bool
);

// Link lifecycle, driven by the Network machine.
event eDisconnect;
event eReconnect;

// --- Blockchain ---

// Confirmation event. Per-peer because peers may have divergent chain views.
// Rationale at BOLT 2, `02-peer-protocol.md:2036–2043`.
event eConfirmation : (peer: tPeerId, txid: tTxid, depth: int);
event eReorg : (peer: tPeerId, lost_txid: tTxid, gained_txid: tTxid);

// --- Gossip (BOLT 7 §"announcement_signatures") ---
// 07-routing-gossip.md:70.

// `announcement_signatures` (type 259).
// BOLT 7, `07-routing-gossip.md:70`.
event eRecvAnnouncementSignatures : (channel_id: tChannelId, scid_txid: tTxid);
event eSendAnnouncementSignatures : (channel_id: tChannelId, scid_txid: tTxid);
