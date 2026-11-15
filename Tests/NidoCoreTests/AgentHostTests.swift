// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import NidoAgentKit
import Testing
@testable import NidoCore

/// `AgentHost.startIfEnabled` with a real `VMSession`. Building one needs the virtualization
/// entitlement, which `swift test` lacks: these tests are skipped there (`AgentHostLogicTests`
/// covers the same decisions without a session).
@Suite struct AgentHostTests {
    @MainActor
    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    func notStartedWithoutAgentAccess() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let root = f.tmp.appendingPathComponent("agent", isDirectory: true)
        let session = try VMSession(bundle: f.bundle, imageCache: f.tmp.appendingPathComponent("cache"))
        #expect(f.config.agentAccess == nil)
        #expect(AgentHost.startIfEnabled(session: session, bundle: f.bundle, config: f.config, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    func notStartedForLinux() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let root = f.tmp.appendingPathComponent("agent", isDirectory: true)
        let session = try VMSession(bundle: f.bundle, imageCache: f.tmp.appendingPathComponent("cache"))
        var config = f.config
        config.guest = .linux
        config.agentAccess = true
        #expect(AgentHost.startIfEnabled(session: session, bundle: f.bundle, config: config, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

/// The activity wrapper around a forwarded request.
@Suite struct AgentHostActivityTests {
    private struct Boom: Error {}

    @Test func activityWrapsEachRequest() async throws {
        let events = Mutex<[Bool]>([])
        let wrapped = AgentHost.reportingActivity(
            { @Sendable (_: AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?) in
                #expect(events.withLock { $0 } == [true])
                return (AgentReply(ok: true), nil)
            },
            onActivity: { value in events.withLock { $0.append(value) } })
        _ = try await wrapped(AgentRequest(action: .click(x: 1, y: 2, button: .left, count: 1)))
        #expect(events.withLock { $0 } == [true, false])
    }

    /// Nido asks `status` itself (the Agent pane every 3 s, setup's wait every 2 s): not an
    /// agent at work, so no banner.
    @Test func statusIsNotActivity() async throws {
        let events = Mutex<[Bool]>([])
        let wrapped = AgentHost.reportingActivity(
            { @Sendable (_: AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?) in
                (AgentReply(ok: true), nil)
            },
            onActivity: { value in events.withLock { $0.append(value) } })
        _ = try await wrapped(AgentRequest(action: .status))
        _ = try? await wrapped(AgentRequest(action: .status))
        #expect(events.withLock { $0 }.isEmpty)
        _ = try await wrapped(AgentRequest(action: .screenshot(maxLongEdge: 1280)))
        #expect(events.withLock { $0 } == [true, false])
    }

    @Test func activityEndsWhenTheRequestThrows() async {
        let events = Mutex<[Bool]>([])
        let wrapped = AgentHost.reportingActivity(
            { @Sendable (_: AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?) in
                throw AgentFailure(code: .notReady, message: "x")
            },
            onActivity: { value in events.withLock { $0.append(value) } })
        _ = try? await wrapped(AgentRequest(action: .type(text: "x")))
        #expect(events.withLock { $0 } == [true, false])
    }
}

/// The guard and the failure handling, without a `VMSession` (so they run under `swift test`).
@Suite struct AgentHostLogicTests {
    private func config(guest: GuestOS = .macos, agentAccess: Bool? = true) throws -> VMConfig {
        VMConfig(
            id: UUID(), name: try VMName("mac"), guest: guest, cpuCount: 2, memoryBytes: 4 << 30,
            diskBytes: 1 << 30, macAddress: "02:00:00:00:00:01", agentAccess: agentAccess)
    }

    @Test func servesOnlyMacWithAccessAndDevice() throws {
        #expect(AgentHost.shouldServe(config: try config(), hasSocketDevice: true))
        #expect(!AgentHost.shouldServe(config: try config(agentAccess: nil), hasSocketDevice: true))
        #expect(!AgentHost.shouldServe(config: try config(agentAccess: false), hasSocketDevice: true))
        #expect(!AgentHost.shouldServe(config: try config(guest: .linux), hasSocketDevice: true))
        #expect(!AgentHost.shouldServe(config: try config(), hasSocketDevice: false))
    }

