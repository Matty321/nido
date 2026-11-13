// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
// Measurement harness of docs/DISK-CACHING.md: not part of the Nido package, never shipped.
//   swift build -c release --package-path scripts/disk-caching
//   codesign --sign - --entitlements Resources/nido.entitlements --force scripts/disk-caching/.build/release/vzbench
import PackageDescription

let package = Package(
    name: "vzbench",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "Nido", path: "../..")],
    targets: [
        .executableTarget(name: "vzbench", dependencies: [.product(name: "NidoCore", package: "Nido")]),
    ],
    swiftLanguageModes: [.v6]
)
