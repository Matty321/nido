// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Virtualization

/// Where a vsock listener is registered: the session's `VZVirtioSocketDevice` (a fake in tests,
/// since the device only exists inside a machine). Main actor, like the VM's queue.
@MainActor
public protocol VsockListenerRegistry: AnyObject {
    func setSocketListener(_ listener: VZVirtioSocketListener, forPort port: UInt32)
    func removeSocketListener(forPort port: UInt32)
}

extension VZVirtioSocketDevice: VsockListenerRegistry {}

/// The Mac's end of the remote AI bridge for one VM session: listens on vsock port 7701 of the
/// session's socket device (the guest's `nido-ai-bridge` shim connects there) and hands each
/// connection to `AIBridgeProxy`, with the VM's policy read from `policy` once the request is in
/// (a change in the app applies to the next request; the listener is never restarted).
///
/// Registered only by the app's sessions (`VMSession.attachAIBridge`); `nido start` never
/// registers it, so the guest's connection is refused and the shim answers 502.
///
/// The delegate runs on the VM's queue (the main actor) and does no I/O: the connection's
/// descriptor is `dup`ed into a `FileDescriptorByteStream` (whose waits hold no thread) served by
/// a detached task, and the
/// `VZVirtioSocketConnection` is kept until that task ends, then closed. At most
/// `maxConnections` guest connections are open at once; more are refused (the proxy's own limit
/// of 2 requests in flight applies inside). `shutdown()` (the machine is gone) cancels them all.
@MainActor
public final class AIBridgeHost: NSObject, VZVirtioSocketListenerDelegate {
    /// The host port the guest shim connects to (CID 2).
    public static let port: UInt32 = 7701
    /// Guest connections open at the same time, per VM.
    public static let maxConnections = 4

    public let listener = VZVirtioSocketListener()
    private let proxy: AIBridgeProxy
    private let policy: @Sendable () -> AIBridgePolicy?
    private weak var registry: (any VsockListenerRegistry)?
    /// Open connections: the task serving each one and what to run when it ends (closing the VZ
    /// connection).
    private var open: [Int: (task: Task<Void, Never>?, onFinish: @MainActor () -> Void)] = [:]
    private var nextID = 0
    /// After `shutdown()`: nothing is accepted any more.
    private var isShutDown = false

    /// `policy`: the VM's current policy (nil = bridge off), called once per request.
    public init(proxy: AIBridgeProxy, policy: @escaping @Sendable () -> AIBridgePolicy?) {
        self.proxy = proxy
        self.policy = policy
        super.init()
        listener.delegate = self
    }

    /// Guest connections being served now.
    public var activeConnections: Int { open.count }

    /// Listens on `port` of `registry` (the session's socket device).
    public func register(on registry: any VsockListenerRegistry) {
        registry.setSocketListener(listener, forPort: Self.port)
        self.registry = registry
    }

    /// Stops listening; connections being served finish on their own.
    public func unregister() {
        registry?.removeSocketListener(forPort: Self.port)
        registry = nil
    }

    /// The machine is gone (stopped, failed, or saved for a suspension): stops listening, cancels
    /// every connection being served (a call at the router is cancelled with it and settled as
    /// the proxy settles a guest that went away) and refuses any later one. Idempotent.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        unregister()
        for connection in open.values { connection.task?.cancel() }
    }

    nonisolated public func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        nonisolated(unsafe) let connection = connection
        return MainActor.assumeIsolated {
            accept(fileDescriptor: connection.fileDescriptor, onFinish: { connection.close() })
        }
    }

    /// Serves the guest connection on `fd` (not taken over: it is `dup`ed) in a detached task,
    /// then runs `onFinish` on the main actor. False, with nothing started, when
    /// `maxConnections` are already open or `fd` cannot be duplicated.
    func accept(fileDescriptor fd: Int32, onFinish: @escaping @MainActor () -> Void) -> Bool {
        guard !isShutDown, open.count < Self.maxConnections, fd >= 0 else { return false }
        let copy = dup(fd)
        guard copy >= 0 else { return false }
        _ = fcntl(copy, F_SETFD, FD_CLOEXEC)
        let id = nextID
        nextID += 1
        open[id] = (nil, onFinish)
        let stream = FileDescriptorByteStream(fileHandle: FileHandle(fileDescriptor: copy, closeOnDealloc: true))
        let proxy = proxy
        let policy = policy
        let task = Task.detached { [weak self] in
            await proxy.serve(connection: stream, policy: policy)
            await self?.finished(id)
        }
        // The task cannot have finished yet: `finished` runs on this actor, after this returns.
        open[id]?.task = task
        return true
    }

    private func finished(_ id: Int) {
        open.removeValue(forKey: id)?.onFinish()
    }
}

/// What the bridges of one app process share (router, token store, catalog) and the one
/// `AIBridgeLimiter` per VM, so two sessions of the same VM in this process never get a budget
/// each.
@MainActor
public final class AIBridgeServices {
    public let router: any RouterClient
    public let tokenStore: any TokenStore
    public let catalog: ModelCatalog
    private var limiters: [String: AIBridgeLimiter] = [:]

    public init(router: any RouterClient, tokenStore: any TokenStore) {
        self.router = router
        self.tokenStore = tokenStore
        self.catalog = ModelCatalog(router: router, tokenStore: tokenStore)
    }

    /// The limiter of the VM in `bundle`, created on first use (its usage file in the bundle).
    public func limiter(for bundle: VMBundle) -> AIBridgeLimiter {
        let key = bundle.url.standardizedFileURL.path
        if let existing = limiters[key] { return existing }
        let limiter = AIBridgeLimiter(usageURL: bundle.aiBridgeUsageURL)
        limiters[key] = limiter
        return limiter
    }

    /// The limiter of the VM in `bundle` if one was made already (by its session), else nil:
    /// never creates one (creating reads the usage file).
    public func existingLimiter(for bundle: VMBundle) -> AIBridgeLimiter? {
        limiters[bundle.url.standardizedFileURL.path]
    }

    /// A bridge host for the VM in `bundle`: its limiter, its `ai-bridge.log` and its policy read
    /// from the bundle's config at every request. Throws when the log file cannot be opened.
    public func makeHost(for bundle: VMBundle) throws -> AIBridgeHost {
        let proxy = AIBridgeProxy(
            router: router, tokenStore: tokenStore, limiter: limiter(for: bundle),
            log: try AIBridgeLog(url: bundle.aiBridgeLogURL), catalog: catalog)
        return AIBridgeHost(proxy: proxy, policy: Self.configPolicy(of: bundle))
    }

    /// The VM's policy as its config file says now; nil (bridge off) when the file cannot be read.
    public nonisolated static func configPolicy(of bundle: VMBundle) -> @Sendable () -> AIBridgePolicy? {
        { (try? bundle.readConfig())?.aiBridge }
    }
}
