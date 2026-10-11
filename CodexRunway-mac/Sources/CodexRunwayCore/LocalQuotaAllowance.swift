import Foundation

/// The token mix a window actually consumed, and what each part cost.
///
/// Useful beyond trivia: cached input dominates the raw count while being priced
/// roughly ten times below fresh input, so the cache hit rate is the single best
/// explanation for why a token allowance and a dollar allowance disagree.
public struct LocalAllowanceBreakdown: Sendable, Equatable {
    public var uncachedInputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var outputTokens: Int
    /// Models seen in the window, most tokens first.
    public var models: [String]

    public init(
        uncachedInputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int = 0,
        models: [String] = [])
    {
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.models = models
    }

    /// `input_tokens` already includes the cached portion, so the input side is the
    /// two together.
    public var inputTokens: Int { uncachedInputTokens + cachedInputTokens }
    public var totalTokens: Int { inputTokens + outputTokens }

    /// Share of all input tokens that came from cache, 0...1. Nil when nothing was
    /// billed as input, where a rate would be meaningless rather than zero.
    public var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens)
    }

    /// Share of the *whole* window that is cached input — the number that explains
    /// how the same window can be cheap in dollars and enormous in tokens.
    public var cacheShareOfTotal: Double? {
        guard totalTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(totalTokens)
    }
}

/// One sample of the fit, for explaining where the line came from.
public struct LocalAllowanceSamplePoint: Sendable, Equatable, Identifiable {
    public var id: Double { percent }
    /// Meter percentage at this instant.
    public var percent: Double
    /// Spend accumulated within the window up to this instant, in USD. Nil when the
    /// model at that point was unpriced.
    public var cumulativeUSD: Double?
    public var at: Date

    public init(percent: Double, cumulativeUSD: Double?, at: Date) {
        self.percent = percent
        self.cumulativeUSD = cumulativeUSD
        self.at = at
    }
}

/// A weekly allowance recovered from local session logs.
///
/// Codex writes a `token_count` event after every model turn carrying two things
/// that make this possible: the turn's own token increment, and the rate-limit
/// snapshot the server returned at that moment.
///
/// ```json
/// "info": { "total_token_usage": { "input_tokens": …, "cached_input_tokens": …, "output_tokens": … } },
/// "rate_limits": {
///   "primary":   { "used_percent": 8.0, "window_minutes": 10080, "resets_at": 1790172732 },
///   "plan_type": "team"
/// }
/// ```
///
/// The percentage is the server's own measure of the quota window, and the tokens
/// are what this machine actually spent. Their ratio over time recovers the
/// denominator the API never exposes: the absolute allowance.
///
/// This is strictly better than dividing an online daily total by the live
/// percentage, because the online analytics endpoint only serves whole-day
/// buckets, omits the current day, and does not align with the rolling window.
public struct LocalQuotaAllowance: Sendable, Equatable {
    /// Plan the window belongs to, e.g. `team`.
    public var plan: String
    /// Length of the measured window in minutes (10080 = one week).
    public var windowMinutes: Int
    /// Window end, used as the window's identity.
    public var resetsAt: Date
    /// Implied total allowance for the window, in tokens.
    public var allowanceTokens: Double
    /// The same allowance costed with the public per-model price table.
    ///
    /// This is the more meaningful figure for a plan whose meter tracks spend
    /// rather than raw tokens: cached input dominates the raw count but is priced
    /// ~10x below fresh input, so a token figure overstates the expensive part.
    /// Nil when any consumed model had no known price — a partial sum would
    /// understate the allowance and is worse than saying nothing.
    public var allowanceUSD: Double?
    /// Tokens whose model had no price, when `allowanceUSD` is nil.
    public var unpricedTokens: Int
    /// How much of the window the meter reports as consumed, as of the newest
    /// sample. This is the meter's own percentage, not a value derived here.
    public var usedPercent: Double
    /// Observations that fed the fit.
    public var sampleCount: Int
    /// Goodness of fit; low values mean the samples disagree, so the number is not
    /// trustworthy and callers should treat it as unusable.
    public var rSquared: Double
    /// Percentage points spanned by the samples. A wide span is what makes the
    /// slope meaningful rather than noise.
    public var percentSpan: Double
    public var computedAt: Date

