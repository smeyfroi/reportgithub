import Foundation
import Testing
@testable import ReportGitHubKit

/// The full Report loop on fixtures: the find/extract recipe verifies WAFv2
/// WebACL resources AND extracts their parameters into evidence.fields; the
/// deterministic FieldMatrix aggregates them; the MockReportClient renders a
/// grounded report — all offline, no credentials, byte-stable.
@Suite("WAF report end-to-end")
struct WafReportTests {

    private func runExtract() async throws -> RunOutcome {
        let recipe = try #require(ResourceLocator.recipe(named: "find_waf_resources"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(validated.meta.phase == .check)
        return await ScriptEngine().run(javaScript: validated.javaScript,
                                        phase: validated.meta.phase,
                                        params: validated.meta.params,
                                        github: FixtureGitHubClient.demo(),
                                        organisation: "example-org",
                                        onEvent: { _ in })
    }

    @Test("extract recipe verifies WebACLs and attaches receipt-gated fields")
    func extractEndToEnd() async throws {
        let outcome = try await runExtract()
        #expect(outcome.status == .completed)

        var byRepo: [String: RepoResult] = [:]
        for result in outcome.results { byRepo[result.id] = result }

        #expect(byRepo["example-org/api-service"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/web-frontend"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/data-pipeline"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/legacy-batch"]?.status == .skipped)   // archived
        #expect(byRepo["example-org/infra-tools"]?.status == .skipped)    // no template files
        #expect(byRepo["example-org/docs-site"]?.status == .skipped)      // no template files
        #expect(byRepo["example-org/flaky-service"]?.status == .failed)   // fetch error

        // Fields ride on the verified match's evidence (same receipt as excerpt).
        let apiFields = try #require(byRepo["example-org/api-service"]?.evidence.first?.fields)
        #expect(apiFields["Scope"] == .string("REGIONAL"))
        #expect(apiFields["DefaultAction"] == .string("Allow"))
        #expect(apiFields["RuleCount"] == .number(2))
        if case .array(let groups)? = apiFields["ManagedRuleGroups"] {
            #expect(groups.contains(.string("AWSManagedRulesCommonRuleSet")))
            #expect(groups.contains(.string("AWSManagedRulesKnownBadInputsRuleSet")))
        } else {
            Issue.record("expected ManagedRuleGroups to be an array of names")
        }

        // The audit trail names the fetched file and the extracted field keys.
        #expect(outcome.auditEvents.contains {
            $0.kind == "job.reportMatch" && $0.detail.contains("fields:")
        })

        // Reads go through the batched GraphQL path, not a getContent-per-repo
        // loop: exactly one gh.getContentBatch event, and no gh.getContent.
        #expect(outcome.auditEvents.contains { $0.kind == "gh.getContentBatch" })
        #expect(!outcome.auditEvents.contains { $0.kind == "gh.getContent" })
    }

    @Test("field matrix surfaces similarities, differences, and outliers")
    func matrixAndReport() async throws {
        let outcome = try await runExtract()
        let matrix = FieldMatrix.build(from: outcome.results)

        #expect(matrix.repoCount == 3)
        #expect(Set(matrix.columns.map(\.key)) == ["Scope", "DefaultAction", "ManagedRuleGroups", "RuleCount"])

        // Outliers: web-frontend is the CLOUDFRONT/Block one; data-pipeline has
        // a single rule. ManagedRuleGroups all differ, so it's a difference, not
        // a singled-out outlier (no shared majority value).
        let outliers = Set(matrix.outliers.map { "\($0.repo)|\($0.key)|\($0.value)" })
        #expect(outliers.contains("example-org/web-frontend|Scope|CLOUDFRONT"))
        #expect(outliers.contains("example-org/web-frontend|DefaultAction|Block"))
        #expect(outliers.contains("example-org/data-pipeline|RuleCount|1"))
        #expect(!matrix.outliers.contains { $0.key == "ManagedRuleGroups" })

        let coverage = ReportCoverage(results: outcome.results)
        #expect(coverage.matched == 3)
        #expect(coverage.examined == 7)

        let input = ReportInput(prompt: "WAF parameters in use", matrix: matrix, coverage: coverage)
        let report = try await MockReportClient().makeReport(input)
        #expect(report.markdown.contains("## Outliers"))
        #expect(report.markdown.contains("`Scope` = **CLOUDFRONT**"))
        #expect(report.markdown.contains("`RuleCount` = **1**"))
        #expect(report.markdown.contains("3 repositories matched"))
    }

    @Test("the flagship prompt routes through the mock LLM to the extract recipe")
    func mockRouting() async throws {
        let script = try await MockLLMClient().makeScript(
            prompt: "report on repos that define a WAF resource in cloudformation: give me the different parameters that are in use",
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(script.contains("AWS::WAFv2::WebACL"))
        #expect(ValidationPipeline.sniffPhase(from: script) == .check)
    }
}

/// The named-object starter recipe: find the first object under a template's
/// Resources whose name matches a glob (e.g. "*Bucket") and flatten its
/// properties into dotted-path fields for comparison.
@Suite("Named-object report end-to-end")
struct NamedObjectReportTests {

