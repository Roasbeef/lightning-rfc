// Command gentrace converts the P TraceObserver's `<PrintLog> PTRACE|...`
// marker lines (from `p check --schedules 1 --verbose`) into a JSON trace
// matching the schema in bridge/trace.go.
//
// Usage:
//
//	p check ...Splicing.dll --testcase tcGenSpliceInHappy --schedules 1 \
//	    --verbose 2>&1 | go run ./cmd/gentrace -scenario splice_in_happy \
//	    -out ../traces/splice_in_happy.json
//
// The marker format emitted by src/observer.p is:
//
//	PTRACE|<idx>|<peer>|<sub>|<msg>|<txid>|<amount>|<feerate>|<postState>
//
// where <peer> and <sub> are P enum ordinals (peer: 0=A,1=B; sub:
// 0=quiescence,1=interactive_tx,2=splice,3=channel,4=gossip).
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	bridge "github.com/lightningnetwork/lightning-rfc/models/bridge"
)

func main() {
	scenario := flag.String("scenario", "", "scenario name for the trace")
	out := flag.String("out", "", "output JSON path (default: stdout)")
	flag.Parse()

	if *scenario == "" {
		fmt.Fprintln(os.Stderr, "gentrace: -scenario is required")
		os.Exit(2)
	}

	tr := &bridge.Trace{Scenario: *scenario}

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		// Markers arrive embedded in `<PrintLog> PTRACE|...`. Strip noise.
		i := strings.Index(line, "PTRACE|")
		if i < 0 {
			continue
		}
		marker := line[i:]
		// Trim any trailing checker decoration after the postState field.
		marker = strings.TrimRight(marker, "'\" \t\r\n")

		ev, err := parseMarker(marker)
		if err != nil {
			fmt.Fprintf(os.Stderr, "gentrace: skip %q: %v\n", marker, err)
			continue
		}
		tr.Events = append(tr.Events, ev)
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "gentrace: read: %v\n", err)
		os.Exit(1)
	}

	// Re-index sequentially (the P idx may have gaps if the checker
	// interleaved schedules; with --schedules 1 it won't, but be safe).
	for i := range tr.Events {
		tr.Events[i].Index = i + 1
	}

	if *out == "" {
		data, err := json.MarshalIndent(tr, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "gentrace: marshal: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(string(data))
		return
	}
	if err := tr.Save(*out); err != nil {
		fmt.Fprintf(os.Stderr, "gentrace: save: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "gentrace: wrote %d events to %s\n",
		len(tr.Events), *out)
}

func parseMarker(marker string) (bridge.Event, error) {
	parts := strings.Split(marker, "|")
	// PTRACE | idx | peer | sub | msg | txid | amount | feerate | postState
	if len(parts) != 9 {
		return bridge.Event{}, fmt.Errorf("want 9 fields, got %d", len(parts))
	}
	idx, _ := strconv.Atoi(parts[1])
	peer := peerName(parts[2])
	sub := subName(parts[3])
	msg := parts[4]
	txid, _ := strconv.Atoi(parts[5])
	amount, _ := strconv.ParseInt(parts[6], 10, 64)
	feerate, _ := strconv.Atoi(parts[7])
	postState := parts[8]

	ev := bridge.Event{
		Index:       idx,
		Peer:        peer,
		SubProtocol: sub,
		MsgType:     msg,
		Fields:      map[string]any{},
	}
	fillFields(&ev, txid, amount, feerate)
	fillExpectedPostState(&ev, txid, postState)
	return ev, nil
}

func peerName(s string) bridge.PeerID {
	if s == "1" {
		return bridge.PeerB
	}
	return bridge.PeerA
}

func subName(s string) bridge.SubProtocol {
	switch s {
	case "0":
		return bridge.SubQuiescence
	case "1":
		return bridge.SubInteractiveTx
	case "2":
		return bridge.SubSplice
	case "3":
		return bridge.SubChannel
	case "4":
		return bridge.SubGossip
	}
	return bridge.SubTest
}

// fillFields maps the generic (txid, amount, feerate) columns to the
// BOLT-named fields per message type.
func fillFields(ev *bridge.Event, txid int, amount int64, feerate int) {
	switch ev.MsgType {
	case "stfu":
		ev.Fields["channel_id"] = "1"
		ev.Fields["initiator"] = amount
	case "splice_init":
		ev.Fields["channel_id"] = "1"
		ev.Fields["funding_contribution_satoshis"] = amount
		ev.Fields["funding_feerate_perkw"] = feerate
		ev.Fields["locktime"] = 0
	case "splice_ack":
		ev.Fields["channel_id"] = "1"
		ev.Fields["funding_contribution_satoshis"] = amount
	case "tx_init_rbf":
		ev.Fields["channel_id"] = "1"
		ev.Fields["feerate_perkw"] = feerate
		ev.Fields["funding_output_contribution"] = amount
	case "tx_ack_rbf":
		ev.Fields["channel_id"] = "1"
		ev.Fields["funding_output_contribution"] = amount
	case "commit_sig":
		ev.Fields["channel_id"] = "1"
		ev.Fields["funding_txid"] = strconv.Itoa(txid)
		ev.Fields["commitment_number"] = 0
	case "tx_signatures":
		ev.Fields["channel_id"] = "1"
		ev.Fields["txid"] = strconv.Itoa(txid)
		ev.Fields["has_shared_input_signature"] = amount == 1
	case "splice_locked":
		ev.Fields["channel_id"] = "1"
		ev.Fields["splice_txid"] = strconv.Itoa(txid)
	case "channel_reestablish":
		ev.Fields["channel_id"] = "1"
		ev.Fields["next_funding_txid"] = strconv.Itoa(txid)
	case "confirmation":
		ev.Fields["txid"] = strconv.Itoa(txid)
		ev.Fields["depth"] = feerate
	}
}

// fillExpectedPostState records only the assertions the model and the
// reference MockImplementation reliably agree on. Conservative by design —
// an empty expected_post_state means "no post-condition check at this step".
func fillExpectedPostState(ev *bridge.Event, txid int, postState string) {
	switch ev.MsgType {
	case "stfu":
		ev.ExpectedPostState = map[string]any{"quiescence_state": postState}
	case "splice_init", "splice_ack", "commit_sig", "tx_signatures":
		ev.ExpectedPostState = map[string]any{"splice_state": postState}
	case "splice_locked":
		// Only the terminal lock (postState=Operating) has a stable
		// cross-peer assertion: the locked funding txid.
		if postState == "Operating" {
			ev.ExpectedPostState = map[string]any{
				"locked_funding_txid": strconv.Itoa(txid),
			}
		}
	case "user_disconnect":
		ev.ExpectedPostState = map[string]any{"disconnected": true}
	case "user_reconnect":
		ev.ExpectedPostState = map[string]any{"disconnected": false}
	}
}

