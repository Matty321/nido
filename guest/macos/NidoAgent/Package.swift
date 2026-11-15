// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "NidoAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NidoAgentKit", targets: ["NidoAgentKit"]),
        .executable(name: "NidoAgent", targets: ["NidoAgent"]),
    ],
    targets: [
        .target(name: "CVsock"),
        .target(name: "NidoAgentKit"),
        .executableTarget(name: "NidoAgent", dependencies: ["NidoAgentKit", "CVsock"]),
        .testTarget(name: "NidoAgentKitTests", dependencies: ["NidoAgentKit"]),
    ],
    swiftLanguageModes: [.v6]
)
