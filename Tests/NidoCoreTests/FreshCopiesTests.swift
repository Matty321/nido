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

    /// A copy deleted after `of` listed it (here: while its own edit runs) is skipped, not failed.
    @Test func copyDeletedDuringPropagationIsSkipped() throws {
        let env = try Env()
        defer { env.cleanup() }
        let a = try env.makeVM("base-a")
        let gone = try env.makeVM("base-a-fresh-0001", disposable: true, base: a.id)
        let pattern = try DomainPattern("example.com")
        let url = gone.bundle.url

        let outcome = FreshCopies.propagate(from: a.bundle, paths: env.paths) {
            $0.allow.append(pattern)
            try? FileManager.default.removeItem(at: url)
        }

        #expect(outcome.applied.isEmpty)
        #expect(outcome.failed.isEmpty)
    }

    /// A save-time refusal (the copy's list is at its limit) is not a damaged list.
    @Test func limitErrorIsNotADamagedList() throws {
        let env = try Env()
        defer { env.cleanup() }
        let a = try env.makeVM("base-a")
        let full = try env.makeVM("base-a-fresh-0001", disposable: true, base: a.id)
        let damaged = try env.makeVM("base-a-fresh-0002", disposable: true, base: a.id)
        let names = try (0..<EgressPolicy.maxPatterns).map { try DomainPattern("d\($0).example.com") }
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: names), bundle: full.bundle)
        try Data("{".utf8).write(to: damaged.bundle.egressPolicyURL)
        let pattern = try DomainPattern("example.com")

        let outcome = FreshCopies.propagate(from: a.bundle, paths: env.paths) { $0.allow.append(pattern) }

        #expect(outcome.applied.isEmpty)
        #expect(outcome.failed.count == 2)
        #expect(outcome.failed.first { $0.name.rawValue == "base-a-fresh-0001" }?.damagedList == false)
        #expect(outcome.failed.first { $0.name.rawValue == "base-a-fresh-0002" }?.damagedList == true)
    }

    /// The failure of a damaged list says so; any other failure does not.
    @Test func failureSaysWhetherTheListIsDamaged() throws {
        let env = try Env()
        defer { env.cleanup() }
        let a = try env.makeVM("base-a")
        let damaged = try env.makeVM("base-a-fresh-0001", disposable: true, base: a.id)
        try env.makeVM("base-a-fresh-0002", disposable: true, base: a.id)
        try Data("{".utf8).write(to: damaged.bundle.egressPolicyURL)
        struct Boom: Error {}

        let broken = FreshCopies.propagate(from: a.bundle, paths: env.paths) { _ in }
        #expect(broken.failed.map(\.name.rawValue) == ["base-a-fresh-0001"])
        #expect(broken.failed.map(\.damagedList) == [true])
        let other = FreshCopies.propagate(from: a.bundle, paths: env.paths) { _ in throw Boom() }
        #expect(other.failed.count == 2)
        #expect(other.failed.filter(\.damagedList).map(\.name.rawValue) == ["base-a-fresh-0001"])
    }
}
