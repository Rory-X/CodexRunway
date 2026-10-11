import Foundation
import OSLog

public struct AccountQuotaRefreshResult: Sendable, Equatable {
    public var accountId: String
    public var account: ManagedAccount?
    public var errorDescription: String?
}

/// Refreshes quota for all managed OAuth accounts with bounded concurrency.
public struct AccountQuotaRefresher: Sendable {
    private static let logger = Logger(
        subsystem: "com.github.codex-runway",
        category: "account-quota")

    public var store: AccountStore
    public var switcher: AccountSwitcher
    public var quotaClient: QuotaClient
    public var maxConcurrent: Int
    /// Optional New API dashboard PATs. Absent entries fall back to key-only figures.
    public var newAPITokens: NewAPITokenStore
    /// Injectable transport for relay tests; production uses a regular client.
    public var newAPIClient: @Sendable (URL) -> NewAPIClient
    /// Per-account captured relay settings, consulted before the shared config.
    public var relayConfigStore: RelayConfigStore
    /// Resolves the relay base URL for a New API account.
    ///
    /// Takes the account's own captured address alongside the account row: the live
    /// `config.toml` holds a single `[model_providers.custom]` section shared by every
    /// relay account, so its `base_url` describes whichever account was switched to
    /// last rather than the one being queried.
    public var relayBaseURL: @Sendable (ManagedAccount, String?) -> URL?
    /// The endpoint Codex itself is pointed at, for the currently active account.
    ///
    /// Consulted first for the active account and never for a background one: the file
    /// describes exactly the selected account, and it is what Codex will actually use.
    public var activeRelayBaseURL: @Sendable () -> URL?

    public init(
        store: AccountStore = AccountStore(),
        switcher: AccountSwitcher = AccountSwitcher(),
        quotaClient: QuotaClient = QuotaClient(),
        maxConcurrent: Int = 3,
        newAPITokens: NewAPITokenStore = NewAPITokenStore(),
        newAPIClient: @escaping @Sendable (URL) -> NewAPIClient = { NewAPIClient(baseURL: $0) },
        relayConfigStore: RelayConfigStore? = nil,
        configURL: URL = NewAPIRelayResolver.defaultConfigURL,
        relayBaseURL: @escaping @Sendable (ManagedAccount, String?) -> URL? = {
            NewAPIRelayResolver.accountOwnedBaseURL(for: $0, profileBaseURL: $1)
        },
        activeRelayBaseURL: @escaping @Sendable () -> URL? = { nil })
    {
        self.store = store
        self.switcher = switcher
        self.quotaClient = quotaClient
        self.maxConcurrent = max(1, maxConcurrent)
        self.newAPITokens = newAPITokens
        self.newAPIClient = newAPIClient
        self.relayConfigStore = relayConfigStore ?? RelayConfigStore(
            directory: store.rootURL.deletingLastPathComponent().appendingPathComponent("relay-configs"))
        self.relayBaseURL = relayBaseURL
        self.activeRelayBaseURL = activeRelayBaseURL
    }

    public func refreshAll() async -> [AccountQuotaRefreshResult] {
        let index: AccountIndex
        do {
            index = try store.loadIndex()
        } catch {
            return []
        }

        // Active first for snappier sidebar/current UX.
        let ordered = index.orderedForSidebar()
        var results: [AccountQuotaRefreshResult] = []
        results.reserveCapacity(ordered.count)

        let activeId = index.activeAccountId

        await withTaskGroup(of: AccountQuotaRefreshResult.self) { group in
            var iterator = ordered.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                guard inFlight < maxConcurrent, let account = iterator.next() else { return }
                inFlight += 1
                let isActive = account.id == activeId
                group.addTask { [store, switcher, quotaClient, newAPITokens, newAPIClient, relayConfigStore, relayBaseURL, activeRelayBaseURL] in
                    await Self.refreshOne(
                        account: account,
                        store: store,
                        switcher: switcher,
                        quotaClient: quotaClient,
                        newAPITokens: newAPITokens,
                        newAPIClient: newAPIClient,
                        profiles: relayConfigStore,
                        isActive: isActive,
                        relayBaseURL: relayBaseURL,
                        activeRelayBaseURL: activeRelayBaseURL)
                }
            }

            for _ in 0..<maxConcurrent {
                enqueueNext()
            }

            for await result in group {
                results.append(result)
                inFlight -= 1
                enqueueNext()
            }
        }

