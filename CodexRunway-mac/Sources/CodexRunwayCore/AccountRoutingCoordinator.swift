import Foundation

/// Keeps Codex's global `model_provider` in step with the account being activated.
///
/// `~/.codex/config.toml` holds one top-level `model_provider`, and that single
/// line decides *where* Codex sends traffic. `auth.json` only decides *which
/// credential* it presents. A relay account and an official ChatGPT login need
/// different endpoints, so activating one while the other's provider is still
/// selected pairs an official token with a relay address — which is exactly the
/// bug this fixes.
///
/// Scope is deliberately narrow: only the `model_provider` line is touched. The
/// rest of `config.toml` (plugins, mcp_servers, projects, desktop settings,
/// model, catalogs) belongs to Codex and is preserved byte-for-byte.
public enum AccountRoutingCoordinator {
    public struct Plan: Sendable, Equatable {
        /// Provider to select, or nil to let Codex use its own default (official).
        public var providerName: String?
        /// True when the selected provider was learned from the current config
        /// because the account had not recorded one yet.
        public var inferred: Bool

        public init(providerName: String?, inferred: Bool) {
            self.providerName = providerName
            self.inferred = inferred
        }
    }

    /// The provider section every API-key account uses.
    ///
    /// One fixed name rather than a per-account one: an API key points Codex at a
    /// single relay endpoint, and reusing `custom` means a switch never leaves a
    /// trail of differently-named sections behind, each holding a stale address.
    public static let relayProviderName = "custom"

    /// What a relay account's provider should be, and what it should fall back to.
    public static func plan(for account: ManagedAccount, configURL _: URL) -> Plan {
        Plan(providerName: account.authMode == .apiKey ? relayProviderName : nil, inferred: false)
    }

