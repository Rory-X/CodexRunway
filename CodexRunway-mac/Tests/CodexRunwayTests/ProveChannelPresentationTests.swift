import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("PROVE channel presentation and activation")
@MainActor
struct ProveChannelPresentationTests {
    @Test("API activation uses the live auth loader without an OAuth expiry warning", arguments: [false, true])
    func apiActivationWithLiveAuthLoader(fromOAuth: Bool) async throws {
        let fixture = try Fixture(useLiveAuthLoader: true)
        defer { fixture.remove() }
        let target: ManagedAccount
        if fromOAuth {
            _ = try fixture.twoOAuthAccounts()
            let account = try fixture.store.upsert(auth: .apiKey(apiKey: "sk-account-B"))
            target = try fixture.store.updateAccount(id: account.id) {
                $0.relayBaseURL = "https://b.example/v1"
            }
        } else {
            target = try fixture.twoAccounts().1
        }
        fixture.model.switchAccount(id: target.id, restartCodex: false)
        try await waitUntil {
            !fixture.model.isSwitchingAccount && !fixture.model.isRefreshing
                && !fixture.model.isRefreshingAll && !fixture.model.isRefreshingAccountQuotas
                && !fixture.model.isRefreshingAccountQuota(id: target.id)
        }
        #expect(fixture.model.activeAccountId == target.id)
        #expect(fixture.model.lastError == nil)
        fixture.model.tick()
        #expect(fixture.model.statusText == fixture.model.l10n.text(.planAPI))
        #expect(fixture.model.managedAccounts.first(where: { $0.id == target.id })?.requiresReauth == false)
        let services = RunwayModelServices.live(authStore: CodexAuthStore(authURL: fixture.store.officialAuthURL))
        let auth = try fixture.store.loadOfficialAuth()
        #expect(try await services.loadValidAuth(true, auth) == auth)
        #expect(try await services.loadValidAuth(false, nil) == auth)
        await #expect(throws: (any Error).self) {
            try await services.loadValidAuth(true, .apiKey(apiKey: "short"))
        }
    }

    @Test("first API import installs auth, routing and active index before restart")
    func firstImportActivates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recorder = RestartEvidence(store: fixture.store)
        fixture.model.codexAppRestarter = {
            await recorder.record()
            return .init(terminatedCount: 1, relaunched: true, appPath: "/fixture/Codex.app")
        }
        fixture.model.importAPIKey("sk-fixture", relayBaseURL: "https://a.example/v1")
        try await waitUntil { await recorder.count == 1 }
        #expect(await recorder.sawCompleteCommit)
        #expect(fixture.model.activeAccountId == (try fixture.store.loadIndex()).activeAccountId)
    }

    @Test("optional PAT storage failure cannot leave the first key inactive")
    func firstImportWithUnavailablePATStore() async throws {
        let fixture = try Fixture(tokenSaveFails: true)
        defer { fixture.remove() }
        let recorder = RestartEvidence(store: fixture.store)
        fixture.model.codexAppRestarter = {
            await recorder.record()
            return .init(terminatedCount: 1, relaunched: true, appPath: "/fixture/Codex.app")
        }
        fixture.model.importAPIKey("sk-fixture", relayBaseURL: "https://a.example/v1",
                                   dashboardToken: "fictional-PAT")
        try await waitUntil { await recorder.count == 1 }
        #expect(await recorder.sawCompleteCommit)
    }

    @Test("missing URL rejects the import before any account or restart")
    func missingURLRejects() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recorder = RestartEvidence(store: fixture.store)
        fixture.model.codexAppRestarter = {
            await recorder.record()
            return .init(terminatedCount: 1, relaunched: true, appPath: "/fixture/Codex.app")
        }
        fixture.model.importAPIKey("sk-fixture")
        try await waitUntil { fixture.model.lastError != nil }
        #expect((try fixture.store.loadIndex()).accounts.isEmpty)
        #expect(await recorder.count == 0)
        #expect(fixture.model.lastError == fixture.model.l10n.text(.accountErrorRelayBaseURLMissing))
    }

    @Test("failed core commit neither publishes B nor restarts")
    func failedSwitchStaysOnA() async throws {
        let fixture = try Fixture(failSwitchAt: "auth")
        defer { fixture.remove() }
        let (a, b) = try fixture.twoAccounts()
        let recorder = RestartEvidence(store: fixture.store)
        fixture.model.codexAppRestarter = {
            await recorder.record()
            return .init(terminatedCount: 1, relaunched: true, appPath: "/fixture/Codex.app")
        }
        fixture.model.switchAccount(id: b.id)
        try await waitUntil { fixture.model.lastError != nil }
        #expect(fixture.commitAttempts.count == 1)
        #expect(await recorder.count == 0)
        #expect(fixture.model.activeAccountId == a.id)
        #expect((try fixture.store.loadIndex()).activeAccountId == a.id)
        #expect((try fixture.store.loadOfficialAuth()).openAIAPIKey == "sk-account-A")
        #expect(fixture.model.accountOperationMessage == nil)
    }

    @Test("an actual preflight index change does not retry or restart")
    func preflightIndexConflict() async throws {
        let gate = PreflightGate()
        let fixture = try Fixture(preflightGate: gate)
        defer { fixture.remove() }
        let (a, b) = try fixture.twoOAuthAccounts()
        let recorder = RestartEvidence(store: fixture.store)
        fixture.model.codexAppRestarter = {
            await recorder.record()
            return .init(terminatedCount: 1, relaunched: true, appPath: "/fixture/Codex.app")
        }
        fixture.model.switchAccount(id: b.id)
        try await waitUntil { await gate.entered }
        try fixture.store.updateAccount(id: a.id) { $0.alias = "concurrent-metadata" }
        await gate.release()
        try await waitUntil { fixture.model.lastError != nil }
        #expect(await gate.calls == 1)
        #expect(await recorder.count == 0)
        #expect((try fixture.store.loadIndex()).activeAccountId == a.id)
        #expect((try fixture.store.loadOfficialAuth()).tokens.accountId == "A")
        #expect(fixture.model.accountOperationMessage == nil)
    }

    @Test("recovery-incomplete is never retried or reported as a successful restart")
    func incompleteRecoveryDoesNotRetry() async throws {
        let fixture = try Fixture(failSwitchAt: "profile", failProfileRestore: true)
        defer { fixture.remove() }
        let (a, b) = try fixture.twoAccounts()
        #expect(try fixture.store.loadOfficialAuth() == fixture.store.loadCredential(id: a.id))
        #expect(CodexConfigReader.providerBaseURLs(configURL: fixture.store.officialConfigURL)["custom"]
            == a.relayBaseURL)
        let recorder = RestartEvidence(store: fixture.store)
        fixture.model.codexAppRestarter = {
            await recorder.record()
            return .init(terminatedCount: 1, relaunched: true, appPath: "/fixture/Codex.app")
        }
        fixture.model.switchAccount(id: b.id)
        try await waitUntil { fixture.model.lastError != nil }
        #expect(fixture.commitAttempts.count == 1)
        #expect(fixture.restoreAttempts.count == 1)
        #expect(await recorder.count == 0)
        #expect((try fixture.store.loadIndex()).activeAccountId == a.id)
        #expect(fixture.model.accountOperationMessage == nil)
    }

    @Test("unsupported API renders a neutral label and no card warning")
    func neutralPresentation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (a, _) = try fixture.twoAccounts()
        fixture.model.reloadAccountIndex()
        fixture.model.tick()
        #expect(fixture.model.statusText == fixture.model.l10n.text(.planAPI))
        #expect(fixture.model.statusBarRelayLines.isEmpty)
        #expect(fixture.model.statusBarToolTip.contains("API"))
        #expect(AccountCardStatus.warning(for: a, l10n: fixture.model.l10n) == nil)
    }

    @Test("unknown API failures clear stale windows and warnings across every surface", arguments: [
        UnknownQuotaFailure.http(401), .http(403), .http(429), .http(500),
        .http(404), .malformed, .network(.cannotConnectToHost), .network(.timedOut),
    ])
    private func unknownAPIFailureIsNeutral(failure: UnknownQuotaFailure) async throws {
        let fixture = try Fixture(unknownQuotaFailure: failure)
        defer { fixture.remove() }
        let (account, _) = try fixture.twoAccounts()
        var stale = try #require(fixture.store.loadIndex().account(id: account.id))
        stale.cachedQuota = CachedAccountQuota(plan: "pro", primaryUsedPercent: 99)
        stale.lastError = "relay_refresh_failed"
        stale.requiresReauth = true
        try fixture.store.updateMetadata(stale)
        fixture.model.reloadAccountIndex()
        fixture.model.refreshAccountQuota(id: account.id)
        try await waitUntil { !fixture.model.isRefreshingAccountQuota(id: account.id) }
        fixture.model.tick()
        let disk = try #require(fixture.store.loadIndex().account(id: account.id))
        let shown = try #require(fixture.model.managedAccounts.first(where: { $0.id == account.id }))
        #expect(disk.cachedQuota == nil)
        #expect(disk.lastError == nil)
        #expect(!disk.requiresReauth)
        #expect(AccountCardStatus.warning(for: shown, l10n: fixture.model.l10n) == nil)
        #expect(fixture.model.statusText == fixture.model.l10n.text(.planAPI))
        #expect(fixture.model.statusBarRelayLines.isEmpty)
        #expect(fixture.model.statusBarToolTip.contains("API"))
        #expect(!fixture.model.statusBarToolTip.contains("%"))
    }

    @Test("a late A refresh leaves B selected in UI and on disk")
    func lateRefreshAfterSwitch() async throws {
        let gate = QuotaGate()
        let fixture = try Fixture(quotaGate: gate)
        defer { fixture.remove() }
        let (a, b) = try fixture.twoAccounts()
        fixture.model.refreshAccountQuota(id: a.id)
        try await waitUntil { await gate.entered }
        fixture.model.switchAccount(id: b.id, restartCodex: false)
        try await waitUntil { fixture.model.activeAccountId == b.id }
        await gate.release()
        try await waitUntil { !fixture.model.isRefreshingAccountQuota(id: a.id) }
        #expect(fixture.model.activeAccountId == b.id)
        #expect((try fixture.store.loadIndex()).activeAccountId == b.id)
        #expect((try fixture.store.loadOfficialAuth()).openAIAPIKey == "sk-account-B")
        #expect(fixture.model.managedAccounts.first(where: { $0.id == a.id })?.lastError == nil)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let store: AccountStore
        let model: RunwayModel
        let commitAttempts = AttemptCounter()
        let restoreAttempts = AttemptCounter()
        init(failSwitchAt checkpoint: String? = nil, failProfileRestore: Bool = false,
             quotaGate: QuotaGate? = nil, preflightGate: PreflightGate? = nil,
             tokenSaveFails: Bool = false, useLiveAuthLoader: Bool = false,
             unknownQuotaFailure: UnknownQuotaFailure? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("prove-channel-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = AccountStore(rootURL: root.appendingPathComponent("accounts"),
                                 officialAuthURL: root.appendingPathComponent("auth.json"))
            let tokens = NewAPITokenStore(read: { _, _ in throw NewAPITokenStoreError.unavailable },
                                          write: { _, _ in
                                              if tokenSaveFails { throw NewAPITokenStoreError.writeFailed }
                                          }, remove: { _ in })
            var services = RunwayModelServices(
                loadValidAuth: { _, cached in
                    guard let cached else { throw URLError(.userAuthenticationRequired) }
                    return cached
                }, fetchQuota: { _ in
                    if let preflightGate { await preflightGate.enter() }
                    return QuotaSnapshot(
                        plan: "plus",
                        primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
                        secondary: nil, additionalWindows: [], creditsBalance: nil,
                        updatedAt: Date())
                },
                fetchResetCredits: { _ in throw URLError(.unsupportedURL) },
                fetchRateLimitResetToday: { throw URLError(.unsupportedURL) },
                scanAPIEquivalent: { _, _, _, _ in [:] },
                fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.unsupportedURL) },
                fetchCodexProfileTokenUsage: { _ in throw URLError(.unsupportedURL) },
                dryRunSessions: { .init(missingIndexIDs: [], orphanIndexIDs: [],
                                         duplicateIndexIDs: [], staleTitleIDs: [],
                                         backupPath: nil, plannedEntries: 0) },
                scanRecentSessions: { _ in .init(items: []) })
            if useLiveAuthLoader {
                services.loadValidAuth = RunwayModelServices.live(
                    authStore: CodexAuthStore(authURL: store.officialAuthURL)).loadValidAuth
            }
            var switcher = AccountSwitcher(store: store, fetchQuota: services.fetchQuota)
            if let checkpoint {
                let commitAttempts = commitAttempts
                switcher.failCommitAt = { step in
                    if step == checkpoint {
                        commitAttempts.increment()
                        throw AccountSwitchTransaction.Failure.injected(step)
                    }
                }
            }
            if failProfileRestore {
                let profileURL = store.rootURL.deletingLastPathComponent()
                    .appendingPathComponent("relay-configs")
                let restoreAttempts = restoreAttempts
                switcher.failRestoreAt = { url in
                    if url.deletingLastPathComponent().path == profileURL.path {
                        restoreAttempts.increment()
                        throw AccountSwitchTransaction.Failure.injected("restore-profile")
                    }
                }
            }
            let safeQuota = AccountQuotaRefresher(
                store: store, switcher: AccountSwitcher(store: store), newAPITokens: tokens,
                newAPIClient: { url in NewAPIClient(baseURL: url, transport: { request in
                    guard ["a.example", "b.example"].contains(request.url?.host ?? ""),
                          ["/api/status", "/v1/dashboard/billing/usage",
                           "/v1/dashboard/billing/subscription"].contains(request.url?.path ?? "")
                    else { throw URLError(.badURL) }
                    if request.url?.host == "a.example",
                       request.url?.path == "/v1/dashboard/billing/usage",
                       let quotaGate { await quotaGate.enter() }
                    if request.url?.path == "/v1/dashboard/billing/usage",
                       let unknownQuotaFailure {
                        switch unknownQuotaFailure {
                        case .network(let code): throw URLError(code)
                        case .http, .malformed: break
                        }
                    }
                    let status: Int
                    if request.url?.path == "/v1/dashboard/billing/usage",
                       case .http(let code) = unknownQuotaFailure {
                        status = code
                    } else { status = 404 }
                    let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                                   httpVersion: nil, headerFields: nil)!
                    return (Data("{}".utf8), response)
                }) })
            let settings = RunwaySettings(store: PreferencesStore(
                defaults: UserDefaults(suiteName: "prove-channel-\(UUID())")!))
            model = RunwayModel(settings: settings, services: services, accountStore: store,
                                costCacheStore: UsageCostCacheStore(cacheURL: root.appendingPathComponent("cost.json")),
                                quotaEstimateHistoryStore: QuotaEstimateHistoryStore(
                                    fileURL: root.appendingPathComponent("history.json")),
                                newAPITokens: tokens, accountSwitcher: switcher,
                                accountQuotaRefresher: safeQuota)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func twoAccounts() throws -> (ManagedAccount, ManagedAccount) {
            var a = try store.upsert(auth: .apiKey(apiKey: "sk-account-A"))
            a.relayBaseURL = "https://a.example/v1"
            try store.updateMetadata(a)
            var b = try store.upsert(auth: .apiKey(apiKey: "sk-account-B"))
            b.relayBaseURL = "https://b.example/v1"
            try store.updateMetadata(b)
            // Prepare a complete initial A state without invoking the model's
            // restarter; every path remains under this fixture root.
            try store.saveOfficialAuth(.apiKey(apiKey: "sk-account-A"))
            try store.setActiveAccountId(a.id)
            try "model_provider = \"custom\"\n[model_providers.custom]\nbase_url = \"https://a.example/v1\"\n"
                .write(to: store.officialConfigURL, atomically: true, encoding: .utf8)
            model.reloadAccountIndex()
            return (a, b)
        }
        func twoOAuthAccounts() throws -> (ManagedAccount, ManagedAccount) {
            let aAuth = try Self.oauthAuth("A")
            let bAuth = try Self.oauthAuth("B")
            let a = try store.upsert(auth: aAuth)
            let b = try store.upsert(auth: bAuth)
            try store.saveOfficialAuth(aAuth)
            try store.setActiveAccountId(a.id)
            model.reloadAccountIndex()
            return (a, b)
        }
        private static func oauthAuth(_ id: String) throws -> CodexAuth {
            let claims: [String: Any] = [
                "exp": 4_100_000_000,
                "email": "\(id)@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": id],
            ]
            let payload = try JSONSerialization.data(withJSONObject: claims)
            let token = [Data(#"{"alg":"none"}"#.utf8), payload, Data()]
                .map { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "") }
                .joined(separator: ".")
            return CodexAuth(authMode: "chatgpt", tokens: .init(
                idToken: token, accessToken: token,
                refreshToken: "fictional-refresh-token-for-\(id)-long-enough", accountId: id),
                lastRefresh: nil)
        }
    }

    private enum UnknownQuotaFailure: Sendable {
        case http(Int)
        case malformed
        case network(URLError.Code)
    }

    private actor RestartEvidence {
        let store: AccountStore
        private(set) var count = 0
        private(set) var sawCompleteCommit = false
        init(store: AccountStore) { self.store = store }
        func record() {
            count += 1
            guard let index = try? store.loadIndex(), let id = index.activeAccountId,
                  let account = index.account(id: id),
                  let official = try? store.loadOfficialAuth(),
                  let selected = CodexConfigReader.selectedProvider(configURL: store.officialConfigURL),
                  selected == "custom",
                  let configuredURL = CodexConfigReader.providerBaseURLs(configURL: store.officialConfigURL)["custom"]
            else { return }
            sawCompleteCommit = official.openAIAPIKey == (try? store.loadCredential(id: id))?.openAIAPIKey
                && account.relayBaseURL == configuredURL
        }
    }

    private actor QuotaGate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func enter() async {
            guard !entered else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }
    }

    private actor PreflightGate {
        private(set) var entered = false
        private(set) var calls = 0
        private var continuation: CheckedContinuation<Void, Never>?
        func enter() async {
            calls += 1
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for condition")
    }
}
