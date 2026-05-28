package bridge

import (
	"context"
	"fmt"
	"reflect"
	"sort"
)

// Replay drives both Implementations (Alice and Bob) through the trace.
// It returns the first Mismatch the implementation produces, or nil if
// the implementation conforms to the model end-to-end.
func Replay(ctx context.Context, t *Trace, alice, bob Implementation) (*Mismatch, error) {
	if err := alice.Init(ctx, InitParams{
		PeerID: string(PeerA), OurBalance: 500000, PeerBalance: 500000,
		AnnounceFlag: true, IsFunder: true,
		InitialFunding: "1",
	}); err != nil {
		return nil, fmt.Errorf("init alice: %w", err)
	}
	if err := bob.Init(ctx, InitParams{
		PeerID: string(PeerB), OurBalance: 500000, PeerBalance: 500000,
		AnnounceFlag: true, IsFunder: false,
		InitialFunding: "1",
	}); err != nil {
		return nil, fmt.Errorf("init bob: %w", err)
	}

	defer alice.Close(ctx)
	defer bob.Close(ctx)

	for _, ev := range t.Events {
		impl := alice
		if ev.Peer == PeerB {
			impl = bob
		}
		if err := apply(ctx, impl, ev); err != nil {
			return nil, fmt.Errorf("event #%d (%s/%s): %w",
				ev.Index, ev.SubProtocol, ev.MsgType, err)
		}
		if len(ev.ExpectedPostState) == 0 {
			continue
		}
		got, err := impl.Observe(ctx)
		if err != nil {
			return nil, fmt.Errorf(
				"observe after event #%d: %w", ev.Index, err,
			)
		}
		if mm := compareState(ev, got); mm != nil {
			return mm, nil
		}
	}
	return nil, nil
}

// Mismatch describes a divergence between the model's expected post-state
// and the implementation's observed state.
type Mismatch struct {
	EventIndex   int
	Peer         PeerID
	Field        string
	Want         any
	Got          any
	SpecCitation string
}

func (m *Mismatch) Error() string {
	return fmt.Sprintf(
		"event #%d (peer %s): %s mismatch: want %v, got %v (spec: %s)",
		m.EventIndex, m.Peer, m.Field, m.Want, m.Got, m.SpecCitation,
	)
}

// apply maps an Event to an Implementation call. The mapping is mechanical;
// see models/bridge/README.md for the full table.
func apply(ctx context.Context, impl Implementation, ev Event) error {
	switch ev.MsgType {
	case "user_initiate_splice":
		// Triggered by the test, not a wire message. The implementation
		// should start the splice flow as initiator (initiator=1).
		return impl.SendQuiescenceStfu(ctx, 1)
	case "user_initiate_rbf":
		return impl.SendTxInitRbf(ctx, TxInitRbfParams{
			ChannelID:                 strField(ev, "channel_id", "1"),
			FeeratePerKW:              u32Field(ev, "feerate_perkw"),
			FundingOutputContribution: i64Field(ev, "funding_output_contribution"),
		})
	case "user_initiate_shutdown":
		return impl.SendShutdown(ctx)
	case "user_disconnect":
		return impl.Disconnect(ctx)
	case "user_reconnect":
		return impl.Reconnect(ctx)
	case "stfu":
		// BOLT 2 §1497: initiator field controls the meaning.
		init := uint8(0)
		if v, ok := ev.Fields["initiator"]; ok {
			if f, ok := v.(float64); ok {
				init = uint8(f)
			}
		}
		return impl.SendQuiescenceStfu(ctx, init)
	case "splice_init":
		return impl.SendSpliceInit(ctx, SpliceInitParams{
			ChannelID:                   strField(ev, "channel_id", "1"),
			FundingContributionSatoshis: i64Field(ev, "funding_contribution_satoshis"),
			FundingFeeratePerKW:         u32Field(ev, "funding_feerate_perkw"),
			Locktime:                    u32Field(ev, "locktime"),
		})
	case "splice_ack":
		return impl.SendSpliceAck(ctx, SpliceAckParams{
			ChannelID:                   strField(ev, "channel_id", "1"),
			FundingContributionSatoshis: i64Field(ev, "funding_contribution_satoshis"),
		})
	case "tx_init_rbf":
		return impl.SendTxInitRbf(ctx, TxInitRbfParams{
			ChannelID:                 strField(ev, "channel_id", "1"),
			FeeratePerKW:              u32Field(ev, "feerate_perkw"),
			FundingOutputContribution: i64Field(ev, "funding_output_contribution"),
		})
	case "tx_ack_rbf":
		return impl.SendTxAckRbf(ctx, TxAckRbfParams{
			ChannelID:                 strField(ev, "channel_id", "1"),
			FundingOutputContribution: i64Field(ev, "funding_output_contribution"),
		})
	case "commit_sig":
		return impl.SendCommitSig(ctx, CommitSigParams{
			ChannelID:        strField(ev, "channel_id", "1"),
			FundingTxid:      strField(ev, "funding_txid", ""),
			CommitmentNumber: u64Field(ev, "commitment_number"),
		})
	case "tx_signatures":
		return impl.SendTxSignatures(ctx, TxSignaturesParams{
			ChannelID:               strField(ev, "channel_id", "1"),
			Txid:                    strField(ev, "txid", ""),
			HasSharedInputSignature: boolField(ev, "has_shared_input_signature"),
		})
	case "splice_locked":
		return impl.SendSpliceLocked(ctx, strField(ev, "splice_txid", ""))
	case "confirmation":
		return impl.NotifyConfirmation(ctx,
			strField(ev, "txid", ""), u32Field(ev, "depth"))
	case "reorg":
		return impl.NotifyReorg(ctx,
			strField(ev, "lost_txid", ""), strField(ev, "gained_txid", ""))
	}
	return fmt.Errorf("unknown msg_type %q", ev.MsgType)
}

