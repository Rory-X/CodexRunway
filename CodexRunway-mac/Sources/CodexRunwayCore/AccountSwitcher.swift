import Foundation
import OSLog

public struct AccountSwitchResult: Sendable, Equatable {
    public var account: ManagedAccount
    public var auth: CodexAuth
    /// Set when the credential installed cleanly but Codex's endpoint could not be
    /// pointed at the matching provider. Surfaced to the user rather than thrown:
    /// the account itself is usable, only the routing is stale.
    public var routingFailure: String?

    public init(account: ManagedAccount, auth: CodexAuth, routingFailure: String? = nil) {
        self.account = account
        self.auth = auth
        self.routingFailure = routingFailure
    }
}

/// Switches the CLI-active account by writing the selected credential to official `auth.json`.
public struct AccountSwitcher: Sendable {
    public var store: AccountStore
    public var tokenRefresher: TokenRefresher
    public var fetchQuota: @Sendable (CodexAuth) async throws -> QuotaSnapshot
    /// Codex's own config file, whose global `model_provider` decides where traffic
    /// goes. Injectable so tests never touch the real one.
    public var routingConfigURL: URL
    /// Where the pre-change `config.toml` is copied before a routing rewrite.
    public var routingBackupDirectory: URL?
    /// Per-account relay settings, kept out of `config.toml` so another tool's
    /// rewrite cannot erase them.
    public var relayConfigStore: RelayConfigStore
    /// Test-only checkpoints inside the synchronous commit.
    var failCommitAt: (@Sendable (String) throws -> Void)?
    var failRestoreAt: (@Sendable (URL) throws -> Void)?
    var observeConfigCommit: (@Sendable () -> Void)?
    var reportPersistenceFailure: @Sendable (Error) -> Void = { error in
        let failure = error as NSError
        Logger(subsystem: "com.github.codex-runway", category: "account-switch")
            .error("reauth_status_persistence_failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
    }

    public init(
        store: AccountStore = AccountStore(),
        tokenRefresher: TokenRefresher = TokenRefresher(),
        routingConfigURL: URL? = nil,
        routingBackupDirectory: URL? = nil,
        relayConfigStore: RelayConfigStore? = nil,
        fetchQuota: @escaping @Sendable (CodexAuth) async throws -> QuotaSnapshot = {
            try await QuotaClient().fetchQuota(auth: $0)
        })
    {
        self.store = store
        self.tokenRefresher = tokenRefresher
        // Defaults to the config beside the store's own official auth.json, so a
        // caller that redirects the codex home redirects this too. Defaulting to a
        // hard-coded `~/.codex/config.toml` let the test suite rewrite the real one.
        self.routingConfigURL = routingConfigURL ?? store.officialConfigURL
        self.routingBackupDirectory = routingBackupDirectory ?? store.rootURL.deletingLastPathComponent()
            .appendingPathComponent("config-backups")
        self.fetchQuota = fetchQuota
        self.relayConfigStore = relayConfigStore ?? RelayConfigStore(
            directory: store.rootURL.deletingLastPathComponent().appendingPathComponent("relay-configs"))
    }

    public func switchTo(accountId: String, now: Date = Date()) async throws -> AccountSwitchResult {
        let expected = try AccountSwitchTransaction.synchronized {
            (try AccountSwitchTransaction.read(store.indexURL),
             try AccountSwitchTransaction.read(store.credentialURL(id: accountId)),
             try AccountSwitchTransaction.read(routingConfigURL),
             try AccountSwitchTransaction.read(store.officialAuthURL),
             AccountSwitchTransaction.generation(for: store))
        }
        var auth = try store.loadCredential(id: accountId)
        let initialAuth = auth

        // Allow full OAuth and non-expired access-token-only session credentials.
        // Block only invalid junk or expired session tokens with no refresh.
        switch auth.loginUsability {
        case .usable:
            break
        case .expiredAccessWithoutRefresh:
            throw AccountStoreError.expiredAccessWithoutRefresh
        case .invalidTokens:
            throw AccountStoreError.notUsableAsCodexLogin
        }

        // Validate the target before replacing the current login or restarting the app.
        do {
            auth = try await ensureValid(auth: auth, accountId: accountId)
            if !auth.isAPIKeyAuth {
                _ = try await fetchQuota(auth)
            }
        } catch {
            if (error as? URLError)?.code == .userAuthenticationRequired {
                do {
                    guard let account = try store.loadIndex().account(id: accountId) else {
                        throw AccountStoreError.accountNotFound(accountId)
                    }
                    try store.updateMetadata(account.applying(error: error.localizedDescription, requiresReauth: true))
                } catch {
                    // Preserve the authentication error, but make failed persistence observable.
                    reportPersistenceFailure(error)
                }
            }
            throw error
        }

        switch auth.loginUsability {
        case .usable:
            break
        case .expiredAccessWithoutRefresh:
            throw AccountStoreError.expiredAccessWithoutRefresh
        case .invalidTokens:
            throw AccountStoreError.notUsableAsCodexLogin
        }

        let officialBeforeCommit = try AccountSwitchTransaction.read(store.officialAuthURL)
        if officialBeforeCommit != expected.3 {
            guard auth != initialAuth,
                  (try? JSONDecoder().decode(CodexAuth.self, from: expected.3 ?? Data())) == initialAuth,
                  (try? JSONDecoder().decode(CodexAuth.self, from: officialBeforeCommit ?? Data())) == auth
            else { throw AccountSwitchTransaction.Failure.externalModification }
        }

        return try AccountSwitchTransaction.synchronized {
            let (expectedIndex, _, expectedConfig, _, _) = expected
            // Refresh may have legitimately rotated the target credential while
            // quota was in flight. Other changes to routing/index are conflicts.
            guard try AccountSwitchTransaction.read(store.indexURL) == expectedIndex,
                  try AccountSwitchTransaction.read(routingConfigURL) == expectedConfig,
                  try AccountSwitchTransaction.read(store.officialAuthURL) == officialBeforeCommit,
                  try store.loadCredential(id: accountId) == auth
            else { throw AccountSwitchTransaction.Failure.externalModification }
            var index = try store.loadIndex()
            guard var account = index.account(id: accountId) else {
                throw AccountStoreError.accountNotFound(accountId)
            }
            let previousID = index.activeAccountId
            var targetProfile = relayConfigStore.load(for: accountId)
            if account.authMode == .oauth, targetProfile?.providerName != nil {
                targetProfile = nil
            }
            var outgoingProfile: RelayConfigProfile?
            let liveConfig = String(data: expectedConfig ?? Data(), encoding: .utf8) ?? ""
            if let previousID, let previous = index.account(id: previousID),
               let official = try? store.loadOfficialAuth(),
               let managed = try? store.loadCredential(id: previousID), official == managed,
               ((previous.authMode == .oauth && CodexConfigReader.selectedProvider(toml: liveConfig) == nil
                  && CodexConfigReader.topLevelValues(toml: liveConfig)["openai_base_url"] == nil
                  && CodexConfigReader.topLevelValues(toml: liveConfig)["chatgpt_base_url"] == nil)
                || (previous.authMode == .apiKey && CodexConfigReader.selectedProvider(toml: liveConfig) == "custom"
                  && CodexConfigReader.providerBaseURLs(toml: liveConfig)["custom"] == previous.relayBaseURL)) {
                let top = CodexConfigReader.topLevelValues(toml: liveConfig)
                if previous.authMode == .oauth {
                    outgoingProfile = RelayConfigProfile(model: top["model"],
                        modelReasoningEffort: top["model_reasoning_effort"], capturedAt: now)
                } else {
                    outgoingProfile = AccountRoutingCoordinator.captureProfile(
                        account: previous, configURL: routingConfigURL, now: now)
                    outgoingProfile?.baseURL = previous.relayBaseURL ?? relayConfigStore.load(for: previousID)?.baseURL
                    outgoingProfile?.supportsWebSockets = relayConfigStore.load(for: previousID)?.supportsWebSockets ?? false
                }
                if previousID == accountId, let outgoingProfile { targetProfile = outgoingProfile }
            }
            account = account.withIdentity(from: auth, quotaPlan: nil, now: now)
            account.cachedQuota = nil
            account.lastQuotaAt = nil
            account.lastUsedAt = now
            account.requiresReauth = false
            account.lastError = nil
            if account.authMode == .apiKey { account.relayProviderName = "custom" }
            let config = try AccountSwitchTransaction.renderConfig(
                original: expectedConfig.flatMap { String(data: $0, encoding: .utf8) },
                account: account, profile: targetProfile)
            let configData = Data(config.utf8)
            let originalManaged = try AccountSwitchTransaction.read(store.credentialURL(id: accountId))
            let outgoingURL = previousID.map { relayConfigStore.profileURL(for: $0) }
            let originalProfile = try outgoingURL.flatMap { try AccountSwitchTransaction.read($0) }
            let backupURL = routingBackupDirectory?.appendingPathComponent(
                "config.toml.\(UUID().uuidString).bak")
            index.upsert(account)
            index.activeAccountId = accountId
            let snapshots: [AccountSwitchTransaction.Snapshot] = [
                .init(url: routingConfigURL, original: expectedConfig),
                .init(url: store.officialAuthURL, original: officialBeforeCommit),
                .init(url: store.credentialURL(id: accountId), original: originalManaged),
                .init(url: store.indexURL, original: expectedIndex),
            ] + (outgoingURL.map { [.init(url: $0, original: originalProfile)] } ?? [])
            var attempted: [URL] = []
            do {
                if configData != expectedConfig, let expectedConfig, let backupURL {
                    try AccountSwitchTransaction.atomicWrite(expectedConfig, to: backupURL)
                }
                try failCommitAt?("backup")
                if configData != expectedConfig {
                    attempted.append(routingConfigURL)
                    try AccountSwitchTransaction.atomicWrite(configData, to: routingConfigURL)
                    observeConfigCommit?()
                }
                try failCommitAt?("config")
                attempted.append(store.officialAuthURL)
                try store.saveOfficialAuth(auth)
                try failCommitAt?("auth")
                if (try? JSONDecoder().decode(CodexAuth.self, from: originalManaged ?? Data())) != auth {
                    attempted.append(store.credentialURL(id: accountId))
                    try store.saveCredential(id: accountId, auth: auth)
                }
                try failCommitAt?("managed")
                if let outgoingProfile, let previousID {
                    if let outgoingURL { attempted.append(outgoingURL) }
                    guard relayConfigStore.save(outgoingProfile, for: previousID) else {
                        throw AccountStoreError.io("profile_write_failed")
                    }
                }
                try failCommitAt?("profile")
                attempted.append(store.indexURL)
                try store.saveIndex(index)
                try failCommitAt?("index")
                AccountSwitchTransaction.advance(for: store)
            } catch {
                var failedPaths: [String] = []
                for url in attempted.reversed() {
                    guard let snapshot = snapshots.first(where: { $0.url == url }) else { continue }
                    do {
                        try failRestoreAt?(url)
                        try AccountSwitchTransaction.restore(snapshot.original, at: url)
                    } catch {
                        failedPaths.append(url.path)
                    }
                }
                if failedPaths.isEmpty, let backupURL,
                   FileManager.default.fileExists(atPath: backupURL.path) {
                    do { try FileManager.default.removeItem(at: backupURL) }
                    catch { failedPaths.append(backupURL.path) }
                }
                if !failedPaths.isEmpty {
                    throw AccountSwitchTransaction.RecoveryIncomplete(
                        cause: String(describing: type(of: error)), failedPaths: failedPaths,
                        snapshots: snapshots, configBackupURL: backupURL)
                }
                throw error
            }
            return AccountSwitchResult(account: account, auth: auth)
        }
    }

    /// Refresh OAuth tokens for a managed account. Writes official auth only when it is active.
    public func ensureValidCredential(accountId: String) async throws -> CodexAuth {
        let auth = try store.loadCredential(id: accountId)
        return try await ensureValid(auth: auth, accountId: accountId)
    }

    private func ensureValid(auth: CodexAuth, accountId: String) async throws -> CodexAuth {
        if auth.isAPIKeyAuth {
            guard let key = auth.openAIAPIKey, !key.isEmpty else {
                throw AccountStoreError.invalidCredential
            }
            return auth
        }
        guard auth.canRefreshOAuth || !auth.tokens.accessToken.isEmpty else {
            throw AccountStoreError.invalidCredential
        }
        var working = auth
        if TokenInspector.isExpired(working.tokens.accessToken) {
            guard working.canRefreshOAuth else {
                // Session access tokens cannot be renewed without refresh_token.
                throw AccountStoreError.expiredAccessWithoutRefresh
            }
            let key = store.credentialURL(id: accountId).path + "|" + auth.tokens.refreshToken
            return try await AccountSwitchTransaction.refreshFlights.run(key: key) {
                try await refreshCredential(auth: auth, accountId: accountId)
            }
        }
        return working
    }

    private func refreshCredential(auth: CodexAuth, accountId: String) async throws -> CodexAuth {
        let latest = try AccountSwitchTransaction.synchronized { try store.loadCredential(id: accountId) }
        if latest != auth { return latest }
        var working = auth
            let generation = AccountSwitchTransaction.generation(for: store)
            try await tokenRefresher.refresh(&working, store: nil)
            return try AccountSwitchTransaction.synchronized {
                let current = try store.loadCredential(id: accountId)
                guard current == auth else { return current }
                let active = try store.loadIndex().activeAccountId == accountId
                let officialMatches = (try? store.loadOfficialAuth()) == auth
                try store.saveCredential(id: accountId, auth: working)
                if active && officialMatches && AccountSwitchTransaction.generation(for: store) == generation {
                    try store.saveOfficialAuth(working)
                }
                return working
            }
    }
}
