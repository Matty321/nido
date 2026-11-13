// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Why `AIBridgeLimiter.reserve` refused a request.
public enum AIBridgeLimitError: Error, Equatable, Sendable {
    /// `requestsPerMinute` requests already started in the last 60 s.
    case rateLimited
    /// `AIBridgePolicy.maxConcurrentRequests` requests are in flight.
    case tooManyConcurrent
    /// The request's estimate does not fit in what is left of today's `tokensPerDay`.
    case dailyBudgetExhausted
}

/// A request admitted by `AIBridgeLimiter.reserve`; settle it exactly once with `commit`.
public struct AIBridgeReservation: Sendable, Hashable {
    let id: UUID
    /// Tokens held for it until `commit`.
    public let estimate: Int
}

/// The per-VM limits of the AI bridge (one limiter per VM):
/// - at most `requestsPerMinute` requests admitted in any sliding 60 s window;
/// - at most `AIBridgePolicy.maxConcurrentRequests` (2) in flight;
/// - at most `tokensPerDay` tokens per local calendar day (of the injected calendar), counting
///   the tokens charged so far today plus the estimates of the requests in flight.
///
/// Before forwarding, `reserve` holds the request's prudent estimate; `commit` then charges the
/// real usage when the answer had one, else the estimate (when any byte reached the guest) or
/// nothing (the call failed before any byte). A charge made after midnight goes to the new day.
///
/// Today's charged tokens are kept in `ai-bridge-usage.json` (0600, `{"day": "2026-10-24",
/// "tokens": 1234}`) so the budget survives a restart of the app. An unreadable or corrupt file
/// counts as nothing used (only Nido writes it; the guest cannot reach it); a failed write keeps
/// the count in memory.
public actor AIBridgeLimiter {
    private let usageURL: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var day: String
    private var chargedToday: Int
    private var inFlight: [UUID: Int] = [:]
    private var admitted: [Date] = []

    public init(
        usageURL: URL, calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.usageURL = usageURL
        self.calendar = calendar
        self.now = now
        let today = Self.dayString(now(), calendar: calendar)
        day = today
        let stored = Self.readUsage(usageURL)
        chargedToday = stored?.day == today ? max(0, stored?.tokens ?? 0) : 0
    }

    /// Admits a request whose prudent estimate is `estimate` tokens, or throws why not. Checked in
    /// this order: budget, concurrency, requests per minute. A refused request does not count.
    public func reserve(estimate: Int, policy: AIBridgePolicy) throws(AIBridgeLimitError) -> AIBridgeReservation {
        rollDay()
        let current = now()
        admitted.removeAll { abs(current.timeIntervalSince($0)) >= 60 }
        let held = inFlight.values.reduce(0, Self.add)
        let used = Self.add(chargedToday, held)
        guard estimate >= 0, Self.add(used, estimate) <= policy.tokensPerDay else { throw .dailyBudgetExhausted }
        guard inFlight.count < AIBridgePolicy.maxConcurrentRequests else { throw .tooManyConcurrent }
        guard admitted.count < policy.requestsPerMinute else { throw .rateLimited }
        let reservation = AIBridgeReservation(id: UUID(), estimate: estimate)
        inFlight[reservation.id] = estimate
        admitted.append(current)
        return reservation
    }

    /// Admits a `GET /v1/models` of the guest: it counts against `requestsPerMinute` (the same
    /// window as chat requests) but holds no tokens and no concurrency slot.
    public func admitListing(policy: AIBridgePolicy) throws(AIBridgeLimitError) {
        let current = now()
        admitted.removeAll { abs(current.timeIntervalSince($0)) >= 60 }
        guard admitted.count < policy.requestsPerMinute else { throw .rateLimited }
        admitted.append(current)
    }

    /// Settles `reservation` and returns the tokens charged: `usage` when the answer reported it,
    /// else the estimate if `chargeEstimateWithoutUsage` (some answer reached the guest), else 0.
    /// A second commit of the same reservation charges nothing.
    @discardableResult
    public func commit(_ reservation: AIBridgeReservation, usage: Int?, chargeEstimateWithoutUsage: Bool) -> Int {
        guard inFlight.removeValue(forKey: reservation.id) != nil else { return 0 }
        rollDay()
        let charge = max(0, usage ?? (chargeEstimateWithoutUsage ? reservation.estimate : 0))
        guard charge > 0 else { return 0 }
        chargedToday = Self.add(chargedToday, charge)
        persist()
        return charge
    }

    /// Tokens charged today (requests in flight not included).
    public func tokensUsedToday() -> Int {
        rollDay()
        return chargedToday
    }

    /// Requests admitted and not yet committed.
    public var requestsInFlight: Int { inFlight.count }

    // MARK: - Day and file

    private func rollDay() {
        let today = Self.dayString(now(), calendar: calendar)
        guard today != day else { return }
        day = today
        chargedToday = 0
    }

    /// `yyyy-MM-dd` of `date` in the calendar's time zone.
    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Saturating sum: a hostile estimate cannot overflow the budget check.
    private static func add(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }

    private struct Usage: Codable {
        var day: String
        var tokens: Int
    }

    private static let maxUsageFileSize = 4096

    private static func readUsage(_ url: URL) -> Usage? {
        guard let fd = try? PrivateFile.open(url, flags: O_RDONLY, label: url.lastPathComponent) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxUsageFileSize + 1), data.count <= maxUsageFileSize else {
            return nil
        }
        guard JSONDepth.isSafe(data) else { return nil }
        return try? JSONDecoder().decode(Usage.self, from: data)
    }

    /// Temporary file (0600, `PrivateFile`, synced) renamed over the usage file.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Usage(day: day, tokens: chargedToday)) else { return }
        let directory = usageURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(usageURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let fd = try PrivateFile.open(
                temporary, flags: O_WRONLY | O_CREAT | O_EXCL, label: temporary.lastPathComponent)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try handle.close()
            guard Darwin.rename(temporary.path, usageURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            _ = Darwin.unlink(temporary.path)
        }
    }
}