    /// `nido start` reads `config.json` again for the agent socket: a read that fails is a
    /// warning, not a silent "no agent access".
    @Test func unreadableConfigIsAWarning() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try VMBundle.create(config: try config(), paths: NidoPaths(root: tmp))
        var warnings: [String] = []
        #expect(AgentHost.readConfig(bundle, onWarning: { warnings.append($0) })?.agentAccess == true)
        #expect(warnings.isEmpty)

        try Data("{".utf8).write(to: bundle.configURL)
        #expect(AgentHost.readConfig(bundle, onWarning: { warnings.append($0) }) == nil)
        #expect(warnings.count == 1)
        #expect(warnings.first?.hasPrefix(L10n.string("Agent access isn’t available: \("")")) == true)
    }

    @Test func notServedNeverCallsStart() throws {
        var started = false
        let server = AgentHost.serve(
            config: try config(agentAccess: nil), hasSocketDevice: true, onWarning: { _ in },
            start: { started = true; throw NidoError.unsafePath("x") })
        #expect(server == nil)
        #expect(!started)
    }

    @Test func failedStartIsOneWarningAndNil() throws {
        var warnings: [String] = []
        let server = AgentHost.serve(
            config: try config(), hasSocketDevice: true, onWarning: { warnings.append($0) },
            start: { throw NidoError.unsafePath("/x") })
        #expect(server == nil)
        #expect(warnings.count == 1)
        let reason = NidoError.unsafePath("/x").localizedDescription
        #expect(warnings.first == L10n.string("Agent access isn’t available: \(reason)"))
    }

    @Test func successReturnsTheServerWithoutWarning() throws {
        let tmp = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("nah-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = try config()
        let bundle = try VMBundle.create(config: config, paths: NidoPaths(root: tmp.appendingPathComponent("VMs")))
        let root = tmp.appendingPathComponent("s", isDirectory: true)
        var warnings: [String] = []
        let server = AgentHost.serve(
            config: config, hasSocketDevice: true, onWarning: { warnings.append($0) },
            start: {
                try AgentControlServer.start(
                    bundle: bundle, vmID: config.id,
                    perform: { _ async throws(AgentFailure) in (AgentReply(ok: true), nil) }, root: root)
            })
        #expect(server != nil)
        #expect(warnings.isEmpty)
        server?.stop()
    }
}

/// The owner's own clipboard request (`AgentHost.setClipboard`): straight to the helper, never
/// through the control socket.
@Suite struct AgentHostClipboardTests {
    @Test func sendsTheTextWithItsDelay() async {
        let sent = Mutex<[AgentRequest]>([])
        let answer = await AgentHost.setClipboard(
            "abcde-fghjk", clearAfter: AgentHost.clipboardClearSeconds,
            perform: { @Sendable request async throws(AgentFailure) -> (AgentReply, Data?) in
                sent.withLock { $0.append(request) }
                return (AgentReply(ok: true), nil)
            })
        #expect(answer == AgentAnswer(ok: true))
        #expect(AgentHost.clipboardClearSeconds == 60)
        #expect(sent.withLock { $0 } == [AgentRequest(action: .setClipboard(text: "abcde-fghjk", clearAfter: 60))])
    }

    /// The helper's refusal (an older helper answers `badRequest`) and a transport failure come
    /// back as a failed answer, cleaned like every answer the guest can write in.
    @Test func failuresAreAnswers() async {
        let refused = await AgentHost.setClipboard(
            "abcde", clearAfter: 60,
            perform: { @Sendable _ async throws(AgentFailure) -> (AgentReply, Data?) in
                (AgentReply(ok: false, error: .badRequest, message: "unknown op\u{9B}2J"), nil)
            })
        #expect(refused == .failure(.badRequest, "unknown op 2J"))
        let failed = await AgentHost.setClipboard(
            "abcde", clearAfter: 60,
            perform: { @Sendable _ async throws(AgentFailure) -> (AgentReply, Data?) in
                throw AgentFailure(code: .notReady, message: "waiting")
            })
        #expect(failed == .failure(.notReady, "waiting"))
    }
}
