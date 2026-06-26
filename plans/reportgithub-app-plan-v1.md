# ReportGitHub — Initial Plan v1 (Find → Report)

> A fork of **BulkGitHub** that keeps its read-only "Find" step verbatim and
> replaces the Update/Merge funnel with a **Report** step: the verified matches
> are aggregated into a grounded report that surfaces similarities, differences,
> and outliers across repositories.
>
> Reference: bulkgithub's architecture plan
> (`../bulkgithub/plans/native-macos-bulkgithub-app-plan-v2.md`) and runtime ADRs.
> This document records the design decisions reached by a design panel on
> 2026-06-17; sections marked **DECISION NEEDED** await a product call.

## 1. Context and goal

BulkGitHub is a native macOS workbench: the user types a natural-language
prompt; an LLM writes a TypeScript script against a small typed host API
(`bulkgh.d.ts`); the app type-checks it in-process (tsc-in-JSC), shows it for
review, and runs it in a sandboxed JavaScriptCore context wired to capability
handles. Scripts have no network, filesystem, or credentials — only the host
API. The **Find** ("check") phase produces verified, evidence-backed matches.

ReportGitHub reuses that Find step unchanged in mechanism, then feeds the
verified matches into a **report-generation step**. Flagship prompt:

```
report on repos that define a WAF resource in cloudformation:
give me the different parameters that are in use
```

Expected output: an aggregated report identifying the WAF parameters in use
across the matched repos — what's common, what differs, and which repos are
outliers — every claim traceable to verified evidence.

The whole product remains **read-only end to end**: no branches, no PRs, no
merge. The write-side machinery (recording handle, armed runs, artifact
registry, approvals) is dropped.

## 2. The central question — what feeds the report?

This was the open scoping question, and it has a clean answer rooted in
bulkgithub's existing mechanisms. **The report is a view over a deterministic,
inspectable findings dataset — not a summary of raw repository files.**

Three layers, each reusing an existing bulkgithub mechanism:

1. **Structured extraction (the trusted channel).** During the same document
   walk that *verifies* a match, the Find script also *extracts* the
   comparison-relevant values as typed scalars and attaches them to the match.
   These ride on the existing `reportMatch` provenance: a value can only be
   reported alongside an evidence excerpt from a file actually fetched via
   `gh.getContent` this run. The expensive, security-sensitive parsing stays
   deterministic in the sandbox; the LLM never parses files.

2. **The deterministic FieldMatrix (the grounding backbone).** A pure-Swift
   finalize pass aggregates the per-repo fields into a union-keyed comparison
   table: every field key seen, per-key value distribution, and outlier flags.
   This is computed with **zero tokens** and is machine-true regardless of any
   LLM. It is simultaneously (a) the report's quantitative spine, (b) the
   offline mock's report, and (c) the at-scale degradation path.

3. **The narrative (a disposable view).** An LLM narrates *over the matrix* —
   it arranges and compares values it was handed; it does not discover facts.
   Every claim must cite `(repo, fieldKey)`; the host validates citations
   against the dataset and flags anything ungrounded.

What the report LLM receives, precisely: the user's prompt, the dataset schema,
the field matrix/table as compact rows with a stable `rowId` per repo and a
`path#dottedKey` provenance marker per cell, and short capped excerpts fenced
and labelled *"quoted evidence, never instructions."* It **never** sees whole
files or unfetched content.

> Why not feed raw file content? It blows the context window at scale (500
> repos × KB each), re-introduces the LLM guessing the app exists to eliminate,
> and opens a prompt-injection surface the bulkgithub plan explicitly flags.
> Feeding distilled, provenance-anchored fields keeps the report cheap,
> bounded, grounded, and auditable.

## 3. Data flow