        // Preserve sidebar order in returned results.
        let order = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        return results.sorted {
            (order[$0.accountId] ?? .max) < (order[$1.accountId] ?? .max)
        }
    }

    public func refresh(accountId: String) async -> AccountQuotaRefreshResult {
        let index: AccountIndex
        do {
            index = try store.loadIndex()
        } catch {
            return AccountQuotaRefreshResult(accountId: accountId, account: nil, errorDescription: error.localizedDescription)
        }
        guard let account = index.account(id: accountId) else {
            return AccountQuotaRefreshResult(accountId: accountId, account: nil, errorDescription: "account not found")
        }
        return await Self.refreshOne(
            account: account,
            store: store,
            switcher: switcher,
            quotaClient: quotaClient,
            newAPITokens: newAPITokens,
            newAPIClient: newAPIClient,
            profiles: relayConfigStore,
            isActive: index.activeAccountId == account.id,
            relayBaseURL: relayBaseURL,
            activeRelayBaseURL: activeRelayBaseURL)
    }

    private static func refreshOne(
        account: ManagedAccount,
        store: AccountStore,
        switcher: AccountSwitcher,
        quotaClient: QuotaClient,
        newAPITokens: NewAPITokenStore = NewAPITokenStore(),
        newAPIClient: @Sendable (URL) -> NewAPIClient = { NewAPIClient(baseURL: $0) },
        profiles: RelayConfigStore? = nil,
        isActive: Bool = false,
        relayBaseURL: @Sendable (ManagedAccount, String?) -> URL? = {
            NewAPIRelayResolver.accountOwnedBaseURL(for: $0, profileBaseURL: $1)
        },
        activeRelayBaseURL: @Sendable () -> URL? = { nil }
    ) async -> AccountQuotaRefreshResult
    {
        let generation = AccountSwitchTransaction.generation(for: store)
        if account.authMode == .apiKey {
            // API-key accounts cannot use the ChatGPT quota endpoints, but when the
            // key points at a relay they can read their own spend from the relay's
            // OpenAI-compatible billing endpoints. These accounts used to be skipped
            // outright, so the panel always showed a placeholder.
            return await refreshAPIKey(
                account: account,
                store: store,
                newAPITokens: newAPITokens,
                newAPIClient: newAPIClient,
                profileBaseURL: profiles?.load(for: account.id)?.baseURL,
                isActive: isActive,
                relayBaseURL: relayBaseURL,
                activeRelayBaseURL: activeRelayBaseURL)
        }

        do {
            let auth = try await switcher.ensureValidCredential(accountId: account.id)
            let quota = try await quotaClient.fetchQuota(auth: auth)
            var updated = account.withIdentity(from: auth, quotaPlan: quota.plan).applying(quota: quota)
            var metadataError: String?
            if shouldFetchWorkspaceName(for: updated) {
                do {
                    if let workspaceName = try await quotaClient.fetchWorkspaceName(auth: auth) {
                        updated.workspaceName = workspaceName
                    }
                } catch {
                    metadataError = "workspace_metadata_unavailable"
                    Self.logger.warning("workspace_metadata_unavailable")
                }
            }
            try commitQuota(updated, original: account, store: store, generation: generation,
                            expectedCredential: auth)
            return AccountQuotaRefreshResult(
                accountId: account.id,
                account: updated,
                errorDescription: metadataError)
        } catch {
            let message = error.localizedDescription
            let needsReauth = (error as? URLError)?.code == .userAuthenticationRequired
            let updated = account.applying(error: message, requiresReauth: needsReauth)
            try? commitQuota(updated, original: account, store: store, generation: generation)
            return AccountQuotaRefreshResult(accountId: account.id, account: updated, errorDescription: message)
        }
    }

    private static func shouldFetchWorkspaceName(for account: ManagedAccount) -> Bool {
        guard account.workspaceName == nil else { return false }
        switch account.subscriptionTier {
        case .team, .business, .enterprise, .edu:
            return true
        default:
            return false
        }
    }

    /// Serialize the index merge with a switch; never save an old index snapshot.
    private static func commitQuota(_ refreshed: ManagedAccount, original: ManagedAccount,
                                    store: AccountStore, generation: UInt64,
                                    expectedCredential: CodexAuth? = nil) throws {
        try AccountSwitchTransaction.synchronized {
            guard AccountSwitchTransaction.generation(for: store) == generation else { return }
            if let expectedCredential {
                guard try store.loadCredential(id: original.id) == expectedCredential else { return }
            }
            var index = try store.loadIndex()
            guard var current = index.account(id: original.id),
                  current.authMode == original.authMode,
                  current.relayBaseURL == original.relayBaseURL else { return }
            current.cachedQuota = refreshed.cachedQuota
            current.lastQuotaAt = refreshed.lastQuotaAt
            current.lastError = refreshed.lastError
            current.requiresReauth = refreshed.requiresReauth
            current.workspaceName = refreshed.workspaceName ?? current.workspaceName
            if refreshed.authMode == .apiKey, refreshed.lastError == nil,
               let name = refreshed.cachedQuota?.newAPI?.displayName, !name.isEmpty {
                current.displayName = name
            }
            index.upsert(current)
            try store.saveIndex(index)
        }
    }
}

