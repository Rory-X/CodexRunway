import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Local quota allowance")
struct LocalQuotaAllowanceScannerTests {
    // MARK: - Fixture

    /// Writes a rollout file shaped like Codex's own output.
    private func makeHome() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local-allowance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(
        home: URL,
        day: String,
        name: String,
        plan: String,
        weeklyPercentAt: [(Double, Int)],
        windowMinutes: Int = 10_080,
        resetsAt: Int = 1_790_172_732,
        slot: String = "primary"
    ) throws {
        let parts = day.split(separator: "-").map(String.init)
        let dir = home.appendingPathComponent("sessions/\(parts[0])/\(parts[1])/\(parts[2])")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cumulative = 0
        var lines: [String] = []
        var minute = 0
        for (percent, increment) in weeklyPercentAt {
            cumulative += increment
            minute += 1
            let window = """
            {"used_percent":\(percent),"window_minutes":\(windowMinutes),"resets_at":\(resetsAt)}
            """
            let other = #"{"used_percent":0.0,"window_minutes":300,"resets_at":1}"#
            let primary = slot == "primary" ? window : other
            let secondary = slot == "primary" ? other : window
            lines.append("""
            {"timestamp":"\(day)T00:\(String(format: "%02d", minute)):00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(cumulative),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(cumulative)}},"rate_limits":{"plan_type":"\(plan)","primary":\(primary),"secondary":\(secondary)}}}
            """)
        }
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("rollout-\(name).jsonl"),
            atomically: true,
            encoding: .utf8)
    }

    // MARK: - Tests

    @Test("a clean linear series recovers the window allowance")
    func recoversAllowance() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // 1 percentage point == 500_000 tokens, so the allowance is 50M.
        try writeSession(
            home: home, day: "2026-09-17", name: "a", plan: "team",
            weeklyPercentAt: [(1, 500_000), (2, 500_000), (3, 500_000), (4, 500_000), (5, 500_000)])

        let results = LocalQuotaAllowanceScanner(codexHome: home).scan()
        let allowance = try #require(results.first)
        #expect(results.count == 1)
        #expect(allowance.plan == "team")
        #expect(allowance.windowMinutes == 10_080)
        #expect(abs(allowance.allowanceTokens - 50_000_000) < 1)
        #expect(allowance.isReliable)
        #expect(allowance.rSquared > 0.99)
    }

    @Test("the weekly window is found in the secondary slot too")
    func findsWindowInSecondarySlot() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // `plus` reports its weekly meter as secondary.
        try writeSession(
            home: home, day: "2026-09-17", name: "b", plan: "plus",
            weeklyPercentAt: [(1, 400_000), (2, 400_000), (3, 400_000), (4, 400_000)],
            slot: "secondary")

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        #expect(allowance.plan == "plus")
        #expect(abs(allowance.allowanceTokens - 40_000_000) < 1)
    }

    /// One rollout file legitimately contains two accounts: switching in the app
    /// continues the same file. Fitting across the seam would blend two windows.
    @Test("one file spanning two windows is split, not blended")
    func splitsAcrossWindowChange() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions/2026/09/17")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // First window: 1pp == 100k. Second window: 1pp == 900k, different resets_at.
        let rows: [(Double, Int, Int, String)] = [
            (1, 100_000, 1000, "plus"),
            (2, 200_000, 1000, "plus"),
            (3, 300_000, 1000, "plus"),
            (1, 1_200_000, 2000, "plus"),
            (2, 2_100_000, 2000, "plus"),
            (3, 3_000_000, 2000, "plus"),
        ]
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let (percent, cumulative, reset, plan) = row
            lines.append("""
            {"timestamp":"2026-09-17T00:\(String(format: "%02d", index + 1)):00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(cumulative),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(cumulative)}},"rate_limits":{"plan_type":"\(plan)","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":\(percent),"window_minutes":10080,"resets_at":\(reset)}}}}
            """)
        }
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("rollout-mixed.jsonl"), atomically: true, encoding: .utf8)

        let allowances = LocalQuotaAllowanceScanner(codexHome: home).scan()
        #expect(allowances.count == 2, "each window must be fitted separately")
        let values = allowances.map(\.allowanceTokens).sorted()
        #expect(abs(values[0] - 10_000_000) < 1)
        #expect(abs(values[1] - 90_000_000) < 1)
    }

    @Test("a few seconds of jitter in resets_at is one window, not two")
    func toleratesResetJitter() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Same minute, different seconds: 1_790_172_727 / _732 / _733. Each session
        // carries a real slope so the only thing under test is the window identity.
        for (index, reset) in [1_790_172_727, 1_790_172_732, 1_790_172_733].enumerated() {
            let base = Double(index * 3 + 1)
            try writeSession(
                home: home, day: "2026-09-17", name: "j\(index)", plan: "team",
                weeklyPercentAt: [(base, 500_000), (base + 1, 500_000), (base + 2, 500_000)],
                resetsAt: reset)
        }
        let allowances = LocalQuotaAllowanceScanner(codexHome: home).scan()
        #expect(allowances.count == 1, "jitter must not split an account")
    }

    @Test("a series with no percentage movement yields no allowance")
    func flatSeriesIsRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSession(
            home: home, day: "2026-09-17", name: "flat", plan: "team",
            weeklyPercentAt: [(0, 100_000), (0, 100_000), (0, 100_000), (0, 100_000)])

        #expect(LocalQuotaAllowanceScanner(codexHome: home).scan().isEmpty)
    }

    @Test("a noisy series is reported but flagged unreliable")
    func noisySeriesIsFlagged() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Percentage creeps while tokens jump erratically: a poor fit.
        try writeSession(
            home: home, day: "2026-09-17", name: "noisy", plan: "team",
            weeklyPercentAt: [(1, 5_000_000), (2, 100), (3, 9_000_000), (4, 200), (5, 1_000)])

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        #expect(!allowance.isReliable)
    }

    @Test("an unrelated plan's window is not reported for the weekly scan")
    func ignoresOtherWindows() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Only a 5-hour window present: nothing to fit for the weekly scan.
        try writeSession(
            home: home, day: "2026-09-17", name: "five", plan: "team",
            weeklyPercentAt: [(1, 100_000), (2, 200_000)],
            windowMinutes: 300)

        #expect(LocalQuotaAllowanceScanner(codexHome: home).scan().isEmpty)
    }

    @Test("a missing codex home yields nothing rather than failing")
    func missingHomeIsEmpty() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(LocalQuotaAllowanceScanner(codexHome: missing).scan().isEmpty)
    }

    // MARK: - USD allowance

    /// Writes a session whose turns use a specific model, so the price table applies.
    private func writePricedSession(
        home: URL,
        day: String,
        name: String,
        plan: String,
        model: String,
        weeklyPercentAt: [(Double, Int, Int, Int)],
        unpriced: Bool = false
    ) throws {
        let parts = day.split(separator: "-").map(String.init)
        let dir = home.appendingPathComponent("sessions/\(parts[0])/\(parts[1])/\(parts[2])")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var lines: [String] = []
        var minute = 0
        // Both counters are cumulative per session, exactly as Codex writes them, so
        // the fit has a real slope to recover.
        var cumulativeTokens = 0
        var cumulativeUncached = 0
        var cumulativeCached = 0
        var cumulativeOutput = 0
        for (percent, uncached, cached, output) in weeklyPercentAt {
            minute += 1
            cumulativeUncached += uncached
            cumulativeCached += cached
            cumulativeOutput += output
            cumulativeTokens += uncached + cached + output
            lines.append("""
            {"timestamp":"\(day)T00:\(String(format: "%02d", minute)):00.000Z","type":"turn_context","payload":{"model":"\(model)"}}
            """)
            lines.append("""
            {"timestamp":"\(day)T00:\(String(format: "%02d", minute)):30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(uncached + cached),"cached_input_tokens":\(cached),"output_tokens":\(output),"total_tokens":\(uncached + cached + output)},"total_token_usage":{"input_tokens":\(cumulativeUncached + cumulativeCached),"cached_input_tokens":\(cumulativeCached),"output_tokens":\(cumulativeOutput),"total_tokens":\(cumulativeTokens)}},"rate_limits":{"plan_type":"\(plan)","primary":{"used_percent":\(percent),"window_minutes":10080,"resets_at":1790172732},"secondary":{"used_percent":0.0,"window_minutes":300,"resets_at":1}}}}
            """)
        }
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("rollout-\(name).jsonl"), atomically: true, encoding: .utf8)
    }

    @Test("a priced model yields a dollar allowance alongside the token one")
    func pricesAllowance() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // gpt-6-astra: $10/M fresh input, $1/M cached, $50/M output.
        // Each percentage point spends 1M fresh input = $10, so 100pp = $1000.
        try writePricedSession(
            home: home, day: "2026-09-17", name: "priced", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: [(1, 1_000_000, 0, 0), (2, 1_000_000, 0, 0),
                              (3, 1_000_000, 0, 0), (4, 1_000_000, 0, 0),
                              (5, 1_000_000, 0, 0)])

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        let usd = try #require(allowance.allowanceUSD)
        #expect(abs(usd - 1000) < 1, "got \(usd)")
        #expect(allowance.isReliable)
    }

    @Test("cached input is priced below fresh input, not at the same rate")
    func cachedInputIsDiscounted() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // 1M cached input per point at $1/M => $100 for 100pp, versus $1000 fresh.
        try writePricedSession(
            home: home, day: "2026-09-17", name: "cached", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: [(1, 0, 1_000_000, 0), (2, 0, 1_000_000, 0),
                              (3, 0, 1_000_000, 0), (4, 0, 1_000_000, 0),
                              (5, 0, 1_000_000, 0)])

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        let usd = try #require(allowance.allowanceUSD)
        #expect(abs(usd - 100) < 1, "cached input must be discounted; got \(usd)")
        // The token figure counts cached tokens at full weight: 1M per point over 5
        // points extrapolates to 100M tokens, yet the same window is only $100 —
        // a 10x gap that is exactly why USD is the honest headline for a plan whose
        // meter tracks spend.
        #expect(abs(allowance.allowanceTokens - 100_000_000) < 1_000)
    }

    @Test("an unpriced model withholds the dollar figure rather than understating it")
    func unpricedModelSuppressesUSD() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writePricedSession(
            home: home, day: "2026-09-17", name: "unknown", plan: "team",
            model: "totally-unknown-model-xyz",
            weeklyPercentAt: [(1, 1_000_000, 0, 0), (2, 1_000_000, 0, 0),
                              (3, 1_000_000, 0, 0), (4, 1_000_000, 0, 0)])

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        #expect(allowance.allowanceUSD == nil)
        // The token figure is still recoverable, so the section keeps showing that.
        #expect(allowance.allowanceTokens > 0)
    }

    // MARK: - Remaining

    @Test("remaining is the allowance left after the used percentage")
    func remainingTracksUsedPercent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // One point per step, 1M fresh input per point at $10/M => $10 per point,
        // so the cap is $1000 and stopping at 20% leaves $800.
        try writePricedSession(
            home: home, day: "2026-09-17", name: "rem", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: (1...20).map { (Double($0), 1_000_000, 0, 0) })

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        #expect(abs(allowance.usedPercent - 20) < 0.001)
        let total = try #require(allowance.allowanceUSD)
        let remaining = try #require(allowance.remainingUSD)
        #expect(abs(total - 1000) < 1, "cap was \(total)")
        #expect(abs(remaining - 800) < 1, "got \(remaining)")
        #expect(abs(allowance.usedFraction - 0.2) < 0.001)
    }

    /// A window can be partly spent before this machine logs anything, so remaining
    /// must come from the fitted line and not from subtracting observed costs.
    @Test("remaining accounts for spend that happened before the first local sample")
    func remainingIgnoresSampleOrigin() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // The fixture starts at 40%, as if earlier usage was elsewhere. $10/pp means
        // the cap is $1000 regardless of where observation began.
        try writePricedSession(
            home: home, day: "2026-09-17", name: "origin", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: (40...60).map { (Double($0), 1_000_000, 0, 0) })

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        let total = try #require(allowance.allowanceUSD)
        let remaining = try #require(allowance.remainingUSD)
        #expect(abs(total - 1000) < 5, "cap must not shrink to the observed span; got \(total)")
        #expect(abs(remaining - 400) < 5, "60% used leaves 40%; got \(remaining)")
    }

    @Test("a fully consumed window reports zero remaining, never a negative")
    func exhaustedWindowClampsAtZero() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writePricedSession(
            home: home, day: "2026-09-17", name: "full", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: (80...100).map { (Double($0), 1_000_000, 0, 0) })

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        #expect(allowance.remainingUSD == 0)
        #expect(allowance.usedFraction == 1)
    }

    @Test("restating with a fresher percentage moves the remainder, not the cap")
    func restatedKeepsCapAndMovesRemainder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writePricedSession(
            home: home, day: "2026-09-17", name: "restate", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: (1...10).map { (Double($0), 1_000_000, 0, 0) })

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        let cap = try #require(allowance.allowanceUSD)

        // The live meter has moved on to 50% since the last local sample.
        let fresher = allowance.restated(usedPercent: 50)
        #expect(abs((fresher.allowanceUSD ?? 0) - cap) < 0.001, "the cap itself must not move")
        #expect(fresher.usedPercent == 50)
        #expect(abs((fresher.remainingUSD ?? 0) - cap / 2) < 0.5, "half used leaves half")

        // Out-of-range input is clamped rather than producing a negative remainder.
        #expect(allowance.restated(usedPercent: 140).remainingUSD == 0)
        #expect(allowance.restated(usedPercent: -5).usedPercent == 0)
    }

    @Test("the injected price table is what the dollar figure uses")
    func injectedPricesAreUsed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writePricedSession(
            home: home, day: "2026-09-17", name: "inject", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: (1...10).map { (Double($0), 1_000_000, 0, 0) })

        // A table that prices everything at exactly $1/M fresh input.
        let cheap = PricingTable.Price(
            inputPerMillion: 1, cachedInputPerMillion: 0.1, outputPerMillion: 1)
        let scanner = LocalQuotaAllowanceScanner(
            codexHome: home,
            priceForModel: { _ in cheap })

        let allowance = try #require(scanner.scan().first)
        // 1M fresh input per point at $1/M => $1 per point => $100 cap.
        #expect(abs((allowance.allowanceUSD ?? 0) - 100) < 0.5)
        // The bundled table would have said $1000, so this proves the injection wins.
        let bundled = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        #expect(abs((bundled.allowanceUSD ?? 0) - 1000) < 1)
    }

    @Test("a model the injected table does not know suppresses the dollar figure")
    func injectedTableMissSuppressesUSD() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writePricedSession(
            home: home, day: "2026-09-17", name: "miss", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: (1...8).map { (Double($0), 1_000_000, 0, 0) })

        let scanner = LocalQuotaAllowanceScanner(codexHome: home, priceForModel: { _ in nil })
        let allowance = try #require(scanner.scan().first)
        #expect(allowance.allowanceUSD == nil)
        #expect(allowance.allowanceTokens > 0)
    }

    @Test("the breakdown reports the token mix and cache rate")
    func breakdownReportsMix() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Each point: 1M fresh, 9M cached, 0.1M output. Input = 10M, 90% cached.
        try writePricedSession(
            home: home, day: "2026-09-17", name: "mix", plan: "team",
            model: "gpt-6-astra",
            weeklyPercentAt: (1...10).map { (Double($0), 1_000_000, 9_000_000, 100_000) })

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        let mix = allowance.breakdown
        #expect(mix.uncachedInputTokens == 10_000_000)
        #expect(mix.cachedInputTokens == 90_000_000)
        #expect(mix.outputTokens == 1_000_000)
        #expect(mix.inputTokens == 100_000_000)
        #expect(mix.totalTokens == 101_000_000)
        let rate = try #require(mix.cacheHitRate)
        #expect(abs(rate - 0.9) < 0.001, "got \(rate)")
        #expect(mix.models == ["gpt-6-astra"])
        #expect(!allowance.spansMultipleModels)
        // The observations are exposed so the derivation can be inspected.
        #expect(allowance.points.count == 10)
    }

    @Test("a window using several models is flagged as a blended rate")
    func multiModelIsFlagged() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions/2026/09/17")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var lines: [String] = []
        var cumulative = 0
        let models = ["gpt-6-astra", "gpt-5.6-luna"]
        for point in 1...8 {
            let model = models[point % models.count]
            cumulative += 1_000_000
            lines.append("""
            {"timestamp":"2026-09-17T00:\(String(format: "%02d", point)):00.000Z","type":"turn_context","payload":{"model":"\(model)"}}
            """)
            lines.append("""
            {"timestamp":"2026-09-17T00:\(String(format: "%02d", point)):30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000},"total_token_usage":{"input_tokens":\(cumulative),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(cumulative)}},"rate_limits":{"plan_type":"team","primary":{"used_percent":\(Double(point)),"window_minutes":10080,"resets_at":1790172732},"secondary":{"used_percent":0.0,"window_minutes":300,"resets_at":1}}}}
            """)
        }
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("rollout-multi.jsonl"), atomically: true, encoding: .utf8)

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        #expect(allowance.spansMultipleModels)
        #expect(Set(allowance.breakdown.models) == Set(models))
    }

    /// The bug this guards: Codex's per-session cost counter restarts on a new
    /// session, so presenting it raw made window spend appear to fall backwards —
    /// $20.62 down to $0.23 on an ordinary session change.
    @Test("cumulative spend keeps rising across a session boundary")
    func cumulativeSpendSpansSessions() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions/2026/09/17")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Two sessions of the same window. Each starts its own running total, so the
        // second session's raw cost is small even though the window total is large.
        func session(_ name: String, from: Int, to: Int) throws {
            var lines: [String] = []
            // Each session counts from zero again, which is what makes the raw cost
            // series appear to reset.
            var cumulative = 0
            for point in from...to {
                cumulative += 1_000_000
                lines.append("""
                {"timestamp":"2026-09-17T00:\(String(format: "%02d", point)):00.000Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}
                """)
                lines.append("""
                {"timestamp":"2026-09-17T00:\(String(format: "%02d", point)):30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000},"total_token_usage":{"input_tokens":\(cumulative),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(cumulative)}},"rate_limits":{"plan_type":"team","primary":{"used_percent":\(Double(point)),"window_minutes":10080,"resets_at":1790172732},"secondary":{"used_percent":0.0,"window_minutes":300,"resets_at":1}}}}
                """)
            }
            try lines.joined(separator: "\n").write(
                to: dir.appendingPathComponent("rollout-\(name).jsonl"),
                atomically: true, encoding: .utf8)
        }
        try session("first", from: 1, to: 20)
        try session("second", from: 21, to: 30)

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        let ordered = allowance.points.sorted { $0.at < $1.at }

        var previous = -Double.infinity
        for point in ordered {
            let value = try #require(point.cumulativeUSD)
            #expect(value >= previous, "cumulative spend fell at \(point.percent)%")
            previous = value
        }
        // 30 points at $10 each: the window total must reflect both sessions.
        #expect(abs(previous - 300) < 5, "window total was \(previous)")
    }

    @Test("an unpriced turn leaves the running total intact rather than shifting rows")
    func unpricedTurnDoesNotShiftAlignment() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions/2026/09/17")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Point 3 uses a model with no price; points 1-2 and 4-8 are priced. The
        // percentage must stay paired with its own observation either way.
        var lines: [String] = []
        var cumulative = 0
        for point in 1...8 {
            let model = point == 3 ? "unknown-model-zzz" : "gpt-6-astra"
            cumulative += 1_000_000
            lines.append("""
            {"timestamp":"2026-09-17T00:\(String(format: "%02d", point)):00.000Z","type":"turn_context","payload":{"model":"\(model)"}}
            """)
            lines.append("""
            {"timestamp":"2026-09-17T00:\(String(format: "%02d", point)):30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000},"total_token_usage":{"input_tokens":\(cumulative),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(cumulative)}},"rate_limits":{"plan_type":"team","primary":{"used_percent":\(Double(point)),"window_minutes":10080,"resets_at":1790172732},"secondary":{"used_percent":0.0,"window_minutes":300,"resets_at":1}}}}
            """)
        }
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("rollout-gap.jsonl"), atomically: true, encoding: .utf8)

        let allowance = try #require(LocalQuotaAllowanceScanner(codexHome: home).scan().first)
        let ordered = allowance.points.sorted { $0.at < $1.at }
        #expect(ordered.count == 8)
        // Percentages are still each observation's own, in ascending order.
        #expect(ordered.map { Int($0.percent) } == Array(1...8))
        var previous = -Double.infinity
        for point in ordered {
            let value = try #require(point.cumulativeUSD)
            #expect(value >= previous)
            previous = value
        }
        // The unpriced turn contributed nothing, so 7 priced steps at $10 each.
        #expect(abs(previous - 70) < 1, "got \(previous)")
    }
}
