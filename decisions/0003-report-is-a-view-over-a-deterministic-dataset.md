# 0003 — The report is a view over a deterministic findings dataset

Status: accepted (2026-06-17)

## Context

ReportGitHub forks BulkGitHub's read-only Find step and adds a Report step that
aggregates the matched repositories into a comparison of how they're configured
(the flagship prompt: "report on repos that define a WAF resource in
cloudformation: give me the different parameters that are in use"). The open
question was *what information feeds report generation* — raw matched files, the
existing evidence excerpts, or something else — given BulkGitHub's core stance
that search results are candidates and only deterministically-verified, fetched
content is proof.

## Decision

The report is a **view over a deterministic findings dataset**, not a summary of
raw files. Three layers, each reusing an existing mechanism:

1. **Extraction rides on the Find script.** The same document walk that verifies
   a match also extracts the comparison-relevant values, attached via an
   optional `fields` map on `reportMatch`'s evidence (`Evidence.fields`). Values
   are scalars or arrays of scalars; nested config is flattened to dotted-path
   keys. The host refuses fields for a path that wasn't fetched this run (the
   same receipt gate as the excerpt) and caps their size.

2. **A deterministic `FieldMatrix`** is computed in pure Swift from the verified
   findings — union of keys, per-field value distributions, and outlier flags —
   with zero tokens. It is the report's quantitative truth, the offline mock's
   entire output, and the at-scale degradation path.

3. **The LLM only narrates the matrix.** It never sees raw repository files —
   only the distilled, trusted matrix — so the report is grounded, auditable,
   cheap, bounded, and the prompt-injection surface of feeding repo content to a
   model is avoided.

Supporting choices:

- **Fold into `reportMatch`, no new host call.** One optional, receipt-gated
  field on the existing `Evidence`, modelled on the precedent of
  `matchLines?`/`context?`. Smallest possible contract surface ("every addition
  is forever").
- **Free-form keys, typed-scalar values + soft guards** (JSON-serialisable,
  scalar-or-array, size cap) rather than a fixed schema — the report subject
  varies (WAF params today, log retention tomorrow), and within one run the
  fields are consistent by construction.
- **Coupled single-pass extraction**, and **"Report" is a workspace phase that
  runs no sandboxed script** — it aggregates the Find results and calls a
  `ReportClient` (mock renders the matrix offline; Anthropic narrates it live).
  The report is regenerable over the same findings without re-running Find.

## Consequences

- The report can only discuss fields the Find script extracted; a new question
  about an un-extracted parameter means editing and re-running Find. Acceptable
  for v1; decoupled re-extraction can be added later if demand appears.
- Feeding the model repo content (the injection surface BulkGitHub's plan flags)
  is avoided by construction — extracted scalars are the only fact channel.
- One new `JobPhase.report` case touches phase-gated switches; the report phase
  adds no script declaration and reuses the check surface.
- The deterministic matrix means the report's numbers are machine-true
  regardless of the narrative, and the whole loop is golden-testable offline.
