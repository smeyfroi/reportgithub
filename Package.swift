// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReportGitHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReportGitHubKit", targets: ["ReportGitHubKit"]),
        .executable(name: "ReportGitHub", targets: ["ReportGitHub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/ZeeZide/CodeEditor.git", from: "1.2.0"),
        // Same Markdown engine MDViewer uses — render reports identically.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "ReportGitHubKit",
            dependencies: ["Yams"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ReportGitHub",
            dependencies: [
                "ReportGitHubKit",
                .product(name: "CodeEditor", package: "CodeEditor"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            exclude: ["Assets.xcassets"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReportGitHubKitTests",
            dependencies: ["ReportGitHubKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
