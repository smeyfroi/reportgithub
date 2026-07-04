import Foundation

/// Access to files shipped in the module's resource bundle
/// (Sources/ReportGitHubKit/Resources, copied verbatim by SwiftPM).
public enum ResourceLocator {

    /// The copied directory is literally named "Resources", which collides
    /// with CFBundle's layout detection: in the flat SwiftPM bundle macOS
    /// reports resourceURL as <bundle>/Resources (our directory itself), while
    /// Xcode-built bundles nest it one level deeper. Probe the candidate
    /// layouts for a sentinel file instead of assuming one.
    public static var resourcesRoot: URL? {
        let bundle = Bundle.module
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Resources", isDirectory: true))
            candidates.append(resourceURL)
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Resources", isDirectory: true))
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("bulkgh.d.ts").path)
        }
    }

    public static func string(at relativePath: String) -> String? {
        guard let root = resourcesRoot else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The host API contract published to the LLM and the type-checker.
    public static var apiDeclaration: String? {
        string(at: "bulkgh.d.ts")
    }

    /// The phase-appropriate extra declaration. ReportGitHub is read-only, so
    /// every phase uses the base read surface — there is no extra declaration.
    /// (The report phase's find/extract script is a check script that
    /// populates evidence.fields, so it too adds nothing.)
    public static func extraDeclaration(for phase: JobPhase) -> String? {
        switch phase {
        case .check, .report: return nil
        }
    }

    /// The bundled recipes directory (Resources/recipes), or nil if the
    /// resource bundle can't be located.
    public static var recipesDirectory: URL? {
        resourcesRoot?.appendingPathComponent("recipes", isDirectory: true)
    }

    /// A bundled recipe by file name (without extension).
    public static func recipe(named name: String) -> String? {
        string(at: "recipes/\(name).ts")
    }

    /// The golden recipe: the first-launch example — report the parameters of
    /// a CloudFormation resource across the organisation.
    public static var goldenRecipe: String? {
        recipe(named: "find_waf_resources")
    }

    /// The bundled TypeScript compiler and the ES lib declaration files it
    /// needs to type-check against (no DOM — scripts must not see browser APIs).
    public static func typeScriptCompiler() -> (compiler: String, libs: [String: String])? {
        guard let root = resourcesRoot else { return nil }
        let tsRoot = root.appendingPathComponent("TypeScript", isDirectory: true)
        guard let compiler = try? String(contentsOf: tsRoot.appendingPathComponent("typescript.js"),
                                         encoding: .utf8) else { return nil }
        let libsDir = tsRoot.appendingPathComponent("libs", isDirectory: true)
        var libs: [String: String] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(at: libsDir,
                                                                    includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "ts" {
                libs[file.lastPathComponent] = try? String(contentsOf: file, encoding: .utf8)
            }
        }
        return (compiler, libs)
    }
}
