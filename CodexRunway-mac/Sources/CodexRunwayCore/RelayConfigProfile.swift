import Foundation

/// The Codex settings a relay account needs, captured so they can be re-applied
/// later without re-asking the user.
///
/// Why this exists: several tools write `~/.codex/config.toml` — this app, the
/// relay's own dashboard, and provider switchers like tt-switch. Each rewrites the
/// whole file from its own idea of the settings, so switching to an official account
/// and back used to lose the relay's own values (`model`, `wire_api`, reasoning
/// effort, and any relay-specific flag). Capturing them at the moment they are known
/// to be correct is the only way to put them back afterwards.
///
/// Only settings that describe *how to talk to the relay* are stored. Anything that
/// belongs to the user's own preferences, or that the credential decides, is left
/// out on purpose.
public struct RelayConfigProfile: Codable, Sendable, Equatable {
    /// Tracked by `schemaVersion` so an older file can be read or ignored rather
    /// than mis-parsed after a shape change.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The model to select when this account is active.
    public var model: String?
    public var modelReasoningEffort: String?
    /// A relay-specific model catalog. Kept as an absolute path because a relative
    /// one is resolved against Codex's working directory and never loads.
    public var modelCatalogPath: String?
    /// The provider section name inside `config.toml`, e.g. `custom`.
    public var providerName: String?
    /// The display name *inside* that section, e.g. `apizn`. Distinct from
    /// `providerName`: the section key is what selects the provider, this is only a
    /// label shown in Codex's own UI.
    public var displayName: String?
    /// The relay's OpenAI-compatible endpoint.
    public var baseURL: String?
    /// `responses` or `chat`; a relay that only speaks one will reject the other.
    public var wireAPI: String?
    /// Whether the endpoint expects the ChatGPT auth flow.
    public var requiresOpenAIAuth: Bool?
    public var supportsWebSockets: Bool?
    /// Capture time, so the detail view can say how current this is.
    public var capturedAt: Date

    public init(
        schemaVersion: Int = RelayConfigProfile.currentSchemaVersion,
        model: String? = nil,
        modelReasoningEffort: String? = nil,
        modelCatalogPath: String? = nil,
        providerName: String? = nil,
        displayName: String? = nil,
        baseURL: String? = nil,
        wireAPI: String? = nil,
        requiresOpenAIAuth: Bool? = nil,
        supportsWebSockets: Bool? = nil,
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.model = model
        self.modelReasoningEffort = modelReasoningEffort
        self.modelCatalogPath = modelCatalogPath
        self.providerName = providerName
        self.displayName = displayName
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.requiresOpenAIAuth = requiresOpenAIAuth
        self.supportsWebSockets = supportsWebSockets
        self.capturedAt = capturedAt
    }

    /// True when there is nothing worth re-applying.
    public var isEmpty: Bool {
        model == nil && providerName == nil && baseURL == nil && wireAPI == nil
    }

    /// The fields worth showing in a detail view, in a stable order.
    public var displayFields: [RelayConfigField] {
        [
            .init(key: "model", value: model),
            .init(key: "model_reasoning_effort", value: modelReasoningEffort),
            .init(key: "model_catalog_json", value: modelCatalogPath),
            .init(key: "model_provider", value: providerName),
            .init(key: "name", value: displayName),
            .init(key: "base_url", value: baseURL),
            .init(key: "wire_api", value: wireAPI),
            .init(key: "requires_openai_auth", value: requiresOpenAIAuth.map(String.init)),
            .init(key: "supports_websockets", value: supportsWebSockets.map(String.init)),
        ].filter { $0.value != nil }
    }
}

/// One key/value pair of a stored profile, for display.
public struct RelayConfigField: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var value: String?

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }
}

/// Persists one `RelayConfigProfile` per account.
///
/// Stored beside `index.json` rather than inside it: this is bulky, changes on every
/// switch, and is not needed to list accounts. Keeping it out means a corrupt profile
/// cannot take the account list down with it.
public struct RelayConfigStore: Sendable {
    public var directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway/relay-configs", isDirectory: true)
    }

    private func url(for accountID: String) -> URL {
        // The account id is a hash but may still contain characters a path should
        // not: keep it to a safe alphabet so a crafted id cannot escape the directory.
        let safe = accountID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent("\(String(safe)).json")
    }

    func profileURL(for accountID: String) -> URL { url(for: accountID) }

    public func load(for accountID: String) -> RelayConfigProfile? {
        guard let data = try? Data(contentsOf: url(for: accountID)) else { return nil }
        // The date strategy must match the encoder's: `capturedAt` is written as an
        // ISO-8601 string, and decoding it with the default (numeric) strategy fails
        // for every file this store writes.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(RelayConfigProfile.self, from: data) else {
            return nil
        }
        // A profile written by a newer version is not guessed at.
        guard profile.schemaVersion <= RelayConfigProfile.currentSchemaVersion else { return nil }
        return profile
    }

    @discardableResult
    public func save(_ profile: RelayConfigProfile, for accountID: String) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profile)
            try AccountSwitchTransaction.atomicWrite(data, to: url(for: accountID))
            return true
        } catch {
            return false
        }
    }

    public func remove(for accountID: String) {
        try? FileManager.default.removeItem(at: url(for: accountID))
    }
}
