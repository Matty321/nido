// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

@MainActor
struct AppEnvironmentTests {
    @Test func releaseIgnoresNidoRoot() throws {
        let root = try AppEnvironment.resolveRoot(
            arguments: ["Nido", "-NidoRoot", "/tmp/elsewhere"], isDebug: false)
        #expect(root == NidoPaths.defaultRoot())
        // A relative path is not even looked at in Release.
        let relative = try AppEnvironment.resolveRoot(
            arguments: ["Nido", "-NidoRoot", "relative/dir"], isDebug: false)
        #expect(relative == NidoPaths.defaultRoot())
    }

    @Test func debugRejectsRelativeNidoRoot() {
        #expect(throws: AppEnvironment.LaunchError.self) {
            try AppEnvironment.resolveRoot(
                arguments: ["Nido", "-NidoRoot", "relative/dir"], isDebug: true)
        }
    }

    @Test func debugRejectsMissingNidoRootValue() {
        #expect(throws: AppEnvironment.LaunchError.self) {
            try AppEnvironment.resolveRoot(arguments: ["Nido", "-NidoRoot"], isDebug: true)
        }
    }

    @Test func debugUsesAbsoluteNidoRoot() throws {
        let root = try AppEnvironment.resolveRoot(
            arguments: ["Nido", "-NidoRoot", "/tmp/nido-test-root"], isDebug: true)
        #expect(root.path == "/tmp/nido-test-root")
    }

    @Test func debugWithoutNidoRootUsesDefault() throws {
        let root = try AppEnvironment.resolveRoot(arguments: ["Nido"], isDebug: true)
        #expect(root == NidoPaths.defaultRoot())
    }

    @Test func existingCustomRootKeepsItsMode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: dir) }

        try AppEnvironment.prepareRoot(dir, isCustom: true)

        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.intValue == 0o755)
    }

    @Test func missingCustomRootIsCreatedPrivate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try AppEnvironment.prepareRoot(dir, isCustom: true)

        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.intValue == 0o700)
    }
}

@MainActor
struct AppSetupTests {
    @Test func unitTestHostSkipsTheEnvironment() {
        #expect(AppSetup.isHostingUnitTests(environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"]))
        #expect(!AppSetup.isHostingUnitTests(environment: [:]))
        // This very process is the unit-test host: its AppSetup never built an environment.
        #expect(AppSetup().result == nil)
    }

    // MARK: - Screenshot flags (DEBUG)

