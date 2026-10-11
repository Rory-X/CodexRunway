import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Quota estimate availability")
struct QuotaEstimateAvailabilityTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-03T12:00:00Z")!

    @Test("missing credits on a used day prevent extrapolation and history samples", arguments: ["", "\"credits\":null,"])
    func missingCreditsDoNotExtrapolate(creditField: String) throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":47,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{\(creditField)"uncached_text_input_tokens":2000000}}
        """)
        #expect(snapshot.unavailableReason == .missingCredits)
        #expect(!snapshot.creditsComplete)
        #expect(snapshot.usedCredits == 47)
        #expect(!snapshot.canExtrapolate)
        #expect(snapshot.estimatedCredits == nil)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
        #expect(try #require(snapshot.apiEquivalentUSD) > 0)
    }

    @Test("an explicitly reported zero stays zero while token cost remains available")
    func zeroCreditsWithUsageHasSpecificReason() throws {
        let snapshot = try estimate(#"{"date":"2026-09-02","totals":{"credits":0,"uncached_text_input_tokens":694950000}}"#)
        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
        #expect(snapshot.creditsComplete)
        #expect(snapshot.currentRows.first?.creditsReported == true)
        #expect(snapshot.usedCredits == 0)
        #expect(try #require(snapshot.apiEquivalentUSD) > 0)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
    }

    @Test("a missing day is unknown rather than an unused day", arguments: ["", ",\"totals\":null"])
    func missingDayPreventsCompleteTotals(totalsField: String) throws {
        let unknownDay = "{\"date\":\"2026-09-02\"\(totalsField)}"
        let usedDay = #"{"date":"2026-09-01","totals":{"credits":47,"uncached_text_input_tokens":1000000}}"#
        for days in [unknownDay, "\(usedDay),\(unknownDay)"] {
            let snapshot = try estimate(days)
            #expect(snapshot.currentRows.last?.totalsReported == false)
            #expect(snapshot.unavailableReason == .missingCredits)
            #expect(!snapshot.creditsComplete)
            #expect(snapshot.apiEquivalentUSD == nil)
            #expect(snapshot.estimatedCredits == nil)
            #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
        }
    }

    @Test("token-only days prevent a partial API cost from becoming the complete total")
    func partialCostIsUnavailable() throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":20,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{"credits":27,"text_total_tokens":2000000}}
        """)
        #expect(snapshot.currentRows.first?.usd != nil)
        #expect(snapshot.currentRows.last?.usd == nil)
        #expect(snapshot.apiEquivalentUSD == nil)
        #expect(snapshot.estimatedCredits == 100)
        #expect(snapshot.estimatedUSD == 4)
        #expect(snapshot.unavailableReason == nil)
    }

    @Test("a token-only zero-credits day has neither an invented API cost nor an allowance")
    func totalTokensAloneDoNotInventCost() throws {
        let snapshot = try estimate(#"{"date":"2026-09-02","totals":{"credits":0,"text_total_tokens":694950000}}"#)
        #expect(snapshot.currentRows.first?.tokens == 694_950_000)
        #expect(snapshot.currentRows.first?.usd == nil)
        #expect(snapshot.apiEquivalentUSD == nil)
        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
        #expect(snapshot.estimatedCredits == nil)
    }

    @Test("positive credits retain the original formula and complete token cost total")
    func positiveCreditsKeepFormula() throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":20,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{"credits":27,"uncached_text_input_tokens":2000000}}
        """)
        #expect(snapshot.canExtrapolate)
        #expect(snapshot.creditsComplete)
        #expect(snapshot.unavailableReason == nil)
        #expect(snapshot.estimatedCredits == 100)
        #expect(snapshot.apiEquivalentUSD == snapshot.currentRows.compactMap(\.usd).reduce(0, +))
        #expect(snapshot.apiEquivalentUSD != snapshot.usedUSD)
        #expect(snapshot.statsThroughDate == "2026-09-02")
        #expect(snapshot.calculatedAt == now)
        #expect(QuotaEstimateCalculator.sample(from: snapshot)?.estimatedCredits == 100)
    }

    @Test("an unused row without credits does not block reported usage")
    func unusedRowDoesNotBlockReportedUsage() throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":47,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{"text_total_tokens":0}}
        """)
        #expect(snapshot.creditsComplete)
        #expect(snapshot.estimatedCredits == 100)
        #expect(snapshot.apiEquivalentUSD == snapshot.currentRows.first?.usd)
    }

    @Test("no usage, zero percentage, and a missing window have different reasons")
    func otherUnavailableReasons() throws {
        let empty = try estimate("")
        #expect(empty.unavailableReason == .noUsage)
        #expect(empty.statsThroughDate == nil)
        #expect(empty.apiEquivalentUSD == nil)
        let unused = try estimate(#"{"date":"2026-09-02","totals":{"credits":0,"text_total_tokens":0}}"#)
        #expect(unused.unavailableReason == .noUsage)
        let row = #"{"date":"2026-09-02","totals":{"credits":47,"text_total_tokens":1000}}"#
        #expect(try estimate(row, percent: 0).unavailableReason == .zeroPercent)
        #expect(try estimate(row, weekly: false).unavailableReason == .unavailableWindow)
    }

    @Test("legacy cached credits with unknown provenance cannot create a new estimate")
    func legacyCreditsDoNotExtrapolate() throws {
        let data = Data(#"{"data":[{"date":"2026-09-02","totals":{"credits":47,"text_total_tokens":1000}}]}"#.utf8)
        let summary = try ApiEquivalentSummary.decodeAnalytics(
            from: data, window: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
        var row = try #require(summary.dailyRows.first)
        row.creditsReported = nil
        let snapshot = QuotaEstimateCalculator.make(
            quota: quota(percent: 47, weekly: true), dailyRows: [row], mode: .auto, now: now)
        #expect(snapshot.unavailableReason == .missingCredits)
        #expect(!snapshot.creditsComplete)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
    }

    private func estimate(_ days: String, percent: Int = 47, weekly: Bool = true) throws -> QuotaEstimateSnapshot {
        let summary = try ApiEquivalentSummary.decodeAnalytics(
            from: Data("{\"data\":[\(days)]}".utf8),
            window: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
        return QuotaEstimateCalculator.make(
            quota: quota(percent: percent, weekly: weekly),
            dailyRows: summary.dailyRows, mode: .rollingWeek, now: now)
    }

    private func quota(percent: Int, weekly: Bool) -> QuotaSnapshot {
        QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            secondary: weekly ? RateWindow(usedPercent: percent, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)) : nil,
            additionalWindows: [], creditsBalance: nil, updatedAt: now)
    }
}

@Suite("Quota estimate on plans without Credits")
struct QuotaEstimateTokenFallbackTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!

    /// Shaped like the real `/wham/usage` response for a Team account: the weekly
    /// meter lives on `primary_window`, and the plan declares it has no Credits.
    private func teamQuota(percent: Double = 8, hasCredits: Bool? = false) -> QuotaSnapshot {
        QuotaSnapshot(
            plan: "team",
            primary: RateWindow(
                usedPercent: Int(percent),
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(551_237),
                usedPercentExact: percent),
            secondary: nil,
            additionalWindows: [],
            creditsBalance: nil,
            hasCredits: hasCredits,
            updatedAt: now)
    }

    private func analytics(_ days: String) throws -> ApiEquivalentSummary {
        try ApiEquivalentSummary.decodeAnalytics(
            from: Data("{\"data\":[\(days)]}".utf8),
            window: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
    }

    /// The real Team row: zero Credits, but full token counts.
    private static let teamDay = """
    {"date":"2026-09-16","totals":{"users":1,"threads":2,"turns":2,"credits":0.0,
     "uncached_text_input_tokens":24730,"cached_text_input_tokens":47744,
     "text_output_tokens":6131,"text_total_tokens":78605}}
    """

    @Test("a Team account extrapolates its weekly allowance in tokens")
    func teamAccountEstimatesInTokens() throws {
        let summary = try analytics(Self.teamDay)
        let snapshot = QuotaEstimateCalculator.make(
            quota: teamQuota(), dailyRows: summary.dailyRows, mode: .rollingWeek, now: now)

        #expect(snapshot.metric == .tokens)
        #expect(snapshot.unavailableReason == nil)
        #expect(snapshot.canExtrapolate)
        #expect(snapshot.usedTokens == 78_605)
        // 78,605 tokens at 8% implies a ~982K weekly allowance.
        let estimated = try #require(snapshot.estimatedCredits)
        #expect(abs(estimated - 982_562.5) < 1)
        // USD is a Credits conversion, so it must not be invented for a token estimate.
        #expect(snapshot.estimatedUSD == nil)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) != nil)
    }

    @Test("the Team weekly window is found even though it sits on the primary meter")
    func teamWeeklyWindowIsDetected() {
        let quota = teamQuota()
        #expect(QuotaEstimateCalculator.weeklyWindow(from: quota) != nil)
        #expect(quota.reportsNoCredits)
    }

    /// The safety rule the Credits path depends on: a plan that reports Credits and
    /// simply burned zero today must NOT gain an invented allowance. Only the plan
    /// declaring `has_credits: false` unlocks the token fallback.
    @Test("a credited plan reporting zero is not rescued by the token fallback")
    func creditedPlanWithZeroCreditsStaysUnavailable() throws {
        let summary = try analytics(Self.teamDay)
        // Same daily rows, but the plan does *not* declare itself credit-less.
        let snapshot = QuotaEstimateCalculator.make(
            quota: teamQuota(hasCredits: true),
            dailyRows: summary.dailyRows,
            mode: .rollingWeek,
            now: now)

        #expect(snapshot.metric == .credits)
        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
        #expect(!snapshot.canExtrapolate)
        #expect(snapshot.estimatedCredits == nil)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
    }

    @Test("an API that omits has_credits keeps the stricter Credits rules")
    func absentHasCreditsIsNotTreatedAsNoCredits() throws {
        let summary = try analytics(Self.teamDay)
        let snapshot = QuotaEstimateCalculator.make(
            quota: teamQuota(hasCredits: nil),
            dailyRows: summary.dailyRows,
            mode: .rollingWeek,
            now: now)

        #expect(!teamQuota(hasCredits: nil).reportsNoCredits)
        #expect(snapshot.metric == .credits)
        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
    }

    @Test("has_credits is decoded from the usage payload")
    func hasCreditsDecodes() throws {
        let team = try QuotaSnapshot.decode(from: Data("""
        {"plan_type":"team","credits":{"has_credits":false,"unlimited":false,"balance":null},
         "rate_limit":{"primary_window":{"used_percent":8,"reset_at":1790172732,
         "limit_window_seconds":604800},"secondary_window":null}}
        """.utf8))
        #expect(team.hasCredits == false)
        #expect(team.reportsNoCredits)

        let pro = try QuotaSnapshot.decode(from: Data("""
        {"plan_type":"pro","credits":{"has_credits":true,"balance":12.5},
         "rate_limit":{"primary_window":{"used_percent":8,"reset_at":1790172732,
         "limit_window_seconds":604800},"secondary_window":null}}
        """.utf8))
        #expect(pro.hasCredits == true)
        #expect(!pro.reportsNoCredits)
    }

    @Test("a Team week with no usage at all reports no usage rather than a missing numerator")
    func teamWithoutUsageIsUnavailable() throws {
        let summary = try analytics(#"{"date":"2026-09-16","totals":{"credits":0.0}}"#)
        let snapshot = QuotaEstimateCalculator.make(
            quota: teamQuota(), dailyRows: summary.dailyRows, mode: .rollingWeek, now: now)

        // "No usage" is decided before any numerator question, so it is the accurate
        // reason here: there is nothing to extrapolate from at all.
        #expect(snapshot.unavailableReason == .noUsage)
        #expect(!snapshot.canExtrapolate)
    }

    @Test("a Team day with turns but no token counts reports a missing numerator")
    func teamWithTurnsButNoTokensIsUnavailable() throws {
        let summary = try analytics(#"{"date":"2026-09-16","totals":{"credits":0.0,"turns":3}}"#)
        let snapshot = QuotaEstimateCalculator.make(
            quota: teamQuota(), dailyRows: summary.dailyRows, mode: .rollingWeek, now: now)

        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
        #expect(!snapshot.canExtrapolate)
        #expect(snapshot.estimatedCredits == nil)
    }
}

@Suite("Quota estimate window mismatch")
struct QuotaEstimateLagTests {
    /// Measured against the live API: a request on 2026-09-17 returned day buckets
    /// only through 2026-09-16, while `used_percent` is live. The two sides of the
    /// ratio therefore cover different spans, and the error direction depends on
    /// where the usage fell — it is not a bound in either direction.
    private static let teamDay = """
    {"date":"2026-09-16","totals":{"users":1,"threads":2,"turns":2,"credits":0.0,
     "uncached_text_input_tokens":24730,"cached_text_input_tokens":47744,
     "text_output_tokens":6131,"text_total_tokens":78605}}
    """

    private func snapshot(nowISO: String, hasCredits: Bool = false) throws -> QuotaEstimateSnapshot {
        let now = ISO8601DateFormatter().date(from: nowISO)!
        let summary = try ApiEquivalentSummary.decodeAnalytics(
            from: Data("{\"data\":[\(Self.teamDay)]}".utf8),
            window: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
        let quota = QuotaSnapshot(
            plan: "team",
            primary: RateWindow(
                usedPercent: 8,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(551_237),
                usedPercentExact: 8),
            secondary: nil,
            additionalWindows: [],
            creditsBalance: nil,
            hasCredits: hasCredits,
            updatedAt: now)
        return QuotaEstimateCalculator.make(
            quota: quota, dailyRows: summary.dailyRows, mode: .rollingWeek, now: now)
    }

    @Test("statistics that stop before today are reported as a window mismatch")
    func detectsLag() throws {
        // Built on the 17th, but the newest bucket is the 16th.
        let snap = try snapshot(nowISO: "2026-09-17T05:18:00Z")
        #expect(snap.statsThroughDate == "2026-09-16")
        #expect(snap.windowsMismatch)
        #expect(snap.canExtrapolate)
    }

    @Test("statistics that include today are not reported as mismatched")
    func noLagWhenCurrent() throws {
        // Built on the same day the newest bucket covers.
        let snap = try snapshot(nowISO: "2026-09-16T05:18:00Z")
        #expect(snap.statsThroughDate == "2026-09-16")
        #expect(!snap.windowsMismatch)
    }

    @Test("an unavailable estimate is not flagged as approximate")
    func unavailableIsNotALowerBound() throws {
        // A credited plan reporting zero Credits produces no figure at all, and an
        // absent figure cannot mislead anyone about its precision.
        let snap = try snapshot(nowISO: "2026-09-17T05:18:00Z", hasCredits: true)
        #expect(snap.estimatedCredits == nil)
        #expect(!snap.windowsMismatch)
    }
}