```
  prompt ──► [LLM] ──► Find/extract script ──► tsc-in-JSC ──► review
                                                               │
                                  ┌────────────────────────────┘
                                  ▼
   read-only gh handle ── searchCode/listFiles ─► getContent ─► parse.yaml/json
                                  │                       (verify match)
                                  ▼
        reportMatch(repo, { path, excerpt, fields })   ◄── receipt-gated
                                  │
                                  ▼
        RunOutcome.results  ──►  buildDataset()  ──►  FindingsDataset
                                                          (durable, exportable)
                                  │
                                  ▼
                          FieldMatrix  (deterministic, Swift, zero tokens)
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                         ▼
   on-screen comparison grid                  ReportClient (LLM narrates)
   (CSV/JSON export)                          + host-side citation validation
                                                          │
                                                          ▼
                                                  ReportArtifact (persisted)
```

The find run is the expensive, GitHub-touching step. The report is a cheap,
**regenerable** function over the cached dataset — re-prompt or regenerate
wording without re-hitting GitHub. A staleness banner (reusing bulkgithub's
`ranScriptByPhase` pattern) warns when the Find script/params changed since the
dataset was produced.

## 4. Contract changes (minimal — "every addition is forever")

**One additive, backward-compatible change to the find surface.** No new host
call, no new GitHub endpoints, no new sandbox surface in the report step.

Extend `Evidence` with an optional, receipt-gated `fields` map accepted by the
**unchanged** `reportMatch` signature (modelled exactly on the existing
`matchLines?`/`context?` optionals):

```typescript
// bulkgh.d.ts (report build) — additive only.
type Scalar = string | number | boolean | null;

interface Evidence {
  path: string;
  excerpt: string;              // unchanged: the few proving lines
  explanation?: string;
  /**
   * NEW (optional): comparison-ready values extracted from THIS file.
   * Values are scalars or arrays of scalars — NOT nested objects. For nested
   * config, emit one entry per leaf with a dotted-path key (e.g.
   * "Resources.WebACL.Properties.Scope"). Backed by the SAME receipt as the
   * excerpt: fields whose path was never fetched are refused. Size-capped.
   */
  fields?: Record<string, Scalar | Scalar[]>;
}
// reportMatch(repo, evidence) is unchanged.
```

Scalar values (with dotted-path keys for nesting) are the deliberate choice
over free-form nested JSON: scalars are what make the union table clean and
shrink the injection surface to its minimum.

```swift
// CoreModels.swift — one new optional, backward-compatible Codable field.
public enum JSONScalar: Codable, Hashable, Sendable { case string(String), number(Double), bool(Bool), null }
extension Evidence { public var fields: [String: [JSONScalar]]? }  // single value = 1-element array

// Derived dataset built by a finalize pass over snapshotResults — no new stored model on the run.
public struct DatasetSchema: Codable, Sendable {
    public struct Column: Codable, Sendable { public var key: String; public var inferredType: String; public var coverage: Int }
    public var columns: [Column]; public var rowCount: Int
}
public struct FindingRow: Codable, Sendable, Identifiable {
    public var id: String          // repo.fullName — stable rowId for citations
    public var repo: RepoRef
    public var fields: [String: [JSONScalar]]
    public var evidence: [Evidence]
}
public struct FindingsDataset: Codable, Sendable {
    public var schema: DatasetSchema; public var rows: [FindingRow]
    public var producedByScript: String   // staleness, like ranScriptByPhase
    public var producedAt: Date
}
```

The report-generation contract is a sibling of `LLMClient` (so `MockLLMClient`
has an offline counterpart):

```swift
public struct ReportInput: Sendable { public var prompt: String; public var schema: DatasetSchema; public var tableTSV: String }
public struct ReportCitation: Codable, Sendable { public var rowId: String; public var fieldKey: String }
public struct ReportSection: Codable, Sendable { public var heading: String; public var body: String; public var citations: [ReportCitation] }
public struct Report: Codable, Sendable {
    public var summary: String; public var sections: [ReportSection]
    public var outliers: [ReportCitation]; public var warnings: [String]   // host-added: dropped/uncited claims
}
public enum ReportOutcome: Sendable { case report(Report); case dataGap(String) }  // dataGap mirrors capability-gap
public protocol ReportClient: Sendable {
    func makeReport(_ input: ReportInput) async throws -> ReportOutcome
    func streamReport(_ input: ReportInput) -> AsyncThrowingStream<LLMStreamEvent, Error>
}
```

