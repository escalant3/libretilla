// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CartillaDocx",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CartillaDocx", targets: ["CartillaDocx"])
    ],
    dependencies: [
        // MIT. Zip read/write for the OPC package (ADR 0002). 0.x: pin to the minor version.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.20"))
    ],
    targets: [
        .target(name: "CartillaDocx", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "CartillaDocxTests", dependencies: ["CartillaDocx", "ZIPFoundation"]),
    ]
)
