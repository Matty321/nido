// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import Synchronization

/// The interactive side of a VM's virtio serial console: two pipes between the guest and the
/// host, plus a tee of everything the guest prints into console.log (capped: `ConsoleLog`).
///
/// - Guest → host: the guest writes to `guestWriteHandle`; a dispatch read source on a private
///   serial queue reads the other end (never the main thread), appends every chunk to console.log
///   and delivers it on `output`, coalesced to at most one chunk every `flushInterval` (≈ 60/s),
///   or sooner once `maxChunk` bytes are pending.
/// - Host → guest: `send` queues a chunk (all or nothing: a chunk that does not fit in
///   `maxPendingInput` is dropped whole, so a key sequence or character is never cut) that the
///   same queue writes, non-blocking, into the pipe the guest reads from `guestReadHandle`.
///
/// Guest output is untrusted: this type only moves bytes, it never interprets them.
/// Every descriptor is close-on-exec; `close()` (idempotent, also run on deinit) first reads what
/// the guest already wrote into the pipe (into console.log and `output`), then closes them all
/// and ends `output`.
public final class SerialConsole: Sendable {
    /// Host → guest bytes that may wait for the guest to read them; more is dropped.
    public static let maxPendingInput = 64 * 1024
    /// Guest → host bytes gathered before a chunk is delivered at once.
    static let maxChunk = 256 * 1024
    /// Chunks the `output` stream keeps for a slow reader; older ones are dropped (console.log
    /// still has everything).
    static let streamBufferChunks = 64
    static let flushInterval = DispatchTimeInterval.milliseconds(16)
    /// Most guest bytes read from the pipe by `close()`: a guest still writing cannot hold it.
    static let maxCloseDrain = 4 * 1024 * 1024

    /// For the attachment: the guest reads its input from here.
    public let guestReadHandle: FileHandle
    /// For the attachment: the guest writes its output here.
    public let guestWriteHandle: FileHandle
    /// Guest → host bytes, in order. Single consumer. Ends when the console is closed.
    public let output: AsyncStream<Data>

    private let core: Core

    /// Opens (or creates, 0600) the console.log tee in append mode: a symlink, FIFO, hard link or
    /// foreign file at console.log is refused (`NidoError.unsafePath`, see `PrivateFile`).
    /// Creates the two pipes and starts reading the guest's output.
    /// console.log is capped (`ConsoleLog`: 16 MiB plus one rotated generation). With
    /// `deliversOutput == false` (the CLI without `--console`) the guest's output only goes to
    /// console.log and `output` ends at once.
    public convenience init(logURL: URL, deliversOutput: Bool = true) throws {
        try self.init(logURL: logURL, logCap: ConsoleLog.defaultCap, deliversOutput: deliversOutput)
    }

