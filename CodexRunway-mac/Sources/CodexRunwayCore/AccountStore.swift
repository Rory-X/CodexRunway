import Foundation

public enum AccountStoreError: Error, Sendable, Equatable {
    case accountNotFound(String)
    case credentialMissing(String)
    case invalidCredential
    case missingRefreshToken
    case expiredAccessWithoutRefresh
    case notUsableAsCodexLogin
    case reauthorizationIdentityMismatch
    case io(String)
}

/// Multi-account index + per-account credential files under `~/.codex-runway/accounts`.
public struct AccountStore: Sendable {
    public var rootURL: URL
    public var officialAuthURL: URL
    var failIndexWriteAfterCommit: (@Sendable () throws -> Void)?

    public init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway/accounts"),
        officialAuthURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"))
    {
        self.rootURL = rootURL
        self.officialAuthURL = officialAuthURL
    }

    public var indexURL: URL {
        rootURL.appendingPathComponent("index.json")
    }

    /// Codex's own config, sitting next to the official `auth.json`.
    ///
    /// Derived from `officialAuthURL` rather than hard-coded to `~/.codex`, so a
    /// caller that redirects the codex home (tests, fixtures) also redirects the
    /// config file. Hard-coding it is how a test suite ended up rewriting the
    /// developer's real `~/.codex/config.toml`.
    public var officialConfigURL: URL {
        officialAuthURL.deletingLastPathComponent().appendingPathComponent("config.toml")
    }

    public func accountDirectory(id: String) -> URL {
        rootURL.appendingPathComponent(sanitizePathComponent(id), isDirectory: true)
    }

    public func credentialURL(id: String) -> URL {
        accountDirectory(id: id).appendingPathComponent("auth.json")
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setPOSIXPermissions(rootURL, mode: 0o700)
    }

