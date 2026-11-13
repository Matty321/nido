// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// Outcome of an external process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    /// The process was killed because it ran past its timeout (`status` is then the kill signal's).
    public let timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs external executables. No shell is ever involved.
public protocol ProcessRunner: Sendable {
    func run(executable: URL, arguments: [String]) throws -> ProcessResult

    /// Like `run`, with `stdin` (nil: the null device) fed to the child and a `timeout` after which
    /// the child is killed (`ProcessResult.timedOut`). Output beyond `maxOutput` bytes per stream
    /// is dropped. The default refuses: only runners built for background commands implement it.
    func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int
    ) throws -> ProcessResult

    /// Like the previous one, cancellable, with stdout handed to `onStdout` as it arrives (at
    /// most `maxOutput` bytes; the result's stdout is then unspecified). The default runs the
    /// non-streaming variant and hands its whole stdout over at the end.
    func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?, onStdout: (@Sendable (Data) -> Void)?
    ) throws -> ProcessResult

    /// Like the previous one, with the child's stdin read from `stdinFile` (from its current
    /// offset to its end) instead of a buffer in memory: for inputs too large to hold in RAM or to
    /// map (a file truncated under a mapping is a SIGBUS). `SystemProcessRunner` copies it in
    /// chunks of `SystemProcessRunner.stdinChunkSize`; the default reads it whole and runs the `Data` variant, which
    /// is meant for the tests' runners only.
    func run(
        executable: URL, arguments: [String], stdinFile: FileHandle, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?
    ) throws -> ProcessResult
}

/// Cancels a running child process from another thread (e.g. a Swift task's cancellation
/// handler). Cancelling before the child starts kills it as soon as it starts.
public final class ProcessCancellation: Sendable {
    private let state = Mutex<(cancelled: Bool, handlers: [@Sendable () -> Void])>((false, []))

    public init() {}

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func cancel() {
        let handlers = state.withLock { s -> [@Sendable () -> Void] in
            guard !s.cancelled else { return [] }
            s.cancelled = true
            defer { s.handlers = [] }
            return s.handlers
        }
        for handler in handlers { handler() }
    }

    /// Runs `handler` on cancellation, at once when already cancelled.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let now = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.handlers.append(handler)
            return false
        }
        if now { handler() }
    }
}

extension ProcessRunner {
    public func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int
    ) throws -> ProcessResult {
        throw NidoError.processFailed(executable: executable.path, status: -1)
    }

    /// Only `SystemProcessRunner` streams and kills on cancellation.
    public func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?, onStdout: (@Sendable (Data) -> Void)?
    ) throws -> ProcessResult {
        let result = try run(
            executable: executable, arguments: arguments, stdin: stdin, timeout: timeout,
            maxOutput: maxOutput)
        if let onStdout, !result.stdout.isEmpty { onStdout(result.stdout) }
        return result
    }

    public func run(
        executable: URL, arguments: [String], stdinFile: FileHandle, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?
    ) throws -> ProcessResult {
        let data = try stdinFile.readToEnd() ?? Data()
        return try run(
            executable: executable, arguments: arguments, stdin: data, timeout: timeout, maxOutput: maxOutput,
            cancellation: cancellation, onStdout: nil)
    }
}

/// Runs processes with `Process`, an absolute executable path and a minimal environment.
public struct SystemProcessRunner: ProcessRunner {
    /// Bytes copied per write when a child's stdin comes from a file.
    public static let stdinChunkSize = 1 << 20

    public init() {}

