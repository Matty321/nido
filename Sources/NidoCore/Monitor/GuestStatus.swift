// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Why a status could not be fetched.
public enum MonitorError: Error, Equatable, Sendable {
    /// Nothing listens in the guest (Guest Tools missing or not running yet), or the VM has no
    /// vsock device.
    case unavailable
    case timeout
    /// Truncated, oversized, not HTTP 200 or not a status document.
    case invalidResponse
    /// A well-formed status of a protocol major version this app does not know (the payload).
    case unsupportedVersion(String)
}

/// `OK` / `WARNING` as the guest reports it; anything else is kept as `.unknown`.
public enum GuestHealth: Sendable, Equatable {
    case ok, warning
    case unknown(String)

    init(_ text: String?) {
        switch text {
        case "OK": self = .ok
        case "WARNING": self = .warning
        default: self = .unknown(text ?? "")
        }
    }
}

public struct GuestSystem: Sendable, Equatable {
    public var hostname: String?
    public var architecture: String?
    public var kernel: String?
    public var uptimeSeconds: Int?
}

public struct GuestCPU: Sendable, Equatable {
    public var vcpus: Int?
    public var usagePercent: Double?
    public var load1Min: Double?
    public var load5Min: Double?
    public var load15Min: Double?
    public var status: GuestHealth
}

public struct GuestMemory: Sendable, Equatable {
    public var totalGiB: Double?
    public var usedGiB: Double?
    public var availableGiB: Double?
    public var usagePercent: Double?
    public var swapTotalGiB: Double?
    public var swapUsedGiB: Double?
    /// Nil when no swap is configured (the guest sends null).
    public var swapUsagePercent: Double?
    public var status: GuestHealth
}

public struct GuestDisk: Sendable, Equatable {
    public var totalGiB: Double?
    public var usedGiB: Double?
    public var availableGiB: Double?
    public var usagePercent: Double?
    public var status: GuestHealth
}

/// The guest's provisioning progress (`/var/lib/nido-provision/state.json`), as embedded by the
/// Guest Tools. All fields optional: the file's format belongs to the provisioning script.
/// `nido-provision` writes `{"version": 1, "steps": {name: {...}}}` (read into `steps`, with a
/// `running` entry of another boot or a dead process already reported as `failed` by the Guest
/// Tools); the flat `step`/`state`/`message`/`error` fields are those of a single-step document.
public struct GuestProvisioning: Sendable, Equatable {
    public var step: String?
    public var state: String?
    public var message: String?
    public var error: String?
    /// The steps by name (`ollama-install`, `model-pull`, …), as `AIRuntime.status()` reads them.
    public var steps: [String: ProvisionStep] = [:]
}

/// The `/api/status` document of the guest's monitor (the user's original API or Guest Tools).
/// Decoding is tolerant: every field is optional, a section of the wrong shape is dropped, numbers
/// may be numeric strings. Unknown keys are ignored.
public struct GuestStatus: Sendable, Equatable {
    public var agent: String?
    public var version: String?
    public var timestamp: Date?
    public var hostname: String?
    public var system: GuestSystem?
    public var cpu: GuestCPU?
    public var memory: GuestMemory?
    public var disk: GuestDisk?
    public var alerts: [String]
    public var status: GuestHealth
    public var provisioning: GuestProvisioning?

    /// Protocol major version 2 (`"2"` or `"2.x"`): the only one this app knows.
    public var isSupportedVersion: Bool {
        guard let version else { return false }
        return version.split(separator: ".", omittingEmptySubsequences: false).first == "2"
    }

    /// Decodes a status document. Throws `.invalidResponse` when `data` is not a JSON object or
    /// has none of the known fields. Does not look at the version (`isSupportedVersion`).
    public static func decode(_ data: Data) throws(MonitorError) -> GuestStatus {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .invalidResponse
        }
        let known = ["agent", "version", "timestamp", "hostname", "system", "cpu", "memory", "disk",
                     "alerts", "status", "provisioning"]
        guard known.contains(where: { root[$0] != nil }) else { throw .invalidResponse }
        let reader = Reader(root)
        return GuestStatus(
            agent: reader.string("agent"), version: reader.string("version"),
            timestamp: reader.string("timestamp").flatMap(parseDate),
            hostname: reader.string("hostname") ?? reader.object("system")?.string("hostname"),
            system: reader.object("system").map {
                GuestSystem(
                    hostname: $0.string("hostname"), architecture: $0.string("architecture"),
                    kernel: $0.string("kernel"), uptimeSeconds: $0.int("uptime_seconds"))
            },
            cpu: reader.object("cpu").map {
                GuestCPU(
                    vcpus: $0.int("vcpus"), usagePercent: $0.double("usage_percent"),
                    load1Min: $0.double("load_1min"), load5Min: $0.double("load_5min"),
                    load15Min: $0.double("load_15min"), status: GuestHealth($0.string("status")))
            },
            memory: reader.object("memory").map {
                GuestMemory(
                    totalGiB: $0.double("total_gib"), usedGiB: $0.double("used_gib"),
                    availableGiB: $0.double("available_gib"), usagePercent: $0.double("usage_percent"),
                    swapTotalGiB: $0.double("swap_total_gib"), swapUsedGiB: $0.double("swap_used_gib"),
                    swapUsagePercent: $0.double("swap_usage_percent"), status: GuestHealth($0.string("status")))
            },
            disk: reader.object("disk").map {
                GuestDisk(
                    totalGiB: $0.double("total_gib"), usedGiB: $0.double("used_gib"),
                    availableGiB: $0.double("available_gib"), usagePercent: $0.double("usage_percent"),
                    status: GuestHealth($0.string("status")))
            },
            alerts: (root["alerts"] as? [Any])?.compactMap { $0 as? String } ?? [],
            status: GuestHealth(reader.string("status")),
            provisioning: reader.object("provisioning").map {
                GuestProvisioning(
                    step: $0.string("step"), state: $0.string("state"),
                    message: $0.string("message"), error: $0.string("error"),
                    steps: ProvisionStep.parseSteps($0.values["steps"]))
            })
    }

    /// Reads typed values out of a JSON object, leniently.
    private struct Reader {
        let values: [String: Any]
        init(_ values: [String: Any]) { self.values = values }

        func object(_ key: String) -> Reader? { (values[key] as? [String: Any]).map(Reader.init) }

        /// A string; a number is accepted too (a version sent as `2.0`).
        func string(_ key: String) -> String? {
            switch values[key] {
            case let text as String: return text
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                return number.stringValue
            default: return nil
            }
        }

        /// A number or a numeric string; NaN and infinities are refused.
        func double(_ key: String) -> Double? {
            let value: Double?
            switch values[key] {
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                value = number.doubleValue
            case let text as String:
                value = Double(text.trimmingCharacters(in: .whitespaces))
            default: value = nil
            }
            guard let value, value.isFinite else { return nil }
            return value
        }

        func int(_ key: String) -> Int? {
            guard let value = double(key), value.magnitude < 1e15 else { return nil }
            return Int(value.rounded())
        }
    }

    /// ISO 8601 as Python's `isoformat()` writes it, with or without fractional seconds.
    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
