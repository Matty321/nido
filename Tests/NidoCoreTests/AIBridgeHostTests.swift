// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import Testing
import Virtualization
@testable import NidoCore

/// Records what the host registers (a `VZVirtioSocketDevice` cannot be made outside a VM).
@MainActor
private final class FakeRegistry: VsockListenerRegistry {
    var listeners: [UInt32: VZVirtioSocketListener] = [:]
    var removed: [UInt32] = []
    func setSocketListener(_ listener: VZVirtioSocketListener, forPort port: UInt32) { listeners[port] = listener }
    func removeSocketListener(forPort port: UInt32) {
        removed.append(port)
        listeners[port] = nil
    }
}

/// One guest connection: a socket pair whose host end is handed to the bridge host.
private struct GuestEnd {
    let guest: Int32
    let host: Int32

    init() {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        guest = fds[0]
        host = fds[1]
        var one: Int32 = 1
        _ = setsockopt(guest, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Sends `request` and reads the answer until the host closes, on a thread of its own (a
    /// blocking read must not hold a thread of Swift's cooperative pool).
    func exchange(_ request: Data) async -> HTTPResult {
        let guest = guest
        return await withCheckedContinuation { continuation in
            Thread {
                _ = request.withUnsafeBytes { write(guest, $0.baseAddress!, request.count) }
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                _ = setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var answer = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(guest, &buffer, buffer.count)
                    if n <= 0 { break }
                    answer.append(contentsOf: buffer[0..<n])
                }
                close(guest)
                continuation.resume(returning: HTTPResult(answer))
            }.start()
        }
    }
}

@MainActor
@Suite struct AIBridgeHostTests {
    @Test func listenerRegisteredOnPort7701() throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        let host = AIBridgeHost(proxy: env.proxy, policy: { nil })
        let registry = FakeRegistry()
        host.register(on: registry)
        #expect(AIBridgeHost.port == 7701)
        let listener = try #require(registry.listeners[7701])
        #expect(registry.listeners.count == 1)
        #expect(listener === host.listener)
        #expect(listener.delegate === host)
        host.unregister()
        #expect(registry.removed == [7701])
        #expect(registry.listeners.isEmpty)
    }

    @Test func connectionReachesProxyWithCurrentPolicy() async throws {
        let env = try ProxyEnv(router: .answering(chunks: [completionJSON()]))
        defer { env.cleanup() }
        let host = AIBridgeHost(proxy: env.proxy, policy: { allowedPolicy })
        let end = GuestEnd()
        let closed = Mutex(false)
        let hostFD = end.host
        let accepted = host.accept(fileDescriptor: hostFD, onFinish: {
            close(hostFD)
            closed.withLock { $0 = true }
        })
        #expect(accepted)
        let answer = await end.exchange(chatRequest(#"{"model":"org/m","messages":[]}"#))
        #expect(answer.status == 200)
        #expect(answer.json?["object"] as? String == "chat.completion")
        #expect(env.router.calls.count == 1)
        #expect(!answer.text.contains(testSecret))
        await waitUntil { host.activeConnections == 0 }
        #expect(closed.withLock { $0 })
    }

    @Test func policyChangeAppliesToNextRequest() async throws {
        let env = try ProxyEnv(router: .answering(chunks: [completionJSON()]))
        defer { env.cleanup() }
        let current = Mutex<AIBridgePolicy?>(nil)
        let host = AIBridgeHost(proxy: env.proxy, policy: { current.withLock { $0 } })
        let request = chatRequest(#"{"model":"org/m","messages":[]}"#)

        let off = GuestEnd()
        #expect(host.serve(off))
        let refused = await off.exchange(request)
        #expect(refused.status == 403)
        #expect(refused.errorCode == "bridge_disabled")
        #expect(env.router.calls.isEmpty)

        current.withLock { $0 = allowedPolicy }
        let on = GuestEnd()
        #expect(host.serve(on))
        #expect(await on.exchange(request).status == 200)
        #expect(env.router.calls.count == 1)

        current.withLock { $0 = AIBridgePolicy(enabled: false, allowedModels: ["org/m"]) }
        let offAgain = GuestEnd()
        #expect(host.serve(offAgain))
        #expect(await offAgain.exchange(request).errorCode == "bridge_disabled")
        #expect(env.router.calls.count == 1)
        await waitUntil { host.activeConnections == 0 }
    }

    @Test func connectionsAreCappedAtFour() async throws {
        let env = try ProxyEnv(router: .answering(chunks: [completionJSON()]))
        defer { env.cleanup() }
        let host = AIBridgeHost(proxy: env.proxy, policy: { allowedPolicy })
        #expect(AIBridgeHost.maxConnections == 4)
        // Four guests connect and say nothing yet.
        let held = (0..<4).map { _ in GuestEnd() }
        for end in held {
            #expect(host.serve(end))
        }
        #expect(host.activeConnections == 4)
        let extra = GuestEnd()
        let refused = host.accept(fileDescriptor: extra.host, onFinish: {})
        #expect(!refused)
        #expect(host.activeConnections == 4)
        close(extra.host)
        close(extra.guest)
        // One finishes: the next connection is accepted again.
        #expect(await held[0].exchange(chatRequest(#"{"model":"org/m","messages":[]}"#)).status == 200)
        await waitUntil { host.activeConnections == 3 }
        let next = GuestEnd()
        #expect(host.serve(next))
        for end in held.dropFirst() + [next] { close(end.guest) }
        await waitUntil { host.activeConnections == 0 }
    }

    /// Idle guest connections (each waiting for its request) must not hold Swift's cooperative
    /// threads: with more idle connections than cores (a few VMs × 4) the rest of the app still
    /// runs at once.
    @Test func idleGuestsDoNotStarveTheCooperativePool() async throws {
        var envs: [ProxyEnv] = []
        var ends: [GuestEnd] = []
        var hosts: [AIBridgeHost] = []
        let width = ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<(width / 2 + 1) {
            let env = try ProxyEnv(router: .unreachable())
            envs.append(env)
            let host = AIBridgeHost(proxy: env.proxy, policy: { nil })
            hosts.append(host)
            for _ in 0..<AIBridgeHost.maxConnections {
                let end = GuestEnd()
                #expect(host.serve(end))
                ends.append(end)
            }
        }
        defer {
            for end in ends { close(end.guest) }
            for env in envs { env.cleanup() }
        }
        // Every connection is now waiting for its request (up to `AIBridgeHTTP.readTimeout`):
        // the sleep and the group below need cooperative threads.
        let started = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(300))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(width * 2) {
                group.addTask { @concurrent in
                    var x = 0
                    for i in 0..<1000 { x &+= i }
                    _ = x
                }
            }
        }
        // Ordering, not a stopwatch: if idle connections held the pool, the group could only run
        // once their reads gave up at the read deadline, which also ends those connections. So
        // the group must finish before that deadline, with every connection still open. (The
        // former fixed 2 s bound failed under the load of the full suite.)
        #expect(ContinuousClock.now - started < AIBridgeHTTP.readTimeout)
        for host in hosts { #expect(host.activeConnections == AIBridgeHost.maxConnections) }
    }

    /// The VM stopped: the listener goes, a call still at the router is cancelled (nothing keeps
    /// running, or charging, for a machine that is gone) and no connection is accepted again.
    @Test func shutdownCancelsCallsInFlightAndRefusesNewOnes() async throws {
        let cancelled = Mutex(false)
        let env = try ProxyEnv(router: FakeRouter { _, _ in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
            throw URLError(.timedOut)
        })
        defer { env.cleanup() }
        let host = AIBridgeHost(proxy: env.proxy, policy: { allowedPolicy })
        let registry = FakeRegistry()
        host.register(on: registry)
        let end = GuestEnd()
        #expect(host.serve(end))
        async let answer = end.exchange(chatRequest(#"{"model":"org/m","messages":[]}"#))
        await waitUntil { env.router.calls.count == 1 }
        let started = ContinuousClock.now
        host.shutdown()
        #expect(registry.removed == [7701])
        await waitUntil { host.activeConnections == 0 }
        #expect(host.activeConnections == 0)
        #expect(cancelled.withLock { $0 })
        #expect(ContinuousClock.now - started < .seconds(2))
        _ = await answer
        let late = GuestEnd()
        let lateAccepted = host.accept(fileDescriptor: late.host, onFinish: {})
        #expect(!lateAccepted)
        close(late.host)
        close(late.guest)
        host.shutdown()  // twice: nothing more happens
        #expect(registry.removed == [7701])
    }

    @Test func invalidDescriptorIsRefused() throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        let host = AIBridgeHost(proxy: env.proxy, policy: { nil })
        let accepted = host.accept(fileDescriptor: -1, onFinish: {})
        #expect(!accepted)
        #expect(host.activeConnections == 0)
    }

    @Test func servicesShareOneLimiterPerVM() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = VMBundle(url: tmp.appendingPathComponent("a.nido"))
        let b = VMBundle(url: tmp.appendingPathComponent("b.nido"))
        for bundle in [a, b] { try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true) }
        let services = AIBridgeServices(router: FakeRouter.unreachable(), tokenStore: FakeTokenStore(nil))
        let first = services.limiter(for: a)
        let again = services.limiter(for: a)
        let other = services.limiter(for: b)
        #expect(first === again)
        #expect(first !== other)
        _ = try services.makeHost(for: a)
    }

    /// The app reads usage from the limiter only when a session already made it (no file read on
    /// the main actor to create one).
    @Test func existingLimiterIsNeverCreated() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = VMBundle(url: tmp.appendingPathComponent("a.nido"))
        try FileManager.default.createDirectory(at: a.url, withIntermediateDirectories: true)
        let services = AIBridgeServices(router: FakeRouter.unreachable(), tokenStore: FakeTokenStore(nil))
        #expect(services.existingLimiter(for: a) == nil)
        let made = services.limiter(for: a)
        #expect(services.existingLimiter(for: a) === made)
    }

    #if DEBUG
        /// The proofs' fake router: a filtered catalog and a streamed chat with usage.
        @Test func debugFakeRouterThroughTheHost() async throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-host-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let bundle = VMBundle(url: tmp.appendingPathComponent("vm.nido"))
            try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
            var config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2, memoryBytes: 1 << 30,
                diskBytes: 1 << 30, macAddress: "02:00:00:00:00:01")
            config.aiBridge = AIBridgePolicy(enabled: true, allowedModels: ["openai/gpt-oss-120b"])
            try bundle.writeConfig(config)
            let router = DebugFakeRouter()
            let services = AIBridgeServices(router: router, tokenStore: DebugMemoryTokenStore())
            let host = try services.makeHost(for: bundle)