    init(logURL: URL, logCap: Int, deliversOutput: Bool = true) throws {
        let log = try ConsoleLog(url: logURL, cap: logCap)
        var toGuest: [Int32] = [-1, -1]  // host writes [1], guest reads [0]
        var fromGuest: [Int32] = [-1, -1]  // guest writes [1], host reads [0]
        do {
            try Self.makePipe(&toGuest)
            try Self.makePipe(&fromGuest)
        } catch {
            log.close()
            for fd in toGuest + fromGuest where fd >= 0 { Darwin.close(fd) }
            throw error
        }
        // Our ends are non-blocking (the queue never waits on the guest). A closed reader must
        // give EPIPE, never SIGPIPE, on either writing end.
        for fd in [toGuest[1], fromGuest[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        for fd in [toGuest[1], fromGuest[1]] { _ = fcntl(fd, F_SETNOSIGPIPE, 1) }

        guestReadHandle = FileHandle(fileDescriptor: toGuest[0], closeOnDealloc: true)
        guestWriteHandle = FileHandle(fileDescriptor: fromGuest[1], closeOnDealloc: true)
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(Self.streamBufferChunks))
        output = stream
        if !deliversOutput { continuation.finish() }
        core = Core(readFD: fromGuest[0], writeFD: toGuest[1], log: log, delivers: deliversOutput,
                    continuation: continuation)
        core.start()
    }

    deinit {
        close()
    }

    /// Queues `data` for the guest; returns at once. A chunk that does not fit next to the bytes
    /// still waiting (`maxPendingInput` in all) is dropped whole. Ignored after `close()`.
    public func send(_ data: Data) {
        core.send(data)
    }

    /// Host → guest bytes not yet taken by the guest.
    public var pendingInputCount: Int {
        core.state.withLock { $0.outbox.count }
    }

    /// Stops reading, closes every descriptor (pipes, console.log) and ends `output`. What the
    /// guest wrote before the call and still sits in the pipe is read first (at most
    /// `maxCloseDrain` bytes): the CLI closes the console right after the machine stops, and the
    /// last lines of a shutdown must reach console.log. Safe to call more than once.
    public func close() {
        guard core.beginClose() else { return }
        try? guestReadHandle.close()
        try? guestWriteHandle.close()
    }

    /// `close()`, then waits until the pipe is drained into console.log and every descriptor is
    /// closed (the CLI calls it before exiting, so the guest's last lines are not lost).
    public func closeAndWait() async {
        close()
        await withCheckedContinuation { continuation in
            core.finished.notify(queue: .global()) { continuation.resume() }
        }
    }

    private static func makePipe(_ fds: inout [Int32]) throws {
        // Darwin has no pipe2: set close-on-exec right after creating the pair.
        guard Darwin.pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    }
}

/// The descriptors and the queue that owns them. Every read, write and close of `readFD`,
/// `writeFD` and `log` runs on `queue`, so a descriptor is never used after it is closed;
/// shared bookkeeping is behind `state`.
private final class Core: Sendable {
    struct State {
        var closed = false
        /// Guest output read but not yet delivered.
        var pending = Data()
        var flushScheduled = false
        /// Host input not yet written to the guest.
        var outbox = Data()
        var drainScheduled = false
        /// The read source's cancel handler ran: `readFD` is closed.
        var readerDone = false
        /// The other descriptors are closed and `output` ended.
        var finalized = false
    }

    let state = Mutex(State())
    /// Left by `finalize()`: everything is closed.
    let finished = DispatchGroup()
    private let queue = DispatchQueue(label: "io.gitlab.pichierri.Nido.serial-console")
    private let readFD: Int32
    private let writeFD: Int32
    private let log: ConsoleLog
    private let delivers: Bool
    private let continuation: AsyncStream<Data>.Continuation
    private let source: any DispatchSourceRead
    /// One read buffer for the life of the console.
    /// `nonisolated(unsafe)`: it is only touched inside `readAvailable` and `drainPipe`, which run
    /// on the serial `queue` (the source's handlers), and freed in deinit, after the source (the
    /// only caller) is cancelled and gone.
    private nonisolated(unsafe) let readBuffer = UnsafeMutableRawBufferPointer.allocate(
        byteCount: 64 * 1024, alignment: 1)

    init(readFD: Int32, writeFD: Int32, log: ConsoleLog, delivers: Bool,
         continuation: AsyncStream<Data>.Continuation) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.log = log
        self.delivers = delivers
        self.continuation = continuation
        source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        finished.enter()
    }

    deinit {
        readBuffer.deallocate()
    }

    func start() {
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler { [self] in readerCancelled() }
        source.activate()
    }

    /// Marks the console closed; false when it already was. The read source is cancelled: its
    /// cancel handler (on the queue, after any event already queued) reads what is left in the
    /// pipe and closes `readFD`; then the other descriptors are closed and `output` ends.
    func beginClose() -> Bool {
        let first = state.withLock { state in
            guard !state.closed else { return false }
            state.closed = true
            return true
        }
        guard first else { return false }
        source.cancel()
        // The source may already be cancelled (end of file): then nobody else finalizes.
        queue.async { [self] in
            if state.withLock({ $0.readerDone }) { finalize() }
        }
        return true
    }