// MARK: - New API relay

extension AccountQuotaRefresher {
    /// Reads balance and usage for a New API relay account.
    ///
    /// Never throws: a relay that is unreachable or throttling must not make the
    /// account look broken. Failure is reported through `errorDescription` and the
    /// previously cached figures are preserved.
    static func refreshAPIKey(
        account: ManagedAccount,
        store: AccountStore,
        newAPITokens: NewAPITokenStore,
        newAPIClient: @Sendable (URL) -> NewAPIClient = { NewAPIClient(baseURL: $0) },
        profileBaseURL: String? = nil,
        isActive: Bool = false,
        relayBaseURL: @Sendable (ManagedAccount, String?) -> URL?,
        activeRelayBaseURL: @Sendable () -> URL? = { nil }
    ) async -> AccountQuotaRefreshResult {
        var updated = account
        updated.requiresReauth = false
        updated.lastError = nil
        let generation = AccountSwitchTransaction.generation(for: store)

        // The selected account is the one the file describes, and the file is what Codex
        // will actually use. Every other account falls back to its own record, because a
        // shared section cannot describe an account that is not the one selected.
        let baseURL = relayBaseURL(account, profileBaseURL)
        guard let baseURL else {
            updated.cachedQuota = nil
            updated.lastQuotaAt = nil
            try? commitQuota(updated, original: account, store: store, generation: generation)
            return AccountQuotaRefreshResult(accountId: account.id, account: updated, errorDescription: nil)
        }

        let credential: CodexAuth
        let relayKey: String
        do {
            credential = try store.loadCredential(id: account.id)
            relayKey = credential.openAIAPIKey ?? ""
        } catch {
            return AccountQuotaRefreshResult(
                accountId: account.id, account: account, errorDescription: "relay_credential_unavailable")
        }
        guard !relayKey.isEmpty else {
            updated.lastError = "relay_credential_unavailable"
            try? commitQuota(updated, original: account, store: store, generation: generation)
            return AccountQuotaRefreshResult(
                accountId: account.id, account: updated, errorDescription: "relay_credential_unavailable")
        }

        let dashboardToken = newAPITokens.token(for: account.id)
        let client = newAPIClient(baseURL)

        do {
            let usage = try await client.fetchUsage(
                relayKey: relayKey,
                dashboardToken: dashboardToken)

            // Daily totals need the dashboard API; absent a PAT they stay nil and
            // the panel simply omits the trend rather than showing a false zero.
            var daily: NewAPIDailyUsage?
            var tokenName: String?
            if let dashboardToken, !dashboardToken.isEmpty {
                tokenName = try? await client.resolveTokenName(
                    dashboardToken: dashboardToken,
                    relayKey: relayKey)
                if let tokenName {
                    // Per-key logs, not `/api/data/self` (that endpoint is account-wide).
                    daily = try? await client.fetchDailyUsage(
                        dashboardToken: dashboardToken,
                        tokenName: tokenName,
                        days: 30)
                }
            }

            updated.cachedQuota = Self.makeRelayQuota(
                usage: usage,
                daily: daily,
                tokenName: tokenName,
                now: Date())
            if let name = usage.displayName, !name.isEmpty {
                updated.displayName = name
            }
            updated.lastQuotaAt = Date()
            updated.lastError = nil
            guard AccountSwitchTransaction.generation(for: store) == generation else {
                return AccountQuotaRefreshResult(accountId: account.id, account: nil, errorDescription: nil)
            }
            try commitQuota(updated, original: account, store: store, generation: generation,
                            expectedCredential: credential)
            return AccountQuotaRefreshResult(accountId: account.id, account: updated, errorDescription: nil)
        } catch {
            // Keep the last good snapshot on screen and report the failure.
            //
            // A rejected key and an unreachable relay are different problems with
            // different fixes — the first needs a new key, the second needs the relay
            // to come back — so they are not collapsed into one message.
            let knownCode: String?
            switch error as? NewAPIClientError {
            case .confirmedUnauthorized:
                knownCode = "relay_key_rejected"
            case .confirmedRefreshFailure:
                knownCode = "relay_refresh_failed"
            default:
                knownCode = nil
            }
            guard let knownCode else {
                // A generic API may not expose New API billing at all. No quota is
                // normal for that account, even when the attempted endpoint returns
                // an auth error, server error, or transport failure.
                updated.cachedQuota = nil
                updated.lastQuotaAt = nil
                if AccountSwitchTransaction.generation(for: store) == generation {
                    try? commitQuota(updated, original: account, store: store, generation: generation,
                                     expectedCredential: credential)
                }
                return AccountQuotaRefreshResult(accountId: account.id, account: updated, errorDescription: nil)
            }
            updated.lastError = knownCode
            if AccountSwitchTransaction.generation(for: store) == generation {
                try? commitQuota(updated, original: account, store: store, generation: generation,
                                 expectedCredential: credential)
            }
            return AccountQuotaRefreshResult(
                accountId: account.id,
                account: updated,
                errorDescription: knownCode)
        }
    }

