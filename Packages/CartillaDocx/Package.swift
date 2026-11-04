// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CartillaDocx",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CartillaDocx", targets: ["CartillaDocx"])
    ],
    targets: [
        .target(name: "CartillaDocx"),
        .testTarget(name: "CartillaDocxTests", dependencies: ["CartillaDocx"]),
    ]
)
