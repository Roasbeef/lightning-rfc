# P-Model of Lightning Channel Splicing

This directory holds a [P](https://p-org.github.io/P/) formal model of the
splicing protocol as currently specified across the BOLTs. The goal is twofold:

1. **Understand the protocol precisely.** Translating prose to executable state
   machines forces us to confront every implicit assumption.
2. **Find spec ambiguities.** P's checker explores schedules exhaustively
   (within bounds). Counterexamples that surface real disagreements between
   plausible spec readings become candidate spec issues / clarifications.

The model is grown iteratively, phase by phase. See
[`ARCHITECTURE.md`](./ARCHITECTURE.md) for the decomposition,
[`SPEC_SURVEY.md`](./SPEC_SURVEY.md) for the spec citations every machine
ties back to, [`SPEC_QUESTIONS.md`](./SPEC_QUESTIONS.md) for the running
list of seeded ambiguities, and [`FINDINGS.md`](./FINDINGS.md) for confirmed
findings with reproducer traces.

## Layout

```
models/
  README.md             this file
  ARCHITECTURE.md       machine/event decomposition, monitors
  MODEL_CHECKING.md     how to run the checker, depths, bounds
  CONTRIBUTING.md       conventions for extending the model
  SPEC_SURVEY.md        every relevant BOLT clause with citations
  SPEC_QUESTIONS.md     seeded ambiguities under investigation
  FINDINGS.md           confirmed findings with reproducers

  splicing.pproj        protocol-level model: quiescence + interactive-tx +
                        splice + channel
  channel.pproj         base full-duplex commitment FSM (the F9/F10
                        follow-up: the layer the splice model abstracts)
  infra.pproj           network + blockchain non-determinism, checkable alone

  src/                  machine sources (.p)
  test/                 test drivers (.p)
  traces/               canonical JSON traces per scenario
  bridge/               Go replay harness — plug in real implementations

  scripts/check.sh        compile + run full suite
  scripts/check-quick.sh  CI-sized subset
  scripts/build.sh        compile only

.gitignore                excludes PGenerated/, PCheckerOutput/
```

## Phases

| Phase | Subject                                                   |
|-------|-----------------------------------------------------------|
| 0     | Survey + scaffold (this checkpoint)                       |
| 1     | Quiescence (`stfu`) machine                               |
| 2     | Happy-path single splice, no RBF, no disconnect           |
| 3     | RBF + multiple active commitments                         |
| 4     | Disconnect / `channel_reestablish` retransmit semantics   |
| 5     | Blockchain non-determinism: reorgs, RBF fork disagreement |
| 6     | Channel-close + gossip post-splice                        |
| 7     | Bridge skeleton: trace format + Go replay harness         |
| 8     | Iterate, tighten claims, file findings                    |
| 9     | Base commitment FSM: F9 convergence + F10 reconnect (WIP)  |

Each phase adds machines and/or spec monitors and never breaks the previous
phase's checks.

## Prerequisites (for later phases)

- [P 3.0.4](https://github.com/p-org/P) (`dotnet tool install --global P --version 3.0.4`)
- .NET 8 SDK
- Go 1.21+ for the bridge

## Running

```bash
./scripts/check.sh          # full suite (slower)
./scripts/check-quick.sh    # CI-sized subset
./scripts/build.sh          # compile only, no checking
```

These are placeholder scripts in Phase 0; the underlying models land in
Phases 1+.
