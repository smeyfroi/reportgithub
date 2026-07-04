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

    @Test("user recipes save, rename, and delete through the store")
    func userRecipes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reportgh-recipes-\(UUID().uuidString)")
        let store = UserRecipeStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recipe = UserRecipe(title: "Find stale configs",
                                prompt: "find configs that are stale",
                                phase: .check,
                                source: "async function main() {}")
        try store.save(recipe)
        var loaded = store.load()
        #expect(loaded.map(\.id) == [recipe.id])
        #expect(loaded.first?.asRecipe.source == "async function main() {}")
        #expect(loaded.first?.asRecipe.phase == .check)

        var renamed = recipe
        renamed.title = "Audit configs"
        try store.save(renamed)
        loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Audit configs")

        try store.delete(id: recipe.id)
        #expect(store.load().isEmpty)
        // Deleting a missing recipe is a no-op, not an error.
        try store.delete(id: recipe.id)
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
