// SPDX-License-Identifier: Apache-2.0
import CoreServices
import Foundation
import NidoCore
import Testing
@testable import Nido

@Suite struct UpdateGateTests {
    @Test func allowsWhenNoVMIsRunning() {
        #expect(UpdateGate.decision(running: []) == .proceed)
    }

    /// Review focus 2: a VM started with `nido start` (the app runs none) blocks the update, and
    /// the notice names it.
    @Test func postponesWhileACLIVMRuns() throws {
        let decision = UpdateGate.decision(running: [try VMName("dev")])
        #expect(decision == .postpone(
            message: "Nido si aggiornerà quando nessuna VM sarà accesa. Accese ora: dev."))
    }

    @Test func listsAllRunningNames() throws {
        let decision = UpdateGate.decision(running: [try VMName("alfa"), try VMName("beta"), try VMName("gamma")])
        #expect(decision == .postpone(
            message: "Nido si aggiornerà quando nessuna VM sarà accesa. Accese ora: alfa, beta, gamma."))
    }
}

/// Step 6: without a feed (`NIDO_FEED_URL` empty) there is no updater at all.
@Suite struct UpdateFeedTests {
    @Test func noFeedWhenEmptyOrMissing() {
        #expect(UpdateController.feedURL(info: nil) == nil)
        #expect(UpdateController.feedURL(info: [:]) == nil)
        #expect(UpdateController.feedURL(info: ["SUFeedURL": ""]) == nil)
        #expect(UpdateController.feedURL(info: ["SUFeedURL": "  "]) == nil)
    }

    /// Plain http only on loopback (local update test), never for a remote host.
    @Test func httpFeedOnlyOnLoopback() {
        #expect(UpdateController.feedURL(info: ["SUFeedURL": "http://127.0.0.1:8765/appcast.xml"])?.absoluteString
            == "http://127.0.0.1:8765/appcast.xml")
        #expect(UpdateController.feedURL(info: ["SUFeedURL": "http://localhost:8765/appcast.xml"]) != nil)
        #expect(UpdateController.feedURL(info: ["SUFeedURL": "http://127.0.0.1.example.com/appcast.xml"]) == nil)
        #expect(UpdateController.feedURL(info: ["SUFeedURL": "ftp://127.0.0.1/appcast.xml"]) == nil)
    }

    @Test func onlyAnHTTPSFeedCounts() {
        #expect(UpdateController.feedURL(info: ["SUFeedURL": "http://example.com/appcast.xml"]) == nil)
        #expect(UpdateController.feedURL(info: ["SUFeedURL": "https://example.com/appcast.xml"])?.absoluteString
            == "https://example.com/appcast.xml")
    }

    /// The test host's build has no feed: the app creates no updater.
    @MainActor
    @Test func noUpdaterWithoutAFeed() {
        let paths = NidoPaths(root: URL(fileURLWithPath: "/nonexistent-nido-root", isDirectory: true))
        #expect(UpdateController(bundle: .main, paths: paths) == nil)
    }

    /// Sparkle asks Nido for the feed first, so a `SUFeedURL` left in the user defaults (which
    /// Sparkle otherwise prefers over the Info.plist) can never replace the validated feed.
    @MainActor
    @Test func sparkleUsesTheValidatedFeed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nido-feed-\(UUID().uuidString)")
        let contents = root.appending(path: "Feed.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: NSDictionary = [
            "CFBundleIdentifier": "io.gitlab.pichierri.Nido.feedtest", "CFBundlePackageType": "APPL",
            "SUFeedURL": "https://example.com/appcast.xml",
        ]
        try info.write(to: contents.appending(path: "Info.plist"))
        let bundle = try #require(Bundle(url: root.appending(path: "Feed.app")))
        let paths = NidoPaths(root: URL(fileURLWithPath: "/nonexistent-nido-root", isDirectory: true))
        let controller = try #require(UpdateController(bundle: bundle, paths: paths, startingUpdater: false))
        #expect(controller.updater.feedURL?.absoluteString == "https://example.com/appcast.xml")
    }
}

/// A logout, restart or shutdown is never held by the quit guard; a user's quit is.
@Suite struct QuitReasonTests {
    @Test func systemQuitsAreRecognized() {
        for reason in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown] {
            #expect(UpdateGate.isSystemQuit(reason: OSType(reason)))
        }
    }

    @Test func userQuitIsNotASystemQuit() {
        #expect(!UpdateGate.isSystemQuit(reason: nil))
        #expect(!UpdateGate.isSystemQuit(reason: OSType(kAEQuitApplication)))
    }
}

/// The early gate: no update is offered (so nothing is downloaded) while a VM runs.
@Suite struct ProceedGateTests {
    @Test func proceedsWithNoVM() {
        #expect(UpdateGate.proceedError(running: []) == nil)
    }

    @Test func refusesWithTheGateMessage() throws {
        let error = UpdateGate.proceedError(running: [try VMName("dev")])
        #expect(error?.localizedDescription
            == "Nido si aggiornerà quando nessuna VM sarà accesa. Accese ora: dev.")
    }
}
