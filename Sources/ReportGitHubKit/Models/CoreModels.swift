import Foundation

// MARK: - Repositories and pull requests

public struct RepoRef: Codable, Hashable, Sendable, Identifiable {
    public var fullName: String
    public var name: String
    public var defaultBranch: String
    public var archived: Bool
    public var isPrivate: Bool

    public var id: String { fullName }

    public init(fullName: String, name: String? = nil, defaultBranch: String = "main",
                archived: Bool = false, isPrivate: Bool = true) {
        self.fullName = fullName
        self.name = name ?? fullName.split(separator: "/").last.map(String.init) ?? fullName
        self.defaultBranch = defaultBranch
        self.archived = archived
        self.isPrivate = isPrivate
    }

    /// Shape exposed to scripts (matches the `Repo` interface in bulkgh.d.ts).
    public var scriptValue: [String: Any] {
        ["fullName": fullName, "name": name, "defaultBranch": defaultBranch,
         "archived": archived, "private": isPrivate]
    }
}

public struct PullRequestRef: Codable, Hashable, Sendable {
    public var repo: String
    public var number: Int
    public var headRef: String
    public var headSha: String
    /// The squash-merge commit on the base branch once merged (else nil) —
    /// distinct from headSha (the source-branch tip). Lets a merge confirmed
    /// after a transient error report the real merge commit. Optional for
    /// backward-compatible decoding of previously-persisted refs.
    public var mergeCommitSha: String?
    public var state: String // "open" | "closed" | "merged"
    public var url: String

    public init(repo: String, number: Int, headRef: String, headSha: String,
                state: String, url: String, mergeCommitSha: String? = nil) {
        self.repo = repo
        self.number = number
        self.headRef = headRef
        self.headSha = headSha
        self.state = state
        self.url = url
        self.mergeCommitSha = mergeCommitSha
    }

    public var scriptValue: [String: Any] {
        ["repo": repo, "number": number, "headRef": headRef, "headSha": headSha,
         "state": state, "url": url]
    }
}

// MARK: - Repository custom properties

/// One custom-property value. GitHub custom properties are name/value metadata
/// defined at the organisation level; a value is free-text/single-select
/// (`string`), multi-select (`list`), or unset (`null`). True/false properties
/// arrive as the strings "true"/"false" and ride in `.string`.
public enum PropertyValue: Codable, Hashable, Sendable {
    case string(String)
    case list([String])
    case null

    /// Shape exposed to scripts: a JS string, array of strings, or null.
    public var scriptValue: Any {
        switch self {
        case .string(let s): return s
        case .list(let a): return a
        case .null: return NSNull()
        }
    }

    /// Human-readable form for tables and the report.
    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .list(let a): return "[" + a.joined(separator: ", ") + "]"
        case .null: return "(unset)"
        }
    }
}

/// An organisation custom-property definition — the schema for a value.
public struct PropertyDef: Codable, Hashable, Sendable {
    public var name: String
    /// "string" | "single_select" | "multi_select" | "true_false".
    public var valueType: String
    /// Permitted values for single/multi-select properties; nil for free-text.
    public var allowedValues: [String]?

    public init(name: String, valueType: String, allowedValues: [String]? = nil) {
        self.name = name
        self.valueType = valueType
        self.allowedValues = allowedValues
    }

    public var scriptValue: [String: Any] {
        ["name": name, "valueType": valueType,
         "allowedValues": allowedValues ?? NSNull()]
    }
}

/// A repository paired with its custom-property values — the unit returned by
/// the authoritative org-wide bulk read that powers property queries.
public struct RepoProperties: Sendable {
    public let repo: RepoRef
    public let properties: [String: PropertyValue]

    public init(repo: RepoRef, properties: [String: PropertyValue]) {
        self.repo = repo
        self.properties = properties
    }
}

// MARK: - Results

public enum RepoStatus: String, Codable, Sendable, CaseIterable {
    case candidate
    /// Examined during the run but nothing was reported: distinguishes "we
    /// looked and found nothing" from "still being examined" (candidate).
    case noMatch = "no match"
    case verifiedMatch = "verified match"
    case skipped
    case failed

