// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Nido

/// A VM's tint: the colour of its system mark, chosen per VM (Settings › General › Color, the
/// wizard's summary), else derived from its name as the design mocks do (scripts/design/Logos.swift).
@MainActor
@Suite(.serialized)
struct VMTintTests {
    private func makeStore() -> (VMTintStore, UserDefaults, String) {
        let suite = "io.gitlab.pichierri.Nido.tests-tints-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (VMTintStore(defaults: defaults), defaults, suite)
    }

    /// The same FNV-1a as `designTint(for:)`: the app and the mocks agree.
    @Test func theDefaultFollowsTheNameAsInTheDesign() {
        #expect(VMTint.default(for: "debian-13") == .rose)
        #expect(VMTint.default(for: "archivio") == .plum)
        #expect(VMTint.default(for: "web-staging") == .olive)
        #expect(VMTint.default(for: "debian-ai") == .indigo)
        #expect(VMTint.default(for: "research-01") == .slate)
        #expect(VMTint.allCases == [.slate, .indigo, .plum, .rose, .clay, .olive, .sea, .graphite])
    }

    @Test func aChosenTintIsKeptAndForgotten() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.tint(for: "debian-13") == .rose)
        store.set(.sea, for: "debian-13")
        #expect(store.tint(for: "debian-13") == .sea)
        // Another store on the same defaults (another window, the next launch) sees it.
        #expect(VMTintStore(defaults: defaults).tint(for: "debian-13") == .sea)
        store.remove("debian-13")
        #expect(store.tint(for: "debian-13") == .rose)
        #expect(VMTintStore(defaults: defaults).tint(for: "debian-13") == .rose)
    }

    /// An unknown value in the defaults (a later version's tint) falls back to the name's.
    @Test func anUnknownStoredTintFallsBackToTheName() {
        let (_, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["debian-13": "teal"], forKey: VMTintStore.key)
        #expect(VMTintStore(defaults: defaults).tint(for: "debian-13") == .rose)
    }

    /// The wizard proposes the first tint no VM has yet; with all eight taken, the new name's own.
    @Test func aNewVMGetsAnUnusedTint() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // research-01 is slate by its name; debian-13 chose indigo.
        store.set(.indigo, for: "debian-13")
        #expect(store.freshTint(for: "new-vm", among: ["research-01", "debian-13"]) == .plum)
        let names = VMTint.allCases.map { "vm-\($0.rawValue)" }
        for (tint, name) in zip(VMTint.allCases, names) { store.set(tint, for: name) }
        #expect(store.freshTint(for: "debian-13", among: names) == VMTint.default(for: "debian-13"))
    }
}
