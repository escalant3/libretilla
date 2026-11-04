// swift-tools-version: 6.2
// Milestone 0 spike: evaluate Techopolis/SwiftDocX against Fixtures/ (ADR 0002).
// Not part of the app build. Dependencies here are evaluation-only.
import PackageDescription

let package = Package(
    name: "SwiftDocXEval",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Techopolis/SwiftDocX.git", exact: "1.0.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // Library-independent ground truth: what is actually inside a .docx.
        .target(name: "DocxProbe", dependencies: ["ZIPFoundation"]),
        .executableTarget(
            name: "SwiftDocXEval",
            dependencies: ["DocxProbe", .product(name: "SwiftDocX", package: "SwiftDocX")]),
        .testTarget(
            name: "SwiftDocXEvalTests",
            dependencies: ["DocxProbe", .product(name: "SwiftDocX", package: "SwiftDocX")]),
    ]
)
