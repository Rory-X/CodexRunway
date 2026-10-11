import Foundation

/// Wire formats for the New API dashboard and billing endpoints.
///
/// Field names mirror the relay's JSON exactly. Everything is optional: the
/// endpoints vary across New API versions and forks, and a missing field must
/// degrade rather than throw.

// MARK: - /api/status

struct NewAPIStatusResponse: Decodable {
    var data: NewAPIStatus?
}

public struct NewAPIStatus: Decodable, Sendable, Equatable {
    public var version: String?
    public var systemName: String?
    /// Internal quota unit divisor (e.g. 500000 for $1).
    public var quotaPerUnit: Int?
    /// "USD" | "CNY" | "TOKENS" — decides how quota values are scaled.
    public var quotaDisplayType: String?
    public var usdExchangeRate: Double?

    public var isUSD: Bool { (quotaDisplayType ?? "USD").uppercased() == "USD" }

    public init(
        version: String? = nil,
        systemName: String? = nil,
        quotaPerUnit: Int? = nil,
        quotaDisplayType: String? = nil,
        usdExchangeRate: Double? = nil)
    {
        self.version = version
        self.systemName = systemName
        self.quotaPerUnit = quotaPerUnit
        self.quotaDisplayType = quotaDisplayType
        self.usdExchangeRate = usdExchangeRate
    }

    enum CodingKeys: String, CodingKey {
        case version
        case systemName = "system_name"
        case quotaPerUnit = "quota_per_unit"
        case quotaDisplayType = "quota_display_type"
        case usdExchangeRate = "usd_exchange_rate"
    }

    private static func flexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys) -> Int?
    {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(value) }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(text) }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        systemName = try container.decodeIfPresent(String.self, forKey: .systemName)
        // The site reports this as a number, but forks have shipped it as a string.
        quotaPerUnit = Self.flexibleInt(container, .quotaPerUnit)
        quotaDisplayType = try container.decodeIfPresent(String.self, forKey: .quotaDisplayType)
        usdExchangeRate = try container.decodeIfPresent(Double.self, forKey: .usdExchangeRate)
    }
}

// MARK: - /api/user/self

struct NewAPISelfResponse: Decodable {
    var data: NewAPISelfData?
}

struct NewAPISelfData: Decodable {
    var id: Int?
    var username: String?
    var displayName: String?
    var email: String?
    var role: Int?
    var status: Int?
    var group: String?
    var quota: Int?
    var usedQuota: Int?
    var requestCount: Int?

    var bestDisplayName: String? {
        for candidate in [displayName, username, email] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, username, email, role, status, group, quota
        case displayName = "display_name"
        case usedQuota = "used_quota"
        case requestCount = "request_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.flexibleInt(container, .id)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        role = Self.flexibleInt(container, .role)
        status = Self.flexibleInt(container, .status)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        quota = Self.flexibleInt(container, .quota)
        usedQuota = Self.flexibleInt(container, .usedQuota)
        requestCount = Self.flexibleInt(container, .requestCount)
    }

    /// These counters arrive as either JSON numbers or strings depending on the
    /// fork and on whether the value is large enough to be emitted as a float.
    private static func flexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys) -> Int?
    {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(value) }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(text) }
        return nil
    }
}

// MARK: - /api/log/self

struct NewAPILogListResponse: Decodable {
    var data: NewAPILogPage?
}

struct NewAPILogPage: Decodable {
    var page: Int?
    var pageSize: Int?
    var total: Int?
    var items: [NewAPILogRow]?

    enum CodingKeys: String, CodingKey {
        case page, total, items
        case pageSize = "page_size"
    }
}

struct NewAPILogRow: Decodable {
    var id: Int?
    var createdAt: Int?
    var requestId: String?
    var modelName: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var quota: Int?
    var useTime: Double?
    var tokenName: String?
    var group: String?
    var isStream: Bool?
    var username: String?

