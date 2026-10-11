import Foundation

/// Reads quota, usage and request history from a New API relay.
///
/// Two credential tiers, deliberately kept separate:
///
/// | Credential | Reaches | Yields |
/// | --- | --- | --- |
/// | `sk-` relay key | `/v1/dashboard/billing/*` | this key's own spend |
/// | dashboard PAT | `/api/user/self`, `/api/log/self` | balance, request count, history |
///
/// The PAT is optional. Without it the client degrades to key-only numbers rather
/// than failing.
///
/// The relay rate-limits aggressively — a burst of four requests was observed to
/// draw a `403` — so requests are serialized through a minimum interval and
/// transient throttling is retried with backoff. A failed quota read must never
/// make the account itself look broken, so callers receive partial results.
public actor NewAPIClient {
    /// Observed throttling behaviour: bursts draw 403, so keep a floor between calls.
    public static let minimumRequestInterval: TimeInterval = 1.0
    static let retryDelays: [TimeInterval] = [2, 5]

    private let baseURL: URL
    private let session: URLSession?
    private let transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var lastRequestAt: Date?

    public init(baseURL: URL, session: URLSession? = nil) {
        self.init(
            baseURL: baseURL,
            session: session,
            transport: nil,
            now: Date.init,
            sleep: { seconds in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            })
    }

    /// An exact transport seam for isolated quota tests.
    public init(baseURL: URL,
                transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.init(baseURL: baseURL, session: nil, transport: transport,
                  now: Date.init, sleep: { _ in })
    }

    init(
        baseURL: URL,
        session: URLSession? = nil,
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async -> Void)
    {
        self.baseURL = baseURL
        self.session = session
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Public API

    /// Everything obtainable for this account. Never throws for a missing PAT —
    /// only a hard relay failure surfaces as an error.
    public func fetchUsage(relayKey: String, dashboardToken: String?) async throws -> NewAPIAccountUsage {
        let status = try? await fetchStatus()
        let quotaPerUnit = status?.quotaPerUnit ?? NewAPIUnits.defaultQuotaPerUnit
        do {
            if let dashboardToken, !dashboardToken.isEmpty {
                var usage = try await fetchDashboardSelf(token: dashboardToken, quotaPerUnit: quotaPerUnit)
                // The key-only figure stays useful as a cross-check and as the
                // per-key number shown beside the account total.
                usage.keyOnlyUsedUSD = try? await fetchKeyOnlyUsage(relayKey: relayKey)
                return usage
            }

            // Key-only: the dashboard API is out of reach, so report what the key can see.
            let keyUsage = try await fetchKeyOnlyUsage(relayKey: relayKey)
            let keyIsUnlimited = (try? await fetchSubscription(relayKey: relayKey))?.isUnlimited ?? false
            return NewAPIAccountUsage(
                keyOnlyUsedUSD: keyUsage,
                keyIsUnlimited: keyIsUnlimited,
                quotaPerUnit: quotaPerUnit)
        } catch {
            // A relay-shaped URL or an HTTP error alone cannot identify New API.
            // Only a successfully decoded positive quota divisor from this request's
            // status endpoint is sufficient evidence to report a quota fault.
            guard let divisor = status?.quotaPerUnit, divisor > 0 else {
                throw NewAPIClientError.unsupportedQuota
            }
            if (error as? NewAPIClientError) == .unauthorized {
                throw NewAPIClientError.confirmedUnauthorized
            }
            throw NewAPIClientError.confirmedRefreshFailure
        }
    }

    /// Per-day totals, shaped for the existing token chart.
    ///
    /// Prefers the relay's own aggregate endpoint (`/api/data/self`), which returns
    /// every bucket in one request. The request-log fallback needs one paginated
    /// call per 100 rows: on a real account that meant 14 calls under a
    /// 1-request-per-second throttle, and a page cap silently truncated the totals
    /// by more than half. The aggregate endpoint is both faster and complete.
    public func fetchDailyUsage(
        dashboardToken: String,
        tokenName: String? = nil,
        days: Int = 7,
        maxPages: Int = 20,
        now: Date = Date()) async throws -> NewAPIDailyUsage
    {
        // `/api/data/self` is account-wide. A named token must go through the
        // request log (`token_name`) so the heatmap is this key, not every key.
        if tokenName == nil {
            do {
                return try await fetchAggregateDailyUsage(
                    dashboardToken: dashboardToken,
                    days: days,
                    now: now)
            } catch {
                // Fall through to the log-based path rather than failing the refresh.
            }
        }
        let clamped = min(max(days, 1), 30)
        let end = Int(now.timeIntervalSince1970)
        let start = end - clamped * 86_400
        let entries = try await fetchLogEntries(
            dashboardToken: dashboardToken,
            tokenName: tokenName,
            maxPages: maxPages,
            startTimestamp: start,
            endTimestamp: end)
        return Self.aggregateByDay(entries)
    }

    /// Resolves the dashboard token name that belongs to this `sk-` key.
    public func resolveTokenName(dashboardToken: String, relayKey: String) async throws -> String? {
        let rows = try await fetchTokenRows(dashboardToken: dashboardToken)
        return NewAPITokenKeyMatch.tokenName(
            relayKey: relayKey,
            tokens: rows.compactMap { row in
                guard let name = row.name, let key = row.key else { return nil }
                return (name, key)
            })
    }

    /// One-shot daily buckets from `/api/data/self`.
    ///
    /// The endpoint rejects spans wider than a month, so the window is clamped.
    public func fetchAggregateDailyUsage(
        dashboardToken: String,
        days: Int = 7,
        now: Date = Date()) async throws -> NewAPIDailyUsage
    {
        let clamped = min(max(days, 1), 30)
        let end = Int(now.timeIntervalSince1970)
        let start = end - clamped * 86_400
        let data = try await request(
            path: "/api/data/self",
            query: [
                URLQueryItem(name: "start_timestamp", value: String(start)),
                URLQueryItem(name: "end_timestamp", value: String(end)),
            ],
            bearer: dashboardToken)
        let response = try JSONDecoder().decode(NewAPIDataResponse.self, from: data)
        guard let rows = response.data else { throw NewAPIClientError.malformedResponse }
        return Self.aggregateBuckets(rows)
    }

    /// Recent requests, newest first.
    public func fetchLogEntries(
        dashboardToken: String,
        tokenName: String? = nil,
        pageSize: Int = 100,
        maxPages: Int = 20,
        startTimestamp: Int? = nil,
        endTimestamp: Int? = nil) async throws -> [NewAPILogEntry]
    {
        var collected: [NewAPILogEntry] = []
        var page = 1
        while page <= maxPages {
            var query = [
                URLQueryItem(name: "p", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize)),
            ]
            if let tokenName, !tokenName.isEmpty {
                query.append(URLQueryItem(name: "token_name", value: tokenName))
            }
            if let startTimestamp {
                query.append(URLQueryItem(name: "start_timestamp", value: String(startTimestamp)))
            }
            if let endTimestamp {
                query.append(URLQueryItem(name: "end_timestamp", value: String(endTimestamp)))
            }
            let data = try await request(
                path: "/api/log/self",
                query: query,
                bearer: dashboardToken)
            let response = try JSONDecoder().decode(NewAPILogListResponse.self, from: data)
            let items = response.data?.items ?? []
            collected.append(contentsOf: items.compactMap(Self.makeEntry))
            let total = response.data?.total ?? collected.count
            if items.isEmpty || collected.count >= total { break }
            if let startTimestamp, let oldest = items.compactMap(\.createdAt).min(),
               oldest < startTimestamp
            {
                break
            }
            page += 1
        }
        return collected.sorted { $0.createdAt > $1.createdAt }
    }

    /// Lists dashboard tokens so the live `sk-` key can be matched by prefix.
    func fetchTokenRows(dashboardToken: String) async throws -> [NewAPITokenRow] {
        var collected: [NewAPITokenRow] = []
        var page = 1
        while page <= 10 {
            let data = try await request(
                path: "/api/token/",
                query: [
                    URLQueryItem(name: "p", value: String(page)),
                    URLQueryItem(name: "size", value: "100"),
                    URLQueryItem(name: "page_size", value: "100"),
                ],
                bearer: dashboardToken)
            let response = try JSONDecoder().decode(NewAPITokenListResponse.self, from: data)
            let rows = response.rows
            collected.append(contentsOf: rows)
            if rows.isEmpty || rows.count < 100 { break }
            page += 1
        }
        return collected
    }

    /// Site configuration. Public — no credential needed.
    public func fetchStatus() async throws -> NewAPIStatus {
        let data = try await request(path: "/api/status", query: [], bearer: nil)
        let response = try JSONDecoder().decode(NewAPIStatusResponse.self, from: data)
        return response.data ?? NewAPIStatus()
    }

    // MARK: - Dashboard

    private func fetchDashboardSelf(token: String, quotaPerUnit: Int) async throws -> NewAPIAccountUsage {
        let data = try await request(path: "/api/user/self", query: [], bearer: token)
        let response = try JSONDecoder().decode(NewAPISelfResponse.self, from: data)
        guard let self_ = response.data else { throw NewAPIClientError.malformedResponse }
        return NewAPIAccountUsage(
            remainingQuota: self_.quota,
            usedQuota: self_.usedQuota,
            requestCount: self_.requestCount,
            displayName: self_.bestDisplayName,
            group: self_.group,
            quotaPerUnit: quotaPerUnit)
    }

    // MARK: - Key-only billing endpoints

    private struct Subscription {
        var isUnlimited: Bool
    }

    private func fetchSubscription(relayKey: String) async throws -> Subscription {
        let data = try await request(
            path: "/v1/dashboard/billing/subscription",
            query: [],
            bearer: relayKey)
        let decoded = try JSONDecoder().decode(NewAPISubscriptionResponse.self, from: data)
        // A relay that grants no limit reports the whole quota pool scaled to a
        // sentinel (upstream: `amount = 100000000` when the token is unlimited).
        // There is no separate flag in the payload, so this is the signal.
        return Subscription(isUnlimited: decoded.hardLimitUSD >= NewAPIClient.unlimitedSentinel)
    }

    private static let unlimitedSentinel: Double = 100_000_000

    private func fetchKeyOnlyUsage(relayKey: String) async throws -> Decimal {
        let data = try await request(
            path: "/v1/dashboard/billing/usage",
            query: [],
            bearer: relayKey)
        guard let decoded = try? JSONDecoder().decode(NewAPIUsageResponse.self, from: data) else {
            throw NewAPIClientError.malformedResponse
        }
        return NewAPIUnits.usdFromBillingTotalUsage(decoded.totalUsage)
    }

    // MARK: - Aggregation

    /// Rolls the relay's hourly/model buckets up to whole days.
    static func aggregateBuckets(
        _ rows: [NewAPIDataBucket],
        calendar: Calendar = .current,
        quotaPerUnit: Int = NewAPIUnits.defaultQuotaPerUnit) -> NewAPIDailyUsage
    {
        var tokens: [String: Int] = [:]
        var cost: [String: Decimal] = [:]
        var requests: [String: Int] = [:]
        for row in rows {
            let key = NewAPIDailyUsage.dayKey(
                Date(timeIntervalSince1970: TimeInterval(row.createdAt)),
                calendar: calendar)
            guard !key.isEmpty else { continue }
            // `token_used` is already the total for the bucket; summing buckets is
            // correct because each covers a distinct hour/model slice.
            tokens[key, default: 0] += row.tokenUsed ?? 0
            if let quota = row.quota, quotaPerUnit > 0 {
                cost[key, default: 0] += Decimal(quota) / Decimal(quotaPerUnit)
            }
            requests[key, default: 0] += row.count ?? 0
        }
        return NewAPIDailyUsage(tokensByDay: tokens, costByDay: cost, requestCountByDay: requests)
    }

    static func aggregateByDay(
        _ entries: [NewAPILogEntry],
        calendar: Calendar = .current,
        quotaPerUnit: Int = NewAPIUnits.defaultQuotaPerUnit) -> NewAPIDailyUsage
    {
        var tokens: [String: Int] = [:]
        var cost: [String: Decimal] = [:]
        var requests: [String: Int] = [:]
        for entry in entries {
            let key = NewAPIDailyUsage.dayKey(entry.createdAt, calendar: calendar)
            guard !key.isEmpty else { continue }
            // A log row can be a non-billable event with zero tokens; counting it as
            // a request is correct, but it must not create a phantom token day.
            if let total = entry.totalTokens { tokens[key, default: 0] += total }
            if let usd = entry.costUSD(quotaPerUnit: quotaPerUnit) { cost[key, default: 0] += usd }
            requests[key, default: 0] += 1
        }
        return NewAPIDailyUsage(tokensByDay: tokens, costByDay: cost, requestCountByDay: requests)
    }

    // MARK: - Transport

    private func request(
        path: String,
        query: [URLQueryItem],
        bearer: String?,
        attempt: Int = 0) async throws -> Data
    {
        await throttle()
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)
        else { throw NewAPIClientError.malformedResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NewAPIClientError.malformedResponse }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer, !bearer.isEmpty {
            urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        if let transport {
            (data, response) = try await transport(urlRequest)
        } else {
            (data, response) = try await RunwayNetwork.data(for: urlRequest, session: session)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NewAPIClientError.malformedResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            // Retry briefly: this relay throttles with 403, so the first rejection
            // is not necessarily an authorization failure. After the retries, a
            // 401/403 is reported as unauthorized and the caller degrades.
            if attempt < Self.retryDelays.count {
                await sleep(Self.retryDelays[attempt])
                return try await request(path: path, query: query, bearer: bearer, attempt: attempt + 1)
            }
            throw NewAPIClientError.unauthorized
        }
        if (500...599).contains(http.statusCode), attempt < Self.retryDelays.count {
            await sleep(Self.retryDelays[attempt])
            return try await request(path: path, query: query, bearer: bearer, attempt: attempt + 1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NewAPIClientError.httpStatus(http.statusCode)
        }
        return data
    }

    /// Keeps a floor between successive calls so a refresh cycle cannot burst.
    private func throttle() async {
        let timestamp = now()
        if let lastRequestAt {
            let elapsed = timestamp.timeIntervalSince(lastRequestAt)
            if elapsed < Self.minimumRequestInterval {
                await sleep(Self.minimumRequestInterval - elapsed)
            }
        }
        lastRequestAt = now()
    }

    private static func makeEntry(_ row: NewAPILogRow) -> NewAPILogEntry? {
        guard let timestamp = row.createdAt else { return nil }
        return NewAPILogEntry(
            id: row.id.map(String.init) ?? "\(timestamp)-\(row.requestId ?? UUID().uuidString)",
            createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            modelName: row.modelName,
            promptTokens: row.promptTokens,
            completionTokens: row.completionTokens,
            quota: row.quota,
            useTime: row.useTime,
            tokenName: row.tokenName,
            group: row.group,
            isStream: row.isStream,
            username: row.username)
    }
}

public enum NewAPIClientError: Error, Equatable, Sendable {
    case unauthorized
    case httpStatus(Int)
    case malformedResponse
    case missingBaseURL
    case unsupportedQuota
    case confirmedUnauthorized
    case confirmedRefreshFailure
}
