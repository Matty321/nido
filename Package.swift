// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "Nido",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NidoCore", targets: ["NidoCore"]),
        .library(name: "NidoCLI", targets: ["NidoCLI"]),
        .executable(name: "nido", targets: ["nido"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "NidoCore", resources: [.process("Resources")]),
        .target(name: "NidoCLI", dependencies: ["NidoCore"]),
        .executableTarget(
            name: "nido",
            dependencies: [
                "NidoCLI",
                "NidoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "NidoCoreTests", dependencies: ["NidoCore"]),
        .testTarget(name: "NidoCLITests", dependencies: ["NidoCLI", "NidoCore"]),
    ],
    swiftLanguageModes: [.v6]
)