    enum CodingKeys: String, CodingKey {
        case id, quota, username
        case createdAt = "created_at"
        case requestId = "request_id"
        case modelName = "model_name"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case useTime = "use_time"
        case tokenName = "token_name"
        case group
        case isStream = "is_stream"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.int(container, .id)
        // `created_at` is a local-time epoch second.
        createdAt = Self.int(container, .createdAt)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        promptTokens = Self.int(container, .promptTokens)
        completionTokens = Self.int(container, .completionTokens)
        quota = Self.int(container, .quota)
        useTime = Self.double(container, .useTime)
        tokenName = try container.decodeIfPresent(String.self, forKey: .tokenName)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        isStream = try container.decodeIfPresent(Bool.self, forKey: .isStream)
        username = try container.decodeIfPresent(String.self, forKey: .username)
    }

    private static func int(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys) -> Int?
    {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(value) }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(text) }
        return nil
    }

    private static func double(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys) -> Double?
    {
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil { return value }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return Double(text) }
        return nil
    }
}

// MARK: - /v1/dashboard/billing/*

struct NewAPISubscriptionResponse: Decodable {
    var softLimitUSD: Double
    var hardLimitUSD: Double
    var systemHardLimitUSD: Double?

    enum CodingKeys: String, CodingKey {
        case softLimitUSD = "soft_limit_usd"
        case hardLimitUSD = "hard_limit_usd"
        case systemHardLimitUSD = "system_hard_limit_usd"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        softLimitUSD = Self.number(container, .softLimitUSD) ?? 0
        hardLimitUSD = Self.number(container, .hardLimitUSD) ?? 0
        systemHardLimitUSD = Self.number(container, .systemHardLimitUSD)
    }

    private static func number(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys) -> Double?
    {
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil { return value }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return Double(text) }
        return nil
    }
}

struct NewAPIUsageResponse: Decodable {
    /// Reported in **$0.01** units (upstream multiplies USD by 100).
    var totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalUsage = "total_usage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = (try? container.decodeIfPresent(Double.self, forKey: .totalUsage)) ?? nil {
            totalUsage = value
        } else if let text = (try? container.decodeIfPresent(String.self, forKey: .totalUsage)) ?? nil,
                  let value = Double(text) {
            totalUsage = value
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.totalUsage,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Billing usage has no total_usage"))
        }
    }
}

// MARK: - /api/data/self

/// One aggregated bucket: an hour × model × group slice of usage.
struct NewAPIDataResponse: Decodable {
    var data: [NewAPIDataBucket]?
}

struct NewAPIDataBucket: Decodable {
    var createdAt: Int
    var modelName: String?
    var tokenUsed: Int?
    var count: Int?
    var quota: Int?

    enum CodingKeys: String, CodingKey {
        case count, quota
        case createdAt = "created_at"
        case modelName = "model_name"
        case tokenUsed = "token_used"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = Self.int(container, .createdAt) ?? 0
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        tokenUsed = Self.int(container, .tokenUsed)
        count = Self.int(container, .count)
        quota = Self.int(container, .quota)
    }

    private static func int(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys) -> Int?
    {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(value) }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(text) }
        return nil
    }
}

// MARK: - /api/token/

struct NewAPITokenListResponse: Decodable {
    var data: NewAPITokenListPayload?

    var rows: [NewAPITokenRow] { data?.rows ?? [] }
}

/// Dashboard token list payloads vary: a bare array, or `{ items: [...] }`.
struct NewAPITokenListPayload: Decodable {
    var rows: [NewAPITokenRow]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([NewAPITokenRow].self) {
            rows = array
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([NewAPITokenRow].self, forKey: .items) {
            rows = items
        } else if let data = try container.decodeIfPresent([NewAPITokenRow].self, forKey: .data) {
            rows = data
        } else {
            rows = []
        }
    }

    enum CodingKeys: String, CodingKey {
        case items, data
    }
}

struct NewAPITokenRow: Decodable, Sendable, Equatable {
    var name: String?
    var key: String?
}