    /// What is left to spend in this window.
    ///
    /// The allowance is the cap at 100%, so the remainder is the same line evaluated
    /// at the current percentage rather than at 100. Computed from the fitted slope
    /// instead of subtracting a sum of observed costs, so a window that was already
    /// partly spent before the first local sample still reports correctly.
    public var remainingUSD: Double? {
        guard let allowanceUSD, usedPercent.isFinite else { return nil }
        let remaining = allowanceUSD * (1 - usedPercent / 100)
        return remaining > 0 ? remaining : 0
    }

    /// The same remainder in tokens. Approximate, and included only when the token
    /// allowance itself cleared the confidence bar.
    public var remainingTokens: Double? {
        guard isReliable, usedPercent.isFinite else { return nil }
        let remaining = allowanceTokens * (1 - usedPercent / 100)
        return remaining > 0 ? remaining : 0
    }

    /// Share of the window already consumed, for display.
    public var usedFraction: Double {
        min(max(usedPercent / 100, 0), 1)
    }

    /// The same allowance, re-evaluated with a fresher percentage.
    ///
    /// The allowance itself is a property of the plan and changes slowly, so it is
    /// worth fitting locally. The *percentage* is what moves minute to minute, and
    /// the live quota is fresher than the newest local sample — it comes from the
    /// usage API rather than from the last turn this machine happened to log.
    /// Pairing the fitted allowance with the live percentage keeps both halves at
    /// their most accurate.
    public func restated(usedPercent freshPercent: Double) -> LocalQuotaAllowance {
        var copy = self
        copy.usedPercent = min(max(freshPercent, 0), 100)
        return copy
    }

    /// What the window consumed, in tokens.
    public var breakdown: LocalAllowanceBreakdown
    /// The observations the line was fitted to, for showing the derivation.
    public var points: [LocalAllowanceSamplePoint]
    /// Pricing table version the dollar figures were computed with.
    public var pricingVersion: String

    /// The fitted line itself: spend per percentage point. This is the number the
    /// whole estimate rests on, so the detail view shows it directly.
    public var usdPerPercentPoint: Double? {
        guard let allowanceUSD else { return nil }
        return allowanceUSD / 100
    }

    /// The same rate in tokens.
    public var tokensPerPercentPoint: Double {
        allowanceTokens / 100
    }

    /// True when the dollar figure came from more than one model, where a single
    /// effective rate is an average rather than an exact price.
    public var spansMultipleModels: Bool { breakdown.models.count > 1 }

    /// The fit is only quoted when the samples actually describe a line.
    ///
    /// Both thresholds exist because a narrow span over few points magnifies
    /// integer rounding: at 0.5pp of span, one percent of quantization noise moves
    /// the slope by double digits.
    public var isReliable: Bool {
        sampleCount >= 4 && percentSpan >= 2 && rSquared >= 0.9
    }

    public init(
        plan: String,
        windowMinutes: Int,
        resetsAt: Date,
        allowanceTokens: Double,
        allowanceUSD: Double? = nil,
        unpricedTokens: Int = 0,
        usedPercent: Double = 0,
        breakdown: LocalAllowanceBreakdown = LocalAllowanceBreakdown(),
        points: [LocalAllowanceSamplePoint] = [],
        pricingVersion: String = PricingTable.version,
        sampleCount: Int,
        rSquared: Double,
        percentSpan: Double,
        computedAt: Date)
    {
        self.plan = plan
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.allowanceTokens = allowanceTokens
        self.allowanceUSD = allowanceUSD
        self.unpricedTokens = unpricedTokens
        self.usedPercent = usedPercent
        self.breakdown = breakdown
        self.points = points
        self.pricingVersion = pricingVersion
        self.sampleCount = sampleCount
        self.rSquared = rSquared
        self.percentSpan = percentSpan
        self.computedAt = computedAt
    }
}
