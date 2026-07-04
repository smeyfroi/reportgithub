import Foundation
import Observation
import ReportGitHubKit

@MainActor
@Observable
final class AppModel {
    var settings = AppSettings()
    /// The selected job phase: drives what kind of script Generate requests.
    /// Kept in sync with the editor — validating or loading a script adopts
    /// its declared phase.
    var phase: JobPhase = .check
    var prompt: String = ""
    var scriptText: String = ""
    var paramsDraft: [String: String] = [:]
    /// Cross-phase job state (JSON per key) — written and read by the find
    /// script's writeState/readState (read-only across runs).
    var jobState: [String: String] = [:]
    var quotaText: String?
    /// Each phase is its own workspace — prompt, script, and params swap
    /// together on a phase switch.
    private var promptsByPhase: [JobPhase: String] = [:]
    private var scriptsByPhase: [JobPhase: String] = [:]
    private var paramsByPhase: [JobPhase: [String: String]] = [:]
    var diagnostics: [Diagnostic] = []
    /// Results are kept per phase: switching phases shows each phase's own
    /// last run instead of leaking one phase's table into the other.
    private(set) var resultsByPhase: [JobPhase: [RepoResult]] = [:]
    /// The script source that produced each phase's results, for staleness:
    /// regenerating or editing the script makes existing results stale.
    private var ranScriptByPhase: [JobPhase: String] = [:]
    /// The effective params each phase's results were produced with —
    /// param edits change what the script computes just like source edits,
    /// so they trigger the same staleness.
    private var ranParamsByPhase: [JobPhase: [String: String]] = [:]
    /// The defaults declared in the script's meta.params (captured at
    /// validation), so the params bar can mark edited values and offer a
    /// reset back to the script's own default.
    private var declaredParamsByPhase: [JobPhase: [String: String]] = [:]
    var results: [RepoResult] { resultsByPhase[phase] ?? [] }
    var logs: [String] = []
    var auditEvents: [AuditEvent] = []
    /// Cumulative across all runs of this job (capped), each run prefixed
    /// with a synthetic boundary event — the job's full audit trail.
    var auditTrail: [AuditEvent] = []
    var statusLine: String = "Ready"
    var running = false
    /// True once the current run has enumerated repos (candidate rows). Drives
    /// the determinate scan meter: it stays determinate from the first
    /// candidate until the run ends, so the meter holds at 100% rather than
    /// blinking back to a spinner the instant the last candidate resolves.
    var runHadCandidates = false

    var generating = false
    var validating = false
    var selectedRepo: String?

    // MARK: Report phase (ReportGitHub)

    /// The generated report narrative for this job (persisted). The
    /// deterministic matrix is re-derived from the Find results on demand.
    var report: Report?
    /// Live accumulator while a report streams in.
    var reportMarkdown: String = ""
    var generatingReport = false

    /// The deterministic comparison matrix over the Find run's verified
    /// findings — the report's grounded backbone, shown even before/without an
    /// LLM, and the offline mock's whole output.
    var reportMatrix: FieldMatrix { FieldMatrix.build(from: resultsByPhase[.check] ?? []) }
    var reportCoverage: ReportCoverage { ReportCoverage(results: resultsByPhase[.check] ?? []) }
    /// True when there are findings (matches carrying extracted fields) to report on.
    var canGenerateReport: Bool {
        !reportMatrix.isEmpty && !running && !generating && !generatingReport
    }

    @ObservationIgnored let credentials: CredentialStore
    @ObservationIgnored private let store = AppStateStore()
    @ObservationIgnored private let engine = ScriptEngine()
    @ObservationIgnored private let rateLimit = RateLimitMonitor()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    /// In-flight validation, joinable: Run during the post-generation
    /// auto-validate waits for that result instead of silently bailing.
    @ObservationIgnored private var validationTask: Task<ValidatedScript?, Never>?
    /// Bumped per run; engine events carry the generation they belong to, so
    /// stragglers arriving after the final snapshot can't re-append stale rows
    /// or duplicate log lines.
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private let typescript = TypeScriptService.loadDefault()
    @ObservationIgnored private lazy var pipeline = ValidationPipeline(typescript: typescript)