            let list = GuestEnd()
            #expect(host.serve(list))
            let models = await list.exchange(rawRequest("GET", "/v1/models"))
            #expect(models.status == 200)
            #expect((models.json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
                == ["openai/gpt-oss-120b"])

            let chat = GuestEnd()
            #expect(host.serve(chat))
            let streamed = await chat.exchange(
                chatRequest(#"{"model":"openai/gpt-oss-120b","stream":true,"messages":[{"role":"user","content":"hi"}]}"#))
            #expect(streamed.status == 200)
            #expect(streamed.headers["content-type"]?.hasPrefix("text/event-stream") == true)
            #expect(streamed.text.contains(#""content":" finto""#))
            #expect(streamed.text.contains("data: [DONE]"))
            #expect(!streamed.text.contains("hf_NidoDebugFakeToken"))
            await waitUntil { host.activeConnections == 0 }
            let log = try String(contentsOf: bundle.aiBridgeLogURL, encoding: .utf8)
            #expect(log.contains("openai/gpt-oss-120b"))
            #expect(!log.contains("Ciao"))
        }
    #endif

    /// The policy of a VM is read from its config file at each request.
    @Test func configPolicyReadsTheBundleEachTime() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = VMBundle(url: tmp.appendingPathComponent("vm.nido"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        let policy = AIBridgeServices.configPolicy(of: bundle)
        #expect(policy() == nil)  // no config: off
        var config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2, memoryBytes: 1 << 30,
            diskBytes: 1 << 30, macAddress: "02:00:00:00:00:01")
        try bundle.writeConfig(config)
        #expect(policy() == nil)
        config.aiBridge = allowedPolicy
        try bundle.writeConfig(config)
        #expect(policy() == allowedPolicy)
    }
}

extension AIBridgeHost {
    /// Accepts the host end of `end`, closed when its serve is over.
    fileprivate func serve(_ end: GuestEnd) -> Bool {
        let fd = end.host
        return accept(fileDescriptor: fd, onFinish: { close(fd) })
    }
}

/// Polls `condition` on the main actor for up to 5 s.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}