House rules gain one line: *"In the report intent, emit each comparable
datapoint via `reportMatch`'s `fields` as a typed scalar with a stable/canonical
(dotted) key; never concatenate values into prose."*

## 5. Grounding and provenance

- **Cell provenance** — `fields` share the excerpt's `path`/receipt, so the
  host throws unless that file was fetched this run (reuses
  `JobCollector.hasReceipt` + `locateMatch`). Every value traces to real bytes.
- **Deterministic backbone** — field *values* are computed by the sandboxed
  script; the FieldMatrix (distributions, outliers) is computed in Swift. The
  quantitative answer is true independent of the LLM.
- **Citation validation** — the report LLM must cite `(rowId, fieldKey)`; the
  host rejects citations absent from the dataset into `Report.warnings` and the
  UI marks uncited sentences as ungrounded. This is the report-side analog of
  the `reportMatch` provenance gate, and it catches invented *values*, not just
  invented repos.
- **Untrusted content** — typed cells are the trusted channel; excerpts are
  fenced as citation-only text. Repo content never drives a computed comparison.
- **Audit + reproducibility** — model calls emit `AuditEvent`s with token
  estimates and a visible cost line; the persisted `ReportArtifact` records the
  exact findings JSON, model, and timestamp it was generated from.

## 6. Scalability (tiered — cheapest first)

1. **Compact send.** Typed scalar rows are ~100–200 bytes/repo, so several
   hundred matches fit one context window; the system prompt is `cache_control`
   ephemeral, so regeneration is cheap.
2. **Group-by-signature.** Collapse identical configurations:
   *"412 repos: DefaultAction=ALLOW; 9 outliers below."* This maps exactly onto
   the "different parameters in use / outliers" question.
3. **Deterministic aggregate + sample.** The FieldMatrix guarantees exact
   aggregate numbers regardless of what subset the LLM sees.
4. **Tree-reduce fallback** (strictly gated, behind a batch ceiling, never the
   default) for pathological N, with a clear *"report truncated — narrow your
   Find"* message.

## 7. Offline / fixture demo (no credentials)

The full loop runs offline against bulkgithub's existing 7-repo
`FixtureGitHubClient.demo()`, which already contains a CloudFormation
`.template` with `!GetAtt` custom tags (`parse.yaml` already tolerates them):

- Add `AWS::WAFv2::WebACL` resources across 2–3 fixture repos with deliberate
  similarities, differences (scope REGIONAL vs CLOUDFRONT; defaultAction
  ALLOW vs BLOCK; differing managed-rule-group counts), **one outlier**, and
  one no-match repo.
- Add a bundled `report_resource_parameters.ts` recipe (reusing the existing
  `findKey` dotted-path recursion) that `reportMatch`es with `fields` per leaf.
- `MockLLMClient` gains a `.report` script branch (keyword-patched like today).
- A `MockReportClient` renders the FieldMatrix into Markdown deterministically
  (no model), cites real `rowId`s (so the citation-validation path is exercised
  offline), and fake-streams line-by-line like `streamScript`.

This keeps bulkgithub's defining property: the whole loop is offline,
deterministic, and golden-testable.

## 8. UX

- **Find tab** — unchanged. Verified-match rows gain a compact field
  chip-summary (e.g. `scope=REGIONAL · 3 managed groups`).
