import Foundation

/// In-memory GitHub client for offline development and tests.
/// Behaviour is fully deterministic: canned repos, file contents keyed by
/// repo/path, canned search results, and per-repo error injection.
public final class FixtureGitHubClient: GitHubClient, @unchecked Sendable {
    public var repos: [RepoRef]
    /// fullName -> path -> content
    public var contents: [String: [String: String]]
    /// Returned for any code search query.
    public var searchResults: [RepoRef]
    /// fullName -> error message thrown from getContent
    public var errorInjections: [String: String]
    /// Artificial latency per call, for cancellation tests and UI realism.
    public var delay: Duration
    /// The org's custom-property definitions (schema + allowed values).
    public var propertyDefs: [PropertyDef]
    /// fullName -> property name -> value.
    public var customProperties: [String: [String: PropertyValue]]

    private let lock = NSLock()
    private var _callLog: [String] = []
    public var callLog: [String] {
        lock.lock(); defer { lock.unlock() }
        return _callLog
    }

    public init(repos: [RepoRef] = [],
                contents: [String: [String: String]] = [:],
                searchResults: [RepoRef] = [],
                errorInjections: [String: String] = [:],
                customProperties: [String: [String: PropertyValue]] = [:],
                propertyDefs: [PropertyDef] = [],
                delay: Duration = .zero) {
        self.repos = repos
        self.contents = contents
        self.searchResults = searchResults
        self.errorInjections = errorInjections
        self.customProperties = customProperties
        self.propertyDefs = propertyDefs
        self.delay = delay
    }

    // MARK: Custom properties (read-only)

    public func listOrgProperties(org: String) async throws -> [RepoProperties] {
        record("listOrgProperties(\(org))")
        try await pause()
        return repos.map { RepoProperties(repo: $0, properties: customProperties[$0.fullName] ?? [:]) }
    }

    public func getProperties(repo: String) async throws -> [String: PropertyValue] {
        record("getProperties(\(repo))")
        try await pause()
        guard repos.contains(where: { $0.fullName == repo }) else {
            throw GitHubClientError.notFound("repository \(repo)")
        }
        return customProperties[repo] ?? [:]
    }

    public func listPropertyDefs(org: String) async throws -> [PropertyDef] {
        record("listPropertyDefs(\(org))")
        try await pause()
        return propertyDefs
    }

    private func record(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        _callLog.append(call)
    }

    private func pause() async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
    }

    public func listOrgRepos(org: String) async throws -> [RepoRef] {
        record("listOrgRepos(\(org))")
        try await pause()
        return repos
    }

    public func searchCode(org: String, query: String) async throws -> [RepoRef] {
        record("searchCode(\(query))")
        try await pause()
        return searchResults
    }

    public func getRepo(fullName: String) async throws -> RepoRef {
        record("getRepo(\(fullName))")
        try await pause()
        guard let repo = repos.first(where: { $0.fullName == fullName }) else {
            throw GitHubClientError.notFound("repository \(fullName)")
        }
        return repo
    }

    public func getContent(repo: String, path: String, ref: String?) async throws -> String? {
        record("getContent(\(repo), \(path))")
        try await pause()
        if let message = errorInjections[repo] {
            throw GitHubClientError.network(message)
        }
        guard let files = contents[repo] else {
            throw GitHubClientError.notFound("repository \(repo)")
        }
        return files[path]
    }

    public func listFiles(repo: String, ref: String?) async throws -> [String] {
        record("listFiles(\(repo))")
        try await pause()
        if let message = errorInjections[repo] {
            throw GitHubClientError.network(message)
        }
        guard let files = contents[repo] else {
            throw GitHubClientError.notFound("repository \(repo)")
        }
        return files.keys.sorted()
    }

    public func getRef(repo: String, ref: String) async throws -> String? {
        record("getRef(\(repo), \(ref))")
        try await pause()
        guard repos.contains(where: { $0.fullName == repo }) else { return nil }
        // Only default branches exist.
        if ref.hasPrefix("heads/") {
            let name = String(ref.dropFirst("heads/".count))
            if let repoRef = repos.first(where: { $0.fullName == repo }),
               name != repoRef.defaultBranch {
                return nil
            }
        }
        return Self.fakeSha("\(repo)#\(ref)")
    }

    public func listPRs(repo: String, head: String?, state: String) async throws -> [PullRequestRef] {
        record("listPRs(\(repo))")
        try await pause()
        return []
    }

    /// Deterministic fake SHA derived from inputs.
    private static func fakeSha(_ basis: String) -> String {
        let sha = basis.unicodeScalars.reduce(into: UInt64(5381)) { $0 = ($0 << 5) &+ $0 &+ UInt64($1.value) }
        return String(format: "%016llx%016llx", sha, ~sha)
    }

    public func searchPRs(org: String, query: String) async throws -> [PullRequestRef] {
        record("searchPRs(\(query))")
        try await pause()
        return []
    }
}

