// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private struct LimiterEnv {
    let tmp: URL
    let clock: TestClock

    init(start: Date = romeDate(2026, 10, 24, 10, 0)) throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-limiter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        clock = TestClock(start)
    }

    var usageURL: URL { tmp.appendingPathComponent("ai-bridge-usage.json") }

    func limiter() -> AIBridgeLimiter {
        let clock = clock
        return AIBridgeLimiter(usageURL: usageURL, calendar: romeCalendar(), now: { clock.now() })
    }

    func usageFile() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: usageURL)) as? [String: Any] ?? [:]
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

@Suite struct AIBridgeLimiterTests {
    @Test func dailyBudgetPersistsAcrossRestart() async throws {
        let env = try LimiterEnv()
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, tokensPerDay: 1000)

        let first = env.limiter()
        let reservation = try await first.reserve(estimate: 600, policy: policy)
        let charged = await first.commit(reservation, usage: 700, chargeEstimateWithoutUsage: true)
        #expect(charged == 700)
        #expect(await first.tokensUsedToday() == 700)

        let file = try env.usageFile()
        #expect(file["day"] as? String == "2026-10-24")
        #expect(file["tokens"] as? Int == 700)
        let mode = try FileManager.default.attributesOfItem(atPath: env.usageURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // A new limiter (the app restarted) reads the same budget.
        let second = env.limiter()
        #expect(await second.tokensUsedToday() == 700)
        await #expect(throws: AIBridgeLimitError.dailyBudgetExhausted) {
            _ = try await second.reserve(estimate: 301, policy: policy)
        }
        _ = try await second.reserve(estimate: 300, policy: policy)
    }

    @Test func budgetResetsAtLocalMidnight() async throws {
        let env = try LimiterEnv(start: romeDate(2026, 10, 24, 23, 59))
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, tokensPerDay: 1000)
        let limiter = env.limiter()
        let reservation = try await limiter.reserve(estimate: 1000, policy: policy)
        _ = await limiter.commit(reservation, usage: 1000, chargeEstimateWithoutUsage: true)
        await #expect(throws: AIBridgeLimitError.dailyBudgetExhausted) {
            _ = try await limiter.reserve(estimate: 1, policy: policy)
        }

        env.clock.set(romeDate(2026, 10, 25, 0, 1))
        #expect(await limiter.tokensUsedToday() == 0)
        // A limiter started after midnight ignores yesterday's file too.
        #expect(await env.limiter().tokensUsedToday() == 0)
        let next = try await limiter.reserve(estimate: 1000, policy: policy)
        _ = await limiter.commit(next, usage: 10, chargeEstimateWithoutUsage: true)
        #expect(try env.usageFile()["day"] as? String == "2026-10-25")
        #expect(try env.usageFile()["tokens"] as? Int == 10)
    }

    @Test func requestWindowSlides() async throws {
        let env = try LimiterEnv()
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, requestsPerMinute: 3)
        let limiter = env.limiter()
        for _ in 0..<3 {
            let r = try await limiter.reserve(estimate: 1, policy: policy)
            _ = await limiter.commit(r, usage: 1, chargeEstimateWithoutUsage: true)
            env.clock.advance(10)
        }
        await #expect(throws: AIBridgeLimitError.rateLimited) {
            _ = try await limiter.reserve(estimate: 1, policy: policy)
        }
        // 60 s after the first request it leaves the window.
        env.clock.set(romeDate(2026, 10, 24, 10, 1, 1))
        _ = try await limiter.reserve(estimate: 1, policy: policy)
    }

    @Test func concurrentReservationsCappedAtTwo() async throws {
        let env = try LimiterEnv()
        defer { env.cleanup() }
        let limiter = env.limiter()
        let a = try await limiter.reserve(estimate: 1, policy: allowedPolicy)
        _ = try await limiter.reserve(estimate: 1, policy: allowedPolicy)
        await #expect(throws: AIBridgeLimitError.tooManyConcurrent) {
            _ = try await limiter.reserve(estimate: 1, policy: allowedPolicy)
        }
        _ = await limiter.commit(a, usage: nil, chargeEstimateWithoutUsage: false)
        _ = try await limiter.reserve(estimate: 1, policy: allowedPolicy)
    }

    @Test func reservationsCountAgainstTheBudget() async throws {
        let env = try LimiterEnv()
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, tokensPerDay: 1000)
        let limiter = env.limiter()
        let held = try await limiter.reserve(estimate: 800, policy: policy)
        await #expect(throws: AIBridgeLimitError.dailyBudgetExhausted) {
            _ = try await limiter.reserve(estimate: 201, policy: policy)
        }
        // Released without usage and without bytes: nothing charged.
        #expect(await limiter.commit(held, usage: nil, chargeEstimateWithoutUsage: false) == 0)
        #expect(await limiter.tokensUsedToday() == 0)
        // Without usage after bytes reached the guest: the estimate.
        let estimated = try await limiter.reserve(estimate: 900, policy: policy)
        #expect(await limiter.commit(estimated, usage: nil, chargeEstimateWithoutUsage: true) == 900)
        #expect(await limiter.tokensUsedToday() == 900)
    }

    @Test func corruptUsageFileStartsFromZero() async throws {
        let env = try LimiterEnv()
        defer { env.cleanup() }
        try Data("not json".utf8).write(to: env.usageURL)
        #expect(await env.limiter().tokensUsedToday() == 0)
    }
}
