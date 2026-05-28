# Contributing to the splicing P-model

Conventions for adding machines, events, monitors, and test cases.

## Where things go

- New protocol machine → `src/<component>.p`.
- New monitor (spec property) → `src/monitors.p` (or split if it grows).
- New event or type → `src/events.p` / `src/types.p`.
- New test case → `test/<component>_test.p`.
- New canonical trace → `traces/<scenario>.json` + entry in
  `bridge/event_mapping.go`.

## Always cite the spec

Every machine, every monitor, every requirement is anchored to a `file:line`
in `SPEC_SURVEY.md`. The comment style:

```p
// MUST NOT send `splice_init` if the channel is not quiescent.
// BOLT 2 §"The splice_init Message", 02-peer-protocol.md:1667.
```

If you find yourself writing a rule without a citation, stop and either:
1. Find the citation in `SPEC_SURVEY.md`, add it, then continue.
2. Add an entry to `SPEC_QUESTIONS.md` flagging it as "implicit / not stated."

## Conventions

- One machine per file. Filename is the lowercase machine name
  (`quiescence.p`, `interactive_tx.p`, `splice_coordinator.p`, ...).
- Events: `e<Verb><Object>`. Send events: `eSend<Msg>`. Recv events: `eRecv<Msg>`.
- Types: `t<Name>` (`tPeerId`, `tOutpoint`, `tCommitmentNumber`).
- Monitors: `Spec_<InvariantName>` (`Spec_CapacityConservation`,
  `Spec_LockMonotonicity`).
- Test cases: `tc<Subject>` (`tcQuiescenceTied`, `tcSpliceHappyPath`).

## Modeling spec ambiguities

If a clause has more than one plausible reading, model **all** of them under
a configuration flag. Pattern lifted from `lightninglabs/darepo#216`:

```p
type tModelConfig = (
  quiescenceTiedInitiatorRule: tTiedInitiatorRule,
  rbfRequiresReQuiescence:     bool,
  spliceLockedMismatchBuffer:  bool,
);
```

Each test case picks a config and checks the ideal monitor. The mode that
violates the ideal becomes a finding.

## Counterexample workflow

1. Reproduce: `p check ... --testcase tcX --schedules N --max-steps M`.
2. Replay to confirm deterministic: `--replay <schedule>`.
3. Decide model bug vs real finding (see `MODEL_CHECKING.md`).
4. If real:
   - Add a brief entry to `FINDINGS.md`.
   - Drop the JSON trace under `traces/` so the bridge can replay it.
   - Mark the matching `SPEC_QUESTIONS.md` item as confirmed.

## Code review

- Cite the BOLT clause for every new rule.
- Cite the matching `SPEC_QUESTIONS.md` item for any new configuration flag.
- New machines must come with at least one test case and one monitor.
- Don't break previous phase's checks. Run `./scripts/check.sh` before opening
  a PR.

## Phase discipline

The phases in [`README.md`](./README.md) are sequenced. Don't reach forward —
e.g., don't start modeling reconnect (Phase 4) inside the Phase 2 happy-path
machines. Reach back is fine: a Phase 4 finding may need Phase 1's
quiescence monitor strengthened.
