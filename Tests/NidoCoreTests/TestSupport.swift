// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
@testable import NidoCore

/// Runs `body` on its own thread and returns its result, or nil when it has not returned within
/// `seconds` (the thread is then left behind, blocked: the caller reports a hang instead of
/// hanging the whole test run).
func withinTimeout<T: Sendable>(_ seconds: Double = 3, _ body: @escaping @Sendable () -> T) -> T? {
    let result = Mutex<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    Thread {
        let value = body()
        result.withLock { $0 = value }
        done.signal()
    }.start()
    guard done.wait(timeout: .now() + seconds) == .success else { return nil }
    return result.withLock { $0 }
}

/// The error `body` throws, or nil when it returns normally.
func thrownError(_ body: () throws -> Void) -> NidoErrorBox {
    do {
        try body()
        return NidoErrorBox(nil)
    } catch {
        return NidoErrorBox(error)
    }
}

/// A Sendable description of an outcome, comparable in `#expect`.
struct NidoErrorBox: Sendable, Equatable {
    let description: String?
    init(_ error: (any Error)?) {
        description = error.map { error in
            if let nido = error as? NidoError { return "NidoError.\(nido)" }
            return "\(type(of: error)): \(error)"
        }
    }
}

/// Creates a FIFO at `url`.
func makeFIFO(_ url: URL) throws {
    guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// `realpath(3)` of an existing path (keeps `/private`, unlike `URL.resolvingSymlinksInPath`).
func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}