    static func makeRelayQuota(
        usage: NewAPIAccountUsage,
        daily: NewAPIDailyUsage?,
        tokenName: String? = nil,
        now: Date
    ) -> CachedAccountQuota {
        let balance = CachedNewAPIBalance(
            remainingUSD: usage.remainingUSD.map(Self.double),
            usedUSD: usage.usedUSD.map(Self.double),
            totalUSD: usage.totalUSD.map(Self.double),
            keyUsedUSD: usage.keyOnlyUsedUSD.map(Self.double),
            keyIsUnlimited: usage.keyIsUnlimited,
            requestCount: usage.requestCount,
            displayName: usage.displayName,
            group: usage.group,
            todayTokens: daily.map { $0.tokens(on: now) },
            sevenDayTokens: daily.map { $0.tokensInLast(days: 7, now: now) },
            todayCostUSD: daily.map { Self.double($0.costInLast(days: 1, now: now)) },
            sevenDayCostUSD: daily.map { Self.double($0.costInLast(days: 7, now: now)) },
            quotaPerUnit: usage.quotaPerUnit,
            tokensByDay: daily?.tokensByDay,
            tokenName: tokenName)

        // A relay account has no 5h/weekly windows. The bar is driven from the
        // balance fraction, and a relay that reports no limit shows 0% used so the
        // sidebar renders a neutral bar instead of a full one.
        let usedPercent = Int(((balance.usedFraction ?? 0) * 100).rounded())
        return CachedAccountQuota(
            plan: usage.group,
            primaryUsedPercent: usedPercent,
            updatedAt: now,
            newAPI: balance)
    }

