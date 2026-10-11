import Foundation

/// Quota and usage for one New API (relay) account.
///
/// New API exposes two different views of usage, with **different units**, and
/// conflating them silently produces wrong numbers:
///
/// - The dashboard API (`/api/user/self`) reports `quota` / `used_quota` in the
///   site's internal *quota* unit, scaled by a configurable `quota_per_unit`
///   (500000 on the relay this was built against: `quota + used_quota` came out to
///   exactly $65.00).
/// - The OpenAI-compatible billing endpoint (`/v1/dashboard/billing/usage`) reports
///   `total_usage` in **$0.01** units — upstream multiplies by 100
///   (`controller/billing.go`: `TotalUsage: amount * 100`).
///
/// Values are therefore kept in their native units and only converted at the edge
/// by `USD(minorUnits:perUnit:)`.
public struct NewAPIAccountUsage: Sendable, Equatable {
    /// Remaining quota, in the site's quota unit. Nil when only the `sk-` key is available.
    public var remainingQuota: Int?
    /// Consumed quota, in the site's quota unit. Nil when only the `sk-` key is available.
    public var usedQuota: Int?
    /// Total requests recorded for the account.
    public var requestCount: Int?
    /// Display name / username from the dashboard.
    public var displayName: String?
    /// Group the account belongs to (drives relay multipliers).
    public var group: String?

    /// Account-level spend in USD, when the dashboard API was reachable.
    public var usedUSD: Decimal? { USD(quotaUnits: usedQuota) }
    /// Remaining balance in USD, when the dashboard API was reachable.
    public var remainingUSD: Decimal? { USD(quotaUnits: remainingQuota) }
    /// Total grant in USD (remaining + used), when both halves are known.
    public var totalUSD: Decimal? {
        guard let remainingQuota, let usedQuota else { return nil }
        return USD(quotaUnits: remainingQuota + usedQuota)
    }

    /// `sk-`-key-only fallback: spend for this key alone, in USD.
    public var keyOnlyUsedUSD: Decimal?
    /// Whether the relay reports this key as unlimited (no meaningful percentage).
    public var keyIsUnlimited: Bool

    /// The quota unit divisor used for the conversions above.
    public var quotaPerUnit: Int

    public init(
        remainingQuota: Int? = nil,
        usedQuota: Int? = nil,
        requestCount: Int? = nil,
        displayName: String? = nil,
        group: String? = nil,
        keyOnlyUsedUSD: Decimal? = nil,
        keyIsUnlimited: Bool = false,
        quotaPerUnit: Int = NewAPIUnits.defaultQuotaPerUnit)
    {
        self.remainingQuota = remainingQuota
        self.usedQuota = usedQuota
        self.requestCount = requestCount
        self.displayName = displayName
        self.group = group
        self.keyOnlyUsedUSD = keyOnlyUsedUSD
        self.keyIsUnlimited = keyIsUnlimited
        self.quotaPerUnit = quotaPerUnit
    }

    /// Whether enough is known to draw a remaining/total bar.
    public var hasBalance: Bool { remainingUSD != nil && totalUSD != nil }

    /// Fraction of the grant consumed, 0...1, or nil when not computable.
    /// A relay that reports the key as unlimited has no meaningful fraction.
    public var usedFraction: Double? {
        guard !keyIsUnlimited,
              let remainingQuota, let usedQuota,
              remainingQuota + usedQuota > 0
        else { return nil }
        return Double(usedQuota) / Double(remainingQuota + usedQuota)
    }

    private func USD(quotaUnits: Int?) -> Decimal? {
        guard let quotaUnits, quotaPerUnit > 0 else { return nil }
        return Decimal(quotaUnits) / Decimal(quotaPerUnit)
    }
}

/// Converts between the relay's quota unit and USD.
public enum NewAPIUnits {
    /// Fallback divisor when `/api/status` cannot be read.
    /// 500000 is the New API default, verified against a live relay where
    /// `quota + used_quota` divided by it produced an exact whole-dollar figure.
    public static let defaultQuotaPerUnit = 500_000

    /// The OpenAI-compatible billing endpoint reports `total_usage` in $0.01 units.
    public static func usdFromBillingTotalUsage(_ totalUsage: Double) -> Decimal {
        Decimal(totalUsage) / 100
    }
}