extension FixtureGitHubClient {
    /// The demo dataset used by the app's fixture mode and the golden recipe test.
    /// Exercises every interesting path of a check script: clean matches, a
    /// value mismatch, an archived repo, a stale search hit whose file is gone,
    /// and a repo where content fetch fails.
    public static func demo() -> FixtureGitHubClient {
        let api = RepoRef(fullName: "example-org/api-service")
        let web = RepoRef(fullName: "example-org/web-frontend")
        let pipeline = RepoRef(fullName: "example-org/data-pipeline", defaultBranch: "master")
        let legacy = RepoRef(fullName: "example-org/legacy-batch", archived: true)
        let infra = RepoRef(fullName: "example-org/infra-tools")
        let flaky = RepoRef(fullName: "example-org/flaky-service")
        let docs = RepoRef(fullName: "example-org/docs-site", isPrivate: false)

        let matchingYAML = """
        # production deployment
        account_id: "481832923858"
        region: eu-west-1
        stack: production
        """

        let differingYAML = """
        account_id: "999911112222"
        region: eu-west-1
        stack: production
        """

        // The deploy-key worked example (plan v2): the string to find — and
        // delete line-wise — appears once in YAML and once in JSON with the
        // key-value pair LAST in its object, so the deletion must also strip
        // the trailing comma on the line above.
        let deployKeyYAML = """
        region: eu-west-1
        deployKey: legacy-deploy-key-2019
        instanceType: m5.large
        """

        let deployKeyJSON = """
        {
          "stack": "web-frontend",
          "region": "eu-west-1",
          "deployKey": "legacy-deploy-key-2019"
        }
        """

        // The README/license worked example (the golden recipe pair): one
        // README already carries the section (skip), several lack it
        // (matches — including the master-default repo), one repo has no
        // README at all (skip), and the flaky repo's fetch fails.
        let licensedREADME = """
        # api-service

        Internal service.

        # License

        MIT
        """

        // The project.json key/value scenario (Find YAML key/value recipe):
        // two rails projects (matches), one react (value differs), the rest
        // have no project.json.
        let railsProject = """
        {
          "name": "service",
          "type": "rails"
        }
        """
        let reactProject = """
        {
          "name": "web-frontend",
          "type": "react"
        }
        """

        // The glob key/value scenario (Find YAML key/value under path glob):
        // RetentionInDays matches in api (top-level) and pipeline (nested in
        // a CloudFormation .template with custom tags — the real-world
        // shape), differs in web, absent elsewhere.
        let retention14 = """
        logGroup: app
        RetentionInDays: 14
        """
        let retention30 = """
        logGroup: web
        RetentionInDays: 30
        """
        let cloudFormationTemplate = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          LogGroup:
            Type: AWS::Logs::LogGroup
            Properties:
              RetentionInDays: 14
              LogGroupName: "/example-org/data-pipeline"
            DeletionPolicy: RetainExceptOnCreate
          # >>> PG14 TO BE DELETED
          OldParameterGroup:
            Type: AWS::RDS::DBClusterParameterGroup
            Properties:
              Description: Optimised postgres14 parameter group
              Family: aurora-postgresql14
          # <<< PG14 TO BE DELETED
          PipelineDomain:
            Type: AWS::Route53::RecordSet
            Properties:
              Name: data-pipeline.example.com
              ResourceRecords:
              - !GetAtt
                - PipelineCluster
                - Endpoint.Address
              Type: CNAME
              TTL: 300
        """

        // The marker-block scenario (Delete lines between marker text): the
        // recipe's default glob is deploy/*.template, hitting the annotated
        // PG14 block in pipeline's CloudFormation template. The yml marker
        // blocks in api and web sit outside that glob — they're there for
        // widening the glob param to deploy/** and catching more.
        let markedCron = """
        jobs:
          # >>>
          - legacy_export
          # <<<
          - daily_report
        """
        let markedMaintenance = """
        window: nightly
        # >>>
        drainQueues: true
        # <<<
        notify: ops
        """

        // The WAF report scenario (find_waf_resources recipe): three repos
        // define an AWS::WAFv2::WebACL with deliberate overlap and divergence —
        // api & pipeline are REGIONAL/Allow, web is the CLOUDFRONT/Block
        // outlier; pipeline carries a single managed rule group (a RuleCount
        // outlier), and each repo's managed-rule-group set differs. infra/docs
        // have no template (no match), legacy is archived (skip), flaky errors.
        let wafApi = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          WebACL:
            Type: AWS::WAFv2::WebACL
            Properties:
              Name: api-service-waf
              Scope: REGIONAL
              DefaultAction:
                Allow: {}
              Rules:
                - Name: CommonRuleSet
                  Priority: 1
                  Statement:
                    ManagedRuleGroupStatement:
                      VendorName: AWS
                      Name: AWSManagedRulesCommonRuleSet
                - Name: KnownBadInputs
                  Priority: 2
                  Statement:
                    ManagedRuleGroupStatement:
                      VendorName: AWS
                      Name: AWSManagedRulesKnownBadInputsRuleSet
        """
        let wafWeb = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          WebACL:
            Type: AWS::WAFv2::WebACL
            Properties:
              Name: web-frontend-waf
              Scope: CLOUDFRONT
              DefaultAction:
                Block: {}
              Rules:
                - Name: CommonRuleSet
                  Priority: 1
                  Statement:
                    ManagedRuleGroupStatement:
                      VendorName: AWS
                      Name: AWSManagedRulesCommonRuleSet
                - Name: SQLiRuleSet
                  Priority: 2
                  Statement:
                    ManagedRuleGroupStatement:
                      VendorName: AWS
                      Name: AWSManagedRulesSQLiRuleSet
        """
        let wafPipeline = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          WebACL:
            Type: AWS::WAFv2::WebACL
            Properties:
              Name: data-pipeline-waf
              Scope: REGIONAL
              DefaultAction:
                Allow: {}
              Rules:
                - Name: CommonRuleSet
                  Priority: 1
                  Statement:
                    ManagedRuleGroupStatement:
                      VendorName: AWS
                      Name: AWSManagedRulesCommonRuleSet
        """

        // The named-object scenario (find_named_object_properties recipe): a
        // deploy/*.template with an S3 bucket resource whose logical name ends
        // in "Bucket". The Properties align across repos (so they compare), but
        // web-frontend is the outlier — PublicRead access and Suspended
        // versioning where the others are Private/Enabled.
        let storageApi = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          AssetsBucket:
            Type: AWS::S3::Bucket
            Properties:
              BucketName: api-assets
              AccessControl: Private
              VersioningConfiguration:
                Status: Enabled
        """
        let storageWeb = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          StaticBucket:
            Type: AWS::S3::Bucket
            Properties:
              BucketName: web-static
              AccessControl: PublicRead
              VersioningConfiguration:
                Status: Suspended
        """
        let storagePipeline = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          RawBucket:
            Type: AWS::S3::Bucket
            Properties:
              BucketName: pipeline-raw
              AccessControl: Private
              VersioningConfiguration:
                Status: Enabled
        """

        return FixtureGitHubClient(
            repos: [api, web, pipeline, legacy, infra, flaky, docs],
            contents: [
                api.fullName: ["deploy/prod.yml": matchingYAML,
                               ".github/dependabot.yml": "version: 2\nupdates: []\n",
                               "README.md": licensedREADME,
                               "project.json": railsProject,
                               "deploy/logging.yml": retention14,
                               "deploy/cron.yml": markedCron,
                               "infra/waf.template": wafApi,
                               "deploy/storage.template": storageApi],
                web.fullName: ["deploy/prod.yml": differingYAML,
                               "deploy/infra.json": deployKeyJSON,
                               "README.md": "# web-frontend\n\nCustomer-facing frontend.\n",
                               "project.json": reactProject,
                               "deploy/logging.yml": retention30,
                               "deploy/maintenance.yml": markedMaintenance,
                               "infra/waf.template": wafWeb,
                               "deploy/storage.template": storageWeb],
                pipeline.fullName: ["deploy/prod.yml": matchingYAML,
                                    "deploy/keys.yml": deployKeyYAML,
                                    "deploy/prod_permanent.template": cloudFormationTemplate,
                                    "README.md": "# data-pipeline\n",
                                    "project.json": railsProject,
                                    "infra/waf.template": wafPipeline,
                                    "deploy/storage.template": storagePipeline],
                legacy.fullName: ["deploy/prod.yml": matchingYAML,
                                  "README.md": "# legacy-batch\n"],
                infra.fullName: [:],  // stale search hit: repo exists, file absent
                flaky.fullName: ["deploy/prod.yml": matchingYAML,
                                 "README.md": "# flaky-service\n"], // unreachable: error injected
                docs.fullName: ["README.md": "# Docs\n"],
            ],
            searchResults: [api, web, pipeline, legacy, infra, flaky],
            errorInjections: [flaky.fullName: "connection reset by peer"],
            // Org custom properties on three repos — aligned so they compare,
            // with web-frontend the outlier (react/silver vs rails/gold).
            customProperties: [
                api.fullName: ["ProjectType": .string("rails"), "Tier": .string("gold")],
                web.fullName: ["ProjectType": .string("react"), "Tier": .string("silver")],
                pipeline.fullName: ["ProjectType": .string("rails"), "Tier": .string("gold")],
            ],
            propertyDefs: [
                PropertyDef(name: "ProjectType", valueType: "single_select",
                            allowedValues: ["rails", "react", "go", "python"]),
                PropertyDef(name: "Tier", valueType: "string", allowedValues: nil),
            ]
        )
    }
}
