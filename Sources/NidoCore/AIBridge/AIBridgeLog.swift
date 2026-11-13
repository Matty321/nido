// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// One call of the AI bridge, as written to `ai-bridge.log`. Never prompts, answers, headers
/// or the token: only what is below.
public struct AIBridgeLogEntry: Codable, Sendable, Equatable {
    public var time: Date
    /// The model id the guest asked for (already checked against the policy).
    public var model: String
    /// The provider that served the call, when the router said so.
    public var provider: String?
    public var inputTokens: Int
    public var outputTokens: Int
    /// True when the tokens are the prudent estimate (the answer had no `usage`).
    public var estimated: Bool
    /// HTTP status given to the guest (502 also for a stream cut midway).
    public var status: Int
    public var durationMs: Int

    public init(
        time: Date, model: String, provider: String?, inputTokens: Int, outputTokens: Int, estimated: Bool,
        status: Int, durationMs: Int
    ) {
        self.time = time
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimated = estimated
        self.status = status
        self.durationMs = durationMs
    }
}

/// The content-free call log of the AI bridge: one JSON object per line in `ai-bridge.log`
/// (0600 via `PrivateFile`), rotated at 1 MiB into `ai-bridge.log.1` (so at most 2 MiB on disk).
/// Writing is best effort: a failure never fails a call.
public final class AIBridgeLog: Sendable {
    public static let cap = 1 << 20

    private let file: ConsoleLog

    /// Opens (or creates) the log; refuses an unsafe file (`NidoError.unsafePath`).
    public init(url: URL, cap: Int = AIBridgeLog.cap) throws {
        file = try ConsoleLog(url: url, cap: cap)
    }

    public func append(_ entry: AIBridgeLogEntry) {
        guard let line = try? Self.line(for: entry) else { return }
        file.write(line)
    }

    public func close() {
        file.close()
    }

    /// The JSON line (keys sorted, time in ISO 8601 UTC) ending in a newline.
    static func line(for entry: AIBridgeLogEntry) throws -> Data {
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Entries of `ai-bridge.log.1` then `ai-bridge.log` (oldest first), skipping lines that do
    /// not decode. Files are opened without following symlinks.
    public static func readEntries(at url: URL) -> [AIBridgeLogEntry] {
        let rotated = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [AIBridgeLogEntry] = []
        for file in [rotated, url] {
            guard let fd = try? PrivateFile.open(file, flags: O_RDONLY, label: file.lastPathComponent) else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            // A generation is at most `cap` bytes; read a little more in case the cap changed.
            guard let data = try? handle.read(upToCount: 4 * cap) else { continue }
            for line in data.split(separator: 0x0A) {
                if let entry = try? decoder.decode(AIBridgeLogEntry.self, from: Data(line)) { entries.append(entry) }
            }
        }
        return entries
    }
}