    public func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        try run(
            executable: executable, arguments: arguments, stdin: nil, timeout: .infinity,
            maxOutput: .max)
    }

    public func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int
    ) throws -> ProcessResult {
        try run(
            executable: executable, arguments: arguments, stdin: stdin, timeout: timeout,
            maxOutput: maxOutput, cancellation: nil, onStdout: nil)
    }

    public func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?, onStdout: (@Sendable (Data) -> Void)?
    ) throws -> ProcessResult {
        try launch(
            executable: executable, arguments: arguments, input: stdin.map(Input.data) ?? .none, timeout: timeout,
            maxOutput: maxOutput, cancellation: cancellation, onStdout: onStdout)
    }

    public func run(
        executable: URL, arguments: [String], stdinFile: FileHandle, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?
    ) throws -> ProcessResult {
        try launch(
            executable: executable, arguments: arguments, input: .file(stdinFile), timeout: timeout,
            maxOutput: maxOutput, cancellation: cancellation, onStdout: nil)
    }

    /// Where the child's stdin comes from.
    private enum Input {
        case none
        case data(Data)
        case file(FileHandle)
    }

    private func launch(
        executable: URL, arguments: [String], input: Input, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?, onStdout: (@Sendable (Data) -> Void)?
    ) throws -> ProcessResult {
        let path = executable.path
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw NidoError.processFailed(executable: path, status: -1)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        if case .none = input {
            process.standardInput = FileHandle.nullDevice
        } else {
            process.standardInput = inPipe
        }
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            throw NidoError.processFailed(executable: path, status: -1)
        }
        // Everything that can block runs on a thread of its own: a block on a global queue can
        // wait forever for a worker thread when the callers (e.g. Swift concurrency tasks) block
        // every thread of the pool in here.
        let timedOut = DataBox()
        // Left once the process has been reaped. A group, not a semaphore: the timeout's and the
        // cancellation's waiters all wake on it, none takes the signal from another.
        let finished = DispatchGroup()
        finished.enter()
        cancellation?.onCancel {
            // Same escalation as the timeout: terminate, SIGKILL after 2 s if still running.
            guard process.isRunning else { return }
            process.terminate()
            Thread {
                if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }.start()
        }
        if timeout.isFinite {
            Thread {
                if finished.wait(timeout: .now() + timeout) == .timedOut, process.isRunning {
                    timedOut.flag = true
                    // terminate, wait, SIGKILL only if still running after the grace period
                    // (`finished` is left once the process has been reaped).
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }.start()
        }
        let handle = inPipe.fileHandleForWriting
        // Signalled when the copy of a stdin file has ended (`.file` only).
        let stdinCopied = DispatchSemaphore(value: 0)
        // A child that exits early must not kill us with SIGPIPE.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        switch input {
        case .none:
            break
        case .data(let stdin):
            Thread {
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }.start()
        case .file(let source):
            // Chunk by chunk: the file is never held in memory nor mapped. A child that exits
            // early ends the copy (EPIPE). The thread reads its own duplicate of the descriptor,
            // so the caller closing its handle once `run` returns never leaves it reading a
            // closed (or reused) descriptor; `run` also waits for the copy to end.
            let copy = dup(source.fileDescriptor)
            Thread {
                defer {
                    try? handle.close()
                    stdinCopied.signal()
                }
                guard copy >= 0 else { return }
                let reader = FileHandle(fileDescriptor: copy, closeOnDealloc: true)
                while let chunk = try? reader.read(upToCount: Self.stdinChunkSize), !chunk.isEmpty {
                    do { try handle.write(contentsOf: chunk) } catch { break }
                }
            }.start()
        }
        let errBox = DataBox()
        let drained = DispatchSemaphore(value: 0)
        Thread {
            errBox.data = Self.drain(errPipe.fileHandleForReading, limit: maxOutput)
            drained.signal()
        }.start()
        let out: Data
        if let onStdout {
            Self.stream(outPipe.fileHandleForReading, limit: maxOutput, to: onStdout)
            out = Data()
        } else {
            out = Self.drain(outPipe.fileHandleForReading, limit: maxOutput)
        }
        drained.wait()
        process.waitUntilExit()
        finished.leave()
        if case .file = input {
            // The child is gone, so the copy ends at its next write (EPIPE); bounded anyway.
            _ = stdinCopied.wait(timeout: .now() + 10)
        }
        return ProcessResult(
            status: process.terminationStatus, stdout: out, stderr: errBox.data,
            timedOut: timedOut.flag)
    }

    /// Hands each chunk to `sink` as soon as `read(2)` returns it, up to `limit` bytes in all; the
    /// rest is read and dropped so the child never blocks on a full pipe.
    private static func stream(_ handle: FileHandle, limit: Int, to sink: @Sendable (Data) -> Void) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var delivered = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            if delivered < limit {
                let take = min(n, limit - delivered)
                delivered += take
                sink(Data(buffer[0..<take]))
            }
        }
    }

    /// Reads to end of file but keeps only the first `limit` bytes (the rest is read and dropped
    /// so the child never blocks on a full pipe).
    private static func drain(_ handle: FileHandle, limit: Int) -> Data {
        guard limit < .max else { return handle.readDataToEndOfFile() }
        var kept = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if kept.count < limit { kept.append(chunk.prefix(limit - kept.count)) }
        }
        return kept
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
    var flag = false
}
