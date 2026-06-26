import Foundation

/// Produces the Report-step narrative from a verified findings matrix. Sibling
/// of `LLMClient`: the mock renders the deterministic matrix offline (no model,
/// byte-stable); the Anthropic client narrates over the same matrix live.
public protocol ReportClient: Sendable {
    func makeReport(_ input: ReportInput) async throws -> Report
    /// Streaming generation, mirroring `LLMClient.streamScript`. The default
    /// runs `makeReport` and emits the whole markdown as one delta.
    func streamReport(_ input: ReportInput) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public extension ReportClient {
    func streamReport(_ input: ReportInput) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let report = try await makeReport(input)
                    continuation.yield(.delta(report.markdown))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Deterministic renderer

/// Renders a `ReportInput` into grounded Markdown using ONLY the deterministic
/// field matrix — no model, no guessing. Every figure traces to the matrix, so
/// this doubles as the offline mock's report, the at-scale fallback, and the
/// grounding anchor the live LLM's prose must not contradict.
public enum ReportRenderer {
    public static func markdown(for input: ReportInput) -> String {
        let m = input.matrix
        let c = input.coverage
        var out: [String] = []

        out.append("# Report")
        out.append("")
        out.append("> \(input.prompt.trimmingCharacters(in: .whitespacesAndNewlines))")
        out.append("")

        let coverageLine = "**\(c.matched) repositor\(c.matched == 1 ? "y" : "ies") matched** of \(c.examined) examined — \(c.noMatch) no match, \(c.skipped) skipped, \(c.failed) failed."
        out.append(coverageLine)
        out.append("")

        guard !m.isEmpty else {
            out.append("No verified matches carried structured fields, so there is nothing to compare.")
            return out.joined(separator: "\n")
        }

        // The comparison table itself is shown as the interactive matrix in the
        // app; the narrative covers what it means — similarities, differences,
        // and outliers across the \(m.repoCount) repos and \(m.columns.count) fields.

        // Similarities: fields every matched repo shares.
        let shared = m.columns.filter { $0.distinctValues == 1 && $0.coverage == m.repoCount }
        if !shared.isEmpty {
            out.append("## Similarities")
            out.append("")
            for column in shared {
                let value = column.distribution.first?.value ?? "—"
                out.append("- All \(m.repoCount) repos set `\(column.key)` to **\(value)**.")
            }
            out.append("")
        }

        // Differences: fields that vary, with their distribution.
        let varying = m.columns.filter { $0.distinctValues >= 2 || $0.coverage < m.repoCount }
        if !varying.isEmpty {
            out.append("## Differences")
            out.append("")
            for column in varying {
                let parts = column.distribution.map { group in
                    "\(group.value) (\(group.count): \(group.repos.map(shortRepo).joined(separator: ", ")))"
                }
                var line = "- `\(column.key)`: " + parts.joined(separator: "; ")
                if column.coverage < m.repoCount {
                    line += " — absent in \(m.repoCount - column.coverage) of \(m.repoCount)"
                }
                out.append(line)
            }
            out.append("")
        }

        // Outliers: a value held by exactly one repo for a varying field.
        if !m.outliers.isEmpty {
            out.append("## Outliers")
            out.append("")
            for outlier in m.outliers {
                out.append("- **\(shortRepo(outlier.repo))** is the only matched repo with `\(outlier.key)` = **\(outlier.value)**.")
            }
            out.append("")
        }

        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// "example-org/api-service" → "api-service" for compact tables.
    private static func shortRepo(_ fullName: String) -> String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }
}

// MARK: - Offline mock

/// Offline report "generation": renders the deterministic field matrix to
/// Markdown with no model. Byte-stable and golden-testable — the whole
/// find → fields → matrix → report loop runs with no credentials.
public final class MockReportClient: ReportClient, @unchecked Sendable {
    public init() {}

    public func makeReport(_ input: ReportInput) async throws -> Report {
        Report(markdown: ReportRenderer.markdown(for: input),
               model: "mock (deterministic field matrix)",
               generatedAt: Date())
    }

    /// Fake-stream the rendered report line by line, mirroring
    /// MockLLMClient.streamScript, so the offline demo drives the same UI path.
    public func streamReport(_ input: ReportInput) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let markdown = ReportRenderer.markdown(for: input)
                for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: .milliseconds(8))
                    continuation.yield(.delta(String(line) + "\n"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
