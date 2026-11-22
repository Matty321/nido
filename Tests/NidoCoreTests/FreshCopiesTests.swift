// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct FreshCopiesTests {
    private struct Env {
        let paths: NidoPaths

        init() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-fresh-copies-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: dir)
            try paths.ensureRoot()
        }

        func cleanup() { try? FileManager.default.removeItem(at: paths.root) }

        @discardableResult
        func makeVM(_ name: String, disposable: Bool? = nil, base: UUID? = nil) throws -> (bundle: VMBundle, id: UUID) {
            let id = UUID()
            var config = VMConfig(
                id: id, name: try VMName(name), guest: .macos, cpuCount: 2,
                memoryBytes: 2 << 30, diskBytes: 8 << 30, macAddress: "02:00:00:00:00:01",
                controlledNetwork: true, agentAccess: true, disposable: disposable)
            config.freshBaseID = base
            return (try VMBundle.create(config: config, paths: paths), id)
        }

        func allowList(_ bundle: VMBundle) -> [String]? {
            EgressPolicyStore.load(bundle: bundle)?.allow.map(\.description)
        }
    }

    private static func names(_ bundles: [VMBundle]) -> [String] {
        bundles.map(\.url.lastPathComponent).sorted()
    }

    @Test func findsOnlyDisposableCopiesOfThatBase() throws {
        let env = try Env()
        defer { env.cleanup() }
        let a = try env.makeVM("base-a")
        let b = try env.makeVM("base-b")
        let copyOfA = try env.makeVM("base-a-fresh-0001", disposable: true, base: a.id)
        try env.makeVM("base-b-fresh-0002", disposable: true, base: b.id)
        // Claimed or kept: not disposable any more, even if the id is still there.
        try env.makeVM("base-a-fresh-0003", disposable: nil, base: a.id)

        let copies = FreshCopies.of(a.bundle, paths: env.paths)

        #expect(Self.names(copies) == [copyOfA.bundle.url.lastPathComponent])
        #expect(FreshCopies.of(copyOfA.bundle, paths: env.paths).isEmpty)
    }

    @Test func baseWithUnreadableConfigHasNoCopies() throws {
        let env = try Env()
        defer { env.cleanup() }
        let a = try env.makeVM("base-a")
        try env.makeVM("base-a-fresh-0001", disposable: true, base: a.id)
        try Data("{".utf8).write(to: a.bundle.configURL)

        #expect(FreshCopies.of(a.bundle, paths: env.paths).isEmpty)
    }

    @Test func allowReachesTheCopies() throws {
        let env = try Env()
        defer { env.cleanup() }
        let a = try env.makeVM("base-a")
        let copy = try env.makeVM("base-a-fresh-0001", disposable: true, base: a.id)
        let pattern = try DomainPattern("example.com")

        let outcome = FreshCopies.propagate(from: a.bundle, paths: env.paths) { $0.allow.append(pattern) }

        #expect(outcome.applied.map(\.rawValue) == ["base-a-fresh-0001"])
        #expect(outcome.failed.isEmpty)
        #expect(env.allowList(copy.bundle) == ["example.com"])
        // Only the copies: the base is the caller's to write.
        #expect(env.allowList(a.bundle) == [])
    }

    /// A copy whose list does not load is named and left as it is; the others still get it.
    @Test func propagationSkipsADamagedCopy() throws {
        let env = try Env()
        defer { env.cleanup() }
        let a = try env.makeVM("base-a")
        let damaged = try env.makeVM("base-a-fresh-0001", disposable: true, base: a.id)
        let sound = try env.makeVM("base-a-fresh-0002", disposable: true, base: a.id)
        let bad = Data("{".utf8)
        try bad.write(to: damaged.bundle.egressPolicyURL)
        let pattern = try DomainPattern("example.com")

        let outcome = FreshCopies.propagate(from: a.bundle, paths: env.paths) { $0.allow.append(pattern) }

        #expect(outcome.applied.map(\.rawValue) == ["base-a-fresh-0002"])
        #expect(outcome.failed.map(\.0.rawValue) == ["base-a-fresh-0001"])
        #expect(outcome.failed.allSatisfy { !$0.1.isEmpty })
        #expect(try Data(contentsOf: damaged.bundle.egressPolicyURL) == bad)
        #expect(env.allowList(sound.bundle) == ["example.com"])
    }
}
