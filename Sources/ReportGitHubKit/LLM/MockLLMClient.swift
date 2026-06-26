import Foundation

/// Offline script "generation": returns the golden recipe with params patched
/// from whatever the prompt obviously specifies. Deterministic, instant, and
/// good enough to exercise the whole validate→review→run loop without network.
public final class MockLLMClient: LLMClient, @unchecked Sendable {

    public init() {}

    public func makeScript(prompt: String, context: ScriptGenerationContext) async throws -> String {
        // The selected phase decides what kind of script comes back, exactly
        // like the real client's system prompt does; keywords only refine the
        // recipe choice within the check phase.
        switch context.phase {
        case .report:
            // The report phase generates no sandboxed script — it aggregates the
            // Find run's results via a ReportClient. Script generation is not a
            // report-phase action.
            throw LLMClientError.invalidResponse("the report phase does not generate scripts")
        case .check:
            // Custom-property report (GitHub org metadata, not files).
            if prompt.range(of: #"custom propert|repo(sitor[a-z]*)? propert|github propert"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
                return try customPropertiesScript(for: prompt)
            }
            // Named-object report ("an object named *Bucket … save the Properties").
            if prompt.range(of: #"object named|properties of the object"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
                return try namedObjectScript(for: prompt)
            }
            // Default: the CloudFormation-resource report.
            return try wafResourcesScript(for: prompt)
        }
    }

    private func customPropertiesScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "report_custom_properties") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        // "the <Name> property" / "property <Name>" → limit to that property.
        if let property = firstMatch(in: prompt, pattern: #"(?:the\s+)?["']?([A-Za-z][A-Za-z0-9_]*)["']?\s+property\b"#)
            ?? firstMatch(in: prompt, pattern: #"property\s+["']?([A-Za-z][A-Za-z0-9_]*)["']?"#) {
            script = Self.replaceParam(in: script, name: "property", value: property)
        }
        return script
    }

    private func namedObjectScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "find_named_object_properties") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        // "object named "*Bucket"" → namePattern; a "*.template" path → glob.
        if let pattern = firstMatch(in: prompt, pattern: #"named\s+["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "namePattern", value: pattern)
        }
        if let glob = firstMatch(in: prompt, pattern: #"([\w./*-]+\.template)"#) {
            script = Self.replaceParam(in: script, name: "glob", value: glob)
        }
        return script
    }

    private func wafResourcesScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "find_waf_resources") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        // Patch the CloudFormation resource type if the prompt names one
        // explicitly (e.g. "AWS::WAFv2::WebACL"); otherwise the WAF default holds.
        if let type = firstMatch(in: prompt, pattern: #"(AWS::[A-Za-z0-9]+::[A-Za-z0-9]+)"#) {
            script = Self.replaceParam(in: script, name: "resourceType", value: type)
        }
        return script
    }

    /// Fake-streams the patched recipe line by line so the offline demo
    /// exercises the same live-generation UI path as the real client.
    public func streamScript(prompt: String, context: ScriptGenerationContext)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let script = try await makeScript(prompt: prompt, context: context)
                    continuation.yield(.delta("```typescript\n"))
                    for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
                        try await Task.sleep(for: .milliseconds(12))
                        continuation.yield(.delta(String(line) + "\n"))
                    }
                    continuation.yield(.delta("```"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func reviseScript(_ script: String, prompt: String, diagnostics: [Diagnostic],
                             context: ScriptGenerationContext) async throws -> String {
        let summary = diagnostics.first.map { "\($0.line):\($0.column) \($0.message)" } ?? "no diagnostics"
        return "// mock revision (was: \(summary))\n" + script
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func replaceParam(in script: String, name: String, value: String) -> String {
        let pattern = "(\\b\(NSRegularExpression.escapedPattern(for: name)):\\s*\")[^\"]*(\")"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return script }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return regex.stringByReplacingMatches(in: script,
                                              range: NSRange(script.startIndex..., in: script),
                                              withTemplate: "$1\(escaped)$2")
    }
}
