import Foundation

/// A recipe: the script plus the natural-language prompt that would generate
/// it — loading one restores both, so the prompt field always matches the
/// code in the editor. Bundled recipes load their source from the resource
/// bundle; user-saved recipes carry it inline.
public struct Recipe: Identifiable, Sendable {
    public let id: String          // bundled: resource file name (without .ts)
    public let title: String
    public let prompt: String
    public let phase: JobPhase
    public let systemImage: String
    private let inlineSource: String?

    public var source: String? { inlineSource ?? ResourceLocator.recipe(named: id) }

    /// A bundled recipe (source resolved from the resource bundle by id).
    public init(id: String, title: String, prompt: String, phase: JobPhase,
                systemImage: String) {
        self.init(id: id, title: title, prompt: prompt, phase: phase,
                  systemImage: systemImage, source: nil)
    }

    /// A recipe with its source carried inline (user-saved recipes).
    public init(id: String, title: String, prompt: String, phase: JobPhase,
                systemImage: String, source: String?) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.phase = phase
        self.systemImage = systemImage
        self.inlineSource = source
    }
}

public enum RecipeCatalog {
    public static let all: [Recipe] = [
        Recipe(id: "find_waf_resources",
               title: "Report on a CloudFormation resource",
               prompt: "report on repos that define a WAF resource in cloudformation: give me the different parameters that are in use",
               phase: .check,
               systemImage: "shield.lefthalf.filled"),
        Recipe(id: "find_named_object_properties",
               title: "Report a named object's properties",
               prompt: "Find repos where there is a file deploy/*.template that contains a yaml object named \"*Bucket\". save the Properties/Parameters of the object.",
               phase: .check,
               systemImage: "cube.box"),
        Recipe(id: "report_custom_properties",
               title: "Report repository custom properties",
               prompt: "report on the GitHub custom properties set across the organisation's repositories",
               phase: .check,
               systemImage: "tag"),
    ]

    public static func recipe(id: String) -> Recipe? {
        all.first { $0.id == id }
    }
}
