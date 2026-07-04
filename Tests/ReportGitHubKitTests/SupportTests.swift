import Foundation
import Testing
@testable import ReportGitHubKit

/// Cross-cutting support: persistence, the user-recipe store, catalog
/// consistency, credentials, and LLM-response parsing. (The recipe end-to-end
/// coverage lives in ReportRecipeTests against the two shipped report recipes.)
@Suite("Support")
struct SupportTests {

    @Test("app state snapshot round-trips")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reportgh-test-\(UUID().uuidString)")
        let store = AppStateStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = AppSettings()
        settings.organisation = "example-org"
        settings.maxConcurrentOps = 3
        var job = Job(prompt: "find things")
        job.scriptSource = "async function main() {}"
        job.params = ["path": "x.yml"]
        job.results = [RepoResult(repo: RepoRef(fullName: "example-org/a"), status: .verifiedMatch,
                                  reason: "ok", evidence: [Evidence(path: "x.yml", excerpt: "k: v")])]
        job.auditEvents = [AuditEvent(kind: "gh.getContent", repo: "example-org/a", detail: "x.yml")]

        try store.save(AppStateSnapshot(settings: settings, job: job))
        let loaded = try #require(store.load())
        #expect(loaded.settings == settings)
        #expect(loaded.job?.prompt == "find things")
        #expect(loaded.job?.results.first?.evidence.first?.path == "x.yml")
        #expect(loaded.job?.auditEvents.count == 1)
    }

    @Test("user recipes save, rename, and delete as .ts through the store")
    func userRecipes() throws {
        let service = try #require(TypeScriptService.loadDefault())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reportgh-recipes-\(UUID().uuidString)")
        let store = UserRecipeStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        func load() -> [Recipe] {
            RecipeCatalogLoader(service: service, bundledDirectory: nil, userDirectory: directory).load()
        }
        let source = """
        const meta: ScriptMeta = { title: "generated", phase: "check", apiVersion: 1 };
        async function main(): Promise<void> {}
        """
        let id = try store.save(title: "Find stale configs",
                                prompt: "find configs that are stale", source: source, using: service)

        var loaded = load()
        #expect(loaded.map(\.id) == [id])
        #expect(loaded.first?.title == "Find stale configs")
        #expect(loaded.first?.prompt == "find configs that are stale")
        #expect(loaded.first?.phase == .check)
        #expect(loaded.first?.origin == .user)

        try store.rename(id: id, to: "Audit configs", using: service)
        loaded = load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Audit configs")

        try store.delete(id: id)
        #expect(load().isEmpty)
        // Deleting a missing recipe is a no-op, not an error.
        try store.delete(id: id)
    }

    // Catalog consistency (every recipe resolves its source, is a check recipe,
    // and has a "Report" title) now lives in RecipeCatalogLoaderTests, which
    // builds the catalog from files rather than the deleted RecipeCatalog.all.

    @Test("in-memory credential store basics")
    func credentials() throws {
        let store = InMemoryCredentialStore()
        #expect(store.read(.githubToken) == nil)
        try store.write(.githubToken, value: "tok")
        #expect(store.read(.githubToken) == "tok")
        try store.delete(.githubToken)
        #expect(store.read(.githubToken) == nil)
    }

    @Test("code extraction from fenced LLM responses")
    func codeExtraction() {
        let fenced = """
        Here is the script:
        ```typescript
        const meta = { title: "x" };
        ```
        """
        #expect(PromptLibrary.extractCode(from: fenced) == "const meta = { title: \"x\" };")
        #expect(PromptLibrary.extractCode(from: "plain code") == "plain code")
    }
}
