// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibretillaDocx",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LibretillaDocx", targets: ["LibretillaDocx"])
    ],
    dependencies: [
        // MIT. Zip read/write for the OPC package (ADR 0002). 0.x: pin to the minor version.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.20"))
    ],
    targets: [
        .target(name: "LibretillaDocx", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "LibretillaDocxTests", dependencies: ["LibretillaDocx", "ZIPFoundation"]),
    ]
)
