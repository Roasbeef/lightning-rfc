package bridge

import "context"

// Implementation is the contract a Lightning implementation must satisfy
// to be replayed against. The interface is intentionally narrow and
// implementation-agnostic so lnd, eclair, CLN, and ldk can all plug in.
//
// Two peers run in parallel; each Implementation instance represents one
// side. The replay harness drives both sides through the trace.
type Implementation interface {
	// Init configures the implementation for a fresh channel between the
	// two peers, with the given initial balances. The implementation must
	// behave as if `channel_ready` has been exchanged.
	Init(ctx context.Context, params InitParams) error

	// SendQuiescenceStfu emits an `stfu` message. `initiator==1` means we
	// are the quiescence initiator (BOLT 2 §1513); `initiator==0` means
	// we are replying to a received stfu (§1511).
	SendQuiescenceStfu(ctx context.Context, initiator uint8) error

	// SendSpliceInit triggers a splice_init message.
	// BOLT 2 §1646.
	SendSpliceInit(ctx context.Context, p SpliceInitParams) error

	// SendSpliceAck triggers a splice_ack.
	// BOLT 2 §1713.
	SendSpliceAck(ctx context.Context, p SpliceAckParams) error

	// SendTxInitRbf triggers a tx_init_rbf message.
	// BOLT 2 §466 (generic) + §1903 (splice overlay).
	SendTxInitRbf(ctx context.Context, p TxInitRbfParams) error

	// SendTxAckRbf triggers a tx_ack_rbf message.
	// BOLT 2 §537 (generic) + §1961 (splice overlay).
	SendTxAckRbf(ctx context.Context, p TxAckRbfParams) error

	// SendCommitSig sends a commitment_signed for the given funding_txid.
	// BOLT 2 §1830 splice-specific overlay.
	SendCommitSig(ctx context.Context, p CommitSigParams) error

	// SendTxSignatures sends tx_signatures, including
	// `shared_input_signature` for the splice case.
	// BOLT 2 §408 (generic) + §1871 (splice overlay).
	SendTxSignatures(ctx context.Context, p TxSignaturesParams) error

	// SendSpliceLocked broadcasts the splice_locked message.
	// BOLT 2 §2004.
	SendSpliceLocked(ctx context.Context, txid string) error

	// SendShutdown (BOLT 2 §2135) — should fail with ErrShutdownBlocked
	// if a splice is still pending. The bridge uses this to verify
	// §2155.
	SendShutdown(ctx context.Context) error

	// Disconnect simulates a TCP disconnect. The implementation MUST
	// honour BOLT 2 §3419–3425 (reverse uncommitted updates).
	Disconnect(ctx context.Context) error

	// Reconnect restores the connection and triggers the
	// channel_reestablish exchange (BOLT 2 §3360).
	Reconnect(ctx context.Context) error

	// NotifyConfirmation pushes a blockchain confirmation event from the
	// bridge's blockchain stub.
	NotifyConfirmation(ctx context.Context, txid string, depth uint32) error

	// NotifyReorg pushes a reorg event: `lost` is unconfirmed, `gained`
	// replaces it.
	NotifyReorg(ctx context.Context, lostTxid, gainedTxid string) error

	// Observe returns the current observable state. The replay harness
	// compares this to Event.ExpectedPostState.
	Observe(ctx context.Context) (State, error)

	// Close releases any resources.
	Close(ctx context.Context) error
}

// InitParams configures a fresh channel.
type InitParams struct {
	PeerID         string
	OurBalance     int64
	PeerBalance    int64
	AnnounceFlag   bool
	IsFunder       bool
	InitialFunding string
}

// SpliceInitParams is the BOLT-faithful message payload for splice_init.
type SpliceInitParams struct {
	ChannelID                   string
	FundingContributionSatoshis int64
	FundingFeeratePerKW         uint32
	Locktime                    uint32
	FundingPubkey               []byte
	RequireConfirmedInputs      bool
}

// SpliceAckParams is the splice_ack payload.
type SpliceAckParams struct {
	ChannelID                   string
	FundingContributionSatoshis int64
	FundingPubkey               []byte
	RequireConfirmedInputs      bool
}

// TxInitRbfParams is the tx_init_rbf payload.
type TxInitRbfParams struct {
	ChannelID                 string
	Locktime                  uint32
	FeeratePerKW              uint32
	FundingOutputContribution int64
	RequireConfirmedInputs    bool
}

// TxAckRbfParams is the tx_ack_rbf payload.
type TxAckRbfParams struct {
	ChannelID                 string
	FundingOutputContribution int64
	RequireConfirmedInputs    bool
}

// CommitSigParams is the commitment_signed payload (splice variant) — it
// must include funding_txid so a peer with multiple active commitments
// can route the signature correctly.
type CommitSigParams struct {
	ChannelID        string
	FundingTxid      string
	CommitmentNumber uint64
	SignaturePresent bool
}

// TxSignaturesParams is the tx_signatures payload.
type TxSignaturesParams struct {
	ChannelID                string
	Txid                     string
	NumWitnesses             uint16
	HasSharedInputSignature  bool
}

// State is the implementation's observable state at a given replay step.
// The bridge asserts these fields against Event.ExpectedPostState.
type State struct {
	QuiescenceState        string
	SpliceState            string
	ActiveFundingTxids     []string
	LockedFundingTxid      string
	OurBalance             int64
	PeerBalance            int64
	PendingSpliceTxids     []string
	Disconnected           bool
	ShutdownSent           bool
	ShutdownReceived       bool
	AnnouncementSignatures map[string]bool // txid → emitted?
}
