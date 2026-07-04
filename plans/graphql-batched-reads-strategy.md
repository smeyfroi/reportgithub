# GraphQL batched reads — portable strategy

A project-agnostic guide for collapsing a per-repo `getContent` read fan-out into
**one GraphQL query per ~100 files**, drawing on GitHub's **separate `graphql`
rate-limit pool** instead of the REST core budget. Written for **near-clone
siblings** of bulkgithub: Swift + JavaScriptCore, a single HTTP fetch funnel, a
`GitHubClient` protocol, and self-describing `.ts` recipes bound through a
`hostPromise` wrapper.

> **Worked reference:** bulkgithub shipped this in **v1.5.0** (PR #4). The exact
> shapes live in `../bulkgithub/Sources/BulkGitHubKit/GitHub/{GitHubClient,LiveGitHubClient}.swift`,
> `.../Engine/HostBindings.swift`, `.../Resources/bulkgh.d.ts`, and the tests in
> `.../Tests/BulkGitHubKitTests/GraphQLBatchTests.swift`. When a step here is
> vague, diff against those. The load-bearing commits: `3ee5aa8` (engine),
> `8ec71f3` (isolation tests), `e5bfd56` (d.ts + serial-default isolation),
> `d9eb628` (recipe adoption). Ignore `f3f2de8` — that wires the batch binding to
> bulkgithub's *quota gate*, which reportgithub does not have.

## The strategy in one paragraph

The read fan-out — `getContent` called per repo (or per file) in a serial loop —
is what exhausts the 5,000/hr REST core budget on a large scan. GitHub's GraphQL
API fetches a blob from ~100 repos in **one aliased query**, and it bills a
**separate `graphql` pool**, so batching is a *double* win: far fewer requests,
on a different budget than the one being blocked. Add a `getContentBatch` host
method backed by chunked GraphQL, expose it in the `.d.ts`, and adopt it in the
recipes whose cost is genuinely `getContent`-bound. **The catch:** a batch has no
per-repo `try/catch`, so an erroring repo collapses to `null` —
indistinguishable from "file absent." You trade per-repo error *visibility* for
the request savings. Phase the engine (inert, low-risk) ahead of recipe adoption
(a behavior change that rewrites golden tests).

## Applicability checklist — run this FIRST, per project

1. **Is there a single HTTP fetch funnel** every request flows through? (The
   injection point — the linchpin. If reads are scattered across ad-hoc
   `URLSession` calls, unify them first.)
2. **Does that funnel branch on HTTP method** — a GET-only retry loop, or a
   write-pacer that would catch a POST? **This decides whether you need an
   `isRead` flag.** GraphQL is a POST but a *read*; if the funnel would mis-pace
   or refuse-to-retry a POST, thread `isRead` through it (bulkgithub did). If the
   funnel is a plain round-trip, **skip `isRead` entirely** and POST straight
   through.
3. **Do recipes loop `getContent` per repo?** Classify each:
   - **Simple** (`getContent`-per-repo, no `listFiles`) → clean win, port it.
   - **Two-level** (`listFiles`-per-repo *then* `getContent`-per-file) → the
     `listFiles` tree call stays serial (GraphQL can't batch a recursive tree),
     so batching `getContent` is only a *partial* win. Measure the
     `getContent`:`listFiles` ratio before porting.
   - **Bulk** (`listOrgProperties` etc.) → already optimal, no benefit.
4. **Does `job.reportMatch` require a proof-of-fetch receipt?** If so, the batch
   binding **must** record a receipt per `(repo, path)` exactly like `getContent`
   does, or every match throws.
5. **Does `RateLimitMonitor` bucket by `x-ratelimit-resource`** (core/search/
   graphql)? If yes, GraphQL quota surfaces for free once you emit the queries.
6. **Does error visibility matter for this product?** A batch turns an errored
   repo into a silent skip. For a **reporting** tool especially, a report that
   quietly drops repos that failed to fetch is *misleading* — weigh the
   richer-result option (Phase 2) before adopting batching in recipes.

## Binding table — fill in per sibling

| Role | bulkgithub | reportgithub (pre-filled) |
|---|---|---|
| Live client | `LiveGitHubClient` | `LiveGitHubClient` (`Sources/ReportGitHubKit/GitHub/LiveGitHubClient.swift`) |
| HTTP funnel | `performFetch(_:cacheable:isRead:)` | `fetch(_:)` — **plain round-trip, LiveGitHubClient.swift:45** |
| `getContent` | ✅ | ✅ `getContent(repo:path:ref:)` (LiveGitHubClient.swift:166) |
| Protocol | `GitHubClient` (+ `getContentBatch`) | `GitHubClient` (GitHubClient.swift:24) — **no `getContentBatch`** |
| Script API surface | `bulkgh.d.ts` (+ update/merge) | `bulkgh.d.ts` (single, check-only) |
| Phases | check / update / merge | **check / report** (read-only; NO write phases) |
| Engine binding | `hostPromise(limiter:cancel:quotaGate:vmQueue:)` | `hostPromise(limiter:cancel:vmQueue:)` — **no quotaGate** (HostBindings.swift:483) |
| Recipes dir | `Resources/recipes/*.ts` | `Resources/recipes/*.ts` (3 files) |
| Rate-limit monitor | `RateLimitMonitor` (pools) | `RateLimitMonitor` — **already buckets graphql** (RateLimitMonitor.swift:41) |
| Golden tests | `GoldenRecipeTests` | `ReportRecipeTests` (asserts `flaky-service → .failed`) |
| Write pacer / ETag / quota gate / RetryMonitor | present | **all ABSENT** (read-only) — none needed |

## reportgithub-specific findings (this is why the plan is smaller than bulkgithub's)

- **Read-only tool** — phases are `check` (script verifies matches) and `report`
  (LLM-driven view, no script). There is no write surface. So **none** of
  bulkgithub's write machinery is in play: no `WritePacer`, no `ETagCache`, no
  `QuotaGate`, no `RetryMonitor`, no `isRead`.
- **The funnel is a plain round-trip** (`fetch(_:)`, LiveGitHubClient.swift:45–65):
  `session.data` → `rateLimit?.update` → 403/429 check → return. No retry loop,
  no method branching. **⟹ `graphQL()` calls `fetch(request)` directly with a
  POST; do NOT port bulkgithub's `isRead` parameter.**
- **`RateLimitMonitor` already tracks the `graphql` pool** — no monitor changes.
- **Both file recipes are two-level and `listFiles`-bound:**
  - `find_waf_resources.ts` — `listOrgRepos` → `listFiles("**/*.template")` per
    repo → `getContent` per template, with an **early-break** at the first
    matching resource (lines 27–72).
  - `find_named_object_properties.ts` — the same shape.
  - `report_custom_properties.ts` — `listOrgProperties` (bulk), no file fetch →
    **not a candidate.**
  So recipe adoption here is the *partial-win, harder* case (gather pairs across
  repos, group results back, lose the early-break) — the exact category
  bulkgithub left serial. Do the engine regardless; treat recipe adoption as a
  measured, per-recipe judgment.
- **Golden tests** (`ReportRecipeTests.swift`) inject an error on `flaky-service`
  and assert `.failed`. Porting a recipe to batching flips that to `.skipped` and
  must update those assertions (see Phase 1 / risk #3).

## The phases

### Phase 0 — The engine (the `getContentBatch` capability). Inert, low-risk.

Ships the capability without changing any recipe behavior — no golden test moves.

1. **`ContentRequest` + protocol method + serial default** in `GitHubClient.swift`.
   Add `struct ContentRequest { repo; path; ref? }`, declare
   `func getContentBatch(_ requests: [ContentRequest]) async throws -> [String?]`,
   and a **default extension** that reads serially **catching per-item errors →
   `nil`** (so any non-GraphQL conformer — the fixture client — *isolates* one bad
   repo instead of failing the whole batch; let `CancellationError` propagate).
   Diff: bulkgithub GitHubClient.swift `ContentRequest` + `public extension`.
2. **`graphQL(query:variables:)` transport** in `LiveGitHubClient.swift`. Build a
   POST to `/graphql` with a `{query, variables}` JSON body and call
   **`fetch(request)`** (no `isRead` — reportgithub's funnel is plain). Parse the
   `data` object; **throw only when `data` is entirely absent** — a per-repo
   failure returns partial `data` plus a non-fatal top-level `errors` array,
   which is isolation, not a batch failure. Diff: bulkgithub `graphQL(...)`.
3. **`getContentBatch` + `fetchContentChunk`** in `LiveGitHubClient.swift`. Chunk
   requests to ~100; per chunk build an aliased query
   (`r0: repository(owner:$o0,name:$n0){ object(expression:$e0){ ...on Blob{text} } } …`)
   passing every value as a **GraphQL variable** (never string-interpolated, so
   repo/path can't break out); return texts aligned to input, `nil` for a
   malformed/missing repo, a missing file, or a binary blob. Diff: bulkgithub
   `getContentBatch` + `fetchContentChunk`.
4. **`gh.getContentBatch` host binding** in `HostBindings.swift`, modeled on the
   `getContent` binding (LiveGitHubClient... `HostBindings` `getContent` block):
   parse a JS array of `{repo, path, ref?}` → `[ContentRequest]`, call through
   `hostPromise(limiter:cancel:vmQueue:)` (**no quotaGate here**), **record a
   receipt per non-nil `(repo, path)`** so `reportMatch` still accepts the
   evidence, audit `kind: "gh.getContentBatch"` with `"N file(s) → M present"`,
   and return the aligned array with `NSNull` for the `nil` holes.
5. **Declare it in `bulkgh.d.ts`** on the check surface, documenting the contract
   — *aligned to input; null for missing/binary; per-repo isolation, so you can't
   tell absent from fetch-failed; no per-repo try/catch.*
6. **Tests** (new file, mirror `GraphQLBatchTests`): alignment with null holes,
   **missing-file isolation**, **missing-repo isolation** (partial `data` + a
   non-fatal `errors` array must NOT fail the batch), and chunking into multiple
   queries. Land Phase 0 as its own verified commit; existing golden tests are
   untouched because no recipe calls it yet.

### Phase 1 — Recipe adoption. Behavior change; per-recipe judgment.

Only worth it where `getContent` is the real cost. **Measure first** for
reportgithub's two-level recipes: if repos typically hold one template file,
`getContent` ≈ `listFiles` and the win is ~2×; if they hold many, the win grows.

- Restructure a candidate: gather **all** `(repo, path)` pairs across repos (after
  the per-repo `listFiles`), issue **one** `getContentBatch`, then group results
  back per repo. The **early-break is lost** — you fetch every candidate file
  up-front rather than stopping at the first match. That's *more bytes* but still
  *fewer requests* (one batch vs a getContent-until-match chain).
- **Update the golden tests:** `flaky-service → .skipped` (its fetch error is now
  an indistinguishable `null`), and the audit trail shows **one**
  `gh.getContentBatch` instead of N `gh.getContent`. Diff: bulkgithub `d9eb628`
  updated `GoldenRecipeTests` exactly this way.

### Phase 2 (optional; for a report tool, consider it BEFORE Phase 1)

A report that silently omits repos that *failed to fetch* is misleading. If that
visibility is a product requirement, upgrade `getContentBatch` to a **richer
result** that distinguishes *absent* from *errored* — GraphQL's `errors` array
names the failed aliases (NOT_FOUND / FORBIDDEN), so the binding can surface a
per-repo error and the recipe can still mark it `.failed`. This is more API
surface (`[BatchEntry]` where `BatchEntry = .content | .absent | .error`) and it
is the reason bulkgithub's simpler `[String?]` was an explicit *tradeoff*, not an
oversight. Decide this up front for reportgithub — it changes Phase 0's return
type.

## Transferable risk catalog

1. **POST-is-a-read.** GraphQL is a POST but a read. If the funnel has a GET-only
   retry loop or a write pacer, thread an `isRead` flag so GraphQL isn't
   mis-paced or denied retries. *(reportgithub: N/A — plain funnel; POST straight
   through.)*
2. **Injection.** Pass `owner`/`name`/`expression` as GraphQL **variables**,
   never interpolated into the query string.
3. **Per-repo isolation loss.** An erroring repo → `null` → skipped, not failed.
   Update golden tests; for a report tool weigh Phase 2 before adopting.
4. **`reportMatch` receipts.** The batch binding MUST record a receipt per
   `(repo, path)`; miss this and every `reportMatch` throws.
5. **`listFiles` is not batchable.** GraphQL can't fetch a recursive tree in one
   shot, so two-level recipes keep their per-repo `listFiles` cost — don't
   over-claim the win.
6. **Partial-failure handling.** Throw ONLY when `data` is entirely absent
   (systemic: HTTP non-2xx, or a query-level rejection). A null alias or a
   non-fatal `errors` entry is per-repo isolation — return the rest.
7. **Chunk size.** ~100 aliases per query keeps you under GraphQL's node/complexity
   limits; confirm against real data.

## Adaptation workflow

1. Copy the **binding table**; the reportgithub column is pre-filled — verify each
   line against the current code before you rely on it.
2. Run the **applicability checklist**, especially **#2** (is `isRead` needed? —
   no, for reportgithub) and **#6** (does error visibility force Phase 2 first?).
3. **Phase 0 (engine) → tests green → Phase 1 (recipe adoption, per recipe, measured)**,
   each as its own verified commit.
4. Diff every step against bulkgithub **v1.5.0** (`3ee5aa8`, `8ec71f3`,
   `e5bfd56`, `d9eb628`) for the exact shape — skipping `f3f2de8`
   (quota-gate wiring, absent here).