    /// Stable ordinal for sorting tables by status — declaration order tracks
    /// the funnel/lifecycle (candidate → match → resolved).
    public var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A small any-JSON value: the structured datapoints a find/extract script
/// attaches to a verified match via `reportMatch`'s `evidence.fields`. Values
/// are scalars or arrays of scalars — nested config is flattened by the script
/// to dotted-path keys (e.g. "Resources.WebACL.Properties.Scope"), which keeps
/// the report's comparison matrix a clean union of columns. Encodes/decodes as
/// natural JSON so it round-trips through persistence and the report input.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Double: JSONDecoder is strict, so a JSON number won't
        // decode as Bool and a JSON bool won't decode as Double.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        throw DecodingError.dataCorruptedError(in: c,
            debugDescription: "unsupported JSON value for a finding field")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        }
    }

    /// A stable, human-readable rendering for the comparison matrix and report.
    /// Arrays render as a comma-separated list; whole numbers drop the decimal.
    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .null: return "—"
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .array(let a): return a.map(\.displayString).joined(separator: ", ")
        }
    }
}

public struct Evidence: Codable, Hashable, Sendable {
    public var path: String
    public var excerpt: String
    public var explanation: String?
    /// Structured, comparison-ready values extracted from THIS file by a
    /// find/extract script, supplied on `reportMatch`'s evidence. Nil for plain
    /// matches. Backed by the SAME receipt as the excerpt — the host refuses
    /// fields whose path was never fetched this run. This is the channel the
    /// Report step aggregates over (the FieldMatrix); the LLM never parses
    /// files, only arranges these already-verified values.
    public var fields: [String: JSONValue]?
    /// Surrounding lines from the fetched file, captured by the host when the
    /// script reports a match — the script only supplies the excerpt.
    public var context: String?
    /// 1-based line number of the first context line, for display.
    public var contextStartLine: Int?
    /// Absolute 1-based file line numbers the host located as the match. The
    /// UI highlights exactly these — it does no matching of its own. Empty when
    /// the match has no single line to point at (see `noSpecificLine`).
    /// Optional so previously-persisted results (which lack the key) still
    /// decode; treat nil as "none".
    public var matchLines: [Int]?
    /// True when the match isn't pinned to specific lines — e.g. the script
    /// reported the whole file, or the excerpt couldn't be located in it. The
    /// UI then shows context without highlighting and captions why. Optional
    /// for backward-compatible decoding; treat nil as false.
    public var noSpecificLine: Bool?

    public init(path: String, excerpt: String, explanation: String? = nil,
                fields: [String: JSONValue]? = nil,
                context: String? = nil, contextStartLine: Int? = nil,
                matchLines: [Int]? = nil, noSpecificLine: Bool? = nil) {
        self.path = path
        self.excerpt = excerpt
        self.explanation = explanation
        self.fields = fields
        self.context = context
        self.contextStartLine = contextStartLine
        self.matchLines = matchLines
        self.noSpecificLine = noSpecificLine
    }
}

public struct RepoResult: Codable, Hashable, Sendable, Identifiable {
    public var repo: RepoRef
    public var status: RepoStatus
    public var reason: String?
    public var evidence: [Evidence]

    public var id: String { repo.fullName }

    public init(repo: RepoRef, status: RepoStatus, reason: String? = nil, evidence: [Evidence] = []) {
        self.repo = repo
        self.status = status
        self.reason = reason
        self.evidence = evidence
    }
}

// MARK: - Jobs

public enum JobPhase: String, Codable, Sendable, CaseIterable {
    case check
    /// ReportGitHub: aggregates the Find run's verified findings into a report.
    /// Unlike the check phase, the report phase runs NO sandboxed script — it is
    /// a view over the check results (the find/extract script populated their
    /// evidence.fields), so its "run" generates a report rather than executing.
    case report

    /// User-facing phase name. The contract keeps the rawValues ("check",
    /// "report") stable — meta.phase in scripts, persistence keys, and the LLM
    /// prompt all use them — but the UI names the phases differently.
    public var displayName: String {
        switch self {
        case .check: return "Find"
        case .report: return "Report"
        }
    }
}

public struct AuditEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var kind: String   // e.g. "gh.searchCode", "gh.getContent", "job.reportMatch"
    public var repo: String?
    public var detail: String

    public init(kind: String, repo: String? = nil, detail: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.repo = repo
        self.detail = detail
    }
}

