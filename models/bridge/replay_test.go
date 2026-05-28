package bridge

import (
	"context"
	"path/filepath"
	"testing"
)

func TestReplaySpliceInHappy(t *testing.T) {
	tr, err := LoadTrace(filepath.Join("..", "traces", "splice_in_happy.json"))
	if err != nil {
		t.Fatalf("load trace: %v", err)
	}

	alice := NewMockImplementation(PeerA)
	bob := NewMockImplementation(PeerB)

	mm, err := Replay(context.Background(), tr, alice, bob)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if mm != nil {
		t.Fatalf("mismatch: %s", mm.Error())
	}
}

func TestReplayDisconnectMidSplice(t *testing.T) {
	tr, err := LoadTrace(filepath.Join("..", "traces", "disconnect_mid_splice.json"))
	if err != nil {
		t.Fatalf("load trace: %v", err)
	}

	alice := NewMockImplementation(PeerA)
	bob := NewMockImplementation(PeerB)

	mm, err := Replay(context.Background(), tr, alice, bob)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if mm != nil {
		t.Fatalf("mismatch: %s", mm.Error())
	}
}

// TestReplayDetectsBadState shows that the bridge fires when the
// implementation diverges from the model. We feed a mock that
// intentionally forgets to mark itself quiescent on stfu — the bridge
// should flag the divergence at event #1.
func TestReplayDetectsBadState(t *testing.T) {
	tr, err := LoadTrace(filepath.Join("..", "traces", "splice_in_happy.json"))
	if err != nil {
		t.Fatalf("load trace: %v", err)
	}

	alice := &brokenStfu{MockImplementation: NewMockImplementation(PeerA)}
	bob := NewMockImplementation(PeerB)

	mm, err := Replay(context.Background(), tr, alice, bob)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if mm == nil {
		t.Fatalf("expected mismatch but replay succeeded")
	}
	if mm.Field != "quiescence_state" {
		t.Fatalf("expected mismatch on quiescence_state, got %s", mm.Field)
	}
}

// brokenStfu is a deliberately broken mock that ignores SendQuiescenceStfu.
// Used by TestReplayDetectsBadState as a sanity-check fixture.
type brokenStfu struct{ *MockImplementation }

func (b *brokenStfu) SendQuiescenceStfu(ctx context.Context, initiator uint8) error {
	// Intentionally do nothing — the model expects state transition,
	// the bridge should detect the divergence.
	return nil
}