/// One relay request, as listed in the dashboard log.
public struct NewAPILogEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var modelName: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// Charged amount, in the site's quota unit.
    public var quota: Int?
    /// Seconds the request took.
    public var useTime: Double?
    public var tokenName: String?
    public var group: String?
    public var isStream: Bool?
    public var username: String?

    /// Charged amount in USD.
    public func costUSD(quotaPerUnit: Int) -> Decimal? {
        guard let quota, quotaPerUnit > 0 else { return nil }
        return Decimal(quota) / Decimal(quotaPerUnit)
    }

    public var totalTokens: Int? {
        guard promptTokens != nil || completionTokens != nil else { return nil }
        return (promptTokens ?? 0) + (completionTokens ?? 0)
    }

    public init(
        id: String,
        createdAt: Date,
        modelName: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        quota: Int? = nil,
        useTime: Double? = nil,
        tokenName: String? = nil,
        group: String? = nil,
        isStream: Bool? = nil,
        username: String? = nil)
    {
        self.id = id
        self.createdAt = createdAt
        self.modelName = modelName
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.quota = quota
        self.useTime = useTime
        self.tokenName = tokenName
        self.group = group
        self.isStream = isStream
        self.username = username
    }
}

/// Per-day totals, ready to feed the existing token-usage chart
/// (`TokenUsageHeatmapBuilder.makeSeries(dailyTokens:)`).
public struct NewAPIDailyUsage: Sendable, Equatable {
    /// `yyyy-MM-dd` (UTC-free day key, matching the chart's convention) → tokens.
    public var tokensByDay: [String: Int]
    /// Same day keys → charged USD.
    public var costByDay: [String: Decimal]
    public var requestCountByDay: [String: Int]

    public init(
        tokensByDay: [String: Int] = [:],
        costByDay: [String: Decimal] = [:],
        requestCountByDay: [String: Int] = [:])
    {
        self.tokensByDay = tokensByDay
        self.costByDay = costByDay
        self.requestCountByDay = requestCountByDay
    }

    public var isEmpty: Bool { tokensByDay.isEmpty }

    public func tokens(on day: Date, calendar: Calendar = .current) -> Int {
        tokensByDay[Self.dayKey(day, calendar: calendar)] ?? 0
    }

    public func cost(on day: Date, calendar: Calendar = .current) -> Decimal? {
        costByDay[Self.dayKey(day, calendar: calendar)]
    }

    /// Sum over the last `days` days ending today (inclusive).
    public func tokensInLast(days: Int, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard days > 0 else { return 0 }
        var total = 0
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            total += tokens(on: day, calendar: calendar)
        }
        return total
    }

    public func costInLast(days: Int, now: Date = Date(), calendar: Calendar = .current) -> Decimal {
        guard days > 0 else { return 0 }
        var total: Decimal = 0
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            total += cost(on: day, calendar: calendar) ?? 0
        }
        return total
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day
        else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Matches a live `sk-` relay key against a dashboard token row.
///
/// New API never returns the full secret: the list shows a masked prefix/suffix
/// such as `KOEf**********KPnf`. The stored key is `sk-KOEfR…KPnf`.
public enum NewAPITokenKeyMatch {
    public static func matches(relayKey: String, listedKey: String) -> Bool {
        let relay = normalize(relayKey)
        let listed = normalize(listedKey)
        guard !relay.isEmpty, !listed.isEmpty else { return false }
        if listed.contains("*") {
            let parts = listed.split(separator: "*", omittingEmptySubsequences: true).map(String.init)
            guard let prefix = parts.first, !prefix.isEmpty, relay.hasPrefix(prefix) else { return false }
            if parts.count > 1, let suffix = parts.last, !suffix.isEmpty {
                return relay.hasSuffix(suffix)
            }
            return true
        }
        return relay == listed
    }

    public static func tokenName(relayKey: String, tokens: [(name: String, key: String)]) -> String? {
        for token in tokens {
            guard matches(relayKey: relayKey, listedKey: token.key) else { continue }
            let name = token.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func normalize(_ key: String) -> String {
        var value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 3, value.lowercased().hasPrefix("sk-") {
            value = String(value.dropFirst(3))
        }
        return value
    }
}
