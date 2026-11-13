// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
// Helper of scripts/integration-linux.sh: not part of the Nido package, never shipped.
// Built in debug (DebugFakeRouter exists only in DEBUG builds of NidoCore) and signed ad hoc with
// the virtualization entitlement by the script:
//   swift build --package-path scripts/integration-probe
//   codesign --sign - --entitlements Resources/nido.entitlements --force scripts/integration-probe/.build/debug/nidoprobe
import PackageDescription

let package = Package(
    name: "nidoprobe",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "Nido", path: "../..")],
    targets: [
        .executableTarget(name: "nidoprobe", dependencies: [.product(name: "NidoCore", package: "Nido")]),
    ],
    swiftLanguageModes: [.v6]
)
