package bridge

// pobserve.go — placeholder for the P-side trace observer.
//
// In future iterations, the P model will emit JSON traces directly during
// `p check`, removing the hand-authoring step. The plan:
//
// 1. Add a P spec machine `Observer` under `models/src/observer.p` that
//    observes every announced event from the protocol machines.
//
// 2. The Observer writes a JSON-line per event to an output file via a
//    P foreign-function-interface (FFI) call. P 3.0.4 has limited FFI;
//    the realistic path is:
//      a. The Observer accumulates events in a P sequence.
//      b. At the end of a check run, the Observer's exit handler prints
//         the sequence to stdout in a known marker format.
//      c. A Go post-processor reads stdout, extracts the markers, and
//         writes them as a JSON file matching the schema in `trace.go`.
//
// 3. For each test case in `models/test/*.p`, the build/CI pipeline runs
//    `p check --testcase X`, extracts the trace, and saves it as
//    `models/traces/X.json`. The bridge then runs `Replay` against each.
//
// This wires the model and the implementations into a single conformance
// loop: a spec PR that changes a clause produces a new monitor,
// regenerates the trace, and exposes any implementation that no longer
// matches.
//
// Until that's plumbed, the canonical traces under `models/traces/` are
// hand-authored from `models/SPEC_SURVEY.md`. The schema in `trace.go`
// is forward-compatible with the auto-generated form.