    private func runExtract() async throws -> RunOutcome {
        let recipe = try #require(ResourceLocator.recipe(named: "find_named_object_properties"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)
        return await ScriptEngine().run(javaScript: validated.javaScript,
                                        phase: validated.meta.phase,
                                        params: validated.meta.params,
                                        github: FixtureGitHubClient.demo(),
                                        organisation: "example-org",
                                        onEvent: { _ in })
    }

    @Test("flattens the matched object's properties into dotted-path fields")
    func extractEndToEnd() async throws {
        let outcome = try await runExtract()
        #expect(outcome.status == .completed)

        var byRepo: [String: RepoResult] = [:]
        for result in outcome.results { byRepo[result.id] = result }
        #expect(byRepo["example-org/api-service"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/web-frontend"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/data-pipeline"]?.status == .verifiedMatch)

        let webFields = try #require(byRepo["example-org/web-frontend"]?.evidence.first?.fields)
        #expect(webFields["ObjectName"] == .string("StaticBucket"))
        #expect(webFields["Type"] == .string("AWS::S3::Bucket"))
        #expect(webFields["Properties.AccessControl"] == .string("PublicRead"))
        #expect(webFields["Properties.VersioningConfiguration.Status"] == .string("Suspended"))
        #expect(byRepo["example-org/web-frontend"]?.evidence.first?.path == "deploy/storage.template")
    }

    @Test("matrix flags the access-control and versioning outliers")
    func matrix() async throws {
        let outcome = try await runExtract()
        let matrix = FieldMatrix.build(from: outcome.results)
        #expect(matrix.repoCount == 3)
        #expect(matrix.columns.map(\.key).contains("Properties.AccessControl"))
        #expect(matrix.columns.map(\.key).contains("Properties.VersioningConfiguration.Status"))

        let outliers = Set(matrix.outliers.map { "\($0.repo)|\($0.key)|\($0.value)" })
        #expect(outliers.contains("example-org/web-frontend|Properties.AccessControl|PublicRead"))
        #expect(outliers.contains("example-org/web-frontend|Properties.VersioningConfiguration.Status|Suspended"))
        // Type is shared by all three — a similarity, not an outlier.
        #expect(!matrix.outliers.contains { $0.key == "Type" })
    }

    @Test("the starter prompt routes through the mock LLM with params patched")
    func mockRouting() async throws {
        let script = try await MockLLMClient().makeScript(
            prompt: "Find repos where there is a file deploy/*.template that contains a yaml object named \"*Bucket\". save the Properties/Parameters of the object.",
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(script.contains("namePattern: \"*Bucket\""))
        #expect(script.contains("glob: \"deploy/*.template\""))
        #expect(ValidationPipeline.sniffPhase(from: script) == .check)
    }
}

/// The custom-properties report: reads GitHub org custom properties and emits
/// each repo's values as fields. A property read (not a file fetch) backs the
/// match — exercises the relaxed reportMatch provenance rule.
@Suite("Custom properties report end-to-end")
struct CustomPropertiesReportTests {

    private func runExtract() async throws -> RunOutcome {
        let recipe = try #require(ResourceLocator.recipe(named: "report_custom_properties"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)
        return await ScriptEngine().run(javaScript: validated.javaScript,
                                        phase: validated.meta.phase,
                                        params: validated.meta.params,
                                        github: FixtureGitHubClient.demo(),
                                        organisation: "example-org",
                                        onEvent: { _ in })
    }

    @Test("reports each repo's custom properties as fields, no file fetch")
    func extractEndToEnd() async throws {
        let outcome = try await runExtract()
        #expect(outcome.status == .completed)

        var byRepo: [String: RepoResult] = [:]
        for result in outcome.results { byRepo[result.id] = result }
        #expect(byRepo["example-org/api-service"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/web-frontend"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/data-pipeline"]?.status == .verifiedMatch)
        // Repos with no custom properties set are skipped (listOrgProperties is a
        // bulk read, so even the flaky repo merely has no properties here).
        #expect(byRepo["example-org/infra-tools"]?.status == .skipped)

        let web = try #require(byRepo["example-org/web-frontend"]?.evidence.first?.fields)
        #expect(web["ProjectType"] == .string("react"))
        #expect(web["Tier"] == .string("silver"))
        // The match is backed by the property read, not a fetched file.
        #expect(byRepo["example-org/web-frontend"]?.evidence.first?.path == "custom properties")

        // Reading properties earns the match — no gh.getContent anywhere.
        #expect(outcome.auditEvents.contains { $0.kind == "gh.listOrgProperties" })
        #expect(!outcome.auditEvents.contains { $0.kind == "gh.getContent" })
    }

    @Test("matrix flags the property outliers")
    func matrix() async throws {
        let outcome = try await runExtract()
        let matrix = FieldMatrix.build(from: outcome.results)
        #expect(matrix.repoCount == 3)
        let outliers = Set(matrix.outliers.map { "\($0.repo)|\($0.key)|\($0.value)" })
        #expect(outliers.contains("example-org/web-frontend|ProjectType|react"))
        #expect(outliers.contains("example-org/web-frontend|Tier|silver"))
    }

    @Test("the prompt routes through the mock LLM to the property recipe")
    func mockRouting() async throws {
        let script = try await MockLLMClient().makeScript(
            prompt: "report on the GitHub custom properties set across the organisation's repositories",
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(script.contains("listOrgProperties"))
        #expect(ValidationPipeline.sniffPhase(from: script) == .check)
    }
}
