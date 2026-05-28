# Model Checking

How the P checker is run against this model, what bounds we use, and how to
interpret results.

## Toolchain

- P 3.0.4 (`dotnet tool install --global P --version 3.0.4`).
- .NET 8 SDK.
- Optional: Go 1.21+ for the `bridge/` replay harness.

## Compiling

```bash
./scripts/build.sh                          # both .pproj files
p compile splicing.pproj                    # just protocol
p compile infra.pproj                       # just infra
```

Generated artifacts land under `PGenerated/` (gitignored).

## Running the checker

```bash
./scripts/check.sh                          # full suite
./scripts/check-quick.sh                    # CI-sized smoke
```

Single-test-case invocation, useful when iterating:

```bash
p check PGenerated/PChecker/net8.0/Splicing.dll \
  --testcase tcQuiescenceTied \
  --schedules 1000 \
  --max-steps 200
```

Output goes to `PCheckerOutput/` (gitignored). On a counterexample, P writes a
trace that can be replayed with:

```bash
p check ... --replay PCheckerOutput/<run>/CoyoteOutput/<schedule>.schedule
```

## Bounds & passing depth

For each test case we track the maximum schedule depth reached at the
default bounds. These are recorded as passing depths in
[`FINDINGS.md`](./FINDINGS.md) per phase.

Current passing depths (as of latest run):

| Test                            | Schedules | Max steps | Timelines |
|---------------------------------|-----------|-----------|-----------|
| tcQuiescenceClean               | 2000      | 5000      | 2         |
| tcQuiescenceTied                | 2000      | 5000      | 4         |
| tcStfuWithPending               | 2000      | 5000      | 2         |
| tcQuiescenceDisconnect          | 2000      | 5000      | 12        |
| tcQuiescenceTerminateResume     | 2000      | 5000      | 10        |
| tcSpliceInHappy                 | 2000      | 5000      | 13        |
| tcSpliceOutHappy                | 2000      | 5000      | 12        |
| tcSpliceZeroContribution        | 2000      | 5000      | 12        |
| tcSpliceWithRbf                 | 2000      | 5000      | 19        |
| tcSpliceMultiRbf                | 2000      | 5000      | 24        |
| tcSpliceRbfFromNonInitiator     | 2000      | 5000      | 17        |
| tcDisconnectMidSplice           | 3000      | 5000      | 88        |
| tcDivergentConfirmation         | 2000      | 5000      | 15        |
| tcSpliceThenShutdown            | 2000      | 5000      | 16        |

## How counterexamples become findings

1. Checker reports a violation on monitor `Spec_X`.
2. Replay the schedule to confirm it's deterministic.
3. Trace through the BOLT clauses involved using `SPEC_SURVEY.md` citations.
4. Decide:
   - Model bug → fix the model, no finding.
   - Real spec ambiguity → add a `FINDINGS.md` entry with the schedule
     attached as a JSON trace in `traces/`, cross-link the matching
     `SPEC_QUESTIONS.md` item, propose a spec clarification.
   - Spec is fine but implementations *could* diverge → finding with a
     bridge test vector in `traces/` so other implementations can verify
     conformance.

## CI

Phase 0 ships placeholder scripts only. CI integration lands with
Phase 1 (`.github/workflows/p-model-check.yml`, mirroring
`lightninglabs/darepo#216`).

## Recommended developer loop

```bash
# Edit src/*.p
./scripts/build.sh                          # fast iterate
p check ... --testcase tcMyNewTest --schedules 50 --max-steps 100
# Once happy, bump schedules and max-steps:
p check ... --testcase tcMyNewTest --schedules 5000 --max-steps 400
```
