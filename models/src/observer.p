// observer.p — trace-generation observer.
//
// The protocol machines announce `eWireTrace` at every observable protocol
// step. The TraceObserver spec machine records each one and `print`s a
// pipe-delimited marker line. During `p check --testcase tcGen* --schedules 1
// --verbose`, those lines surface as `<PrintLog> PTRACE|...`. The Go
// extractor in `bridge/cmd/gentrace` scrapes them and emits a JSON trace
// matching the schema in `bridge/trace.go`.
//
// Why pipe-delimited instead of JSON: building escaped JSON in P's format()
// is brittle; emitting fields delimited by '|' and letting Go assemble the
// JSON keeps the P side simple and the schema authoritative in one place.

// eWireTrace is announced by QuiescencePeer / SpliceCoordinator / Blockchain
// at each protocol step. `postState` is the emitting machine's own label for
// the state it has reached, used to populate Event.ExpectedPostState.
event eWireTrace: (
  peer:      tPeerId,
  sub:       tSubProtocol,
  msg:       string,
  txid:      tTxid,
  amount:    int,
  feerate:   int,
  postState: string
);

spec TraceObserver observes eWireTrace {
  var idx: int;

  start state Watching {
    entry { idx = 0; }

    on eWireTrace do (e: (
      peer: tPeerId, sub: tSubProtocol, msg: string,
      txid: tTxid, amount: int, feerate: int, postState: string
    )) {
      idx = idx + 1;
      // Marker format (consumed by bridge/cmd/gentrace):
      //   PTRACE|<idx>|<peer>|<sub>|<msg>|<txid>|<amount>|<feerate>|<postState>
      print format("PTRACE|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}",
        idx, e.peer, e.sub, e.msg, e.txid, e.amount, e.feerate, e.postState);
    }
  }
}
