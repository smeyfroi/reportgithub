import Foundation
import Testing
@testable import ReportGitHubKit

/// Phase 0 cutover guard (temporary). Every bundled recipe's in-file `meta`
/// must match its hardcoded `RecipeCatalog` entry — title, phase, prompt, and
/// icon — so that deleting the Swift catalog in Phase 1 loses nothing. Uses the
/// same cheap transpile + extractMeta path the Phase 1 loader will. Deleted once
/// the loader replaces the catalog.
@Suite("Recipe meta cutover")
struct RecipeMetaCutoverTests {

    @Test("every bundled recipe's meta matches its catalog entry")
    func metaMatchesCatalog() throws {
        let service = try #require(TypeScriptService.loadDefault())
        #expect(RecipeCatalog.all.count == 3)
        for recipe in RecipeCatalog.all {
            let source = try #require(ResourceLocator.recipe(named: recipe.id),
                                      "no bundled source for \(recipe.id)")
            let javaScript = try service.transpile(source: source)
            let meta = try ValidationPipeline.extractMeta(fromJavaScript: javaScript)

            #expect(meta.title == recipe.title,
                    "title mismatch for \(recipe.id): meta=\(meta.title) catalog=\(recipe.title)")
            #expect(meta.phase == recipe.phase, "phase mismatch for \(recipe.id)")
            #expect(meta.prompt == recipe.prompt,
                    "prompt mismatch for \(recipe.id): meta=\(String(describing: meta.prompt))")
            #expect(meta.icon == recipe.systemImage,
                    "icon mismatch for \(recipe.id): meta=\(String(describing: meta.icon))")
            #expect(!(meta.prompt ?? "").isEmpty, "\(recipe.id) has an empty meta.prompt")
            #expect(!(meta.icon ?? "").isEmpty, "\(recipe.id) has an empty meta.icon")
        }
    }
}
