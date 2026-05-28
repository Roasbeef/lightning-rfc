package bridge

import (
	"context"
	"errors"
	"sort"
)

// ErrShutdownBlocked is returned by an Implementation when SendShutdown is
// called while a splice is still pending. The bridge uses this to verify
// BOLT 2 §2155 compliance: `MUST NOT send shutdown if there is a splice
// transaction that isn't locked yet`.
var ErrShutdownBlocked = errors.New(
	"BOLT 2 §2155: shutdown blocked while splice unlocked")

// MockImplementation is a built-in reference Implementation that just
// follows the model's expected state transitions in lockstep. It exists so
// the bridge's tests (and the replay harness in general) can run with no
// external dependencies — wiring an actual lnd / eclair / CLN instance is
// the production use case but not a prerequisite for testing the bridge
// itself.
//
// To plug in a real implementation:
//   1. Implement the Implementation interface for your client (e.g., over
//      that client's gRPC or RPC).
//   2. Call bridge.Replay(ctx, trace, yourAlice, yourBob).
//   3. Inspect the returned *Mismatch.
type MockImplementation struct {
	peerID PeerID

	quiescenceState string
	spliceState     string

	activeFundingTxids map[string]struct{}
	lockedFundingTxid  string
	pendingSpliceTxids map[string]struct{}

	ourBalance, peerBalance int64
	disconnected            bool
	shutdownSent            bool
	shutdownReceived        bool
	announcementSigs        map[string]bool
}

// NewMockImplementation creates a mock that conforms to the P model.
func NewMockImplementation(peer PeerID) *MockImplementation {
	return &MockImplementation{
		peerID:             peer,
		activeFundingTxids: map[string]struct{}{},
		pendingSpliceTxids: map[string]struct{}{},
		announcementSigs:   map[string]bool{},
	}
}

func (m *MockImplementation) Init(_ context.Context, p InitParams) error {
	m.quiescenceState = "Idle"
	m.spliceState = "Operating"
	m.activeFundingTxids = map[string]struct{}{p.InitialFunding: {}}
	m.lockedFundingTxid = p.InitialFunding
	m.pendingSpliceTxids = map[string]struct{}{}
	m.ourBalance = p.OurBalance
	m.peerBalance = p.PeerBalance
	m.disconnected = false
	m.shutdownSent = false
	m.shutdownReceived = false
	m.announcementSigs = map[string]bool{}
	return nil
}

func (m *MockImplementation) SendQuiescenceStfu(_ context.Context, initiator uint8) error {
	// BOLT 2 §1497–1517. initiator=1 → we are initiating, go Quiescing.
	// initiator=0 → we are replying, peer already sent us stfu, so we
	// become Quiescent immediately.
	if initiator == 1 {
		m.quiescenceState = "Quiescing"
	} else {
		m.quiescenceState = "Quiescent"
	}
	return nil
}

func (m *MockImplementation) SendSpliceInit(_ context.Context, _ SpliceInitParams) error {
	m.spliceState = "AwaitingSpliceAck"
	return nil
}

func (m *MockImplementation) SendSpliceAck(_ context.Context, _ SpliceAckParams) error {
	m.spliceState = "InItx"
	return nil
}

func (m *MockImplementation) SendTxInitRbf(_ context.Context, _ TxInitRbfParams) error {
	m.spliceState = "AwaitingTxAckRbf"
	return nil
}

func (m *MockImplementation) SendTxAckRbf(_ context.Context, _ TxAckRbfParams) error {
	m.spliceState = "InItx"
	return nil
}

func (m *MockImplementation) SendCommitSig(_ context.Context, p CommitSigParams) error {
	m.activeFundingTxids[p.FundingTxid] = struct{}{}
	m.pendingSpliceTxids[p.FundingTxid] = struct{}{}
	m.spliceState = "AwaitingPeerCommitSig"
	return nil
}

func (m *MockImplementation) SendTxSignatures(_ context.Context, p TxSignaturesParams) error {
	m.spliceState = "AwaitingConfirmation"
	m.quiescenceState = "Idle" // BOLT 2 §1886
	return nil
}

func (m *MockImplementation) SendSpliceLocked(_ context.Context, txid string) error {
	// Both sides locked → finalize.
	m.lockedFundingTxid = txid
	m.activeFundingTxids = map[string]struct{}{txid: {}}
	m.pendingSpliceTxids = map[string]struct{}{}
	m.announcementSigs[txid] = true
	m.spliceState = "Operating"
	return nil
}

func (m *MockImplementation) SendShutdown(_ context.Context) error {
	if len(m.pendingSpliceTxids) > 0 {
		return ErrShutdownBlocked
	}
	m.shutdownSent = true
	return nil
}

func (m *MockImplementation) Disconnect(_ context.Context) error {
	m.disconnected = true
	m.quiescenceState = "Idle"
	return nil
}

func (m *MockImplementation) Reconnect(_ context.Context) error {
	m.disconnected = false
	return nil
}

func (m *MockImplementation) NotifyConfirmation(_ context.Context, txid string, _ uint32) error {
	// Stays in AwaitingConfirmation until splice_locked sent by both sides.
	_ = txid
	return nil
}

func (m *MockImplementation) NotifyReorg(_ context.Context, _, _ string) error {
	return nil
}

func (m *MockImplementation) Observe(_ context.Context) (State, error) {
	active := make([]string, 0, len(m.activeFundingTxids))
	for k := range m.activeFundingTxids {
		active = append(active, k)
	}
	sort.Strings(active)

	pending := make([]string, 0, len(m.pendingSpliceTxids))
	for k := range m.pendingSpliceTxids {
		pending = append(pending, k)
	}
	sort.Strings(pending)

	return State{
		QuiescenceState:        m.quiescenceState,
		SpliceState:            m.spliceState,
		ActiveFundingTxids:     active,
		LockedFundingTxid:      m.lockedFundingTxid,
		OurBalance:             m.ourBalance,
		PeerBalance:            m.peerBalance,
		PendingSpliceTxids:     pending,
		Disconnected:           m.disconnected,
		ShutdownSent:           m.shutdownSent,
		ShutdownReceived:       m.shutdownReceived,
		AnnouncementSignatures: m.announcementSigs,
	}, nil
}

func (m *MockImplementation) Close(_ context.Context) error { return nil }