    @Test func fakeStatesParse() {
        #expect(FakeVMSessionFactory.parsePlans("dev-box=starting,test-arm=error")
            == ["dev-box": .starting, "test-arm": .error])
        #expect(FakeVMSessionFactory.parsePlans("dev-box=dormiente") == nil)
        #expect(FakeVMSessionFactory.parsePlans("dev-box") == nil)
        #expect(FakeVMSessionFactory.parsePlans("=running") == nil)
        #expect(FakeVMSessionFactory.parsePlans("") == nil)
    }

    @Test func fakeGuestParse() {
        #expect(FakeGuest.parse("debian-ai=values+ollama,web=missing+no-bridge") == [
            "debian-ai": FakeGuest(monitor: .values, ollama: .installed, bridgeAttached: true),
            "web": FakeGuest(monitor: .missing, ollama: .absent, bridgeAttached: false),
        ])
        #expect(FakeGuest.parse("a=phase2") == ["a": FakeGuest(monitor: .values, ollama: .phase2)])
        #expect(FakeGuest.parse("a=boh") == nil)
        #expect(FakeGuest.parse("a=absent") == nil)
        #expect(FakeGuest.parse("a=") == nil)
        #expect(FakeGuest.parse("") == nil)
    }

    @Test func fakeGuestIsValidated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: AppEnvironment.LaunchError.invalidValue("-NidoFakeGuest", "x=boh")) {
            try AppEnvironment(arguments: ["Nido", "-NidoRoot", dir.path, "-NidoFakeGuest", "x=boh"], isDebug: true)
        }
    }

    @Test func releaseIgnoresDebugValues() throws {
        #expect(try AppEnvironment.debugValue(after: "-NidoFakeStates", in: ["Nido", "-NidoFakeStates", "a=error"],
                                              isDebug: false) == nil)
        #expect(try AppEnvironment.debugValue(after: "-NidoWizardFixture", in: ["Nido", "-NidoWizardFixture", "summary"],
                                              isDebug: true) == "summary")
    }

    @Test func wizardFixtureIsValidatedAndUsesItsOwnCache() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: AppEnvironment.LaunchError.invalidValue("-NidoWizardFixture", "boh")) {
            try AppEnvironment(arguments: ["Nido", "-NidoRoot", dir.path, "-NidoWizardFixture", "boh"], isDebug: true)
        }
        let environment = try AppEnvironment(
            arguments: ["Nido", "-NidoRoot", dir.path, "-NidoWizardFixture", "summary"], isDebug: true)
        #expect(environment.wizardFixture == .summary)
        #expect(environment.imageCacheRoot != ImageStore.defaultCacheRoot())
    }

    @Test func fakeStatesAreValidated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: AppEnvironment.LaunchError.invalidValue("-NidoFakeStates", "x=boh")) {
            try AppEnvironment(arguments: ["Nido", "-NidoRoot", dir.path, "-NidoFakeStates", "x=boh"], isDebug: true)
        }
    }

    /// Fake sessions take real locks and the wizard fixtures fake a download: never on the
    /// user's own VM root. Refused before the root is even prepared.
    @Test(arguments: [
        ["-NidoFakeSessions"], ["-NidoWizardFixture", "summary"], ["-NidoFakeStates", "a=running"], ["-NidoFakeAIRouter"],
        ["-NidoFakeGuest", "a=values"], ["-NidoOpenVM", "macos-t8"],
    ])
    func debugFlagsRequireNidoRoot(_ flag: [String]) {
        #expect(throws: AppEnvironment.LaunchError.requiresRoot(flag[0])) {
            try AppEnvironment(arguments: ["Nido"] + flag, isDebug: true)
        }
    }

    /// At launch the app ends the gvproxy orphans a Nido killed with -9 left behind (their SSH
    /// port stays open on 127.0.0.1 otherwise), off the main actor.
    @Test func launchSweepsGvproxyOrphans() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let swept = DispatchSemaphore(value: 0)
        let onMain = Mutex<Bool?>(nil)
        _ = try AppEnvironment(arguments: ["Nido", "-NidoRoot", dir.path], isDebug: true, sweepOrphans: {
            onMain.withLock { $0 = Thread.isMainThread }
            swept.signal()
        })
        // The sweep runs on a queue of its own: waiting here on the main actor does not block it.
        #expect(swept.wait(timeout: .now() + 5) == .success)
        #expect(onMain.withLock { $0 } == false)
    }

    /// The AI bridge uses the Keychain and the real router, unless DEBUG `-NidoFakeAIRouter`.
    @Test func fakeAIRouterOnlyWithItsFlag() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try AppEnvironment(arguments: ["Nido", "-NidoRoot", dir.path, "-NidoFakeAIRouter"], isDebug: true)
        #expect(fake.aiBridge.router is DebugFakeRouter)
        #expect(fake.aiBridge.tokenStore is DebugMemoryTokenStore)
        let real = try AppEnvironment(arguments: ["Nido", "-NidoRoot", dir.path], isDebug: true)
        #expect(real.aiBridge.router is URLSessionRouterClient)
        #expect(real.aiBridge.tokenStore is KeychainTokenStore)
    }

    /// DEBUG `-NidoOpenVM <name>`: the window of one VM opens (and the VM starts) at launch, for
    /// the real proofs of the macOS window; never in a release build.
    @Test func openVMArgumentIsDebugOnly() throws {
        let args = ["Nido", "-NidoOpenVM", "macos-t8"]
        #expect(try AppEnvironment.resolveOpenVM(arguments: args, isDebug: true) == (try VMName("macos-t8")))
        #expect(try AppEnvironment.resolveOpenVM(arguments: args, isDebug: false) == nil)
        #expect(try AppEnvironment.resolveOpenVM(arguments: ["Nido"], isDebug: true) == nil)
        #expect(throws: AppEnvironment.LaunchError.invalidValue("-NidoOpenVM", "../x")) {
            try AppEnvironment.resolveOpenVM(arguments: ["Nido", "-NidoOpenVM", "../x"], isDebug: true)
        }
        // Once per launch: a library window opened again does not reopen it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = try AppEnvironment(arguments: ["Nido", "-NidoRoot", dir.path] + args.dropFirst(), isDebug: true)
        #expect(environment.takeOpenAtLaunch() == (try VMName("macos-t8")))
        #expect(environment.takeOpenAtLaunch() == nil)
    }
}