    static func isOfficial(_ raw: String) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return true }
        return NewAPIRelayResolver.isOfficial(url)
    }

    /// The address a live section holds, when it can be attributed to this account.
    ///
    /// Every relay account shares one `[model_providers.custom]` section, so the live
    /// `base_url` describes whichever account was switched to last — not necessarily
    /// the one being handled. Reading it as this account's address copied a stranger's
    /// relay onto the account, which then reported a refresh failure against a host
    /// that had never issued its key. The account's own record is authoritative; the
    /// section only fills in what the account does not already know.
    static func attributableBaseURL(
        sectionAddress: String?,
        account: ManagedAccount
    ) -> String? {
        let own = account.relayBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sectionAddress, !sectionAddress.isEmpty else {
            return (own?.isEmpty == false) ? own : nil
        }
        guard let own, !own.isEmpty, own != sectionAddress else { return sectionAddress }
        // They disagree. A forwarder port is this machine's own address rather than the
        // account's, so the section's real endpoint still wins over it.
        if let parsed = NewAPIRelayResolver.normalize(own), NewAPIRelayResolver.isLoopback(parsed) {
            return sectionAddress
        }
        return own
    }

    /// What the config file says right now, read without consulting any account record.
    ///
    /// The live `[model_providers.*]` sections are shared by every relay account, so the
    /// file describes exactly one account: the active one. Reading it through an
    /// account's recorded provider name could therefore report a different account's
    /// section — and substituting that account's own stored address made the display
    /// contradict the file it claims to quote.
    ///
    /// This is the honest read: the file's own `model_provider`, then that section.
    public static func liveProfile(configURL: URL, now: Date = Date()) -> RelayConfigProfile? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        let top = CodexConfigReader.topLevelValues(toml: text)
        // No selection means Codex is on its built-in endpoint; there is no relay section
        // describing this state, so there is nothing to report.
        guard let providerName = CodexConfigReader.selectedProvider(toml: text) else { return nil }
        let section = CodexConfigReader.sectionValues(
            "model_providers.\(providerName)", toml: text)

        let profile = RelayConfigProfile(
            model: top["model"],
            modelReasoningEffort: top["model_reasoning_effort"],
            modelCatalogPath: top["model_catalog_json"],
            providerName: providerName,
            displayName: section["name"],
            baseURL: section["base_url"],
            wireAPI: section["wire_api"],
            requiresOpenAIAuth: section["requires_openai_auth"].flatMap(Bool.init),
            supportsWebSockets: section["supports_websockets"].flatMap(Bool.init) ?? false,
            capturedAt: now)
        return profile.isEmpty ? nil : profile
    }

    /// Reads the relay settings currently in the config, for storage on the account.
    ///
    /// Captured from the live file rather than from a form: at the moment a relay
    /// account is active the file holds values that are known to work, and those are
    /// exactly what should come back after a switch away and back.
    ///
    /// Reports what the file actually says, including an address that belongs to a
    /// different account. Callers that need this account's own endpoint use
    /// `attributableBaseURL`; a caller showing "what the file currently holds" must not
    /// have that value substituted, or the display contradicts the file it names.
    public static func captureProfile(
        account: ManagedAccount,
        configURL: URL,
        now: Date = Date()
    ) -> RelayConfigProfile? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        let top = CodexConfigReader.topLevelValues(toml: text)

        let providerName = account.relayProviderName
            ?? CodexConfigReader.selectedProvider(toml: text)
        // Without a provider section there is no relay to describe; an official
        // account would otherwise capture the official endpoint as if it were a relay.
        guard let providerName else { return nil }
        let section = CodexConfigReader.sectionValues(
            "model_providers.\(providerName)", toml: text)
        let baseURL = section["base_url"] ?? account.relayBaseURL


        let profile = RelayConfigProfile(
            model: top["model"],
            modelReasoningEffort: top["model_reasoning_effort"],
            modelCatalogPath: top["model_catalog_json"],
            providerName: providerName,
            displayName: section["name"],
            baseURL: baseURL,
            wireAPI: section["wire_api"],
            requiresOpenAIAuth: section["requires_openai_auth"].flatMap(Bool.init),
            // Defaults to off, and only an explicit `true` in the file turns it on. A
            // relay advertising WebSocket support it does not implement fails in a way
            // that names no cause, so "unset" must not be read as "enabled".
            supportsWebSockets: section["supports_websockets"].flatMap(Bool.init) ?? false,
            capturedAt: now)
        return profile.isEmpty ? nil : profile
    }

    /// Applies `plan` to the account's config, recording what was learned so the
    /// next switch does not have to guess again.
    ///
    /// Also repairs a `base_url` that Codex's own rewrite removed. Codex
    /// re-serializes `config.toml` from its own model and drops keys it does not
    /// recognise, which silently deleted the relay address while leaving the section
    /// header behind. With the address gone, the resolver had nothing to resolve and
    /// the account fell back to the official endpoint. The account row is the
    /// durable copy that survives that rewrite.
    @discardableResult
    public static func apply(
        _ plan: Plan,
        account: inout ManagedAccount,
        configURL: URL,
        backupDirectory: URL? = nil,
        settings _: CodexConfigProviderEditor.ContextWindow = .standard,
        profile: RelayConfigProfile? = nil
    ) -> CodexConfigProviderEditor.Outcome {
        do {
            let original = try AccountSwitchTransaction.read(configURL)
            let text = try AccountSwitchTransaction.renderConfig(
                original: original.flatMap { String(data: $0, encoding: .utf8) },
                account: account, profile: profile)
            let result = Data(text.utf8)
            guard result != original else { return .unchanged }
            if let original {
                let directory = backupDirectory ?? CodexConfigProviderEditor.defaultBackupDirectory()
                try AccountSwitchTransaction.atomicWrite(original,
                    to: directory.appendingPathComponent("config.toml.\(UUID().uuidString).bak"))
            }
            try AccountSwitchTransaction.atomicWrite(result, to: configURL)
            if plan.providerName != nil { account.relayProviderName = relayProviderName }
            return .updated(previous: CodexConfigReader.selectedProvider(toml: String(data: original ?? Data(), encoding: .utf8) ?? ""), current: plan.providerName)
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func host(of raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        return URL(string: text)?.host?.lowercased()
    }
}