    init(credentials: CredentialStore = KeychainCredentialStore()) {
        self.credentials = credentials
        var restoredJob = false
        if let snapshot = store.load() {
            settings = snapshot.settings
            if let job = snapshot.job {
                restoredJob = true
                phase = job.phase
                promptsByPhase = Self.byPhase(job.promptsByPhase)
                scriptsByPhase = Self.byPhase(job.scriptsByPhase)
                paramsByPhase = Self.byPhase(job.paramsByPhase)
                resultsByPhase = Self.byPhase(job.resultsByPhase)
                ranScriptByPhase = Self.byPhase(job.ranScriptByPhase)
                ranParamsByPhase = Self.byPhase(job.ranParamsByPhase)
                declaredParamsByPhase = Self.byPhase(job.declaredParamsByPhase)
                // Pre-per-phase saves: attribute the legacy single slots to
                // the job's phase.
                if scriptsByPhase.isEmpty { scriptsByPhase[job.phase] = job.scriptSource }
                if paramsByPhase.isEmpty { paramsByPhase[job.phase] = job.params }
                if promptsByPhase.isEmpty { promptsByPhase[job.phase] = job.prompt }
                if resultsByPhase.isEmpty, !job.results.isEmpty {
                    resultsByPhase[job.phase] = job.results
                    ranScriptByPhase[job.phase] = job.scriptSource
                }
                prompt = promptsByPhase[job.phase] ?? ""
                scriptText = scriptsByPhase[job.phase] ?? ""
                paramsDraft = paramsByPhase[job.phase] ?? [:]
                logs = job.logs
                auditEvents = job.auditEvents
                auditTrail = job.auditTrail ?? []
                report = job.report
                reportMarkdown = job.report?.markdown ?? ""
                jobState = job.state ?? [:]
                statusLine = job.lastRunStatus ?? "Restored previous job"
            }
        }
        userRecipes = recipeStore.load()
        // The catalog is built from files off the main actor; on a fresh launch
        // the golden recipe loads into the editor once it's ready.
        loadRecipeCatalog(loadGoldenWhenReady: !restoredJob)
    }

    private static func byPhase<T>(_ raw: [String: T]?) -> [JobPhase: T] {
        guard let raw else { return [:] }
        var mapped: [JobPhase: T] = [:]
        for (key, value) in raw {
            if let phase = JobPhase(rawValue: key) { mapped[phase] = value }
        }
        return mapped
    }

