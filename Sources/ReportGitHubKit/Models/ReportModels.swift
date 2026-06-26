import Foundation

// MARK: - Field matrix (the deterministic comparison backbone)

/// The deterministic aggregate at the heart of the Report step: a union-keyed
/// comparison table built in pure Swift from the verified findings, with zero
/// tokens and independent of any LLM. It is the report's quantitative truth —
/// which repos hold which values, the distribution per field, and the
/// outliers — the offline mock report, and the at-scale degradation path. The
/// LLM only ever narrates over this; it never recomputes the numbers.
public struct FieldMatrix: Codable, Hashable, Sendable {
    /// One field (column) seen across the findings.
    public struct Column: Codable, Hashable, Sendable, Identifiable {
        public var key: String
        /// Repos carrying this field (≤ repoCount — fields are ragged).
        public var coverage: Int
        /// Distinct display values seen for this field.
        public var distinctValues: Int
        /// value → repo fullNames holding it, sorted by frequency then value.
        public var distribution: [ValueGroup]
        public var id: String { key }
    }

    public struct ValueGroup: Codable, Hashable, Sendable, Identifiable {
        public var value: String
        public var repos: [String]
        public var count: Int { repos.count }
        public var id: String { value }
    }

    /// One repository (row) and its display values per field key.
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var repo: String
        public var cells: [String: String]
        public var id: String { repo }
    }

    /// A value held by only one repo for a field that varies — the report's
    /// "outlier" callout. Grounded: every outlier names a real repo and field.
    public struct Outlier: Codable, Hashable, Sendable, Identifiable {
        public var repo: String
        public var key: String
        public var value: String
        public var id: String { "\(repo)|\(key)" }
    }

    public var columns: [Column]
    public var rows: [Row]
    public var repoCount: Int
    public var outliers: [Outlier]

    public var isEmpty: Bool { rows.isEmpty }

    /// Build the matrix from a run's results — verified matches only. Fully
    /// deterministic: column order is by coverage (desc) then key; value groups
    /// by frequency (desc) then value; repo lists and outliers sorted. Row
    /// order follows the results order (run order).
    public static func build(from results: [RepoResult]) -> FieldMatrix {
        let matched = results.filter { $0.status == .verifiedMatch }

        // Union each repo's fields (across its evidence) into one cell map.
        var rowOrder: [String] = []
        var fieldsByRepo: [String: [String: JSONValue]] = [:]
        for result in matched {
            let repo = result.repo.fullName
            if fieldsByRepo[repo] == nil { rowOrder.append(repo); fieldsByRepo[repo] = [:] }
            for evidence in result.evidence {
                guard let fields = evidence.fields else { continue }
                for (key, value) in fields where fieldsByRepo[repo]?[key] == nil {
                    fieldsByRepo[repo]?[key] = value
                }
            }
        }

        let rows: [Row] = rowOrder.map { repo in
            let cells = (fieldsByRepo[repo] ?? [:]).mapValues(\.displayString)
            return Row(repo: repo, cells: cells)
        }

        // Columns: union of keys with per-value repo distributions.
        var reposByValueByKey: [String: [String: [String]]] = [:]
        for row in rows {
            for (key, value) in row.cells {
                reposByValueByKey[key, default: [:]][value, default: []].append(row.repo)
            }
        }
        let columns: [Column] = reposByValueByKey.map { key, valueRepos in
            let groups = valueRepos
                .map { ValueGroup(value: $0.key, repos: $0.value.sorted()) }
                .sorted { lhs, rhs in
                    lhs.count != rhs.count ? lhs.count > rhs.count : lhs.value < rhs.value
                }
            let coverage = groups.reduce(0) { $0 + $1.count }
            return Column(key: key, coverage: coverage,
                          distinctValues: groups.count, distribution: groups)
        }
        .sorted { lhs, rhs in
            lhs.coverage != rhs.coverage ? lhs.coverage > rhs.coverage : lhs.key < rhs.key
        }

        // Outliers: for a broadly-covered field (≥3 repos) where most repos
        // agree — there's a shared majority/plurality value (count ≥ 2) — a
        // value held by exactly ONE repo stands out. A field where every repo
        // differs has no shared baseline, so it's a "difference", not an
        // outlier, and isn't flagged here.
        var outliers: [Outlier] = []
        for column in columns
        where column.coverage >= 3 && column.distribution.contains(where: { $0.count >= 2 }) {
            for group in column.distribution where group.count == 1 {
                outliers.append(Outlier(repo: group.repos[0], key: column.key, value: group.value))
            }
        }
        outliers.sort { $0.key != $1.key ? $0.key < $1.key : $0.repo < $1.repo }

        return FieldMatrix(columns: columns, rows: rows, repoCount: rows.count, outliers: outliers)
    }
}

// MARK: - Report input / output

/// How many repos the find run examined and what became of them — context the
/// report leads with so coverage is never silently dropped.
public struct ReportCoverage: Codable, Hashable, Sendable {
    public var matched: Int
    public var skipped: Int
    public var failed: Int
    public var noMatch: Int

    public init(matched: Int = 0, skipped: Int = 0, failed: Int = 0, noMatch: Int = 0) {
        self.matched = matched; self.skipped = skipped; self.failed = failed; self.noMatch = noMatch
    }

    public init(results: [RepoResult]) {
        self.init()
        for result in results {
            switch result.status {
            case .verifiedMatch: matched += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            case .noMatch: noMatch += 1
            default: break
            }
        }
    }

    public var examined: Int { matched + skipped + failed + noMatch }
}

/// Everything the report generator receives. The deterministic `matrix` is the
/// trusted substrate; `prompt` is the user's question; `coverage` frames it.
/// No raw file content — the LLM never parses files, only narrates the matrix.
public struct ReportInput: Sendable {
    public var prompt: String
    public var matrix: FieldMatrix
    public var coverage: ReportCoverage

    public init(prompt: String, matrix: FieldMatrix, coverage: ReportCoverage) {
        self.prompt = prompt
        self.matrix = matrix
        self.coverage = coverage
    }
}

/// A generated report: the markdown narrative plus provenance for audit and
/// reproducibility (which model produced it, and from what).
public struct Report: Codable, Hashable, Sendable {
    public var markdown: String
    public var model: String
    public var generatedAt: Date

    public init(markdown: String, model: String, generatedAt: Date) {
        self.markdown = markdown
        self.model = model
        self.generatedAt = generatedAt
    }
}