    private static func double(_ decimal: Decimal) -> Double {
        (decimal as NSDecimalNumber).doubleValue
    }
}

/// Resolves the relay base URL for a New API account.
///
/// The address is not stored per account: it is read from Codex's own
/// `~/.codex/config.toml`, which already maps provider names to `base_url`.
/// That keeps a single source of truth and avoids asking the user to type a URL
/// the app can already see.
public enum NewAPIRelayResolver {
    /// Only values captured for this account may receive its key.
    public static func accountOwnedBaseURL(for account: ManagedAccount,
                                           profileBaseURL: String? = nil) -> URL? {
        for raw in [account.relayBaseURL, profileBaseURL] {
            if let raw, let url = normalize(raw), !isOfficial(url), !isLoopback(url) {
                return url
            }
        }
        return nil
    }

    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    /// Hosts that serve the official OpenAI API. A key pointed at one of these is
    /// not a relay, so there is no relay quota API to query.
    static let officialHosts: Set<String> = [
        "api.openai.com",
        "chatgpt.com",
        "openai.com",
    ]

    /// A loopback address is a *forwarding proxy*, not the relay site itself.
    ///
    /// Switcher apps (tt-switch and friends) rewrite `base_url` to their own local
    /// port and forward `/v1/*` upstream. That works for model requests, but the
    /// dashboard API lives at `/api/*` on the real site, and a forwarder that only
    /// speaks `/v1` answers 404. The account then reports a refresh failure with a
    /// perfectly good token stored.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" { return true }
        // Must be a real IPv4 literal: a hostname like `127.example.com` only looks
        // like loopback, and treating it as one would discard a working address.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        return octets[0] == "127"
    }

    /// The endpoint the config file currently selects, read as the file it is.
    ///
    /// This is what Codex itself will use, so for the active account it outranks any
    /// record this app keeps: those records describe the account, while this describes
    /// the request that will actually be made. The file names one provider, so the answer
    /// belongs to whichever account is selected.
    public static func configFileBaseURL(configURL: URL = defaultConfigURL) -> URL? {
        guard let name = CodexConfigReader.selectedProvider(configURL: configURL),
              let raw = CodexConfigReader.providerBaseURLs(configURL: configURL)[name],
              let resolved = normalize(raw),
              !isOfficial(resolved)
        else { return nil }
        return resolved
    }

    /// Overload kept so existing call sites keep resolving to a two-argument
    /// symbol; adding a defaulted parameter changes the mangled name, not just the
    /// call syntax.
    public static func baseURL(for account: ManagedAccount, configURL: URL? = nil) -> URL? {
        baseURL(for: account, configURL: configURL, backupDirectory: nil)
    }

    public static func baseURL(
        for account: ManagedAccount,
        configURL: URL?,
        backupDirectory: URL? = nil
    ) -> URL? {
        baseURL(
            for: account,
            configURL: configURL,
            backupDirectory: backupDirectory,
            profileBaseURL: nil)
    }

    /// Resolves the relay address, preferring sources that belong to *this* account.
    ///
    /// The live `config.toml` holds one `[model_providers.custom]` section shared by
    /// every relay account, so its `base_url` describes whichever account was switched
    /// to last — not the account being queried. Reading it for anyone else copied a
    /// stranger's relay onto the account, and a healthy account then reported a
    /// refresh failure against a host that was never its own.
    ///
    /// `profileBaseURL` is the account's own captured address, which is the durable
    /// per-account record for exactly that case.
    public static func baseURL(
        for account: ManagedAccount,
        configURL: URL?,
        backupDirectory: URL?,
        profileBaseURL: String?
    ) -> URL? {
        // An explicitly entered address always wins: the user may point this account
        // at a relay that Codex's own config does not mention. A loopback address does
        // not count as "entered" — it is a forwarder's port, and the dashboard API is
        // not reachable through it.
        if let typed = account.relayBaseURL, let resolved = normalize(typed), !isLoopback(resolved) {
            return resolved
        }

        // The account's own captured settings, before anything read from the shared
        // section. Skipped when it names an official host, which has no relay to read.
        if let stored = profileBaseURL, let resolved = normalize(stored),
           !isLoopback(resolved), !isOfficial(resolved)
        {
            return resolved
        }

        let url = configURL ?? defaultConfigURL
        let providers = CodexConfigReader.providerBaseURLs(configURL: url)

        // Codex re-serializes its config from its own model and drops the relay's
        // `base_url`, leaving the section header behind. The account's own copy and
        // the pre-change backups are the durable record, so recover from them rather
        // than reporting the account broken over a rewrite we cannot prevent.
        if let recorded = account.relayProviderName,
           providers[recorded] == nil,
           let recovered = recoveredBaseURL(
               forProvider: recorded, configURL: url, backupDirectory: backupDirectory)
        {
            return normalize(recovered)
        }

        guard !providers.isEmpty else {
            return nil
        }

        // Prefer the provider the account was recorded against, then the one Codex
        // currently has selected.
        //
        // When there is no selection at all — the normal state after an official
        // account clears `model_provider` — fall back to the first relay provider in
        // file order, because the relay's own `[model_providers.*]` section is still
        // in the config. A *selected* provider is respected as-is: if it is official,
        // Codex is deliberately pointed at the official API, and quietly querying
        // some other provider section would send requests to an unrelated host.
        let selected = CodexConfigReader.selectedProvider(configURL: url)
        var candidates: [String] = []
        if let name = account.relayProviderName { candidates.append(name) }
        if let selected {
            candidates.append(selected)
        } else {
            candidates.append(contentsOf: CodexConfigReader.providerNamesInFileOrder(configURL: url))
        }

        for candidate in candidates {
            guard let raw = providers[candidate], let resolved = normalize(raw) else { continue }
            // An official endpoint is not a relay: querying it would at best 404.
            if isOfficial(resolved) { continue }
            // A forwarder's own port cannot answer `/api/*`, so prefer the last real
            // address this provider used. Only reached when the config has been
            // rewritten to point at a local proxy.
            if isLoopback(resolved) {
                if let recovered = recoveredBaseURL(
                    forProvider: candidate,
                    configURL: url,
                    backupDirectory: backupDirectory,
                    excludingLoopback: true
                ), let real = normalize(recovered)
                {
                    return real
                }
                // No real address on record. The forwarder still serves `/v1/*`, so
                // keep it: the key-only billing endpoints stay usable, which is more
                // than returning nothing would allow.
                return resolved
            }
            return resolved
        }
        return nil
    }

    static func isOfficial(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return officialHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The last known address for a provider, read from the pre-change backups.
    ///
    /// Backups are written before every routing rewrite, so they preserve addresses
    /// that Codex later stripped from the live file.
    static func recoveredBaseURL(
        forProvider name: String,
        configURL: URL,
        backupDirectory: URL? = nil,
        excludingLoopback: Bool = false
    ) -> String? {
        // Injectable so a test never reads the developer's real backups — which
        // would both hide the test's own fixture and leak real addresses into it.
        let directory = backupDirectory ?? CodexConfigProviderEditor.defaultBackupDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        // Newest first: the most recent address is the one still in use.
        let ordered = entries
            .filter { $0.lastPathComponent.hasPrefix("config.toml.") }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
        for backup in ordered {
            let providers = CodexConfigReader.providerBaseURLs(configURL: backup)
            guard let address = providers[name], !address.isEmpty else { continue }
            // When skipping forwarders, keep walking: the newest backups may all hold
            // the loopback port, and the real site is further back.
            if excludingLoopback, let parsed = normalize(address), isLoopback(parsed) { continue }
            return address
        }
        return nil
    }

    /// Strips the OpenAI-compatible `/v1` suffix: dashboard calls are rooted at
    /// the origin, and `appendingPathComponent` would otherwise nest under it.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        guard let url = URL(string: text), url.scheme != nil, url.host != nil else { return nil }
        return url
    }
}