func compareState(ev Event, got State) *Mismatch {
	for field, want := range ev.ExpectedPostState {
		actual := stateField(got, field)
		if !reflect.DeepEqual(normalize(want), normalize(actual)) {
			return &Mismatch{
				EventIndex:   ev.Index,
				Peer:         ev.Peer,
				Field:        field,
				Want:         want,
				Got:          actual,
				SpecCitation: ev.SpecCitation,
			}
		}
	}
	return nil
}

func stateField(s State, field string) any {
	switch field {
	case "quiescence_state":
		return s.QuiescenceState
	case "splice_state":
		return s.SpliceState
	case "active_funding_txids":
		sort.Strings(s.ActiveFundingTxids)
		return s.ActiveFundingTxids
	case "locked_funding_txid":
		return s.LockedFundingTxid
	case "our_balance":
		return s.OurBalance
	case "peer_balance":
		return s.PeerBalance
	case "pending_splice_txids":
		sort.Strings(s.PendingSpliceTxids)
		return s.PendingSpliceTxids
	case "disconnected":
		return s.Disconnected
	case "shutdown_sent":
		return s.ShutdownSent
	case "shutdown_received":
		return s.ShutdownReceived
	}
	return nil
}

// normalize converts JSON-unmarshalled values into types comparable to Go's
// native types. JSON numbers come back as float64; we widen ints and slices
// for reflect.DeepEqual.
func normalize(v any) any {
	switch x := v.(type) {
	case float64:
		// Integers in JSON round-trip as float64. We can't distinguish
		// from a real float, but for our schema all integer fields are
		// ints. Cast.
		return int64(x)
	case int:
		return int64(x)
	case int32:
		return int64(x)
	case int64:
		return x
	case uint32:
		return int64(x)
	case []any:
		out := make([]string, 0, len(x))
		for _, e := range x {
			if s, ok := e.(string); ok {
				out = append(out, s)
			}
		}
		sort.Strings(out)
		return out
	case []string:
		out := append([]string(nil), x...)
		sort.Strings(out)
		return out
	}
	return v
}

func strField(ev Event, key, defVal string) string {
	if v, ok := ev.Fields[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
		if f, ok := v.(float64); ok {
			return fmt.Sprintf("%d", int64(f))
		}
	}
	return defVal
}

func i64Field(ev Event, key string) int64 {
	if v, ok := ev.Fields[key]; ok {
		if f, ok := v.(float64); ok {
			return int64(f)
		}
	}
	return 0
}

func u32Field(ev Event, key string) uint32 {
	if v, ok := ev.Fields[key]; ok {
		if f, ok := v.(float64); ok {
			return uint32(f)
		}
	}
	return 0
}

func u64Field(ev Event, key string) uint64 {
	if v, ok := ev.Fields[key]; ok {
		if f, ok := v.(float64); ok {
			return uint64(f)
		}
	}
	return 0
}

func boolField(ev Event, key string) bool {
	if v, ok := ev.Fields[key]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return false
}