    private static func rawKeyed<T>(_ map: [JobPhase: T]) -> [String: T] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
    }

    var typeCheckingAvailable: Bool { typescript != nil }
    var typeCheckerLabel: String {
        guard typescript != nil else { return "Type-check unavailable" }
        if let version = typescript?.compilerVersion { return "TypeScript \(version)" }
        return "TypeScript ready"
    }

    /// Params shown in the editable strip.
    var visibleParamKeys: [String] {
        paramsDraft.keys.sorted()
    }

    var selectedResult: RepoResult? {
        guard let selectedRepo else { return nil }
        if let result = results.first(where: { $0.id == selectedRepo }) { return result }
        // The report phase is a view over the Find findings — it inspects the
        // selected repo's check evidence (and its extracted fields).
        if phase == .report {
            return resultsByPhase[.check]?.first { $0.id == selectedRepo }
        }
        return nil
    }

    /// The visible results were produced by a different script — or different
    /// params — than what's on screen now. Suppressed while generating or
    /// running.
    var resultsAreStale: Bool { staleReason != nil }

    /// What changed since the visible results were produced (nil = nothing).
    var staleReason: String? {
        guard !generating, !running,
              !results.isEmpty, let ran = ranScriptByPhase[phase] else { return nil }
        let scriptChanged = ran != scriptText
        let paramsChanged = ranParamsByPhase[phase].map { $0 != effectiveParams(for: phase) } ?? false
        switch (scriptChanged, paramsChanged) {
        case (true, true): return "The script and its parameters have changed since these results were produced — Run to refresh."
        case (true, false): return "The script has changed since these results were produced — Run to refresh."
        case (false, true): return "The parameters have changed since these results were produced — Run to refresh."
        case (false, false): return nil
        }
    }

    /// The params a run of `runPhase` would receive right now: the editable
    /// draft. Mirrored by runInternal.
    private func effectiveParams(for runPhase: JobPhase) -> [String: String] {
        paramsDraft
    }

    /// The script's own default for a param (nil when unknown — e.g. the
    /// script hasn't been validated since it changed).
    func declaredDefault(for key: String) -> String? {
        declaredParamsByPhase[phase]?[key]
    }

    /// Row count for the status footer.
    var visibleRowCount: Int {
        switch phase {
        case .check: return results.count
        // The report phase reads the Find run's findings (the matched repos).
        case .report: return matchedCount
        }
    }

    /// Switching between fixture data and live GitHub is switching WORLDS:
    /// results and carried state from the old world are meaningless in the new
    /// one. Workspaces — prompts, scripts, params — survive; they are
    /// world-independent.
    func dataSourceChanged() {
        guard !running else { return }
        resultsByPhase = [:]
        ranScriptByPhase = [:]
        ranParamsByPhase = [:]
        jobState = [:]
        selectedRepo = nil
        quotaText = nil
        logs = []
        auditEvents = []
        auditTrail = []
        report = nil
        reportMarkdown = ""
        statusLine = settings.useFixtureGitHub
            ? "Switched to fixture data — findings cleared, scripts kept"
            : "Switched to LIVE GitHub — findings cleared, scripts kept"
        saveNow()
    }

    // MARK: New job (File > New Job…, ⌘N)

    /// Drives the confirmation alert — New Job always confirms before
    /// discarding, since it wipes every phase's workspace and history.
    var showNewJobConfirmation = false

    func requestNewJob() {
        guard !running, !generating, !validating else { return }
        showNewJobConfirmation = true
    }

    /// Discard the entire job — every phase workspace, results, logs, the
    /// audit trail, and carried job state — leaving an empty workspace. (First
    /// launch loads the golden recipe for discoverability; New Job deliberately
    /// does not.) Settings and credentials survive. Reached only via
    /// requestNewJob's confirmation.
    func startNewJob() {
        guard !running, !generating else { return }
        wipeJobState()
        statusLine = "New job — describe what to find, or load a recipe"
        saveNow()
    }

    /// The shared in-memory wipe behind startNewJob: every phase workspace,
    /// results, logs, audit trail, and carried job state. Does not touch the
    /// status line, persistence, or settings — callers own those.
    private func wipeJobState() {
        phase = .check
        prompt = ""
        scriptText = ""
        paramsDraft = [:]
        jobState = [:]
        promptsByPhase = [:]
        scriptsByPhase = [:]
        paramsByPhase = [:]
        diagnostics = []
        resultsByPhase = [:]
        ranScriptByPhase = [:]
        ranParamsByPhase = [:]
        declaredParamsByPhase = [:]
        logs = []
        auditEvents = []
        auditTrail = []
        selectedRepo = nil
        quotaText = nil
        report = nil
        reportMarkdown = ""
        generatingReport = false
    }

    func clearResults() {
        resultsByPhase[phase] = []
        ranScriptByPhase[phase] = nil
        ranParamsByPhase[phase] = nil
        selectedRepo = nil
        statusLine = "Results cleared"
    }

    // MARK: Flow bar badges — what each stage has produced

    var matchedCount: Int {
        (resultsByPhase[.check] ?? []).filter { $0.status == .verifiedMatch }.count
    }

    /// Determinate run progress as (processed, total) when the current run has
    /// a known denominator, else nil (→ the indeterminate spinner). A Find scan
    /// gets it from the streamed candidate rows.
    var runProgress: (processed: Int, total: Int)? {
        guard running else { return nil }
        if runHadCandidates {
            let total = results.count
            guard total > 0 else { return nil }
            return (results.filter { $0.status != .candidate }.count, total)
        }
        // Find and Report runs don't have a determinate per-repo denominator
        // here (a scan is metered via runHadCandidates above; report generation
        // streams text).
        return nil
    }

    func setPhase(_ newPhase: JobPhase) {
        guard newPhase != phase, !running, !generating else { return }
        // Each phase is a separate workspace: prompt, script, and params swap
        // together.
        stashWorkspace()
        phase = newPhase
        restoreWorkspace()
        switch newPhase {
        case .check:
            statusLine = "Find phase — prompts generate read-only search scripts"
        case .report:
            statusLine = matchedCount > 0
                ? "Report phase — generate a report aggregating the \(matchedCount) finding(s) from Find"
                : "Report phase — run a Find first; its findings feed the report"
        }
    }

    private func stashWorkspace() {
        promptsByPhase[phase] = prompt
        scriptsByPhase[phase] = scriptText
        paramsByPhase[phase] = paramsDraft
    }

    private func restoreWorkspace() {
        prompt = promptsByPhase[phase] ?? ""
        scriptText = scriptsByPhase[phase] ?? ""
        paramsDraft = paramsByPhase[phase] ?? [:]
        diagnostics = []
    }

    func loadRecipe(_ recipe: Recipe) {
        guard !running, !generating else { return }
        let source = recipe.source
        if recipe.phase != phase {
            stashWorkspace()
            phase = recipe.phase
        }
        scriptText = source
        prompt = recipe.prompt
        promptsByPhase[recipe.phase] = recipe.prompt
        scriptsByPhase[recipe.phase] = source
        // The params belong to the script: a replaced script means a fresh
        // draft (and fresh declared defaults), not the previous script's
        // values lingering in the bar.
        paramsDraft = [:]
        paramsByPhase[recipe.phase] = [:]
        declaredParamsByPhase[recipe.phase] = nil
        diagnostics = []
        statusLine = "Loaded \"\(recipe.title)\""
        // Validate right away so the param bar repopulates from the recipe's
        // meta.params without waiting for a manual Check. Any in-flight
        // validation of the replaced script must fully drain first.
        Task { [weak self] in
            while let task = self?.validationTask {
                _ = await task.value
                await Task.yield()
            }
            await self?.validate()
        }
    }

    func loadRecipe(named name: String) {
        guard let recipe = recipes.first(where: { $0.id == name }) else { return }
        loadRecipe(recipe)
    }

    // MARK: Recipe catalog (bundled, built from files at launch)

    /// The bundled recipe catalog, built by reading each recipe file's meta at
    /// launch (off the main actor). Empty until the first load completes.
    private(set) var recipes: [Recipe] = []
    /// True while the initial catalog build is in flight — drives a brief
    /// "loading recipes" row so the empty library doesn't read as "no recipes".
    private(set) var recipesLoading = false
    @ObservationIgnored private lazy var recipeLoader = RecipeCatalogLoader(service: typescript)

    /// Build the bundled catalog off the main actor (transpile + meta read per
    /// file), then publish it. On a fresh launch (no restored job) load the
    /// golden recipe into the editor once the catalog is ready.
    private func loadRecipeCatalog(loadGoldenWhenReady: Bool) {
        recipesLoading = true
        let loader = recipeLoader
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { loader.load() }.value
            guard let self else { return }
            self.recipes = loaded
            self.recipesLoading = false
            if loadGoldenWhenReady, self.scriptText.isEmpty, !self.running, !self.generating {
                self.loadGoldenRecipe()
            }
        }
    }

    // MARK: User recipes (saved from the workspace, file-backed)

    @ObservationIgnored private let recipeStore = UserRecipeStore()
    private(set) var userRecipes: [UserRecipe] = []

    /// Drives the save-as-recipe name prompt; recipeNameDraft backs the
    /// rename prompt too.
    var showSaveRecipePrompt = false
    var recipeNameDraft = ""
    var renamingRecipe: UserRecipe?
    var deletingRecipe: UserRecipe?

    func requestSaveRecipe() {
        guard !scriptText.isEmpty else {
            statusLine = "Nothing to save — the editor is empty"
            return
        }
        recipeNameDraft = ""
        showSaveRecipePrompt = true
    }

    /// Capture the current workspace — prompt, script, phase — under the
    /// drafted name.
    func saveCurrentAsRecipe() {
        let title = recipeNameDraft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !scriptText.isEmpty else { return }
        do {
            try recipeStore.save(UserRecipe(title: title, prompt: prompt,
                                            phase: phase, source: scriptText))
            userRecipes = recipeStore.load()
            statusLine = "Saved recipe \"\(title)\""
        } catch {
            statusLine = "Could not save recipe: \(error.localizedDescription)"
        }
    }

    func renameRecipe(_ recipe: UserRecipe) {
        let title = recipeNameDraft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != recipe.title else { return }
        var renamed = recipe
        renamed.title = title
        do {
            try recipeStore.save(renamed)
            userRecipes = recipeStore.load()
            statusLine = "Renamed recipe to \"\(title)\""
        } catch {
            statusLine = "Could not rename recipe: \(error.localizedDescription)"
        }
    }

    func deleteRecipe(_ recipe: UserRecipe) {
        do {
            try recipeStore.delete(id: recipe.id)
            userRecipes = recipeStore.load()
            statusLine = "Deleted recipe \"\(recipe.title)\""
        } catch {
            statusLine = "Could not delete recipe: \(error.localizedDescription)"
        }
    }

    func loadGoldenRecipe() {
        loadRecipe(named: "find_waf_resources")
    }

    // MARK: Client selection

    @ObservationIgnored private lazy var fixtureClient = FixtureGitHubClient.demo()

    func githubClient() -> GitHubClient {
        if settings.useFixtureGitHub { return fixtureClient }
        let credentials = self.credentials
        return LiveGitHubClient(apiHost: settings.apiHost,
                                tokenProvider: { credentials.read(.githubToken) },
                                rateLimit: rateLimit)
    }

    private func refreshQuota() {
        quotaText = settings.useFixtureGitHub ? nil : rateLimit.display
    }

    func llmClient() -> LLMClient {
        if settings.useMockLLM { return MockLLMClient() }
        let credentials = self.credentials
        return AnthropicClient(model: settings.aiModel,
                               keyProvider: { credentials.read(.anthropicAPIKey) })
    }

    func reportClient() -> ReportClient {
        if settings.useMockLLM { return MockReportClient() }
        let credentials = self.credentials
        return AnthropicReportClient(model: settings.aiModel,
                                     keyProvider: { credentials.read(.anthropicAPIKey) })
    }

    // MARK: Actions

    func generate() {
        guard !generating, !prompt.isEmpty else { return }
        generating = true
        statusLine = "Requesting script… (model thinking)"
        let client = llmClient()
        let context = ScriptGenerationContext(organisation: settings.organisation, phase: phase)
        let promptText = prompt
        let previousScript = scriptText
        Task {
            // Stream the raw response, painting the in-progress script into
            // the editor as it is written; parse the assembled text at the end.
            var raw = ""
            do {
                for try await event in client.streamScript(prompt: promptText, context: context) {
                    guard case .delta(let chunk) = event else { continue }
                    raw += chunk
                    let live = PromptLibrary.liveScript(fromPartial: raw)
                    if !live.isEmpty { scriptText = live }
                    statusLine = "Writing script… \(raw.count) characters"
                }
                switch PromptLibrary.parseGeneration(from: raw) {
                case .script(let script) where !script.isEmpty:
                    scriptText = script
                    // A generated script replaces the old one wholesale, so
                    // its declared params must win.
                    paramsDraft = [:]
                    declaredParamsByPhase[phase] = nil
                    statusLine = "Script generated — review before running"
                    generating = false
                    await validate()
                case .script:
                    scriptText = previousScript
                    statusLine = "Generation produced no script"
                    generating = false
                case .capabilityGap(let report):
                    scriptText = capabilityGapScript(report)
                    surfaceCapabilityGap(report)
                    generating = false
                }
            } catch LLMClientError.capabilityGap(let report) {
                scriptText = capabilityGapScript(report)
                surfaceCapabilityGap(report)
                generating = false
            } catch {
                scriptText = previousScript
                statusLine = "Generation failed: \(error.localizedDescription)"
                generating = false
            }
        }
    }

    private func surfaceCapabilityGap(_ report: String) {
        statusLine = "Capability gap — the model needs host APIs we don't offer (details in console)"
        logs.append("◆ The model reports this request needs capabilities the host API does not provide:")
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            logs.append("  " + String(line))
        }
    }

    /// Renders a capability-gap report as a commented-out script so the error
    /// stays visible in the editor — where the user is looking — instead of
    /// being lost under a restored previous script. It is intentionally not
    /// runnable; the user revises the prompt and regenerates.
    private func capabilityGapScript(_ report: String) -> String {
        var lines = ["// ⚠︎ Capability gap — this request can't be fulfilled with the host APIs",
                     "// available. Revise the prompt and Generate again.",
                     "//"]
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(line.isEmpty ? "//" : "// " + String(line))
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    func validate() async -> ValidatedScript? {
        // Join an in-flight validation (e.g. the auto-validate right after
        // generation) instead of bailing with nil.
        if let task = validationTask { return await task.value }
        let task = Task { await performValidation() }
        validationTask = task
        let result = await task.value
        validationTask = nil
        return result
    }

    private func performValidation() async -> ValidatedScript? {
        validating = true
        defer { validating = false }
        statusLine = typeCheckingAvailable ? "Type-checking against bulkgh.d.ts…" : "Checking…"
        let source = scriptText
        let pipeline = self.pipeline
        do {
            let validated = try await Task.detached(priority: .userInitiated) {
                try pipeline.validate(source: source)
            }.value
            // The editor moved on mid-validation (recipe load, regenerate):
            // this result describes a script that is no longer on screen.
            guard source == scriptText else { return nil }
            diagnostics = validated.diagnostics
            var merged = validated.meta.params
            for (key, value) in paramsDraft where merged[key] != nil {
                merged[key] = value
            }
            paramsDraft = merged
            // A script declaring a different phase moves there WITH the
            // current buffer (no workspace swap): the script, prompt, and
            // params on screen belong to the declared phase now.
            phase = validated.meta.phase
            declaredParamsByPhase[validated.meta.phase] = validated.meta.params
            statusLine = "Valid — \(validated.meta.title)"
            return validated
        } catch let error as ValidationError {
            guard source == scriptText else { return nil }
            diagnostics = error.diagnostics
            statusLine = error.errorDescription ?? "Validation failed"
            return nil
        } catch {
            guard source == scriptText else { return nil }
            statusLine = "Validation failed: \(error.localizedDescription)"
            return nil
        }
    }

    func run() {
        guard !running, !generating else { return }
        runTask = Task { await runInternal() }
    }

    private func runInternal() async {
        guard let validated = await validate() else { return }
        running = true
        runHadCandidates = false
        defer { running = false }
        let runPhase = validated.meta.phase
        let runScript = scriptText
        // A fresh check starts a fresh funnel.
        if runPhase == .check {
            // The report was built from the findings this run replaces.
            report = nil
            reportMarkdown = ""
        }
        runGeneration += 1
        let generation = runGeneration
        resultsByPhase[runPhase] = []
        logs = []
        auditEvents = []
        statusLine = "Running…"
        let params = effectiveParams(for: runPhase)
        let configuration = EngineConfiguration(settings: settings)
        let outcome = await engine.run(javaScript: validated.javaScript,
                                       phase: runPhase,
                                       params: params,
                                       github: githubClient(),
                                       organisation: settings.organisation,
                                       configuration: configuration,
                                       initialState: jobState) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.runGeneration == generation else { return }
                self.handle(event, phase: runPhase)
            }
        }
        // Retire stragglers before installing the final snapshot — a late
        // event hopping onto the main actor afterwards would duplicate rows
        // or log lines.
        runGeneration += 1
        resultsByPhase[runPhase] = outcome.results
        ranScriptByPhase[runPhase] = runScript
        ranParamsByPhase[runPhase] = params
        logs = outcome.logs
        auditEvents = outcome.auditEvents
        // The cumulative trail: boundary event, then the run's events.
        auditTrail.append(AuditEvent(kind: "run", repo: nil,
                                     detail: "\(runPhase.displayName.lowercased()) (read-only, \(settings.useFixtureGitHub ? "fixture" : "live")) — \(outcome.status.label)"))
        auditTrail.append(contentsOf: outcome.auditEvents)
        if auditTrail.count > 5000 {
            auditTrail.removeFirst(auditTrail.count - 5000)
        }
        if !outcome.state.isEmpty {
            jobState.merge(outcome.state) { _, new in new }
        }
        refreshQuota()
        if let quotaText {
            logs.append("◆ GitHub \(quotaText) requests remaining")
        }
        let matched = outcome.results.filter { $0.status == .verifiedMatch }
        if selectedRepo == nil { selectedRepo = matched.first?.id }
        statusLine = "Run \(outcome.status.label)"
        saveNow()
    }

    func cancel() {
        runTask?.cancel()
        statusLine = "Cancelling…"
    }

    // MARK: Report generation (no sandboxed script — a view over Find results)

    /// Aggregate the Find run's findings into a report. Builds the deterministic
    /// field matrix, then streams a narrative over it from the report client
    /// (mock renders the matrix offline; Anthropic narrates it live). The matrix
    /// is the trusted backbone; the narrative is regenerable over the same
    /// findings without re-running Find.
    func generateReport() {
        guard canGenerateReport else {
            if reportMatrix.isEmpty {
                statusLine = "No findings with extracted fields yet — run a Find that extracts parameters first"
            }
            return
        }
        let matrix = reportMatrix
        let coverage = reportCoverage
        let basis = (promptsByPhase[.check] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let input = ReportInput(
            prompt: basis.isEmpty ? "Report on the findings across repositories." : basis,
            matrix: matrix, coverage: coverage)
        let client = reportClient()
        let usingMock = settings.useMockLLM
        let modelName = settings.aiModel.isEmpty ? AnthropicClient.defaultModel : settings.aiModel
        generatingReport = true
        reportMarkdown = ""
        report = nil
        statusLine = "Generating report…"
        reportTask = Task {
            var raw = ""
            do {
                for try await event in client.streamReport(input) {
                    guard case .delta(let chunk) = event else { continue }
                    raw += chunk
                    reportMarkdown = raw
                }
                report = Report(markdown: raw,
                                model: usingMock ? "mock (deterministic field matrix)" : modelName,
                                generatedAt: Date())
                reportMarkdown = raw
                statusLine = "Report generated — \(matrix.repoCount) repo(s) compared"
                generatingReport = false
                saveNow()
            } catch {
                statusLine = "Report generation failed: \(error.localizedDescription)"
                generatingReport = false
            }
        }
    }

    func cancelReport() {
        reportTask?.cancel()
        generatingReport = false
        statusLine = "Report generation cancelled"
    }

    private func handle(_ event: RunEvent, phase runPhase: JobPhase) {
        switch event {
        case .log(let line):
            logs.append(line)
        case .progress(let line):
            logs.append("▸ \(line)")
        case .repo(let result):
            if result.status == .candidate { runHadCandidates = true }
            var rows = resultsByPhase[runPhase] ?? []
            if let index = rows.firstIndex(where: { $0.id == result.id }) {
                rows[index] = result
            } else {
                rows.append(result)
            }
            resultsByPhase[runPhase] = rows
        case .audit(let event):
            auditEvents.append(event)
            refreshQuota()
        }
    }

    // MARK: Persistence

    func saveNow() {
        stashWorkspace()
        var job = Job(prompt: prompt, phase: phase)
        job.scriptSource = scriptText
        job.params = paramsDraft
        job.results = results
        job.resultsByPhase = Self.rawKeyed(resultsByPhase)
        job.ranScriptByPhase = Self.rawKeyed(ranScriptByPhase)
        job.ranParamsByPhase = Self.rawKeyed(ranParamsByPhase)
        job.declaredParamsByPhase = Self.rawKeyed(declaredParamsByPhase)
        job.scriptsByPhase = Self.rawKeyed(scriptsByPhase)
        job.paramsByPhase = Self.rawKeyed(paramsByPhase)
        job.logs = logs
        job.auditEvents = auditEvents
        job.auditTrail = auditTrail
        job.state = jobState
        job.promptsByPhase = Self.rawKeyed(promptsByPhase)
        job.report = report
        job.lastRunStatus = statusLine
        try? store.save(AppStateSnapshot(settings: settings, job: job))
    }
}