    public func loadIndex() throws -> AccountIndex {
        try AccountSwitchTransaction.synchronized {
        try ensureRoot()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return AccountIndex()
        }
        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .accountStoreDates
        var index = try decoder.decode(AccountIndex.self, from: data)
        // Legacy rows may not persist identity display metadata. Hydrate it from the row's existing
        // credential without renaming ids/directories or changing active/sort metadata.
        for position in index.accounts.indices where index.accounts[position].authMode == .oauth {
            let needsIdentityMetadata = index.accounts[position].subjectId == nil
                || index.accounts[position].accountId == nil
                || index.accounts[position].email == nil
            guard needsIdentityMetadata else { continue }
            let auth: CodexAuth
            do {
                auth = try loadCredential(id: index.accounts[position].id)
            } catch let error as AccountStoreError {
                switch error {
                case .credentialMissing:
                    index.accounts[position].requiresReauth = true
                    index.accounts[position].lastError = "credential_missing"
                    continue
                case .invalidCredential:
                    index.accounts[position].requiresReauth = true
                    index.accounts[position].lastError = "invalid_credential"
                    continue
                default:
                    throw error
                }
            }
            let explicitUserId = AccountIdentity.oauthUserId(for: auth)
            let subjectId = AccountIdentity.oauthSubjectId(for: auth)
            if index.accounts[position].subjectId == nil {
                index.accounts[position].subjectId = subjectId
                if let subjectId,
                   firstNonEmpty(index.accounts[position].userId) == subjectId
                {
                    index.accounts[position].userId = explicitUserId
                }
            }
            if index.accounts[position].userId == nil {
                index.accounts[position].userId = explicitUserId
            }
            if let workspaceId = AccountIdentity.oauthAccountId(for: auth) {
                index.accounts[position].accountId = workspaceId
            }
            if index.accounts[position].email == nil {
                index.accounts[position].email = AccountIdentity.oauthEmail(for: auth)
            }
            if index.accounts[position].workspaceName == nil {
                index.accounts[position].workspaceName = AccountIdentity.oauthWorkspaceName(for: auth)
            }
        }
        return index
        }
    }

    public func saveIndex(_ index: AccountIndex) throws {
        try AccountSwitchTransaction.synchronized {
            try ensureRoot()
            try atomicWriteJSON(index, to: indexURL, mode: 0o600)
            try failIndexWriteAfterCommit?()
        }
    }

    public func loadCredential(id: String) throws -> CodexAuth {
        let data = try loadCredentialData(id: id)
        do {
            return try JSONDecoder().decode(CodexAuth.self, from: data)
        } catch {
            throw AccountStoreError.invalidCredential
        }
    }

    public func loadCredentialData(id: String) throws -> Data {
        let url = credentialURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AccountStoreError.credentialMissing(id)
        }
        return try Data(contentsOf: url)
    }

    public func saveCredential(id: String, auth: CodexAuth) throws {
        try ensureRoot()
        let directory = accountDirectory(id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setPOSIXPermissions(directory, mode: 0o700)
        // Managed library may keep session/partial credentials; official writes stay strict.
        let store = CodexAuthStore(authURL: credentialURL(id: id))
        try store.save(auth, allowUnusable: true)
        try setPOSIXPermissions(credentialURL(id: id), mode: 0o600)
    }

    /// Copy the managed credential file into official `~/.codex/auth.json` without re-encoding.
    public func installCredentialAsOfficial(id: String) throws -> CodexAuth {
        let data = try loadCredentialData(id: id)
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        switch auth.loginUsability {
        case .usable:
            break
        case .expiredAccessWithoutRefresh:
            throw AccountStoreError.expiredAccessWithoutRefresh
        case .invalidTokens:
            throw AccountStoreError.notUsableAsCodexLogin
        }
        try saveOfficialAuthRaw(data)
        return auth
    }

    public func saveOfficialAuthRaw(_ data: Data) throws {
        let store = CodexAuthStore(authURL: officialAuthURL)
        // Re-save through AuthStore so runway-only keys are stripped and empties cleaned.
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        try store.save(auth)
    }

    public func deleteAccount(id: String) throws {
        try AccountSwitchTransaction.synchronized {
        var index = try loadIndex()
        index.remove(id: id)
        try saveIndex(index)
        let directory = accountDirectory(id: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        }
    }

    /// Upsert by stable identity (account id / email / token fingerprint). Returns final account id.
    @discardableResult
    public func upsert(
        auth: CodexAuth,
        makeActive: Bool = false,
        alias: String? = nil,
        note: String? = nil,
        now: Date = Date()) throws -> ManagedAccount
    {
        try AccountSwitchTransaction.synchronized {
        var index = try loadIndex()
        let existing = index.accounts.first { AccountIdentity.matches(account: $0, auth: auth) }
        let sortIndex = existing?.sortIndex ?? (index.accounts.map(\.sortIndex).max() ?? -1) + 1
        // Always rebuild identity (email / displayName / plan) from the new credential.
        var account = ManagedAccount.make(
            id: existing?.id,
            auth: auth,
            sortIndex: sortIndex,
            alias: alias ?? existing?.alias,
            note: note ?? existing?.note,
            quotaPlan: nil,
            now: existing?.createdAt ?? now)
        if let existing {
            account.createdAt = existing.createdAt
            account.lastUsedAt = existing.lastUsedAt
            account.sortIndex = existing.sortIndex
            account.userId = firstNonEmpty(account.userId, existing.userId)
            account.subjectId = firstNonEmpty(account.subjectId, existing.subjectId)
            account.workspaceName = firstNonEmpty(account.workspaceName, existing.workspaceName)
            // Drop stale meters / errors so the row refreshes immediately after re-import.
            account.cachedQuota = nil
            account.lastQuotaAt = nil
            account.requiresReauth = false
            account.lastError = nil
        }
        try saveCredential(id: account.id, auth: auth)
        index.upsert(account)
        if makeActive {
            index.activeAccountId = account.id
            account.lastUsedAt = now
            index.upsert(account)
        }
        try saveIndex(index)
        return index.account(id: account.id) ?? account
        }
    }

    /// Replaces an existing account's credential in place, after a fresh browser sign-in.
    ///
    /// This is the "authorization expired" repair path. It exists so the user does not
    /// have to delete the row and add the account again: everything that identifies the
    /// row for the person using it — the id, its position in the list, its alias and
    /// note — is kept, and only the credential and the identity fields derived from it
    /// are refreshed.
    ///
    /// The new credential must belong to the same account. `upsert` would otherwise
    /// quietly file it under a different row (or create one), which is exactly the
    /// duplication this method is meant to avoid. A sign-in for some other account is
    /// rejected instead of silently replacing the wrong row.
    @discardableResult
    public func reauthorize(id: String, auth: CodexAuth, now: Date = Date()) throws -> ManagedAccount {
        try AccountSwitchTransaction.synchronized {
            var index = try loadIndex()
            guard var account = index.account(id: id) else {
                throw AccountStoreError.accountNotFound(id)
            }
            switch auth.loginUsability {
            case .usable:
                break
            case .expiredAccessWithoutRefresh:
                throw AccountStoreError.expiredAccessWithoutRefresh
            case .invalidTokens:
                throw AccountStoreError.notUsableAsCodexLogin
            }
            guard AccountIdentity.matches(account: account, auth: auth) else {
                throw AccountStoreError.reauthorizationIdentityMismatch
            }

            // Kept: identity of the row, and everything the user set on it.
            let preservedId = account.id
            let preservedCreatedAt = account.createdAt
            let preservedLastUsedAt = account.lastUsedAt
            let preservedSortIndex = account.sortIndex
            let preservedAlias = account.alias
            let preservedNote = account.note
            let preservedUserId = account.userId
            let preservedSubjectId = account.subjectId
            let preservedWorkspaceName = account.workspaceName

            account = account.withIdentity(from: auth, quotaPlan: nil, now: now)
            account.id = preservedId
            account.createdAt = preservedCreatedAt
            account.lastUsedAt = preservedLastUsedAt
            account.sortIndex = preservedSortIndex
            account.alias = preservedAlias
            account.note = preservedNote
            account.userId = firstNonEmpty(account.userId, preservedUserId)
            account.subjectId = firstNonEmpty(account.subjectId, preservedSubjectId)
            account.workspaceName = firstNonEmpty(account.workspaceName, preservedWorkspaceName)

            // The credential is known good again, so the warning and any stale meters
            // that were about the expired credential go away together.
            account.requiresReauth = false
            account.lastError = nil
            account.cachedQuota = nil
            account.lastQuotaAt = nil

            try saveCredential(id: account.id, auth: auth)
            index.upsert(account)
            try saveIndex(index)
            return index.account(id: account.id) ?? account
        }
    }

    public func updateMetadata(_ account: ManagedAccount) throws {
        try AccountSwitchTransaction.synchronized {
            var index = try loadIndex()
            guard index.account(id: account.id) != nil else {
                throw AccountStoreError.accountNotFound(account.id)
            }
            index.upsert(account)
            try saveIndex(index)
        }
    }

    /// Update one row against the latest index while sharing the switch commit lock.
    /// Callers can merge quota/status fields without carrying a stale active ID.
    @discardableResult
    public func updateAccount(id: String, _ update: (inout ManagedAccount) throws -> Void) throws -> ManagedAccount {
        try AccountSwitchTransaction.synchronized {
            var index = try loadIndex()
            guard var account = index.account(id: id) else {
                throw AccountStoreError.accountNotFound(id)
            }
            try update(&account)
            index.upsert(account)
            try saveIndex(index)
            return account
        }
    }

    public func setActiveAccountId(_ id: String?, lastUsedAt: Date = Date()) throws {
        try AccountSwitchTransaction.synchronized {
        var index = try loadIndex()
        if let id {
            guard var account = index.account(id: id) else {
                throw AccountStoreError.accountNotFound(id)
            }
            account.lastUsedAt = lastUsedAt
            index.upsert(account)
            index.activeAccountId = id
        } else {
            index.activeAccountId = nil
        }
        try saveIndex(index)
        }
    }

    public func reorder(ids: [String]) throws {
        try AccountSwitchTransaction.synchronized {
        var index = try loadIndex()
        index.reindexSortOrder(ids)
        try saveIndex(index)
        }
    }

    public func loadOfficialAuth() throws -> CodexAuth {
        let data = try Data(contentsOf: officialAuthURL)
        return try JSONDecoder().decode(CodexAuth.self, from: data)
    }

    public func saveOfficialAuth(_ auth: CodexAuth) throws {
        let store = CodexAuthStore(authURL: officialAuthURL)
        try store.save(auth)
    }

    /// Import official `auth.json` into the store (upsert) and mark active when requested.
    @discardableResult
    public func importOfficialAuth(makeActive: Bool = true, now: Date = Date()) throws -> ManagedAccount {
        let auth = try loadOfficialAuth()
        return try upsert(auth: auth, makeActive: makeActive, now: now)
    }

    /// If the official auth file identity diverges from `activeAccountId`, import/update and mark it active.
    @discardableResult
    public func syncFromOfficialAuth(now: Date = Date()) throws -> AccountIndex {
        try AccountSwitchTransaction.synchronized {
        var index = try loadIndex()
        let official: CodexAuth
        do {
            official = try loadOfficialAuth()
        } catch {
            // Official auth missing/corrupt — try restore from a usable managed account.
            _ = try? repairOfficialAuthFromManagedAccounts(now: now)
            return try loadIndex()
        }

        // Official auth present but unusable (truncated tokens / empty refresh) — restore before Codex thrashing.
        if official.loginUsability != .usable {
            if let repaired = try? repairOfficialAuthFromManagedAccounts(now: now) {
                return repaired
            }
            // Still mark active managed entry as needing reauth when its credential is also bad.
            if let activeId = index.activeAccountId, var active = index.account(id: activeId) {
                active.requiresReauth = true
                active.lastError = "invalid credential"
                index.upsert(active)
                try? saveIndex(index)
            }
            return index
        }

        if index.accounts.isEmpty {
            _ = try upsert(auth: official, makeActive: true, now: now)
            return try loadIndex()
        }

        if let existing = index.accounts.first(where: { AccountIdentity.matches(account: $0, auth: official) }) {
            // Official is usable (gated above). Still avoid clobbering a managed credential that
            // already has a refresh_token when official is access-token-only (session), etc.
            let existingCred = try? loadCredential(id: existing.id)
            let shouldReplaceManaged = shouldReplaceManagedCredential(existing: existingCred, with: official)
            if shouldReplaceManaged {
                try saveCredential(id: existing.id, auth: official)
            }
            var updated = existing.withIdentity(
                from: shouldReplaceManaged ? official : (existingCred ?? official),
                quotaPlan: existing.planType,
                now: now)
            updated.lastUsedAt = now
            updated.requiresReauth = false
            updated.lastError = nil
            index.upsert(updated)
            index.activeAccountId = existing.id
            try saveIndex(index)
            return index
        }

        _ = try upsert(auth: official, makeActive: true, now: now)
        return try loadIndex()
        }
    }

    /// When `~/.codex/auth.json` is missing or broken, reinstall the best managed OAuth credential.
    @discardableResult
    public func repairOfficialAuthFromManagedAccounts(now: Date = Date()) throws -> AccountIndex {
        try AccountSwitchTransaction.synchronized {
        var index = try loadIndex()
        let orderedIds: [String] = {
            var ids: [String] = []
            if let active = index.activeAccountId { ids.append(active) }
            ids.append(contentsOf: index.accounts.map(\.id).filter { !ids.contains($0) })
            return ids
        }()

        for id in orderedIds {
            guard let auth = try? loadCredential(id: id) else { continue }
            guard auth.loginUsability == .usable else {
                if var account = index.account(id: id) {
                    account.requiresReauth = true
                    index.upsert(account)
                }
                continue
            }
            try saveOfficialAuth(auth)
            index.activeAccountId = id
            var account = index.account(id: id) ?? ManagedAccount.make(id: id, auth: auth, now: now)
            account = account.withIdentity(from: auth, quotaPlan: account.planType, now: now)
            account.requiresReauth = false
            account.lastError = nil
            account.lastUsedAt = now
            index.upsert(account)
            try saveIndex(index)
            return index
        }
        try saveIndex(index)
        return index
        }
    }

    /// Prefer keeping a managed credential that can refresh over a weaker official snapshot.
    private func shouldReplaceManagedCredential(existing: CodexAuth?, with incoming: CodexAuth) -> Bool {
        guard let existing else { return true }
        if existing == incoming { return false }
        // Never replace a full OAuth credential (has refresh) with access-token-only session.
        if existing.canRefreshOAuth, !incoming.canRefreshOAuth {
            return false
        }
        // Never replace usable with unusable.
        if existing.loginUsability == .usable, incoming.loginUsability != .usable {
            return false
        }
        return true
    }

    private func atomicWriteJSON<T: Encodable>(_ value: T, to url: URL, mode: UInt16) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .accountStoreDates
        let data = try encoder.encode(value)
        try AccountSwitchTransaction.atomicWrite(data, to: url, mode: mode_t(mode))
    }

    private func setPOSIXPermissions(_ url: URL, mode: UInt16) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path)
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? "account" : cleaned
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    /// Fractional-second ISO-8601 for stable round-trips of account index dates.
    static var accountStoreDates: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AccountStoreDateFormat.string(from: date))
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var accountStoreDates: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = AccountStoreDateFormat.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date: \(raw)")
        }
    }
}

private enum AccountStoreDateFormat {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