    /// The read source's cancel handler (on `queue`): the only place `readFD` is closed. When the
    /// console is closing, what the guest already wrote is read first.
    private func readerCancelled() {
        let closing = state.withLock { $0.closed }
        if closing { drainPipe() }
        Darwin.close(readFD)
        state.withLock { $0.readerDone = true }
        if closing { finalize() }
    }

    /// Reads the pipe until it is empty (or `maxCloseDrain` bytes): into console.log and, when
    /// delivering, into the last chunk of `output`.
    private func drainPipe() {
        var total = 0
        while total < SerialConsole.maxCloseDrain {
            let count = Darwin.read(readFD, readBuffer.baseAddress, readBuffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }  // empty (EAGAIN), end of file or error
            total += count
            let chunk = Data(UnsafeRawBufferPointer(rebasing: readBuffer[0..<count]))
            log.write(chunk)
            if delivers { state.withLock { $0.pending.append(chunk) } }
        }
    }

    /// Delivers the pending output, closes the remaining descriptors and ends `output`, once.
    private func finalize() {
        let first = state.withLock { state -> Bool in
            guard !state.finalized else { return false }
            state.finalized = true
            return true
        }
        guard first else { return }
        flush()
        Darwin.close(writeFD)
        log.close()
        continuation.finish()
        finished.leave()
    }

    // MARK: Guest → host (on `queue`)

    private func readAvailable() {
        let count = Darwin.read(readFD, readBuffer.baseAddress, readBuffer.count)
        if count == 0 {
            // Every writer is gone: nothing more will come.
            source.cancel()
            flush()
            return
        }
        guard count > 0 else { return }  // EAGAIN/EINTR: the source fires again
        let chunk = Data(UnsafeRawBufferPointer(rebasing: readBuffer[0..<count]))
        log.write(chunk)
        guard delivers else { return }
        let action = state.withLock { state -> (flushNow: Bool, schedule: Bool) in
            state.pending.append(chunk)
            // Closing: `finalize` (on this queue, after the drain) delivers what is pending.
            guard !state.closed else { return (false, false) }
            if state.pending.count >= SerialConsole.maxChunk { return (true, false) }
            if state.flushScheduled { return (false, false) }
            state.flushScheduled = true
            return (false, true)
        }
        if action.flushNow {
            flush()
        } else if action.schedule {
            queue.asyncAfter(deadline: .now() + SerialConsole.flushInterval) { [self] in flush() }
        }
    }

    private func flush() {
        let chunk = state.withLock { state -> Data in
            state.flushScheduled = false
            defer { state.pending = Data() }
            return state.pending
        }
        if !chunk.isEmpty { continuation.yield(chunk) }
    }

    // MARK: Host → guest

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        let schedule = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            guard state.outbox.count + data.count <= SerialConsole.maxPendingInput else { return false }
            state.outbox.append(data)
            if state.drainScheduled { return false }
            state.drainScheduled = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Writes what the pipe takes; retries shortly while the guest is not reading.
    private func drain() {
        let pending = state.withLock { state -> Data? in
            guard !state.closed else {
                state.drainScheduled = false
                return nil
            }
            return state.outbox
        }
        guard let pending, !pending.isEmpty else {
            state.withLock { $0.drainScheduled = false }
            return
        }
        let written = pending.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        let failure = written < 0 ? errno : 0
        let again = state.withLock { state -> Bool in
            if written > 0 {
                state.outbox.removeFirst(min(written, state.outbox.count))
            } else if failure != EAGAIN, failure != EINTR {
                state.outbox = Data()  // EPIPE or worse: the guest side is gone
            }
            if state.closed || state.outbox.isEmpty {
                state.drainScheduled = false
                return false
            }
            return true
        }
        guard again else { return }
        if written > 0 {
            queue.async { [self] in drain() }
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in drain() }
        }
    }
}
