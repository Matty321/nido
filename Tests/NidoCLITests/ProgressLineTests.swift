// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCLI
@testable import NidoCore

private final class Sink: Sendable {
    let text = Mutex("")
    func write(_ s: String) { text.withLock { $0 += s } }
}

@Suite(.italian) struct ProgressLineTests {
    /// The `\r` progress line is ended on every exit path, so "Errore: …" starts on its own line.
    @Test func lineIsTerminatedWhenTheDownloadFails() {
        let sink = Sink()
        func download() throws {
            let line = ProgressLine(write: sink.write)
            defer { line.finish() }
            line.show(DownloadProgress(receivedBytes: 1 << 20, expectedBytes: 4 << 20))
            throw NidoError.downloadFailed("rete")
        }
        #expect(throws: NidoError.self) { try download() }
        sink.write("Errore: download fallito\n")
        #expect(sink.text.withLock { $0 } == "\rDownload: 25% (1 MiB / 4 MiB)\nErrore: download fallito\n")
    }

    @Test func nothingIsWrittenWithoutProgress() {
        let sink = Sink()
        let line = ProgressLine(write: sink.write)
        line.finish()
        line.finish()
        #expect(sink.text.withLock { $0 }.isEmpty)
    }

    @Test func finishWritesOneNewlineOnly() {
        let sink = Sink()
        let line = ProgressLine(write: sink.write)
        line.show(DownloadProgress(receivedBytes: 3 << 20, expectedBytes: nil))
        line.finish()
        line.finish()
        #expect(sink.text.withLock { $0 } == "\rDownload: 3 MiB\n")
    }

    /// A progress report racing with `finish()` never lands after the final newline: the write
    /// happens under the lock, so `finish()` waits for it.
    @Test func lateProgressAfterFinishIsIgnored() {
        let sink = Sink()
        let inShow = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let line = ProgressLine { text in
            if text.hasPrefix("\r") {
                inShow.signal()
                _ = proceed.wait(timeout: .now() + 5)
            }
            sink.write(text)
        }
        let finished = DispatchSemaphore(value: 0)
        let shower = Thread {
            line.show(DownloadProgress(receivedBytes: 2 << 20, expectedBytes: 4 << 20))
        }
        shower.start()
        #expect(inShow.wait(timeout: .now() + 5) == .success)
        Thread {
            line.finish()
            finished.signal()
        }.start()
        // finish() runs (or waits) while the progress text is still being written.
        usleep(100_000)
        proceed.signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        line.show(DownloadProgress(receivedBytes: 3 << 20, expectedBytes: 4 << 20))
        #expect(sink.text.withLock { $0 } == "\rDownload: 50% (2 MiB / 4 MiB)\n")
    }
}
