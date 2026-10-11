import Foundation

public enum QuotaEstimateUnavailableReason: Sendable, Equatable {
    /// The analytics rows never carried token totals, so there is nothing to
    /// extrapolate from at all.
    case missingCredits
    /// Usage exists, but the rows carry neither Credits nor tokens — no numerator
    /// is available in any metric.
    case zeroCreditsWithUsage
    /// Usage exists but the meter reports no percentage, so the divisor is unusable.
    case zeroPercent
    case noUsage
    case unavailableWindow

    public var metric: QuotaEstimateMetric {
        switch self {
        case .missingCredits, .zeroCreditsWithUsage, .noUsage, .unavailableWindow, .zeroPercent:
            return .credits
        }
    }
}

extension QuotaEstimateUnavailableReason {
    /// Decides whether a cycle can be extrapolated, and in which metric.
    ///
    /// The meter's percentage is always the denominator. The numerator is Credits
    /// for plans that meter in Credits, and tokens for plans that declare they do
    /// not (Team and similar): those report `credits: 0` on every day, so a
    /// Credits ratio would divide zero and claim the entire quota is zero.
    ///
    /// `planReportsNoCredits` must come from the plan itself (`credits.has_credits
    /// == false`). Inferring it from a zero on a single day would be wrong: a
    /// credited plan that genuinely burned no Credits today looks identical, and
    /// inventing an allowance for it is the mistake these rules exist to prevent.
    static func evaluate(
        meter: RateWindow?,
        rows: [QuotaEstimateDailyRow],
        planReportsNoCredits: Bool = false
    ) -> (reason: Self?, metric: QuotaEstimateMetric) {
        guard let meter, (meter.windowMinutes ?? 0) > 0, meter.resetsAt != nil else {
            return (.unavailableWindow, .credits)
        }
        // Token totals are the floor: without them there is no numerator at all.
        guard rows.allSatisfy(\.totalsReported) else { return (.missingCredits, .credits) }

        let usedRows = rows.filter(\.hasUsage)
        guard !usedRows.isEmpty else { return (.noUsage, .credits) }
        guard meter.usedPercentExact > 0 else { return (.zeroPercent, .credits) }

        if planReportsNoCredits {
            // Tokens are the only numerator this plan reports.
            guard usedRows.contains(where: { $0.tokens > 0 }) else {
                return (.zeroCreditsWithUsage, .credits)
            }
            return (nil, .tokens)
        }

        // Credits are the faithful numerator here: the percentage is measured in
        // Credits on these plans.
        let creditsUsable = usedRows.allSatisfy(\.creditsReported)
            && usedRows.contains { $0.credits > 0 }
        guard creditsUsable else {
            // A day with usage and no Credits reported leaves the ratio undefined.
            let anyMissing = usedRows.contains { !$0.creditsReported }
            return (anyMissing ? .missingCredits : .zeroCreditsWithUsage, .credits)
        }
        return (nil, .credits)
    }
}

extension QuotaEstimateDailyRow {
    var hasUsage: Bool { tokens > 0 || turns > 0 || credits > 0 }
}

public extension QuotaEstimateSnapshot {
    var creditsComplete: Bool {
        currentRows.contains(where: \.creditsReported)
            && currentRows.allSatisfy(\.totalsReported)
            && currentRows.allSatisfy { !$0.hasUsage || $0.creditsReported }
    }

    /// API-equivalent token cost is separate from the Credits-to-USD reference conversion.
    var apiEquivalentUSD: Double? {
        guard !currentRows.isEmpty,
              currentRows.allSatisfy(\.totalsReported),
              currentRows.allSatisfy({ !$0.hasUsage || $0.usd != nil })
        else { return nil }
        return currentRows.compactMap(\.usd).reduce(0, +)
    }

    var statsThroughDate: String? { currentRows.map(\.date).max() }

    /// True when the numerator and the denominator do not cover the same span.
    ///
    /// The two sides come from different sources with different windows:
    ///
    /// - The denominator (`used_percent`) is live and measures an exact rolling
    ///   window (e.g. 168h), and it arrives as an **integer**, so it is quantized.
    /// - The numerator is built from **whole-day** buckets, which the API only
    ///   serves through yesterday (`group_by=hour` is rejected, so no finer grain
    ///   exists). Filtering those buckets by `date >= cycleStartDate` therefore
    ///   also sweeps in the part of the cycle-start day that belongs to the
    ///   *previous* cycle, while the current day is missing entirely.
    ///
    /// The result is an estimate whose error direction is **indeterminate**: the
    /// extra slice inflates the numerator and the missing day deflates it, so
    /// which dominates depends on where the usage actually fell. It is neither a
    /// reliable lower nor upper bound, and the label must not claim either.
    ///
    /// Only meaningful when a figure was produced at all: an unavailable estimate
    /// is not misleading, it is simply absent.
    var windowsMismatch: Bool {
        guard canExtrapolate, let through = statsThroughDate else { return false }
        // Both are `yyyy-MM-dd` UTC days, so lexical order is chronological.
        return through < QuotaEstimateCalculator.utcDay(calculatedAt)
    }
}