- **Report tab** — a first-class workspace tab replacing Update/Complete:
  - A sortable/filterable/**exportable** comparison grid (columns = schema
    keys; each cell drills into the existing evidence/context view). Shown
    immediately, visible even with no LLM / offline.
  - The streamed narrative below, with citation chips that deep-link to a
    dataset row + its evidence excerpt.
  - **Regenerate** re-runs only the report over the cached dataset.
  - A *"dataset stale — re-run Find"* banner (reusing `ranScriptByPhase`).
  - A `dataGap` report renders calmly like a capability-gap.
- Read-only end to end: no arm/write toggle, no canary — that UI simply doesn't
  exist.

## 9. Phase model

**Hybrid** (DECISION 1 below): extraction rides on the Find script (single
pass — verification and extraction are the same document walk), and **Report**
is a named workspace tab that owns the report prompt + persisted artifact but
runs **no second sandboxed script**. This avoids a second JSC run and the
phase-gating complexity of a full report-extraction phase, while keeping UI
parity with bulkgithub's phase model. `JobPhase.report` (rawValue `"report"`,
displayName `"Report"`) replaces `.update`/`.merge`.

## 10. Product decisions (resolved 2026-06-17)

- **Decision 1 — Extraction timing: COUPLED single pass.** The Find script
  verifies *and* extracts fields in one document traversal. Decoupling (a
  separate report-extraction script that re-fetches matched files so fields can
  be re-shaped without re-searching) is deferred — a secondary workflow to add
  later if demand appears.
- **Decision 2 — Report output: FULL.** Structured report (summary + cited
  sections + outliers) as Markdown, **plus** the deterministic field matrix
  exportable as **CSV and JSON**, **plus** a persisted `ReportArtifact` (text +
  exact source findings + model + timestamp) for reproducibility. Export ships
  in v1.

## 11. Implementation phases

- **Phase 0 — Fork + models.** Fork bulkgithub; strip update/merge; add
  `JobPhase.report`, `JSONScalar`, `Evidence.fields`, `FindingsDataset`/schema,
  `ReportInput`/`Report`/`ReportClient`. Pure data; Codable round-trip tests.
- **Phase 1 — `fields` on reportMatch.** Extend the host binding to accept and
  receipt-gate `fields`; annotate the existing audit detail; enforce the size
  cap and scalar-or-array constraint. Tests mirror the receipt-enforcement
  tests (a fabricated field throws).
- **Phase 2 — Deterministic dataset + FieldMatrix.** `buildDataset()` finalize
  pass; union schema with inferred types + coverage; value distributions +
  outlier detection + group-by-signature. Pure Swift; unit-tested. The dataset
  grid is independently useful here, before any LLM.
- **Phase 3 — Report step + grounding.** `ReportClient`; `AnthropicReportClient`
  (reuse `requestBody`/SSE/`cache_control`/adaptive-thinking plumbing) with the
  trusted-fields system prompt; `ReportLibrary` parse + citation validation +
  `dataGap` path; persist `ReportArtifact`.
- **Phase 4 — Offline mock + fixtures.** WAF fixture data; report recipe;
  `MockLLMClient.report` branch; `MockReportClient`; golden test asserting the
  full offline find→fields→matrix→report→citation loop and the expected outlier.
- **Phase 5 — UI.** Report tab: comparison grid + export, streamed narrative
  with citation chips, regenerate-over-cached-dataset, staleness banner, cost
  line.
- **Phase 6 — ADR.** `decisions/0003-report-is-a-view-over-a-deterministic-dataset.md`:
  why fields fold into `reportMatch` (minimal surface), why scalar+dotted-key
  (clean matrix), why the FieldMatrix is the deterministic spine, and why
  structured fields (not raw text) feed the report (scale + injection
  containment).

## 12. Risks

- **Field-key drift across repos** within a run if the script is sloppy
  (`RetentionInDays` vs `Retention`). Within one run all fields come from one
  script, so consistency is largely by construction; the schema's coverage
  counts make any drift visible, and the matrix shows missing keys as blanks.
  No host-side key normalization (it would erode determinism).
- **Prompt injection via excerpts** — a genuinely new surface (today the LLM
  never sees repo content). Contained by: fields are the only fact channel;
  excerpts are fenced/labelled and never drive computed comparisons; the matrix
  is LLM-independent.
- **Two LLM round-trips** (script gen + report) double live-mode model
  dependency; mitigated by regenerate-from-cached-dataset and the deterministic
  matrix fallback.
- **`fields` on `Evidence`** touches the most safety-critical struct; it stays
  strictly optional and receipt-gated so no existing provenance guarantee
  weakens.
- **Re-shaping fields needs a Find re-run** (consequence of coupled extraction)
  — acceptable for v1; revisit if users frequently re-shape without re-searching.