public struct Job: Codable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var prompt: String
    public var phase: JobPhase
    public var scriptSource: String
    public var params: [String: String]
    public var results: [RepoResult]
    public var logs: [String]
    public var auditEvents: [AuditEvent]
    public var lastRunStatus: String?
    /// Cross-phase job state (writeState/readState), JSON-encoded per key.
    public var state: [String: String]?
    /// Prompt per phase — switching phases must not carry prompts across.
    public var promptsByPhase: [String: String]?
    /// Results per phase (keyed by JobPhase rawValue). `results` remains the
    /// legacy single list.
    public var resultsByPhase: [String: [RepoResult]]?
    /// The script source each phase's results were produced by, for staleness
    /// detection after the script is regenerated or edited.
    public var ranScriptByPhase: [String: String]?
    /// The effective params each phase's results were produced with — param
    /// edits stale results just like source edits.
    public var ranParamsByPhase: [String: [String: String]]?
    /// The meta.params defaults captured at validation, so the params bar
    /// can mark edited values across relaunches.
    public var declaredParamsByPhase: [String: [String: String]]?
    /// Each phase is a separate workspace: its own script and params, like
    /// promptsByPhase. `scriptSource`/`params` remain the legacy single slots.
    public var scriptsByPhase: [String: String]?
    public var paramsByPhase: [String: [String: String]]?
    /// Cumulative audit trail across ALL of this job's runs (capped), with a
    /// synthetic "run" event marking each run boundary. `auditEvents` remains
    /// the last run only.
    public var auditTrail: [AuditEvent]?
    /// The generated report (ReportGitHub) — the narrative over the Find run's
    /// findings, persisted with the model and timestamp that produced it. The
    /// deterministic field matrix is re-derived from the check results, so only
    /// the narrative needs storing. Optional for backward-compatible decoding.
    public var report: Report?

    public init(prompt: String = "", phase: JobPhase = .check, scriptSource: String = "",
                params: [String: String] = [:]) {
        self.id = UUID()
        self.createdAt = Date()
        self.prompt = prompt
        self.phase = phase
        self.scriptSource = scriptSource
        self.params = params
        self.results = []
        self.logs = []
        self.auditEvents = []
        self.lastRunStatus = nil
    }
}

// MARK: - Script metadata and validation

public struct ScriptMeta: Sendable, Equatable {
    public var title: String
    public var phase: JobPhase
    public var params: [String: String]
    public var apiVersion: Int
    /// One-line natural-language description (the prompt that would generate
    /// this recipe). Optional so existing/in-flight scripts stay valid; the
    /// recipe catalog uses it as the library subtitle.
    public var prompt: String?
    /// SF Symbol name for the recipe-library icon. Optional; the loader
    /// supplies a per-phase default when absent.
    public var icon: String?

    public init(title: String = "Untitled", phase: JobPhase = .check,
                params: [String: String] = [:], apiVersion: Int = 1,
                prompt: String? = nil, icon: String? = nil) {
        self.title = title
        self.phase = phase
        self.params = params
        self.apiVersion = apiVersion
        self.prompt = prompt
        self.icon = icon
    }
}

public struct Diagnostic: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable { case error, warning, info }
    public var severity: Severity
    public var message: String
    public var line: Int      // 1-based; 0 = whole file
    public var column: Int
    public var code: Int?

    public var id: String { "\(line):\(column):\(code ?? 0):\(message)" }

    public init(severity: Severity, message: String, line: Int = 0, column: Int = 0, code: Int? = nil) {
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
        self.code = code
    }
}

// MARK: - Engine run types

public enum RunEvent: Sendable {
    case log(String)
    case progress(String)
    case repo(RepoResult)
    case audit(AuditEvent)
}

public enum RunStatus: Sendable, Equatable {
    case completed
    case failed(String)
    case cancelled

    public var label: String {
        switch self {
        case .completed: return "completed"
        case .failed(let m): return "failed: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}

public struct RunOutcome: Sendable {
    public let status: RunStatus
    public let results: [RepoResult]
    public let logs: [String]
    public let auditEvents: [AuditEvent]
    /// job.writeState values, JSON-encoded per key — the find script's
    /// writeState/readState round-trips through this (read-only across runs).
    public let state: [String: String]
    public let duration: TimeInterval
}

// MARK: - Settings

public struct AppSettings: Codable, Sendable, Equatable {
    public var organisation: String = "example-org"
    public var webHost: String = "https://github.com"
    public var apiHost: String = "https://api.github.com"
    public var aiModel: String = ""        // empty = client default
    // Fresh installs default to LIVE — both the model and GitHub. A returning
    // user's saved choices in state.json still win; these defaults only apply
    // when no snapshot exists.
    public var useMockLLM: Bool = false
    public var useFixtureGitHub: Bool = false
    public var maxConcurrentOps: Int = 8
    public var syncSliceSeconds: Double = 2.0
    public var maxSyncBudgetSeconds: Double = 60.0
    public var maxRunSeconds: Double = 900

    public init() {}
}
