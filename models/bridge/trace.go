// Package bridge replays P-generated traces against a Lightning
// implementation. A trace is a sequence of structured events the P model
// emitted during a check run; the bridge feeds them to the implementation
// and asserts that the implementation's observed behavior matches the
// model's expected post-state.
//
// See models/bridge/README.md for the high-level workflow.
package bridge

import (
	"encoding/json"
	"fmt"
	"os"
)

// Trace is a single P scenario captured as a JSON file under
// `models/traces/<scenario>.json`. The schema is intentionally close to
// the BOLT message structure so mapping to real RPC calls is mechanical.
type Trace struct {
	// Scenario is the human-readable name of the test case
	// (e.g., "splice_in_happy", "disconnect_mid_splice").
	Scenario string `json:"scenario"`

	// SpecCitations is a list of BOLT clauses this trace exercises.
	// Each entry is "file:line" matching `models/SPEC_SURVEY.md`.
	SpecCitations []string `json:"spec_citations,omitempty"`

	// Events is the ordered sequence of P-emitted events.
	Events []Event `json:"events"`
}

// SubProtocol is the bucket the event belongs to. Matches `tSubProtocol`
// in models/src/types.p.
type SubProtocol string

const (
	SubQuiescence    SubProtocol = "quiescence"
	SubInteractiveTx SubProtocol = "interactive_tx"
	SubSplice        SubProtocol = "splice"
	SubChannel       SubProtocol = "channel"
	SubGossip        SubProtocol = "gossip"
	SubBlockchain    SubProtocol = "blockchain"
	SubTest          SubProtocol = "test"
)

// PeerID identifies which side of the channel emitted or received the event.
type PeerID string

const (
	PeerA PeerID = "A"
	PeerB PeerID = "B"
)

// Event is a single tagged action in the trace.
//
// The shape mirrors what `SpliceCoordinator`, `QuiescencePeer`, and the
// `Blockchain` machine produce in P.
type Event struct {
	// Index is the event's position in the trace, 1-based.
	Index int `json:"index"`

	// Peer is the actor that owns this event. For wire messages, this is
	// the SENDER. For user triggers, the receiver. For confirmation, the
	// peer whose chain view sees the confirmation.
	Peer PeerID `json:"peer"`

	// SubProtocol scopes the event so a bridge can route to the right
	// implementation module.
	SubProtocol SubProtocol `json:"sub_protocol"`

	// MsgType is the wire-level message name (`splice_init`, `tx_signatures`,
	// `commit_sig`, ...) or an internal action (`user_initiate_splice`,
	// `confirmation`).
	MsgType string `json:"msg_type"`

	// Fields contains the message's payload, keyed by BOLT field name.
	// Examples:
	//   {"channel_id": 1, "funding_contribution_satoshis": -100000,
	//    "funding_feerate_perkw": 253}
	// Fields whose types are protocol-defined (txid, sha256) are passed as
	// strings so the bridge can decode them per BOLT 1 wire rules.
	Fields map[string]any `json:"fields,omitempty"`

	// ExpectedPostState is the abstract state the model says the actor
	// reaches after processing this event. The bridge asserts the
	// implementation's observable state matches.
	// Empty map means "no post-condition check".
	ExpectedPostState map[string]any `json:"expected_post_state,omitempty"`

	// SpecCitation is the BOLT file:line citation for the clause this
	// event tests. Helps trace findings back to the spec.
	SpecCitation string `json:"spec_citation,omitempty"`
}

// LoadTrace reads a trace JSON file from disk.
func LoadTrace(path string) (*Trace, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read trace %q: %w", path, err)
	}

	var t Trace
	if err := json.Unmarshal(data, &t); err != nil {
		return nil, fmt.Errorf("parse trace %q: %w", path, err)
	}

	for i, e := range t.Events {
		if e.Index != i+1 {
			return nil, fmt.Errorf(
				"trace %q event #%d has out-of-order Index=%d",
				path, i+1, e.Index,
			)
		}
	}

	return &t, nil
}

// Save writes the trace back to disk. Used by the P-side observer in
// future iterations; currently the canonical traces are hand-authored.
func (t *Trace) Save(path string) error {
	data, err := json.MarshalIndent(t, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal trace: %w", err)
	}
	return os.WriteFile(path, data, 0o644)
}
