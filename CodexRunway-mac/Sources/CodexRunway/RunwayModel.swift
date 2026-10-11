import AppKit
import CodexRunwayCore
import Foundation
import SwiftUI

enum CostRangeQueryError: Error {
    case usageUnavailable
}

enum RunwayRefreshSection: CaseIterable, Hashable {
    case quota
    case resetCredits
    case rateLimitResetToday
    case quotaEstimate
    case localAllowance
    case apiCost
    case tokenHeatmap
    case sessionRepair
    case recentSessions
}

private enum RunwayModelAuthError: Error {
    case load(Error)
}

struct RunwayModelServices: Sendable {
    var loadValidAuth: @Sendable (_ preferCached: Bool, _ cachedAuth: CodexAuth?) async throws -> CodexAuth
    var fetchQuota: @Sendable (CodexAuth) async throws -> QuotaSnapshot
    var fetchResetCredits: @Sendable (CodexAuth) async throws -> ResetCreditsSnapshot
    var fetchRateLimitResetToday: @Sendable () async throws -> RateLimitResetTodaySnapshot
    var fetchRateLimitResetTodayReaction: @Sendable () async throws -> RateLimitResetTodayReactionSnapshot = {
        throw URLError(.unsupportedURL)
    }
    var clickRateLimitResetTodayReaction: @Sendable () async throws -> RateLimitResetTodayReactionPostResult = {
        throw URLError(.unsupportedURL)
    }
    var scanAPIEquivalent: @Sendable (
        [ApiCostQuery],
        Date,
        UsageCostRefreshPolicy,
        CostScanProgressReporter?
    ) async throws -> [String: ApiEquivalentSummary]
    var fetchDailyWorkspaceUsage: @Sendable (CodexAuth, String, String, DateInterval, Date) async throws -> ApiEquivalentSummary
    var fetchCodexProfileTokenUsage: @Sendable (CodexAuth) async throws -> CodexProfileTokenUsage
    var dryRunSessions: @Sendable () async throws -> SessionRepairReport
    var scanRecentSessions: @Sendable (Int) async throws -> SessionActivitySummary

    static func live(
        authStore: CodexAuthStore = CodexAuthStore(),
        quotaClient: QuotaClient = QuotaClient(),
        rateLimitResetTodayClient: RateLimitResetTodayClient = RateLimitResetTodayClient(),
        rateLimitResetTodayReactionClient: RateLimitResetTodayReactionClient = RateLimitResetTodayReactionClient(),
        sessionRepair: SessionRepairService = SessionRepairService(),
        sessionActivityScanner: SessionActivityScanner = SessionActivityScanner()) -> Self
    {
        let costRepository = UsageCostRepository()
        return Self(
            loadValidAuth: { preferCached, cachedAuth in
                var auth = preferCached ? cachedAuth : nil
                if auth == nil {
                    do {
                        auth = try authStore.load()
                    } catch {
                        throw RunwayModelAuthError.load(error)
                    }
                }
                guard let validAuth = auth else { throw URLError(.userAuthenticationRequired) }
                switch validAuth.loginUsability {
                case .usable:
                    break
                case .invalidTokens:
                    throw RunwayModelAuthError.load(
                        NSError(domain: "CodexRunwayAuth", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "auth_file_invalid",
                        ]))
                case .expiredAccessWithoutRefresh:
                    throw RunwayModelAuthError.load(
                        NSError(domain: "CodexRunwayAuth", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "auth_expired",
                        ]))
                }
                // API keys have no OAuth tokens; loginUsability already validates the key.
                // Access-token-only session credentials: use while JWT valid; do not hit refresh.
                if !validAuth.isAPIKeyAuth, TokenInspector.isExpired(validAuth.tokens.accessToken) {
                    guard validAuth.canRefreshOAuth else {
                        throw RunwayModelAuthError.load(
                            NSError(domain: "CodexRunwayAuth", code: 2, userInfo: [
                                NSLocalizedDescriptionKey: "auth_expired",
                            ]))
                    }
                    // The model refreshes managed credentials through AccountSwitcher,
                    // which checks the switch generation before any official write.
                }
                return validAuth
            },
            fetchQuota: { auth in
                try await quotaClient.fetchQuota(auth: auth)
            },
            fetchResetCredits: { auth in
                try await quotaClient.fetchResetCredits(auth: auth)
            },
            fetchRateLimitResetToday: {
                try await rateLimitResetTodayClient.fetchStatus()
            },
            fetchRateLimitResetTodayReaction: {
                try await rateLimitResetTodayReactionClient.fetch()
            },
            clickRateLimitResetTodayReaction: {
                try await rateLimitResetTodayReactionClient.click()
            },
            scanAPIEquivalent: { queries, calculatedAt, policy, progress in
                try await costRepository.summaries(
                    for: queries,
                    calculatedAt: calculatedAt,
                    policy: policy,
                    progress: progress)
            },
            fetchDailyWorkspaceUsage: { auth, startDate, endDate, window, calculatedAt in
                try await quotaClient.fetchDailyWorkspaceUsage(
                    auth: auth,
                    startDate: startDate,
                    endDate: endDate,
                    window: window,
                    calculatedAt: calculatedAt)
            },
            fetchCodexProfileTokenUsage: { auth in
                try await quotaClient.fetchCodexProfileTokenUsage(auth: auth)
            },
            dryRunSessions: {
                try await Task.detached {
                    try sessionRepair.dryRun()
                }.value
            },
            scanRecentSessions: { limit in
                try await Task.detached {
                    try sessionActivityScanner.scan(limit: limit)
                }.value
            })
    }
}

@MainActor
final class RunwayModel: ObservableObject {
    struct DetailLine: Identifiable {
        let id = UUID()
        let title: String
        let value: String
    }

    private struct CostCycleIdentity: Equatable {
        var reset: Date?
        var windowMinutes: Int?
    }

    private struct TokenHeatmapRemoteRequest {
        var auth: CodexAuth
        var localTokens: [String: Int]
        var calculatedAt: Date
        var accountGeneration: Int
    }

    @Published var statusText: String
    @Published var quotaText: String
    @Published var resetCreditsText: String
    @Published var rateLimitResetTodayText: String
    @Published var costText: String
    @Published var costSubtitle: String
    @Published var sessionText: String
    @Published var quotaLines: [DetailLine] = []
    @Published var resetCreditLines: [DetailLine] = []
    @Published var rateLimitResetTodayLines: [DetailLine] = []
    @Published var costLines: [DetailLine] = []
    @Published var sessionLines: [DetailLine] = []
    @Published var recentSessionLines: [DetailLine] = []
    @Published var quotaMeters: [QuotaMeter] = []
    @Published var resetCreditSummary: ResetCreditSummary?
    @Published var resetCreditDetails: [ResetCreditDetail] = []
    @Published var quotaEstimate: QuotaEstimateSnapshot?
    @Published var quotaEstimateError: String?
    /// Allowances fitted from this machine's own logs. Separate from the online
    /// estimate on purpose: the two use different numerators, and showing both
    /// keeps a disagreement visible instead of hiding it.
    @Published var localAllowances: [LocalQuotaAllowance] = []
    @Published var localAllowanceError: String?
    @Published var localAllowanceScannedAt: Date?
    @Published var rateLimitResetToday: RateLimitResetTodaySnapshot?
    @Published var rateLimitResetTodayReaction: RateLimitResetTodayReactionSnapshot?
    @Published var isRateLimitResetTodayReactionBusy = false
    @Published var isRateLimitResetTodayReactionLoading = false
    @Published private(set) var isRateLimitResetTodayReactionFresh = false
    @Published var rateLimitResetTodayReactionDelta = RateLimitResetTodayReactionDelta.none
    @Published var costDetail: ApiEquivalentSummary?
    /// Current-account official profile statistics — day → product-displayed tokens.
    @Published var tokenHeatmapAllDevicesTokens: [String: Int] = [:]
    /// All session logs on this Mac; historical entries may span accounts.
    @Published var tokenHeatmapLocalTokens: [String: Int] = [:]
    @Published var tokenHeatmapCalculatedAt: Date?
    @Published var tokenHeatmapOfficialStatsAsOf: String?
    @Published var tokenHeatmapOfficialGeneratedAt: Date?
    @Published var recentSessions: [SessionActivityItem] = []
    @Published var costScanNote: String?
    /// Scan progress lives on its own observable: it publishes ~10x/sec during a
    /// scan, and a model-level @Published write would re-layout the whole panel
    /// (including the PolishedScrollView height probe) on every tick.
    let costProgress = CostProgressModel()
    var costScanProgress: CostScanProgress { costProgress.progress }
    @Published var accountDisplay: CodexAccountDisplay
    @Published var managedAccounts: [ManagedAccount] = []
    @Published var activeAccountId: String?
    @Published private(set) var isSwitchingAccount = false
    @Published private(set) var isRefreshingAccountQuotas = false
    @Published private(set) var refreshingAccountIds: Set<String> = []
    @Published var accountOperationMessage: String?
    /// PKCE authorize URL for the in-progress browser login. The verifier stays in memory.
    @Published var pendingOAuthURL: URL?
    @Published private(set) var isOAuthLoginInProgress = false
    /// The account a browser sign-in is repairing, when one is in progress.
    ///
    /// Kept so the card that started it can show its own progress, and so the finished
    /// credential lands back on that row rather than being filed as a new account.
    @Published private(set) var reauthorizingAccountId: String?
    @Published var lastError: String?
    @Published private(set) var refreshingSections: Set<RunwayRefreshSection> = []
    @Published private(set) var isRefreshingAll = false

    private let services: RunwayModelServices
    private let sessionRepair = SessionRepairService()
    private let costCacheStore: UsageCostCacheStore
    private let quotaEstimateHistoryStore: QuotaEstimateHistoryStore
    private let alertStore = RunwayAlertStore()
    private let statusExporter = RunwayStatusExporter()
    private let notificationService = RunwayNotificationService()
    let settings: RunwaySettings
    private let costProgressReporter = CostScanProgressReporter()
    let accountStore: AccountStore
    /// Restarts the Codex desktop app after a switch. Injectable so the switch
    /// ordering can be tested without touching a real app bundle.
    var codexAppRestarter: () async -> CodexAppRestartResult = {
        await CodexAppRestarter.restart()
    }
    /// Dashboard tokens for relay accounts. Keychain-backed; never in index.json.
    let newAPITokens: NewAPITokenStore
    private let accountSwitcher: AccountSwitcher
    /// Relay settings captured per account, read by the config detail view.
    private let relayConfigStore: RelayConfigStore
    /// Opens a fresh 5-hour window by sending one minimal message through the CLI.
    private let quotaWindowProbe: QuotaWindowProbe
    private let accountImporter: AccountImporter
    private let accountQuotaRefresher: AccountQuotaRefresher
    private var oauthCallbackServer: OAuthCallbackServer?
    private var oauthLoginTask: Task<Void, Never>?
    private var latestAuth: CodexAuth?
    private var latestQuota: QuotaSnapshot?
    private var latestResetCredits: ResetCreditsSnapshot?
    private var latestQuotaEstimateDaily: ApiEquivalentSummary?
    private var lastRateLimitResetTodayFetch: Date?
    private var reactionPollTask: Task<Void, Never>?
    private var reactionPollingDesired = false
    private var reactionWriteGeneration = 0
    private var isReactionDisabled = false
    private var latestCost: ApiEquivalentSummary?
    private var latestCurrentCycleFullWindow: DateInterval?
    private var latestDisplayedCost: ApiEquivalentSummary?
    private var latestDisplayedCostRange: ApiCostSummaryRange?
    private var latestSessionReport: SessionRepairReport?
    private var lastSessionReportAt: Date?
    private var lastRecentSessionsAt: Date?
    private var lastCostRefreshCompletedAt: Date?
    private var lastCostCycleIdentity: CostCycleIdentity?
    private var detailCostCache: [String: ApiEquivalentSummary] = [:]
    private var detailCostCacheOrder: [String] = []
    private var detailCostInFlight: [String: Task<ApiEquivalentSummary, Error>] = [:]
    private var costProgressConsumers = 0
    private static let detailCostCacheLimit = 6
    private static let currentCostQueryID = "current-cycle"
    private static let selectedCostQueryID = "selected-range"
    private static let detailCostQueryID = "detail-range"
    private static let tokenHeatmapQueryID = "token-heatmap"
    private var lastTokenHeatmapRefreshCompletedAt: Date?
    private var accountStateGeneration = 0
    private var activeFullRefreshID: UUID?
    private var fullRefreshWork: Task<Void, Never>?
    private var activeTokenHeatmapRefreshID: UUID?
    private var tokenHeatmapRefreshWork: Task<Void, Never>?
    var onFullRefreshCompleted: (() -> Void)?
    /// Fired when account data lands. The status item reads the active account's
    /// figures, so it has to repaint when they change rather than waiting for the
    /// next scheduler tick.
    var onAccountDataChanged: (() -> Void)?
    var widgetRequirements: RunwayWidgetRequirements = []

    init(
        settings: RunwaySettings,
        services: RunwayModelServices = .live(),
        accountStore: AccountStore = AccountStore(),
        costCacheStore: UsageCostCacheStore = UsageCostCacheStore(),
        quotaEstimateHistoryStore: QuotaEstimateHistoryStore = QuotaEstimateHistoryStore(),
        newAPITokens: NewAPITokenStore = NewAPITokenStore(),
        accountSwitcher: AccountSwitcher? = nil,
        accountQuotaRefresher: AccountQuotaRefresher? = nil)
    {
        self.settings = settings
        self.services = services
        self.accountStore = accountStore
        self.costCacheStore = costCacheStore
        self.quotaEstimateHistoryStore = quotaEstimateHistoryStore
        self.newAPITokens = newAPITokens
        self.relayConfigStore = RelayConfigStore(
            directory: accountStore.rootURL.deletingLastPathComponent()
                .appendingPathComponent("relay-configs"))
        self.quotaWindowProbe = QuotaWindowProbe()
        self.accountSwitcher = accountSwitcher ?? AccountSwitcher(
            store: accountStore,
            relayConfigStore: self.relayConfigStore,
            fetchQuota: services.fetchQuota)
        self.accountImporter = AccountImporter(store: accountStore)
        self.accountQuotaRefresher = accountQuotaRefresher ?? AccountQuotaRefresher(
            store: accountStore,
            switcher: AccountSwitcher(store: accountStore),
            newAPITokens: newAPITokens,
            relayConfigStore: self.relayConfigStore)
        let l10n = settings.l10n
        self.statusText = l10n.text(.statusLogin)
        self.quotaText = l10n.text(.notLoaded)
        self.resetCreditsText = l10n.text(.notLoaded)
        self.rateLimitResetTodayText = l10n.text(.notLoaded)
        self.costText = l10n.text(.notScanned)
        self.costSubtitle = ""
        self.sessionText = l10n.text(.notScanned)
        self.accountDisplay = CodexAccountDisplay.make(auth: nil, quotaPlan: nil)
        if let cached = costCacheStore.load() {
            applyCurrentCost(cached)
            if settings.preferences.apiCostSummaryRange == .current {
                applyDisplayedCost(cached, range: .current)
            }
        }
        costProgressReporter.setHandler { [weak self] progress in
            Task { @MainActor in
                self?.publishCostProgress(progress)
            }
        }
        bootstrapAccounts()
    }

    /// Recent relay requests for the detail page, newest first.
    @Published var relayRequests: [NewAPILogEntry] = []
    @Published var isRefreshingRelayRequests = false
    @Published var relayRequestsError: String?

    /// Loads recent requests for the active relay account. Requires a dashboard
    /// token: the relay key alone cannot read the request log.
    func refreshRelayRequests() {
        guard !isRefreshingRelayRequests,
              let account = managedAccounts.first(where: { $0.id == activeAccountId }),
              account.authMode == .apiKey
        else { return }
        guard let token = newAPITokens.token(for: account.id) else {
            relayRequests = []
            // A stored-but-unreadable token is not a missing one; saying "add a
            // token" when one is present is what made a readable credential look
            // deleted.
            relayRequestsError = newAPITokens.readOutcome(for: account.id) == .unreadable
                ? l10n.text(.newAPIDashboardTokenUnreadable)
                : l10n.text(.newAPIDashboardTokenHint)
            return
        }
        guard let baseURL = NewAPIRelayResolver.accountOwnedBaseURL(
            for: account,
            profileBaseURL: relayConfigStore.load(for: account.id)?.baseURL)
        else {
            relayRequests = []
            relayRequestsError = l10n.text(.newAPIUsageUnavailable)
            return
        }

        isRefreshingRelayRequests = true
        relayRequestsError = nil
        let client = NewAPIClient(baseURL: baseURL)
        let requestAccountID = account.id
        let generation = accountStateGeneration
        Task { [weak self] in
            defer {
                if self?.activeAccountId == requestAccountID,
                   self?.accountStateGeneration == generation {
                    self?.isRefreshingRelayRequests = false
                }
            }
            do {
                let entries = try await client.fetchLogEntries(
                    dashboardToken: token,
                    tokenName: account.cachedQuota?.newAPI?.tokenName,
                    pageSize: 50,
                    maxPages: 1)
                guard self?.activeAccountId == requestAccountID,
                      self?.accountStateGeneration == generation else { return }
                self?.relayRequests = entries
            } catch {
                guard self?.activeAccountId == requestAccountID,
                      self?.accountStateGeneration == generation else { return }
                self?.relayRequestsError = self?.l10n.text(.newAPIUsageUnavailable)
            }
        }
    }

    /// Whether the active account is a plain API-key account.
    ///
    /// Such an account has no ChatGPT subscription, so subscription-derived
    /// modules and the leftover OAuth tier badge stay hidden even before the
    /// relay balance has been fetched.
    var isAPIKeyAccount: Bool {
        managedAccounts.first(where: { $0.id == activeAccountId })?.authMode == .apiKey
    }

    /// The active account, when it is a relay-backed API-key account with data.
    ///
    /// The main panel branches on this: a relay has no Codex quota windows, so it
    /// renders balance/usage instead of meters.
    var activeRelayAccount: (account: ManagedAccount, balance: CachedNewAPIBalance)? {
        guard let account = managedAccounts.first(where: { $0.id == activeAccountId }),
              account.authMode == .apiKey,
              let balance = account.cachedQuota?.newAPI
        else { return nil }
        return (account, balance)
    }

    /// Two stacked status-bar lines for a relay account: today's spend over the
    /// remaining balance.
    ///
    /// Deliberately not a percentage bar: the menu bar has no room to show a bar
    /// *and* the two figures that make it meaningful for a prepaid relay, and the
    /// balance is what tells the user whether they need to top up. Codex accounts
    /// keep their existing meter-based item.
    var statusBarRelayLines: [String] {
        guard let account = managedAccounts.first(where: { $0.id == activeAccountId }),
              account.authMode == .apiKey,
              let balance = account.cachedQuota?.newAPI
        else { return [] }

        let todayText: String
        if let today = balance.todayCostUSD {
            todayText = String(format: "%@ %@", l10n.text(.newAPITodayCost), Self.money(today))
        } else if let tokens = balance.todayTokens {
            todayText = String(format: "%@ %@", l10n.text(.newAPITodayTokens), Self.compactTokens(tokens))
        } else {
            todayText = l10n.text(.newAPIUsageUnavailable)
        }

        // Without a dashboard token the account balance is out of reach, but the
        // key's own cumulative spend is still known — show that rather than a dash,
        // so the item carries information in key-only mode.
        let balanceText: String
        if let remaining = balance.remainingUSD {
            balanceText = String(format: "%@ %@", l10n.text(.newAPIBalance), Self.money(remaining))
        } else if let used = balance.keyUsedUSD {
            balanceText = String(format: "%@ %@", l10n.text(.newAPISevenDayCost), Self.money(used))
        } else {
            balanceText = String(format: "%@ %@", l10n.text(.newAPIBalance), "—")
        }
        return [todayText, balanceText]
    }

    /// Tooltip for the status item. A relay account lists the same two figures
    /// the item draws; a Codex account keeps the quota-window summary.
    var statusBarToolTip: String {
        let lines = statusBarRelayLines.filter { !$0.isEmpty }
        if !lines.isEmpty {
            return (["CodexRunway"] + lines).joined(separator: "\n")
        }
        let quotaDetails = quotaMeters
            .map { "\($0.title): \($0.remainingPercent)%" }
            .joined(separator: " · ")
        return quotaDetails.isEmpty
            ? "CodexRunway · \(statusText)"
            : "CodexRunway · \(statusText)\n\(quotaDetails)"
    }

    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func compactTokens(_ tokens: Int) -> String {
        TokenUsageHeatmapBuilder.compactTokenCount(tokens, language: .english)
    }

    /// Display name for the signed-in Codex account, or a localized fallback.
    var accountDisplayName: String {
        // A relay account has no ChatGPT identity, so fall back to its own label
        // rather than "not signed in", which would be misleading.
        if let relay = managedAccounts.first(where: { $0.id == activeAccountId }),
           relay.authMode == .apiKey
        {
            if let name = relay.cachedQuota?.newAPI?.displayName, !name.isEmpty { return name }
            return relay.resolvedDisplayName
        }
        if !accountDisplay.displayName.isEmpty { return accountDisplay.displayName }
        return accountDisplay.isAuthenticated ? l10n.text(.unknownAccount) : l10n.text(.notLoggedIn)
    }

    /// Sidebar order: active first, then user sort.
    var sidebarAccounts: [ManagedAccount] {
        AccountIndex(activeAccountId: activeAccountId, accounts: managedAccounts).orderedForSidebar()
    }

    func bootstrapAccounts() {
        do {
            // Repairs broken official auth.json from a usable managed account when possible.
            let index = try accountStore.syncFromOfficialAuth()
            publishAccountIndex(index)
            if let auth = try? accountStore.loadOfficialAuth(), auth.loginUsability == .usable {
                latestAuth = auth
                accountDisplay = CodexAccountDisplay.make(auth: auth, quotaPlan: nil)
            }
        } catch {
            // Official auth may be missing on fresh machines.
            if let index = try? accountStore.loadIndex() {
                publishAccountIndex(index)
            }
        }
    }

    func reloadAccountIndex() {
        do {
            let index = try accountStore.loadIndex()
            publishAccountIndex(index)
            onAccountDataChanged?()
        } catch {
            // Surface load failures — silent failure left the UI on a stale/empty list after import.
            lastError = "\(l10n.text(.accountsImportFailed)): \(error.localizedDescription)"
        }
    }

    /// Publish index to UI, forcing a new array identity so SwiftUI always refreshes rows.
    private func publishAccountIndex(_ index: AccountIndex) {
        if activeAccountId != index.activeAccountId {
            relayRequests = []
            relayRequestsError = nil
            isRefreshingRelayRequests = false
        }
        managedAccounts = Array(index.accounts)
        activeAccountId = index.activeAccountId
        applyRelayHeatmapFromCache()
    }

    func switchAccount(id: String, restartCodex: Bool = true) {
        // Re-applying the listed current account is allowed: official auth.json can
        // drift after a manual edit while the account store still marks this row current.
        guard !isSwitchingAccount else { return }
        isSwitchingAccount = true
        accountOperationMessage = l10n.text(.accountsSwitching)
        Task {
            defer {
                isSwitchingAccount = false
            }
            do {
                let result = try await accountSwitcher.switchTo(accountId: id)
                // Signal cancellation but do not wait: draining a full refresh can
                // take as long as the session rescan it is midway through. The
                // relaunch below is what the user is waiting on.
                signalAccountScopedRefreshCancellation()
                // Drop previous account's quota/credits/cost so UI cannot keep showing the old plan.
                clearAccountScopedState(keepingAuth: result.auth)
                publishAccountIndex(try accountStore.loadIndex())
                accountDisplay = CodexAccountDisplay.make(
                    auth: result.auth,
                    quotaPlan: result.account.planType)
                lastError = nil
                // Restart first. The app has to re-read auth.json on a fresh
                // launch, and the user is waiting on this: scheduling the panel
                // refresh first would block the relaunch behind a full session
                // rescan, leaving "switching account…" on screen for its whole
                // duration.
                if restartCodex {
                    let restart = await codexAppRestarter()
                    // Only a confirmed live instance counts. Quitting the app
                    // without it coming back must surface as a failure rather
                    // than as "switched and restarted".
                    if restart.relaunched {
                        accountOperationMessage = l10n.text(.accountsRestartCodexSucceeded)
                    } else {
                        let detail = restart.message ?? "unknown"
                        accountOperationMessage = nil
                        lastError = String(format: l10n.text(.accountsRestartCodexFailed), detail)
                    }
                } else {
                    accountOperationMessage = nil
                }
                // Now wait the cancelled work out, so stale account-scoped
                // results cannot land after the new account's state is applied.
                await drainAccountScopedRefreshes()
                // Reload main panel data for the new active account (must not reuse prior meters).
                // Runs after the restart so it never delays the relaunch.
                refresh(policy: .force)
                if !isRefreshingAll {
                    refreshTokenHeatmap(policy: .force)
                }
                // The full refresh above is the Codex path. A relay account's balance
                // and usage come from its own quota refresh instead, so fetch them
                // here — otherwise the switched-to relay shows nothing until the next
                // scheduled account-quota pass.
                //
                // Scoped to relay accounts on purpose: for an OAuth account the full
                // refresh already covers quotas, and a second concurrent refresh would
                // race the one in flight and could overwrite freshly applied identity.
                if result.account.authMode == .apiKey {
                    refreshAccountQuota(id: id)
                }
                // The credential installed fine but Codex is still pointed at the
                // other account's endpoint. Report it — but never at the cost of a
                // more serious failure the user still needs to see, such as the app
                // not coming back.
                if let routingFailure = result.routingFailure, lastError == nil {
                    accountOperationMessage = nil
                    lastError = String(format: l10n.text(.accountsRoutingUpdateFailed), routingFailure)
                }
            } catch {
                accountOperationMessage = nil
                reloadAccountIndex()
                lastError = switchFailureMessage(error)
            }
        }
    }

    private func switchFailureMessage(_ error: Error) -> String {
        if isAuthenticationFailure(error) {
            return l10n.text(.accountsNeedsReauth)
        }
        if let storeError = error as? AccountStoreError {
            switch storeError {
            case .missingRefreshToken, .expiredAccessWithoutRefresh:
                return l10n.text(.accountsSwitchSessionExpired)
            case .notUsableAsCodexLogin, .invalidCredential:
                return l10n.text(.accountsSwitchInvalidCredential)
            default:
                break
            }
        }
        return "\(l10n.text(.accountsSwitchFailed)): \(error.localizedDescription)"
    }

    func isRefreshingAccountQuota(id: String) -> Bool {
        refreshingAccountIds.contains(id) || isRefreshingAccountQuotas
    }

    func refreshAllAccountQuotas() {
        guard !isRefreshingAccountQuotas else { return }
        isRefreshingAccountQuotas = true
        let ids = Set(managedAccounts.map(\.id))
        // Reassign so @Published notifies (in-place Set mutation does not).
        refreshingAccountIds = refreshingAccountIds.union(ids)
        Task {
            let generation = accountStateGeneration
            defer {
                isRefreshingAccountQuotas = false
                refreshingAccountIds = refreshingAccountIds.subtracting(ids)
            }
            let results = await accountQuotaRefresher.refreshAll()
            applyAccountQuotaRefreshResults(results, generation: generation)
        }
    }

    func refreshAccountQuota(id: String) {
        guard !refreshingAccountIds.contains(id) else { return }
        refreshingAccountIds = refreshingAccountIds.union([id])
        Task {
            let generation = accountStateGeneration
            defer { refreshingAccountIds = refreshingAccountIds.subtracting([id]) }
            let result = await accountQuotaRefresher.refresh(accountId: id)
            applyAccountQuotaRefreshResults([result], generation: generation)
        }
    }

    private func applyAccountQuotaRefreshResults(_ results: [AccountQuotaRefreshResult], generation: Int) {
        guard generation == accountStateGeneration else { return }
        reloadAccountIndex()
        guard generation == accountStateGeneration,
              let activeAccountId,
              results.contains(where: { $0.accountId == activeAccountId && $0.account?.requiresReauth == true })
        else { return }
        handleAuthenticationFailure(URLError(.userAuthenticationRequired))
    }

    func importOfficialAccount() {
        Task {
            do {
                let account = try accountImporter.importOfficial(makeActive: true)
                reloadAccountIndex()
                mergeImportedAccounts([account])
                accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), 1)
                lastError = nil
                refreshAllAccountQuotas()
            } catch {
                lastError = "\(l10n.text(.accountsImportFailed)): \(error.localizedDescription)"
            }
        }
    }

    /// Returns true when at least one account was imported successfully.
    @discardableResult
    func importPastedCredentials(_ text: String) async -> Bool {
        let batch = await accountImporter.importPastedText(text, makeActiveFirst: managedAccounts.isEmpty)
        // Reload index first so the settings list updates before the sheet closes.
        reloadAccountIndex()
        // Optimistic merge: ensure newly imported rows are visible even if index reload races.
        if batch.successCount > 0 {
            mergeImportedAccounts(batch.succeeded)
            accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), batch.successCount)
            lastError = batch.failureCount > 0
                ? "\(l10n.text(.accountsImportFailed)): \(humanizeImportFailures(batch.failures))"
                : nil
            // Quota refresh is background; do not block list visibility on it.
            refreshAllAccountQuotas()
            return true
        }
        accountOperationMessage = nil
        if batch.failures.contains("no_credentials") || batch.failures.isEmpty {
            lastError = l10n.text(.accountsImportNoCredentials)
        } else {
            lastError = "\(l10n.text(.accountsImportFailed)): \(humanizeImportFailures(batch.failures))"
        }
        return false
    }

    private func mergeImportedAccounts(_ imported: [ManagedAccount]) {
        var byID = Dictionary(uniqueKeysWithValues: managedAccounts.map { ($0.id, $0) })
        for account in imported {
            byID[account.id] = account
        }
        managedAccounts = Array(byID.values).sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.resolvedDisplayName.localizedCaseInsensitiveCompare(rhs.resolvedDisplayName)
                == .orderedAscending
        }
    }

    private func humanizeImportFailures(_ failures: [String]) -> String {
        failures.prefix(3).map { failure in
            if failure == "no_credentials" {
                return l10n.text(.accountsImportNoCredentials)
            }
            return failure
        }.joined(separator: "; ")
    }

    func importCredentialFiles(_ urls: [URL]) {
        Task {
            let batch = await accountImporter.importFiles(at: urls, makeActiveFirst: managedAccounts.isEmpty)
            reloadAccountIndex()
            if batch.successCount > 0 {
                mergeImportedAccounts(batch.succeeded)
                accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), batch.successCount)
                lastError = batch.failureCount > 0
                    ? "\(l10n.text(.accountsImportFailed)): \(batch.failures.prefix(3).joined(separator: "; "))"
                    : nil
                refreshAllAccountQuotas()
            } else if batch.failureCount > 0 {
                lastError = "\(l10n.text(.accountsImportFailed)): \(batch.failures.prefix(3).joined(separator: "; "))"
            }
        }
    }

    /// Parse credential / transfer-pack files into a selectable import preview (no writes).
    func previewAccountImport(urls: [URL]) -> CodexAccountImportPreview {
        accountImporter.previewFiles(at: urls)
    }

    /// Commit selected Codex import preview rows.
    @discardableResult
    func commitAccountImport(
        candidates: [CodexAccountImportCandidate],
        selectedIDs: Set<String>) async -> Bool
    {
        let batch = await accountImporter.importPreviewSelection(
            candidates,
            selectedIDs: selectedIDs,
            makeActiveFirst: managedAccounts.isEmpty)
        reloadAccountIndex()
        if batch.successCount > 0 {
            mergeImportedAccounts(batch.succeeded)
            accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), batch.successCount)
            lastError = batch.failureCount > 0
                ? "\(l10n.text(.accountsImportFailed)): \(humanizeImportFailures(batch.failures))"
                : nil
            refreshAllAccountQuotas()
            return true
        }
        accountOperationMessage = nil
        if batch.failures.contains("nothing_selected") {
            lastError = l10n.text(.accountsExportEmpty)
        } else if batch.failures.contains("no_credentials") || batch.failures.isEmpty {
            lastError = l10n.text(.accountsImportNoCredentials)
        } else {
            lastError = "\(l10n.text(.accountsImportFailed)): \(humanizeImportFailures(batch.failures))"
        }
        return false
    }

    /// Export selected managed Codex accounts to a transfer pack file.
    @discardableResult
    func exportAccounts(ids: [String], to url: URL) -> Bool {
        do {
            let exporter = AccountExporter(
                store: accountStore,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            let result = try exporter.write(accountIDs: ids, to: url)
            accountOperationMessage = String(format: l10n.text(.accountsExportSucceeded), result.exportedCount)
            if result.failures.isEmpty {
                lastError = nil
            } else {
                lastError = "\(l10n.text(.accountsExportFailed)): \(result.failures.prefix(3).joined(separator: "; "))"
            }
            return true
        } catch {
            accountOperationMessage = nil
            lastError = "\(l10n.text(.accountsExportFailed)): \(error.localizedDescription)"
            return false
        }
    }

    /// Adds a key-based account, optionally pointing it at a relay and storing a
    /// dashboard token for balance/history.
    ///
    /// Both extras are optional: a plain OpenAI key still works, and a relay key
    /// without a token still reports its own spend.
    func importAPIKey(_ key: String, relayBaseURL: String? = nil, dashboardToken: String? = nil) {
        Task {
            do {
                let trimmedBaseURL = relayBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let endpoint = URLComponents(string: trimmedBaseURL)
                guard endpoint?.scheme?.lowercased() == "https",
                      endpoint?.host?.isEmpty == false,
                      endpoint?.user == nil, endpoint?.password == nil,
                      endpoint?.fragment == nil else {
                    lastError = l10n.text(.accountErrorRelayBaseURLMissing)
                    return
                }
                let firstAccount = (try accountStore.loadIndex()).accounts.isEmpty
                var account = try accountImporter.importAPIKey(
                    key,
                    makeActive: false)

                let trimmedToken = dashboardToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                account.relayBaseURL = trimmedBaseURL
                try accountStore.updateMetadata(account)
                if let trimmedToken, !trimmedToken.isEmpty {
                    // The PAT is optional and its store can be temporarily locked.
                    // Its failure must not leave the first key imported but inactive.
                    try? newAPITokens.save(trimmedToken, for: account.id)
                }

                reloadAccountIndex()
                mergeImportedAccounts([account])
                if firstAccount {
                    switchAccount(id: account.id)
                    return
                }
                accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), 1)
                lastError = nil
                refreshAllAccountQuotas()
            } catch {
                lastError = "\(l10n.text(.accountsImportFailed)): \(error.localizedDescription)"
            }
        }
    }

    /// Whether a dashboard token is stored for this account.
    func hasDashboardToken(accountID: String) -> Bool {
        newAPITokens.hasToken(for: accountID)
    }

    // MARK: - Quota window probe

    /// Last outcome of a manual or automatic start, for display.
    @Published var quotaWindowStartMessage: String?
    /// True while a start is in flight, so the button can disable and show progress.
    @Published var isStartingQuotaWindow = false

    /// Runs the auto-start sweep for every subscription account.
    ///
    /// Called on the same cadence as the quota refresh: a window can only be started
    /// once the previous one has ended, and that moment arrives at a time the app
    /// cannot predict, so the state has to be re-read rather than scheduled for.
    /// Each account is considered independently, and the probe's own lock makes a
    /// repeated sweep harmless.
    func sweepQuotaWindowAutoStart() async {
        guard settings.preferences.autoStartsQuotaWindow else { return }
        for account in managedAccounts where account.authMode == .oauth {
            guard let auth = try? accountStore.loadCredential(id: account.id) else { continue }
            guard !TokenInspector.isExpired(auth.tokens.accessToken) else { continue }
            let readAt = Date()
            guard let quota = try? await QuotaClient().fetchQuota(auth: auth) else {
                // An unreadable state is not a reason to guess.
                continue
            }
            // Only an idle window is worth acting on; checked here as well so the
            // common case skips the probe's own work entirely.
            guard quota.primary.isIdle else { continue }

            let outcome = await quotaWindowProbe.start(
                accountID: account.id,
                credential: auth,
                window: quota.primary,
                dailyWindow: quota.secondary,
                usageReadAt: readAt,
                autoStartEnabled: true)
            if case .started = outcome {
                quotaWindowStartMessage = describe(outcome)
                refreshAccountQuota(id: account.id)
            }
        }
    }

    /// Opens a fresh 5-hour window for the given account, if the guards allow it.
    ///
    /// Reads usage immediately before deciding: the probe refuses to act on a stale
    /// reading, and the switch here is a deliberate one-off, so the reading taken at
    /// the click is the only one worth trusting.
    func startQuotaWindow(accountID: String, autoStartEnabled: Bool) async {
        guard !isStartingQuotaWindow else { return }
        isStartingQuotaWindow = true
        defer { isStartingQuotaWindow = false }
        guard let account = managedAccounts.first(where: { $0.id == accountID }) else { return }
        guard account.authMode == .oauth else {
            // A relay key is metered per token and has no 5-hour window at all.
            quotaWindowStartMessage = l10n.text(.quotaWindowNeedsSubscription)
            return
        }
        guard let auth = try? accountStore.loadCredential(id: accountID) else {
            quotaWindowStartMessage = l10n.text(.quotaWindowStateUnavailable)
            return
        }

        let readAt = Date()
        let quota = try? await QuotaClient().fetchQuota(auth: auth)
        let outcome = await quotaWindowProbe.start(
            accountID: accountID,
            credential: auth,
            window: quota?.primary,
            dailyWindow: quota?.secondary,
            usageReadAt: readAt,
            autoStartEnabled: autoStartEnabled)

        quotaWindowStartMessage = describe(outcome)
        // A start changes the window, so the meter is refreshed to show it.
        if case .started = outcome { refreshAccountQuota(id: accountID) }
    }

    /// A short, user-facing description of what the probe decided.
    private func describe(_ outcome: QuotaWindowStartOutcome) -> String {
        switch outcome {
        case .windowAlreadyActive: return l10n.text(.quotaWindowAlreadyActive)
        case .quotaExhausted: return l10n.text(.quotaWindowExhausted)
        case .stateUnavailable: return l10n.text(.quotaWindowStateUnavailable)
        case .disabled: return l10n.text(.quotaWindowAutoStartOff)
        case .recentlyStarted(let seconds): return String(
            format: l10n.text(.quotaWindowRecentlyStarted), seconds / 60)
        case .cliUnavailable: return l10n.text(.quotaWindowCLIMissing)
        case .started(let tokens): return tokens.map {
            String(format: l10n.text(.quotaWindowStartedWithTokens), $0)
        } ?? l10n.text(.quotaWindowStarted)
        case .failed(let reason): return String(
            format: l10n.text(.quotaWindowFailed), reason)
        }
    }

    /// What is stored for a relay account, for the config detail view.
    func storedRelayConfig(accountID: String) -> RelayConfigProfile? {
        relayConfigStore.load(for: accountID)
    }

    /// What the live Codex config currently says, read as the file it is.
    ///
    /// Read fresh rather than cached: this view exists to show whether another tool has
    /// rewritten the file since the settings were captured, so a stale copy would defeat
    /// its purpose.
    ///
    /// The file describes one account — the active one — because every relay account
    /// shares the same provider section. Passing an account in would let it be read
    /// through that account's recorded provider name, showing a section that may not be
    /// the one the file selects.
    func liveRelayConfig() -> RelayConfigProfile? {
        AccountRoutingCoordinator.liveProfile(configURL: accountStore.officialConfigURL)
    }

    /// Whether this account's provider will use WebSockets.
    ///
    /// Read from the account's own stored settings rather than from the live file: the
    /// `[model_providers.*]` section is shared by every relay account, so the file holds
    /// whichever value the last switch wrote — another account's, not this one's. The
    /// toggle must describe the account the user opened it for.
    func relaySupportsWebSockets(for account: ManagedAccount) -> Bool {
        storedRelayConfig(accountID: account.id)?.supportsWebSockets ?? false
    }

    /// Turns WebSocket transport on or off for the account's provider.
    ///
    /// A compatibility switch: relays often advertise WebSocket support without
    /// implementing it, and the resulting failure — a stream closed by the server
    /// before the response completes — gives no hint about the cause. Disabling it
    /// falls back to plain HTTP streaming, which relays handle.
    ///
    /// The setting is stored per account, because the `[model_providers.*]` section in
    /// the file is shared. The file is only touched while this account is the active
    /// one — otherwise flipping a background account's switch would change the transport
    /// of whichever account actually has the endpoint selected.
    func setRelaySupportsWebSockets(_ enabled: Bool, for account: ManagedAccount) {
        if var profile = relayConfigStore.load(for: account.id) {
            profile.supportsWebSockets = enabled
            profile.capturedAt = Date()
            _ = relayConfigStore.save(profile, for: account.id)
        } else if let provider = relayProviderName(for: account) {
            // No profile yet: create one so the choice is remembered per account.
            let created = RelayConfigProfile(
                providerName: provider,
                baseURL: account.relayBaseURL,
                supportsWebSockets: enabled)
            _ = relayConfigStore.save(created, for: account.id)
        }

        guard account.id == activeAccountId,
              let provider = relayProviderName(for: account)
        else {
            // Not the active account: the selection points elsewhere, so the file must
            // keep describing that other account. The stored choice is applied by the
            // next switch to this one.
            lastError = nil
            return
        }

        let outcome = CodexConfigProviderEditor.setProviderField(
            provider,
            key: "supports_websockets",
            value: enabled ? "true" : "false",
            configURL: accountStore.officialConfigURL)

        if case .failed(let reason) = outcome {
            lastError = reason
            return
        }
        lastError = nil
    }

    /// The provider section this account routes through.
    private func relayProviderName(for account: ManagedAccount) -> String? {
        account.relayProviderName
            ?? CodexConfigReader.selectedProvider(configURL: accountStore.officialConfigURL)
            ?? (account.authMode == .apiKey ? AccountRoutingCoordinator.relayProviderName : nil)
    }

    /// The stored relay key, for masked display.
    func maskedRelayKey(accountID: String) -> String? {
        (try? accountStore.loadCredential(id: accountID))?.openAIAPIKey
    }

    func dashboardToken(accountID: String) -> String? {
        newAPITokens.token(for: accountID)
    }

    func saveDashboardToken(_ token: String, accountID: String) {
        do {
            try newAPITokens.save(token, for: accountID)
            accountOperationMessage = l10n.text(.newAPIDashboardTokenSaved)
            lastError = nil
            refreshAccountQuota(id: accountID)
        } catch {
            lastError = "\(l10n.text(.accountsImportFailed)): \(error.localizedDescription)"
        }
    }

    func removeDashboardToken(accountID: String) {
        try? newAPITokens.delete(for: accountID)
        refreshAccountQuota(id: accountID)
    }

    func startOAuthLogin() {
        startBrowserSignIn(reauthorizing: nil)
    }

    /// Signs in again for an account whose authorization expired.
    ///
    /// The credential this produces is written back onto the same row, so the account
    /// becomes usable again without being removed and added: the list position, the
    /// alias, the note, and everything else the row carried are kept.
    func startReauthorization(accountID: String) {
        guard managedAccounts.contains(where: { $0.id == accountID }) else { return }
        startBrowserSignIn(reauthorizing: accountID)
    }

    /// One browser sign-in flow, for both "add an account" and "repair this account".
    ///
    /// `reauthorizing` decides where the resulting credential goes and nothing else, so
    /// the two paths cannot drift apart in how they handle the callback, cancellation or
    /// failures.
    private func startBrowserSignIn(reauthorizing accountID: String?) {
        // A sign-in is single-flight: the callback server binds one fixed port. Saying so
        // matters, because a click that silently does nothing reads as a broken button —
        // the user has no way to tell it apart from a slow one.
        guard oauthLoginTask == nil else {
            lastError = nil
            accountOperationMessage = l10n.text(.accountsOAuthAlreadyRunning)
            return
        }
        lastError = nil
        isOAuthLoginInProgress = true
        reauthorizingAccountId = accountID
        accountOperationMessage = accountID == nil
            ? l10n.text(.accountsOAuthWaiting)
            : l10n.text(.accountsReauthorizeWaiting)
        oauthLoginTask = Task {
            defer {
                oauthLoginTask = nil
                oauthCallbackServer = nil
                pendingOAuthURL = nil
                isOAuthLoginInProgress = false
                reauthorizingAccountId = nil
            }
            let server = OAuthCallbackServer()
            oauthCallbackServer = server
            do {
                let session = try CodexOAuthLogin.startSession()
                pendingOAuthURL = session.authURL
                // The browser is deliberately not opened here. Starting a repair should
                // leave the user in control of when and where the sign-in happens, so the
                // link is offered in the list instead — to open, or to copy into whichever
                // browser profile or machine they sign in with.
                let callbackURL = try await server.waitForCallback()
                let code = try CodexOAuthLogin.authorizationCode(from: callbackURL, expectedState: session.state)
                let exchanged = try await CodexOAuthLogin.exchangeCode(code, session: session)
                if let accountID {
                    try await completeReauthorization(accountID: accountID, auth: exchanged.auth)
                } else {
                    try await completeNewLogin(auth: exchanged.auth)
                }
            } catch OAuthCallbackServer.ServerError.portInUse(let port) {
                accountOperationMessage = nil
                lastError = "\(l10n.text(.accountsOAuthFailed)): \(String(format: l10n.text(.accountsOAuthPortInUse), Int(port)))"
            } catch OAuthCallbackServer.ServerError.cancelled {
                accountOperationMessage = accountID == nil
                    ? l10n.text(.accountsOAuthCancelled)
                    : l10n.text(.accountsReauthorizeCancelled)
            } catch AccountStoreError.reauthorizationIdentityMismatch {
                accountOperationMessage = nil
                lastError = l10n.text(.accountsReauthorizeWrongAccount)
            } catch {
                accountOperationMessage = nil
                lastError = "\(l10n.text(.accountsOAuthFailed)): \(error.localizedDescription)"
            }
        }
    }

    /// Files a fresh sign-in as a new account.
    private func completeNewLogin(auth: CodexAuth) async throws {
        let makeActive = managedAccounts.isEmpty
        let account = try accountStore.upsert(auth: auth, makeActive: makeActive)
        if makeActive {
            _ = try await accountSwitcher.switchTo(accountId: account.id)
            refresh()
        }
        reloadAccountIndex()
        mergeImportedAccounts([account])
        accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), 1)
        lastError = nil
        refreshAllAccountQuotas()
    }

    /// Writes a fresh sign-in back onto the account that needed it.
    ///
    /// Repairing the row is only half the job. Codex reads its credential from
    /// `~/.codex/auth.json`, so if this account is the active one the same write a manual
    /// switch performs has to happen too — otherwise the card would report success while
    /// Codex itself kept using the expired token.
    ///
    /// Codex is deliberately *not* relaunched here. The credential is on disk and the
    /// user decides when to restart; a repair should not interrupt whatever they were
    /// doing, which is the difference between this and an explicit account switch.
    private func completeReauthorization(accountID: String, auth: CodexAuth) async throws {
        let account = try accountStore.reauthorize(id: accountID, auth: auth)
        let wasActive = activeAccountId == accountID
        var routingFailure: String?
        if wasActive {
            // A routing failure must not hide the repair behind an early return: the
            // credential on disk is already good, so the tail below still has to run.
            let result = try await accountSwitcher.switchTo(accountId: accountID)
            routingFailure = result.routingFailure
            refresh()
        }
        reloadAccountIndex()
        mergeImportedAccounts([account])
        accountOperationMessage = String(format: l10n.text(.accountsReauthorizeSucceeded), account.resolvedDisplayName)
        lastError = routingFailure.map { String(format: l10n.text(.accountsRoutingUpdateFailed), $0) }
        refreshAccountQuota(id: accountID)
    }

    func copyPendingOAuthURL() {
        guard let url = pendingOAuthURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(url.absoluteString, forType: .string) else {
            lastError = l10n.text(.accountsOAuthFailed)
            return
        }
        accountOperationMessage = l10n.text(.accountsOAuthLinkCopied)
        lastError = nil
    }

    func openPendingOAuthURL() {
        guard let url = pendingOAuthURL else { return }
        NSWorkspace.shared.open(url)
    }

    func cancelOAuthLogin() {
        oauthCallbackServer?.cancel()
    }

    func deleteAccount(id: String) {
        Task {
            do {
                let wasActive = activeAccountId == id
                try accountStore.deleteAccount(id: id)
                reloadAccountIndex()
                if wasActive, let next = activeAccountId {
                    switchAccount(id: next)
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func moveAccount(id: String, direction: Int) {
        // direction: -1 up, +1 down in user sort (ignoring active pin).
        var nonActive = managedAccounts
            .filter { $0.id != activeAccountId }
            .sorted { $0.sortIndex < $1.sortIndex }
        guard let index = nonActive.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard nonActive.indices.contains(target) else { return }
        nonActive.swapAt(index, target)
        var orderedIds: [String] = []
        if let activeAccountId {
            orderedIds.append(activeAccountId)
        }
        orderedIds.append(contentsOf: nonActive.map(\.id))
        // Include any missing ids.
        for account in managedAccounts where !orderedIds.contains(account.id) {
            orderedIds.append(account.id)
        }
        try? accountStore.reorder(ids: orderedIds)
        reloadAccountIndex()
    }

    func updateAccountAlias(id: String, alias: String?) {
        guard var account = managedAccounts.first(where: { $0.id == id }) else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        account.alias = (trimmed?.isEmpty == false) ? trimmed : nil
        try? accountStore.updateMetadata(account)
        reloadAccountIndex()
    }

    var l10n: L10n { settings.l10n }

    var isRefreshing: Bool {
        isRefreshingAll || !refreshingSections.isEmpty
    }

    func isRefreshing(_ section: RunwayRefreshSection) -> Bool {
        refreshingSections.contains(section)
    }

    /// A hung leg (trickling response, first-time index rebuild) must never pin the
    /// refresh pipeline: every entry point guards on this state, and RefreshSchedule
    /// only re-arms via onFullRefreshCompleted.
    private static let fullRefreshWatchdogSeconds: UInt64 = 120

    func refresh(policy: UsageCostRefreshPolicy = .force) {
        guard !isRefreshingAll, refreshingSections.isEmpty else { return }
        let refreshID = UUID()
        activeFullRefreshID = refreshID
        isRefreshingAll = true
        let work = Task { await refreshNow(policy: policy) }
        fullRefreshWork = work
        Task {
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: Self.fullRefreshWatchdogSeconds * 1_000_000_000)
                work.cancel()
            }
            await work.value
            watchdog.cancel()
            finishFullRefresh(id: refreshID)
        }
    }

    func refreshQuota() {
        guard !isRefreshingAll else { return }
        Task { await refreshQuotaNow() }
    }

    func refreshResetCredits() {
        guard !isRefreshingAll else { return }
        Task { await refreshResetCreditsNow() }
    }

    func refreshQuotaEstimate() {
        guard settings.preferences.showsQuotaEstimateSummary else { return }
        // A relay key has no ChatGPT windows for this to describe.
        guard !isAPIKeyAccount else { return }
        guard !isRefreshingAll, !isRefreshing(.quotaEstimate) else { return }
        Task { await refreshQuotaEstimateNow() }
    }

    /// Fits the window allowance from local session logs.
    ///
    /// The scan walks rollout files, which reach gigabytes, so it runs off the main
    /// actor and only reports the aggregate.
    /// Runs the local scan once, when the panel first opens.
    ///
    /// Guarded rather than unconditional: the scan walks every rollout file, and
    /// re-running it on each appearance would burn CPU for data that only changes
    /// when the account is actually used.
    func scanLocalAllowanceIfNeeded() {
        guard localAllowances.isEmpty, localAllowanceScannedAt == nil else { return }
        refreshLocalAllowance()
    }

    func refreshLocalAllowance() {
        guard settings.preferences.showsLocalAllowanceSummary else { return }
        guard !isRefreshingAll, !isRefreshing(.localAllowance) else { return }
        Task { await refreshLocalAllowanceNow() }
    }

    func refreshLocalAllowanceNow() async {
        await withRefresh([.localAllowance]) {
            // Reads local files only; no account or network involvement.
            let codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
            // Costed with the same merged price table the API-equivalent cost uses,
            // so the two never disagree on what a model costs.
            let priceLookup = OpenAIPricingCatalog.priceLookup()
            let scanned = await Task.detached(priority: .utility) {
                LocalQuotaAllowanceScanner(
                    codexHome: codexHome,
                    priceForModel: priceLookup).scan()
            }.value
            guard !Task.isCancelled else { return }
            localAllowances = scanned
            localAllowanceScannedAt = Date()
            localAllowanceError = nil
        }
    }

    func refreshRateLimitResetToday(force: Bool = true) {
        guard needsRateLimitResetTodayData else { return }
        guard !isRefreshing(.rateLimitResetToday) else { return }
        Task { await refreshRateLimitResetTodayNow(force: force) }
    }

    func setRateLimitResetTodayReactionPollingEnabled(_ enabled: Bool) {
        if enabled, !reactionPollingDesired {
            isReactionDisabled = false
        }
        reactionPollingDesired = enabled
        let shouldRun = enabled
            && settings.preferences.showsRateLimitResetToday
            && !isReactionDisabled
        if shouldRun {
            if reactionPollTask == nil {
                beginRateLimitResetTodayReactionSession()
            }
        } else {
            endRateLimitResetTodayReactionSession()
        }
    }

    func clickRateLimitResetTodayReaction() {
        guard !isRateLimitResetTodayReactionBusy else { return }
        guard !isRateLimitResetTodayReactionLoading else { return }
        if reactionPollingDesired, !isRateLimitResetTodayReactionFresh { return }
        guard let current = rateLimitResetTodayReaction, current.isVisible, !current.isExhausted else { return }
        isRateLimitResetTodayReactionBusy = true
        reactionWriteGeneration += 1
        rateLimitResetTodayReaction = RateLimitResetTodayReaction.optimisticClick(current)
        publishReactionDelta(1)
        Task { await clickRateLimitResetTodayReactionNow(current) }
    }

    func refreshCost(policy: UsageCostRefreshPolicy = .force) {
        // Cost is derived from the Codex quota payload, which a relay key has none of.
        guard !isAPIKeyAccount else { return }
        guard !isRefreshingAll,
              !refreshingSections.contains(.apiCost),
              shouldRefreshCost(policy: policy)
        else { return }
        refreshingSections.insert(.apiCost)
        Task {
            await refreshCostNow(policy: policy)
            refreshingSections.remove(.apiCost)
            exportStatusIfNeeded()
        }
    }

    func refreshTokenHeatmap(policy: UsageCostRefreshPolicy = .force) {
        guard settings.preferences.showsTokenUsageHeatmap || widgetRequirements.contains(.tokenTrend) else { return }
        guard !isRefreshingAll,
              !refreshingSections.contains(.tokenHeatmap),
              shouldRefreshTokenHeatmap(policy: policy)
        else { return }
        let refreshID = UUID()
        activeTokenHeatmapRefreshID = refreshID
        refreshingSections.insert(.tokenHeatmap)
        let work = Task {
            await refreshTokenHeatmapNow(policy: policy)
            finishTokenHeatmapRefresh(id: refreshID)
        }
        tokenHeatmapRefreshWork = work
    }

    func tokenHeatmapSnapshot(mode: TokenUsageHeatmapMode) -> TokenUsageHeatmapSnapshot {
        TokenUsageHeatmapBuilder.make(
            allDevicesTokens: tokenHeatmapAllDevicesTokens,
            localTokens: tokenHeatmapLocalTokens,
            mode: mode,
            now: tokenHeatmapCalculatedAt ?? Date(),
            timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func tick(now: Date = Date()) {
        // Equality-guard publishes: unconditional @Published writes force the entire
        // popover tree (including PolishedScrollView layout) to rebuild every second.
        if let latestQuota {
            let nextStatus = menuBarText(for: latestQuota, now: now)
            if statusText != nextStatus {
                statusText = nextStatus
            }
        } else if isAPIKeyAccount {
            // A relay key never has a `latestQuota`, so nothing above ever corrects the
            // label: it would keep whatever the previous account left there. Setting it
            // here makes the item identify the account that is actually active.
            let label = l10n.text(.planAPI)
            if statusText != label {
                statusText = label
            }
        }
        if let latestDisplayedCost, let latestDisplayedCostRange {
            let nextSubtitle = costSubtitle(for: latestDisplayedCost, range: latestDisplayedCostRange, now: now)
            if costSubtitle != nextSubtitle {
                costSubtitle = nextSubtitle
            }
        }
        if widgetRequirements.contains(.resetToday) {
            refreshRateLimitResetTodayDisplayIfNeeded(now: now)
            refreshRateLimitResetTodayIfDue(now: now)
        }
    }

    func nextDueQuotaReset(after triggeredReset: Date?, now: Date = Date()) -> Date? {
        latestQuota?.nextDueReset(after: triggeredReset, now: now)
    }

    /// Panel-open refreshes pass force=false: rescanning ~/.codex/sessions is
    /// O(files) heavy IO, and doing it on every open keeps the section spinners
    /// running for the whole visit on large session dirs.
    func refreshSessionReport(force: Bool = true) {
        guard !isRefreshingAll else { return }
        guard force || isStale(lastSessionReportAt) else { return }
        Task { await refreshSessionReportNow() }
    }

    func refreshRecentSessions(force: Bool = true) {
        guard !isRefreshingAll else { return }
        guard force || isStale(lastRecentSessionsAt) else { return }
        Task {
            await refreshRecentSessionsNow()
            exportStatusIfNeeded()
        }
    }

    private static let visibleSectionTTL: TimeInterval = 120

    private func isStale(_ lastSuccess: Date?) -> Bool {
        guard let lastSuccess else { return true }
        return Date().timeIntervalSince(lastSuccess) >= Self.visibleSectionTTL
    }

    func testNotification() -> String? {
        switch notificationService.deliverTest(l10n: l10n) {
        case .requested:
            return nil
        case .developmentMode:
            return l10n.text(.testNotificationDevelopmentMode)
        }
    }

    func repairSessions() {
        guard !isRefreshingAll else { return }
        Task {
            await withRefresh([.sessionRepair]) {
                do {
                    let service = sessionRepair
                    let report = try await Task.detached { try service.repair() }.value
                    applySessionReport(report)
                    let backup = report.backupPath?.lastPathComponent ?? l10n.text(.noPreviousIndex)
                    sessionText = "\(l10n.text(.rebuilt)) \(report.plannedEntries). \(l10n.text(.backup)): \(backup)"
                } catch {
                    sessionText = "\(l10n.text(.repairFailed)): \(error.localizedDescription)"
                }
            }
        }
    }

    var repairWarning: String {
        l10n.text(.repairConfirmMessage)
    }

    func relabel() {
        // Prefer live quota plan only when we still have a matching snapshot; else JWT/auth only.
        accountDisplay = CodexAccountDisplay.make(auth: latestAuth, quotaPlan: latestQuota?.plan)
        if let latestQuota {
            applyQuota(latestQuota)
        } else if isAPIKeyAccount {
            // A relay key has no ChatGPT quota to show, and "not signed in" would be
            // plainly wrong for an account that is configured and working. The badge
            // states what it is instead of implying something is missing.
            statusText = l10n.text(.planAPI)
            quotaText = l10n.text(.notLoaded)
            quotaMeters = []
            quotaLines = []
        } else {
            statusText = l10n.text(.statusLogin)
            quotaText = l10n.text(.notLoaded)
            quotaMeters = []
            quotaLines = []
        }
        if let latestResetCredits { applyResetCredits(latestResetCredits) } else { resetCreditsText = l10n.text(.notLoaded) }
        if let rateLimitResetToday {
            applyRateLimitResetToday(rateLimitResetToday)
        } else if settings.preferences.showsRateLimitResetToday {
            rateLimitResetTodayText = l10n.text(.notLoaded)
            rateLimitResetTodayLines = []
        } else {
            rateLimitResetTodayText = l10n.text(.notLoaded)
            rateLimitResetTodayLines = []
        }
        if let latestDisplayedCost, let latestDisplayedCostRange {
            applyDisplayedCost(latestDisplayedCost, range: latestDisplayedCostRange, clearsScanNote: false)
        } else {
            costText = l10n.text(.notScanned)
            costSubtitle = ""
        }
        if let latestSessionReport { applySessionReport(latestSessionReport) } else { sessionText = l10n.text(.notScanned) }
        applyRecentSessions(recentSessions)
        // Turning the section on should fetch promptly without waiting for the next due tick.
        if settings.preferences.showsRateLimitResetToday,
           rateLimitResetToday == nil
        {
            refreshRateLimitResetToday(force: true)
        }
        if let latestQuota, let latestQuotaEstimateDaily {
            applyQuotaEstimate(quota: latestQuota, daily: latestQuotaEstimateDaily, persist: false)
        } else if settings.preferences.showsQuotaEstimateSummary,
                  quotaEstimate == nil
        {
            refreshQuotaEstimate()
        }
    }

    private func refreshSessionReportNow() async {
        await withRefresh([.sessionRepair]) {
            await loadSessionReport()
        }
    }

    private func loadSessionReport() async {
        do {
            let report = try await services.dryRunSessions()
            applySessionReport(report)
            lastSessionReportAt = Date()
        } catch {
            sessionText = l10n.text(.sessionScanFailed)
            sessionLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
        }
    }

    private func applySessionReport(_ report: SessionRepairReport) {
        latestSessionReport = report
        sessionText = "\(report.missingIndexIDs.count) \(l10n.text(.missing)), \(report.orphanIndexIDs.count) \(l10n.text(.orphan)), \(report.duplicateIndexIDs.count) \(l10n.text(.duplicate))"
        sessionLines = [
            DetailLine(title: l10n.text(.plannedEntries), value: "\(report.plannedEntries)"),
            DetailLine(title: l10n.text(.missingFromIndex), value: "\(report.missingIndexIDs.count)"),
            DetailLine(title: l10n.text(.orphanIndexRows), value: "\(report.orphanIndexIDs.count)"),
            DetailLine(title: l10n.text(.duplicateIndexIDs), value: "\(report.duplicateIndexIDs.count)"),
            DetailLine(title: l10n.text(.staleTitles), value: "\(report.staleTitleIDs.count)"),
        ]
        if let backup = report.backupPath?.lastPathComponent {
            sessionLines.append(DetailLine(title: l10n.text(.backup), value: backup))
        }
    }

    private func refreshRecentSessionsNow() async {
        await withRefresh([.recentSessions]) {
            await loadRecentSessions()
        }
    }

    private func loadRecentSessions() async {
        do {
            let summary = try await services.scanRecentSessions(5)
            applyRecentSessions(summary.items)
            lastRecentSessionsAt = Date()
        } catch {
            recentSessions = []
            recentSessionLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
        }
    }

    private func applyRecentSessions(_ sessions: [SessionActivityItem]) {
        recentSessions = sessions
        recentSessionLines = sessions.prefix(5).map { session in
            let amount = session.estimatedUSD.map(DurationFormatter.money) ?? "--"
            return DetailLine(
                title: session.projectName,
                value: "\(sessionStateText(session.state)) · \(Self.compactNumber(session.totals.totalTokens)) \(l10n.text(.tokens)) · \(amount)")
        }
    }

    private func deliverAlerts(_ alerts: [RunwayAlert], enabled: Bool) {
        guard enabled, !alerts.isEmpty else { return }
        do {
            let unseen = try alertStore.unseen(alerts)
            notificationService.deliver(unseen, l10n: l10n)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func exportStatusIfNeeded() {
        guard settings.preferences.exportsStatusJSON else { return }
        let snapshot = RunwayStatusSnapshot(
            quota: latestQuota.map(RunwayStatusQuota.init),
            cost: latestCost,
            sessions: SessionActivitySummary(items: recentSessions))
        let exporter = statusExporter
        Task.detached { try? exporter.save(snapshot) }
    }

    func makeWidgetSnapshot(now: Date = Date()) -> RunwayWidgetSnapshot {
        return RunwayWidgetSnapshot(
            generatedAt: now,
            language: l10n.language,
            provider: makeWidgetCodexSnapshot(),
            resetToday: makeWidgetResetToday(now: now))
    }

    private var needsRateLimitResetTodayData: Bool {
        settings.preferences.showsRateLimitResetToday || widgetRequirements.contains(.resetToday)
    }

    private func makeWidgetCodexSnapshot() -> RunwayWidgetCodexSnapshot {
        let hasAllDevicesTokens = !tokenHeatmapAllDevicesTokens.isEmpty
        let tokenSource: RunwayWidgetTokenSource = hasAllDevicesTokens ? .allDevices : .thisMac
        let tokens = hasAllDevicesTokens ? tokenHeatmapAllDevicesTokens : tokenHeatmapLocalTokens
        return RunwayWidgetCodexSnapshot(
            availability: latestQuota == nil
                ? (accountDisplay.isAuthenticated ? .unavailable : .notLoggedIn)
                : .available,
            plan: latestQuota?.plan,
            updatedAt: latestQuota?.updatedAt,
            quota: quotaMeters.map { widgetQuota($0) },
            balanceUSD: latestQuota?.creditsBalance.map { Decimal($0) },
            apiEquivalentCostUSD: costDetail?.estimatedUSD,
            tokenSource: tokenSource,
            dailyTokens: widgetDailyTokens(tokens),
            resetCredits: resetCreditSummary.map {
                RunwayWidgetResetCredits(
                    availableCount: $0.availableCount,
                    expiringCount: $0.expiringCount)
            })
    }

    private func widgetQuota(
        _ meter: QuotaMeter,
        source: RunwayWidgetQuotaSource? = nil
    ) -> RunwayWidgetQuota {
        RunwayWidgetQuota(
            title: meter.title,
            windowMinutes: meter.windowMinutes,
            source: source ?? (meter.source == .standard ? .standard : .modelSpecific),
            usedPercent: meter.usedPercent,
            remainingPercent: meter.remainingPercent,
            resetsAt: meter.resetsAt)
    }

    private func widgetDailyTokens(_ tokens: [String: Int]) -> [RunwayWidgetDailyTokens] {
        tokens.map { RunwayWidgetDailyTokens(date: $0.key, tokens: $0.value) }
    }

    private func makeWidgetResetToday(now: Date) -> RunwayWidgetResetTodaySnapshot? {
        guard let snapshot = rateLimitResetToday else { return nil }
        let state: RunwayWidgetResetTodaySnapshot.State
        switch snapshot.resolvedState(now: now) {
        case .yes: state = .yes
        case .no: state = .no
        case .unknown: state = .unknown
        }
        let nextScheduledReset = snapshot.nextScheduledReset(now: now)
        let presentation = snapshot.verdictPresentation(now: now)
        return RunwayWidgetResetTodaySnapshot(
            state: state,
            resetType: snapshot.displayResetType(now: now),
            nextScheduledAt: nextScheduledReset?.effectiveAt,
            nextScheduledResetType: nextScheduledReset?.event.resetType,
            lastSuccessfulCheckAt: snapshot.lastSuccessfulCheckAt,
            fetchedAt: snapshot.fetchedAt,
            confidencePercent: presentation.percent,
            confidenceBand: presentation.band)
    }

    private func withRefresh(_ sections: Set<RunwayRefreshSection>, operation: () async -> Void) async {
        guard refreshingSections.isDisjoint(with: sections) else { return }
        refreshingSections.formUnion(sections)
        defer { refreshingSections.subtract(sections) }
        await operation()
    }

    private func refreshNow(policy: UsageCostRefreshPolicy) async {
        // Keep managed account list aligned with official CLI auth before loading tokens.
        if let index = try? accountStore.syncFromOfficialAuth() {
            publishAccountIndex(index)
        }
        let shouldRefreshSessions = settings.preferences.showsSessionRepairSummary
        let shouldRefreshRecent = settings.preferences.showsRecentSessions
        async let sessionReport: Void = refreshSessionReportIfNeeded(shouldRefreshSessions)
        async let recentSessions: Void = refreshRecentSessionsIfNeeded(shouldRefreshRecent)
        var generation = accountStateGeneration
        var remoteError: Error?
        do {
            let auth: CodexAuth
            do {
                // Finish current-auth metadata writes before background quota results can arrive.
                // Poll managed accounts even if loading the current credential fails.
                defer { Task { await refreshAllAccountQuotasInline() } }
                auth = try await loadValidAuth(preferCached: false)
            }
            generation = accountStateGeneration
            async let quotaResultTask = refreshQuotaForFullRefresh(auth: auth)
            async let resetErrorTask = refreshResetCreditsForFullRefresh(auth: auth)
            let quotaResult = await quotaResultTask
            if case .success(let quotaSnapshot) = quotaResult {
                if settings.preferences.showsQuotaEstimateSummary {
                    await loadQuotaEstimate(auth: auth, quota: quotaSnapshot)
                }
                guard isCurrentAccount(auth, generation: generation) else { return }
                let needsCost =
                    (settings.preferences.showsCostSummary || widgetRequirements.contains(.cost))
                    && shouldRefreshCost(policy: policy, quota: quotaSnapshot)
                let needsHeatmap =
                    (settings.preferences.showsTokenUsageHeatmap || widgetRequirements.contains(.tokenTrend))
                    && shouldRefreshTokenHeatmap(policy: policy)
                if needsCost || needsHeatmap {
                    var sections = Set<RunwayRefreshSection>()
                    if needsCost { sections.insert(.apiCost) }
                    if needsHeatmap { sections.insert(.tokenHeatmap) }
                    await withRefresh(sections) {
                        await scanCostAndHeatmap(
                            quotaSnapshot,
                            auth: auth,
                            policy: policy,
                            includeCost: needsCost,
                            includeHeatmap: needsHeatmap)
                        guard isCurrentAccount(auth, generation: generation) else { return }
                        if needsCost {
                            markCostRefreshCompleted(quota: quotaSnapshot)
                        }
                        if needsHeatmap {
                            markTokenHeatmapRefreshCompleted()
                        }
                    }
                }
            }
            if case .failure(let error) = quotaResult, !(error is QuotaError) {
                // A relay account having no ChatGPT window is its normal state, not a
                // fault to report. Feeding it to the error path put a red line under a
                // successful switch.
                remoteError = error
            }
            if let resetError = await resetErrorTask,
               remoteError == nil || isAuthenticationFailure(resetError)
            {
                remoteError = resetError
            }
        } catch {
            remoteError = error
            if generation == accountStateGeneration {
                statusText = l10n.text(.statusError)
            }
        }
        _ = await (sessionReport, recentSessions)
        guard generation == accountStateGeneration else { return }
        if let remoteError { handleAuthenticationFailure(remoteError) }
        exportStatusIfNeeded()
        if let remoteError {
            lastError = humanizeAuthError(remoteError)
        } else if latestAuth != nil {
            lastError = nil
        }
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if error is RunwayModelAuthError { return true }
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return true
        }
        let ns = error as NSError
        if ns.domain == "CodexRunwayAuth" { return true }
        return ns.domain == NSURLErrorDomain && ns.code == URLError.userAuthenticationRequired.rawValue
    }

    @discardableResult
    private func handleAuthenticationFailure(_ error: Error) -> Bool {
        guard isAuthenticationFailure(error) else { return false }
        let message = humanizeAuthError(error)
        clearAccountScopedState(keepingAuth: nil)
        quotaText = l10n.text(.statusLogin)
        resetCreditsText = l10n.text(.statusLogin)
        lastError = message
        exportStatusIfNeeded()
        return true
    }

    private func humanizeAuthError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "CodexRunwayAuth" {
            switch ns.localizedDescription {
            case "auth_file_invalid":
                return l10n.text(.authFileInvalid)
            case "auth_expired":
                return l10n.text(.authExpired)
            default:
                return l10n.text(.authFileInvalid)
            }
        }
        if isAuthenticationFailure(error) {
            if let auth = try? accountStore.loadOfficialAuth() {
                switch auth.loginUsability {
                case .invalidTokens:
                    return l10n.text(.authFileInvalid)
                case .expiredAccessWithoutRefresh:
                    return l10n.text(.authExpired)
                case .usable:
                    break
                }
            }
            return l10n.text(.authExpired)
        }
        return error.localizedDescription
    }

    private func refreshAllAccountQuotasInline() async {
        guard !isRefreshingAccountQuotas, !isSwitchingAccount else { return }
        let generation = accountStateGeneration
        isRefreshingAccountQuotas = true
        let ids = Set(managedAccounts.map(\.id))
        refreshingAccountIds = refreshingAccountIds.union(ids)
        defer {
            isRefreshingAccountQuotas = false
            refreshingAccountIds = refreshingAccountIds.subtracting(ids)
        }
        let results = await accountQuotaRefresher.refreshAll()
        applyAccountQuotaRefreshResults(results, generation: generation)
    }

    private func refreshSessionReportIfNeeded(_ isShown: Bool) async {
        guard isShown else { return }
        await refreshSessionReportNow()
    }

    private func refreshRecentSessionsIfNeeded(_ isShown: Bool) async {
        guard isShown else { return }
        await refreshRecentSessionsNow()
    }

    private func refreshQuotaForFullRefresh(auth: CodexAuth) async -> Result<QuotaSnapshot, Error> {
        // A relay key has no ChatGPT quota to read. Asking anyway is not a harmless
        // no-op: `auth.json` can carry a leftover `tokens` block beside the key, and the
        // request succeeds against that other account — filling `latestQuota` with a
        // different account's windows, which the menu bar then shows under this
        // account's name.
        guard QuotaEligibility.canReportQuota(auth) else { return .failure(QuotaError.notApplicable) }

        let generation = accountStateGeneration
        var result: Result<QuotaSnapshot, Error> = .failure(CancellationError())
        await withRefresh([.quota]) {
            guard isCurrentAccount(auth, generation: generation) else { return }
            do {
                let snapshot = try await services.fetchQuota(auth)
                guard isCurrentAccount(auth, generation: generation) else { return }
                latestQuota = snapshot
                applyQuota(snapshot)
                deliverAlerts(RunwayAlertDecider.quotaAlerts(snapshot), enabled: settings.preferences.quotaAlertsEnabled)
                result = .success(snapshot)
            } catch {
                guard isCurrentAccount(auth, generation: generation) else { return }
                if !handleAuthenticationFailure(error) {
                    statusText = l10n.text(.statusError)
                    quotaText = l10n.text(.statusError)
                    quotaLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                }
                result = .failure(error)
            }
        }
        return result
    }

    private func refreshResetCreditsForFullRefresh(auth: CodexAuth) async -> Error? {
        // Reset credits are a ChatGPT-side concept, and `QuotaClient` authorises with
        // `auth.tokens.accessToken` regardless of the credential's type. A relay key
        // file can hold a leftover `tokens` block, so without this guard the request
        // would succeed against whichever account that token belongs to and display a
        // stranger's reset credits under this account.
        guard QuotaEligibility.canReportQuota(auth) else { return nil }
        let generation = accountStateGeneration
        var refreshError: Error?
        await withRefresh([.resetCredits]) {
            guard isCurrentAccount(auth, generation: generation) else { return }
            do {
                let snapshot = try await services.fetchResetCredits(auth)
                guard isCurrentAccount(auth, generation: generation) else { return }
                latestResetCredits = snapshot
                applyResetCredits(snapshot)
                deliverAlerts(RunwayAlertDecider.resetCreditAlerts(snapshot), enabled: settings.preferences.resetCreditAlertsEnabled)
            } catch {
                guard isCurrentAccount(auth, generation: generation) else { return }
                if !handleAuthenticationFailure(error) {
                    resetCreditsText = l10n.text(.statusError)
                    resetCreditLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                }
                refreshError = error
            }
        }
        return refreshError
    }

    private func refreshQuotaNow() async {
        await withRefresh([.quota]) {
            var expectedAuth: CodexAuth?
            var generation = accountStateGeneration
            do {
                let auth = try await loadValidAuth(preferCached: false)
                // Same reason as the full-refresh path: a relay key must not read
                // ChatGPT quota, even though a stale `tokens` block would let it.
                guard QuotaEligibility.canReportQuota(auth) else {
                    statusText = l10n.text(.planAPI)
                    return
                }
                expectedAuth = auth
                generation = accountStateGeneration
                let quotaSnapshot = try await services.fetchQuota(auth)
                guard isCurrentAccount(auth, generation: generation) else { return }
                latestQuota = quotaSnapshot
                applyQuota(quotaSnapshot)
                deliverAlerts(RunwayAlertDecider.quotaAlerts(quotaSnapshot), enabled: settings.preferences.quotaAlertsEnabled)
                lastError = nil
                exportStatusIfNeeded()
            } catch {
                guard generation == accountStateGeneration else { return }
                if let expectedAuth, !isCurrentAccount(expectedAuth, generation: generation) { return }
                if handleAuthenticationFailure(error) { return }
                statusText = l10n.text(.statusError)
                quotaText = l10n.text(.statusError)
                quotaLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                lastError = error.localizedDescription
            }
        }
        if settings.preferences.showsQuotaEstimateSummary,
           let quota = latestQuota,
           let auth = latestAuth
        {
            await loadQuotaEstimate(auth: auth, quota: quota)
        }
    }

    func refreshQuotaEstimateNow() async {
        var expectedGeneration = accountStateGeneration
        var expectedAuth: CodexAuth?
        do {
            let auth = try await loadValidAuth(preferCached: true)
            expectedAuth = auth
            expectedGeneration = accountStateGeneration
            var quota = latestQuota
            if quota == nil {
                let snapshot = try await services.fetchQuota(auth)
                guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
                latestQuota = snapshot
                applyQuota(snapshot)
                quota = snapshot
            }
            guard let quota else { return }
            await loadQuotaEstimate(auth: auth, quota: quota)
        } catch {
            guard expectedGeneration == accountStateGeneration else { return }
            if let expectedAuth, !isCurrentAccount(expectedAuth, generation: expectedGeneration) { return }
            if handleAuthenticationFailure(error) { return }
            quotaEstimateError = error.localizedDescription
        }
    }

    private func loadQuotaEstimate(auth: CodexAuth, quota: QuotaSnapshot) async {
        let expectedGeneration = accountStateGeneration
        await withRefresh([.quotaEstimate]) {
            do {
                let range = QuotaEstimateCalculator.analyticsRange()
                let summary = try await services.fetchDailyWorkspaceUsage(
                    auth,
                    range.start,
                    range.end,
                    range.window,
                    Date())
                guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
                latestQuotaEstimateDaily = summary
                applyQuotaEstimate(quota: quota, daily: summary, persist: true)
                quotaEstimateError = nil
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
                if handleAuthenticationFailure(error) { return }
                quotaEstimateError = error.localizedDescription
            }
        }
    }

    /// The local fit for the active plan, re-evaluated with the live percentage.
    ///
    /// Returns nil when no local window matches a live weekly meter, so the caller
    /// can fall back to the fit's own (staler) percentage rather than inventing one.
    func restatedLocalAllowance() -> LocalQuotaAllowance? {
        // The plan decides which window belongs to the account on screen. Without
        // this, a machine that has used two plans (say `team` and `plus`) would show
        // whichever was fitted most recently, regardless of which account is active.
        guard let plan = latestQuota?.plan else { return nil }
        let candidates = localAllowances.filter { $0.plan.caseInsensitiveCompare(plan) == .orderedSame }
        guard let allowance = candidates.first else { return nil }

        // Only a meter of the same window length can restate it: a 5-hour meter's
        // percentage says nothing about a weekly window.
        let live = quotaMeters.first { meter in
            meter.windowMinutes == allowance.windowMinutes
        }
        guard let live else { return allowance }
        return allowance.restated(usedPercent: Double(live.usedPercent))
    }

    private func applyQuotaEstimate(
        quota: QuotaSnapshot,
        daily: ApiEquivalentSummary,
        persist: Bool)
    {
        let accountKey = accountIdentityKey(for: latestAuth) ?? "unknown"
        let history = quotaEstimateHistoryStore.load(accountKey: accountKey)
        var snapshot = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: daily.dailyRows,
            mode: settings.preferences.quotaEstimateWindowMode,
            history: history,
            now: daily.calculatedAt)
        if persist, let sample = QuotaEstimateCalculator.sample(from: snapshot) {
            snapshot.history = quotaEstimateHistoryStore.upsert(accountKey: accountKey, sample: sample)
        }
        quotaEstimate = snapshot
    }

    private func refreshResetCreditsNow() async {
        await withRefresh([.resetCredits]) {
            var expectedAuth: CodexAuth?
            var generation = accountStateGeneration
            do {
                let auth = try await loadValidAuth(preferCached: true)
                // Same reason as the full-refresh path: reset credits are read with the
                // credential's OAuth token, which a relay key file may still carry from
                // an earlier account.
                guard QuotaEligibility.canReportQuota(auth) else { return }
                expectedAuth = auth
                generation = accountStateGeneration
                let snapshot = try await services.fetchResetCredits(auth)
                guard isCurrentAccount(auth, generation: generation) else { return }
                latestResetCredits = snapshot
                applyResetCredits(snapshot)
                deliverAlerts(RunwayAlertDecider.resetCreditAlerts(snapshot), enabled: settings.preferences.resetCreditAlertsEnabled)
                lastError = nil
                exportStatusIfNeeded()
            } catch {
                guard generation == accountStateGeneration else { return }
                if let expectedAuth, !isCurrentAccount(expectedAuth, generation: generation) { return }
                if handleAuthenticationFailure(error) { return }
                resetCreditsText = l10n.text(.statusError)
                resetCreditLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                lastError = error.localizedDescription
            }
        }
    }

    private func refreshRateLimitResetTodayIfDue(now: Date) {
        guard needsRateLimitResetTodayData else { return }
        guard !isRefreshing(.rateLimitResetToday) else { return }
        let interval = TimeInterval(settings.preferences.rateLimitResetTodayRefreshIntervalSeconds)
        if let last = lastRateLimitResetTodayFetch, now.timeIntervalSince(last) < interval {
            return
        }
        refreshRateLimitResetToday(force: false)
    }

    private func refreshRateLimitResetTodayDisplayIfNeeded(now: Date) {
        guard let snapshot = rateLimitResetToday else { return }
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        // Re-check approaching scheduled resets on the local timer between network refreshes.
        deliverAlerts(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: snapshot,
                current: snapshot,
                now: now,
                calendar: calendar),
            enabled: settings.preferences.rateLimitResetTodayAlertsEnabled)
        let state = snapshot.resolvedState(now: now, calendar: calendar)
        let stateText = rateLimitResetTodaySummaryText(snapshot, state: state, now: now)
        if rateLimitResetTodayText != stateText {
            rateLimitResetTodayText = stateText
        }
        let hintText = rateLimitResetTodayHintText(snapshot, now: now)
        guard let statusIndex = rateLimitResetTodayLines.firstIndex(where: {
            $0.title == l10n.text(.status)
        }), rateLimitResetTodayLines[statusIndex].value != hintText
        else {
            return
        }
        var lines = rateLimitResetTodayLines
        lines[statusIndex] = DetailLine(title: l10n.text(.status), value: hintText)
        // Rebuild next-schedule line when local midnight changes the answer context.
        if let next = snapshot.nextScheduledReset(now: now) {
            let nextValue = rateLimitResetScheduleText(next, calendar: calendar)
            if let nextIndex = lines.firstIndex(where: { $0.title == l10n.text(.rateLimitResetTodayNextScheduled) }) {
                lines[nextIndex] = DetailLine(
                    title: l10n.text(.rateLimitResetTodayNextScheduled),
                    value: nextValue)
            } else {
                lines.insert(
                    DetailLine(
                        title: l10n.text(.rateLimitResetTodayNextScheduled),
                        value: nextValue),
                    at: min(1, lines.count))
            }
        } else {
            lines.removeAll { $0.title == l10n.text(.rateLimitResetTodayNextScheduled) }
        }
        rateLimitResetTodayLines = lines
    }

    private func refreshRateLimitResetTodayNow(force: Bool) async {
        guard needsRateLimitResetTodayData else { return }
        if !force,
           let last = lastRateLimitResetTodayFetch
        {
            let interval = TimeInterval(settings.preferences.rateLimitResetTodayRefreshIntervalSeconds)
            if Date().timeIntervalSince(last) < interval { return }
        }
        await withRefresh([.rateLimitResetToday]) {
            do {
                let snapshot = try await services.fetchRateLimitResetToday()
                applyRateLimitResetToday(snapshot)
                lastRateLimitResetTodayFetch = Date()
            } catch {
                lastRateLimitResetTodayFetch = Date()
                // Keep the last good snapshot; only mark error text when nothing is loaded yet.
                if rateLimitResetToday == nil {
                    rateLimitResetTodayText = l10n.text(.statusError)
                    rateLimitResetTodayLines = [
                        DetailLine(title: l10n.text(.error), value: error.localizedDescription),
                    ]
                }
            }
        }
    }

    private func beginRateLimitResetTodayReactionSession() {
        isRateLimitResetTodayReactionFresh = false
        isRateLimitResetTodayReactionLoading = true
        rateLimitResetTodayReactionDelta = .none
        startRateLimitResetTodayReactionPolling()
    }

    private func endRateLimitResetTodayReactionSession() {
        reactionPollTask?.cancel()
        reactionPollTask = nil
        isRateLimitResetTodayReactionFresh = false
        isRateLimitResetTodayReactionLoading = false
        rateLimitResetTodayReactionDelta = .none
    }

    private func startRateLimitResetTodayReactionPolling() {
        reactionPollTask?.cancel()
        reactionPollTask = Task { [weak self] in
            await self?.runRateLimitResetTodayReactionPolling()
        }
    }

    private func runRateLimitResetTodayReactionPolling() async {
        // One fetch on open, then wait pollMs before the next. Closing the
        // panel cancels this task so a hidden popover never hits the site.
        while isRateLimitResetTodayReactionBusy, !Task.isCancelled, reactionPollingDesired {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if Task.isCancelled || !reactionPollingDesired { return }
        await loadRateLimitResetTodayReaction()
        while !Task.isCancelled, reactionPollingDesired {
            let nanoseconds = UInt64((rateLimitResetTodayReaction?.pollInterval ?? 5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled || !reactionPollingDesired { break }
            if isRateLimitResetTodayReactionBusy { continue }
            await loadRateLimitResetTodayReaction()
        }
    }

    private func loadRateLimitResetTodayReaction() async {
        if isRateLimitResetTodayReactionBusy { return }
        let generation = reactionWriteGeneration
        let previousCount = rateLimitResetTodayReaction?.count
        let previousEpoch = rateLimitResetTodayReaction?.epochId
        let announceDelta = isRateLimitResetTodayReactionFresh
        if !announceDelta {
            isRateLimitResetTodayReactionLoading = true
        }
        do {
            let snapshot = try await services.fetchRateLimitResetTodayReaction()
            guard !Task.isCancelled else { return }
            guard generation == reactionWriteGeneration, !isRateLimitResetTodayReactionBusy else { return }
            applyRateLimitResetTodayReaction(
                snapshot,
                previousCount: previousCount,
                previousEpoch: previousEpoch,
                announceDelta: announceDelta)
            isRateLimitResetTodayReactionFresh = true
            isRateLimitResetTodayReactionLoading = false
        } catch RateLimitResetTodayReactionError.disabled {
            guard generation == reactionWriteGeneration else { return }
            isReactionDisabled = true
            rateLimitResetTodayReaction = nil
            isRateLimitResetTodayReactionLoading = false
            isRateLimitResetTodayReactionFresh = false
            reactionPollTask?.cancel()
            reactionPollTask = nil
        } catch {
            isRateLimitResetTodayReactionLoading = false
        }
    }

    private func clickRateLimitResetTodayReactionNow(_ current: RateLimitResetTodayReactionSnapshot) async {
        let local = RateLimitResetTodayReactionLocal(
            epochId: current.epochId,
            previousCount: current.count ?? 0,
            previousRemaining: current.remaining)
        let parsed: RateLimitResetTodayReactionPostResult?
        do {
            parsed = try await services.clickRateLimitResetTodayReaction()
        } catch {
            parsed = nil
        }
        let next = RateLimitResetTodayReaction.reconcileAfterPost(local: local, response: parsed)
        var updated = next.payload ?? current
        updated.count = next.count
        if next.exhausted, updated.dailyLimit > 0 {
            updated.remaining = 0
        } else {
            updated.remaining = next.remaining
        }
        rateLimitResetTodayReaction = updated
        isRateLimitResetTodayReactionBusy = false
        if (updated.count ?? 0) > local.previousCount {
            // +1 was already published locally; only float extra live clicks.
            publishReactionDelta(
                RateLimitResetTodayReaction.positiveDelta(
                    previousCount: local.previousCount + 1,
                    nextCount: updated.count,
                    previousEpoch: local.epochId,
                    nextEpoch: updated.epochId))
        } else {
            rateLimitResetTodayReactionDelta = .none
        }
    }

    private func applyRateLimitResetTodayReaction(
        _ snapshot: RateLimitResetTodayReactionSnapshot,
        previousCount: Int?,
        previousEpoch: String?,
        announceDelta: Bool)
    {
        rateLimitResetTodayReaction = snapshot
        guard announceDelta else { return }
        publishReactionDelta(
            RateLimitResetTodayReaction.positiveDelta(
                previousCount: previousCount,
                nextCount: snapshot.count,
                previousEpoch: previousEpoch,
                nextEpoch: snapshot.epochId))
    }

    private func publishReactionDelta(_ amount: Int) {
        guard amount > 0 else { return }
        rateLimitResetTodayReactionDelta = RateLimitResetTodayReactionDelta(amount: amount)
    }

    private func applyRateLimitResetToday(_ snapshot: RateLimitResetTodaySnapshot) {
        let previous = rateLimitResetToday
        rateLimitResetToday = snapshot
        let now = Date()
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        let state = snapshot.resolvedState(now: now, calendar: calendar)
        rateLimitResetTodayText = rateLimitResetTodaySummaryText(snapshot, state: state, now: now)
        deliverAlerts(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: previous,
                current: snapshot,
                now: now,
                calendar: calendar),
            enabled: settings.preferences.rateLimitResetTodayAlertsEnabled)
        var lines: [DetailLine] = [
            DetailLine(title: l10n.text(.status), value: rateLimitResetTodayHintText(snapshot, now: now)),
        ]
        if let next = snapshot.nextScheduledReset(now: now) {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayNextScheduled),
                    value: rateLimitResetScheduleText(next, calendar: calendar)))
        }
        if let checkedAt = snapshot.lastSuccessfulCheckAt {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayLastCheck),
                    value: DurationFormatter.relativePast(since: checkedAt, language: l10n.language)))
        }
        if let evidence = snapshot.evidenceLine(l10n: l10n, now: now, calendar: calendar) {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayLatestEvidence),
                    value: evidence))
        }
        if let event = snapshot.primaryEvidenceEvent(now: now, calendar: calendar),
           let scope = snapshot.scopeSummary(for: event, l10n: l10n)
        {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayPlans),
                    value: scope))
        }
        if let event = snapshot.primaryEvidenceEvent(now: now, calendar: calendar) {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayConfidence),
                    value: "\(Int((event.confidence * 100).rounded()))%"))
        }
        if let latestReset = snapshot.latestReset(now: now) {
            let when = ResetLabelFormatter.shortLabel(
                for: latestReset.at,
                now: now,
                language: l10n.language,
                calendar: calendar)
            lines.append(
                DetailLine(
                    title: l10n.text(.lastReset),
                    value: "\(latestReset.resetType.localizedName(l10n: l10n)) · \(when)"))
        }
        lines.append(
            DetailLine(
                title: l10n.text(.rateLimitResetTodayLastFetched),
                value: DurationFormatter.relativePast(since: snapshot.fetchedAt, language: l10n.language)))
        rateLimitResetTodayLines = lines
    }

    private func rateLimitResetTodayStateText(_ state: RateLimitResetTodayState) -> String {
        switch state {
        case .yes:
            return l10n.text(.rateLimitResetTodayYes)
        case .no:
            return l10n.text(.rateLimitResetTodayNo)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknown)
        }
    }

    private func rateLimitResetTodaySummaryText(
        _ snapshot: RateLimitResetTodaySnapshot,
        state: RateLimitResetTodayState,
        now: Date) -> String
    {
        if state == .unknown {
            return rateLimitResetTodayStateText(state)
        }
        let presentation = snapshot.verdictPresentation(now: now)
        let title = presentation.titleText(l10n: l10n)
        guard let resetType = presentation.resetType ?? snapshot.displayResetType(now: now) else {
            return title
        }
        return "\(title) · \(resetType.localizedName(l10n: l10n))"
    }

    private func rateLimitResetScheduleText(
        _ next: (
            effectiveAt: Date,
            effectiveUntil: Date,
            isRange: Bool,
            event: RateLimitResetTodayEvent),
        calendar: Calendar) -> String
    {
        let when = ResetLabelFormatter.scheduledLabel(
            for: RateLimitResetScheduleWindow(
                startAt: next.effectiveAt,
                endAt: next.effectiveUntil,
                isRange: next.isRange),
            language: l10n.language,
            calendar: calendar)
        return "\(next.event.resetType.localizedName(l10n: l10n)) · \(when)"
    }

    private func rateLimitResetTodayHintText(
        _ snapshot: RateLimitResetTodaySnapshot,
        now: Date) -> String
    {
        if let detail = snapshot.verdictDetail(l10n: l10n, now: now) {
            return detail.plainText
        }
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        switch snapshot.resolvedState(now: now, calendar: calendar) {
        case .yes:
            if snapshot.prefersSameDayScheduleExplanation(now: now, calendar: calendar),
               let next = snapshot.nextScheduledReset(onLocalDayOf: now, calendar: calendar)
            {
                let when = ResetLabelFormatter.scheduledLabel(
                    for: RateLimitResetScheduleWindow(
                        startAt: next.effectiveAt,
                        endAt: next.effectiveUntil,
                        isRange: next.isRange),
                    language: l10n.language,
                    calendar: calendar)
                let hint = switch next.event.resetType {
                case .global:
                    String(format: l10n.text(.rateLimitResetTodayYesHintScheduledWithTime), when)
                case .banked:
                    "\(l10n.text(.rateLimitResetTodayBankedScheduledHint)) · \(when)"
                case .globalAndBanked:
                    "\(l10n.text(.rateLimitResetTodayGlobalAndBankedScheduledHint)) · \(when)"
                }
                return hint
            }
            if let latestReset = snapshot.latestReset(now: now) {
                let when = ResetLabelFormatter.shortLabel(
                    for: latestReset.at,
                    now: now,
                    language: l10n.language,
                    calendar: calendar)
                let displayType = snapshot.displayResetType(now: now, calendar: calendar)
                    ?? latestReset.resetType
                return switch displayType {
                case .global:
                    String(format: l10n.text(.rateLimitResetTodayYesHintWithTime), when)
                case .banked:
                    "\(l10n.text(.rateLimitResetTodayBankedCompletedHint)) · \(when)"
                case .globalAndBanked:
                    "\(l10n.text(.rateLimitResetTodayGlobalAndBankedCompletedHint)) · \(when)"
                }
            }
            return l10n.text(.rateLimitResetTodayYesHint)
        case .no:
            if let next = snapshot.nextScheduledReset(now: now) {
                let when = ResetLabelFormatter.scheduledLabel(
                    for: RateLimitResetScheduleWindow(
                        startAt: next.effectiveAt,
                        endAt: next.effectiveUntil,
                        isRange: next.isRange),
                    language: l10n.language,
                    calendar: calendar)
                return String(format: l10n.text(.rateLimitResetTodayNoHintWithNext), when)
            }
            if snapshot.hasUncertainNoSignalToday(now: now, calendar: calendar) {
                return l10n.text(.rateLimitResetTodayNoHintUncertain)
            }
            if let unconfirmed = snapshot.unconfirmedScheduleHint(
                l10n: l10n,
                now: now,
                calendar: calendar)
            {
                return unconfirmed.text
            }
            if let last = snapshot.noneHintLastReset(l10n: l10n, now: now) {
                return last.text
            }
            return l10n.text(.rateLimitResetTodayNoHint)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknownHint)
        }
    }

    private func refreshCostNow(policy: UsageCostRefreshPolicy) async {
        var expectedAuth: CodexAuth?
        var generation = accountStateGeneration
        do {
            let auth = try await loadValidAuth(preferCached: true)
            expectedAuth = auth
            generation = accountStateGeneration
            let quotaSnapshot = try await services.fetchQuota(auth)
            guard isCurrentAccount(auth, generation: generation) else { return }
            latestQuota = quotaSnapshot
            applyQuota(quotaSnapshot)
            await scanCostAndHeatmap(
                quotaSnapshot,
                auth: auth,
                policy: policy,
                includeCost: true,
                includeHeatmap: false)
            guard isCurrentAccount(auth, generation: generation) else { return }
            markCostRefreshCompleted(quota: quotaSnapshot)
            lastError = nil
        } catch {
            guard generation == accountStateGeneration else { return }
            if let expectedAuth, !isCurrentAccount(expectedAuth, generation: generation) { return }
            if handleAuthenticationFailure(error) { return }
            if latestDisplayedCost != nil {
                noteCostScanFailure(error.localizedDescription)
            } else {
                clearDisplayedCost(l10n.text(.usageAnalyticsUnavailable))
                costLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
            }
            lastError = error.localizedDescription
        }
    }

    private func shouldRefreshCost(
        policy: UsageCostRefreshPolicy,
        quota: QuotaSnapshot? = nil,
        now: Date = Date()
    ) -> Bool {
        guard policy == .ifChanged, let lastCostRefreshCompletedAt else { return true }
        if let quota, costCycleIdentity(for: quota) != lastCostCycleIdentity { return true }
        let interval = TimeInterval(settings.preferences.refreshIntervalSeconds)
        return now >= lastCostRefreshCompletedAt.addingTimeInterval(interval)
    }

    private func markCostRefreshCompleted(quota: QuotaSnapshot, at completion: Date = Date()) {
        lastCostRefreshCompletedAt = completion
        lastCostCycleIdentity = costCycleIdentity(for: quota)
    }

    private func shouldRefreshTokenHeatmap(
        policy: UsageCostRefreshPolicy,
        now: Date = Date()
    ) -> Bool {
        guard policy == .ifChanged, let lastTokenHeatmapRefreshCompletedAt else { return true }
        let interval = TimeInterval(settings.preferences.refreshIntervalSeconds)
        return now >= lastTokenHeatmapRefreshCompletedAt.addingTimeInterval(interval)
    }

    private func markTokenHeatmapRefreshCompleted(at completion: Date = Date()) {
        lastTokenHeatmapRefreshCompletedAt = completion
    }

    private func refreshTokenHeatmapNow(policy: UsageCostRefreshPolicy) async {
        if isAPIKeyAccount {
            await refreshRelayTokenHeatmap()
            return
        }
        do {
            let auth = try await loadValidAuth(preferCached: true)
            try await scanTokenHeatmap(auth: auth, policy: policy)
            markTokenHeatmapRefreshCompleted()
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            // Keep previous grid when a refresh fails; first load stays empty.
            if tokenHeatmapAllDevicesTokens.isEmpty, tokenHeatmapLocalTokens.isEmpty {
                tokenHeatmapCalculatedAt = Date()
            }
            lastError = l10n.text(.tokenUsageHeatmapUnavailable)
        }
    }

    /// A relay account has no ChatGPT profile activity. The grid is the daily
    /// buckets already fetched with the balance (`/api/data/self`), not the
    /// official/local Codex pair the tooltip would otherwise describe.
    private func refreshRelayTokenHeatmap() async {
        if let id = activeAccountId {
            let generation = accountStateGeneration
            let result = await accountQuotaRefresher.refresh(accountId: id)
            applyAccountQuotaRefreshResults([result], generation: generation)
        } else {
            applyRelayHeatmapFromCache()
        }
        markTokenHeatmapRefreshCompleted()
        lastError = nil
    }

    private func applyRelayHeatmapFromCache() {
        guard isAPIKeyAccount else { return }
        let account = managedAccounts.first(where: { $0.id == activeAccountId })
        let days = account?.cachedQuota?.newAPI?.tokensByDay ?? [:]
        let asOf = account?.lastQuotaAt
        applyTokenHeatmap(
            allDevices: days,
            local: [:],
            officialStatsAsOf: asOf.map { NewAPIDailyUsage.dayKey($0) },
            officialGeneratedAt: asOf,
            now: Date())
    }

    private func scanTokenHeatmap(auth: CodexAuth, policy: UsageCostRefreshPolicy) async throws {
        let expectedGeneration = accountStateGeneration
        let now = Date()
        let window = TokenUsageHeatmapBuilder.utcYearToDateWindow(now: now)
        let query = ApiCostQuery(
            id: Self.tokenHeatmapQueryID,
            window: window,
            dayBoundary: .utc)

        // Collect both independent series. The official profile activity endpoint
        // has a different token definition from workspace analytics.
        let local = try await localCostSummaries(queries: [query], now: now, policy: policy)
        let localMap = local[Self.tokenHeatmapQueryID].map(dailyTokenMap(from:)) ?? [:]
        try Task.checkCancellation()
        guard isCurrentAccount(auth, generation: expectedGeneration) else {
            throw CancellationError()
        }
        applyLocalTokenHeatmap(localMap, now: now)
        try await fetchAndApplyProfileTokenHeatmap(TokenHeatmapRemoteRequest(
            auth: auth,
            localTokens: localMap,
            calculatedAt: now,
            accountGeneration: expectedGeneration))
    }

    private func dailyTokenMap(from summary: ApiEquivalentSummary) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(summary.dailyRows.count)
        for row in summary.dailyRows {
            map[row.date, default: 0] += max(0, row.totals.totalTokens)
        }
        return map
    }

    private func applyTokenHeatmap(
        allDevices: [String: Int],
        local: [String: Int],
        officialStatsAsOf: String?,
        officialGeneratedAt: Date?,
        now: Date
    ) {
        if allDevices != tokenHeatmapAllDevicesTokens {
            tokenHeatmapAllDevicesTokens = allDevices
        }
        if local != tokenHeatmapLocalTokens {
            tokenHeatmapLocalTokens = local
        }
        tokenHeatmapOfficialStatsAsOf = officialStatsAsOf
        tokenHeatmapOfficialGeneratedAt = officialGeneratedAt
        tokenHeatmapCalculatedAt = now
    }

    private func applyLocalTokenHeatmap(_ local: [String: Int], now: Date) {
        if local != tokenHeatmapLocalTokens {
            tokenHeatmapLocalTokens = local
        }
        tokenHeatmapCalculatedAt = now
    }

    private func costCycleIdentity(for quota: QuotaSnapshot) -> CostCycleIdentity {
        CostCycleIdentity(
            reset: quota.secondary?.resetsAt,
            windowMinutes: quota.secondary?.windowMinutes)
    }

    func queryCost(range: ApiCostRange) async throws -> ApiEquivalentSummary {
        let key = Self.detailCacheKey(for: range)
        if let cached = detailCostCache[key] {
            return cached
        }

        let task: Task<ApiEquivalentSummary, Error>
        if let existing = detailCostInFlight[key] {
            task = existing
        } else {
            // Unstructured so navigating away does not cancel the scan; results land in cache.
            task = Task { @MainActor in
                defer { self.detailCostInFlight[key] = nil }
                let summary = try await self.performDetailCostQuery(range: range)
                self.storeDetailCostCache(summary, key: key)
                return summary
            }
            detailCostInFlight[key] = task
        }

        return try await task.value
    }

    /// Loads current-cycle cost for the detail page without treating a missing
    /// snapshot as an immediate hard failure.
    func queryCurrentCycleCost() async throws -> ApiEquivalentSummary {
        let now = Date()
        let range = try await resolveCurrentCycleCostRange(now: now)
        // Reuse an in-memory current-cycle snapshot only when its window still matches.
        if let costDetail,
           costDetail.isDisplayableCost,
           Self.costWindow(costDetail.window, matches: range.window)
        {
            return costDetail
        }
        return try await queryCost(range: range)
    }

    private static func costWindow(
        _ snapshot: DateInterval,
        matches requested: DateInterval
    ) -> Bool {
        abs(snapshot.start.timeIntervalSince(requested.start)) < 60
            && abs(snapshot.end.timeIntervalSince(requested.end)) < 120
    }

    func previousCycleCostRange() -> ApiCostRange? {
        latestCurrentCycleFullWindow.map { ApiCostRange.previousCycle(from: $0) }
    }

    /// Resolves the previous quota cycle window, fetching quota first when needed.
    func resolvePreviousCycleCostRange() async throws -> ApiCostRange {
        if let range = previousCycleCostRange() { return range }
        let full = try await ensureCurrentCycleFullWindow()
        return ApiCostRange.previousCycle(from: full)
    }

    private func resolveCurrentCycleCostRange(now: Date = Date()) async throws -> ApiCostRange {
        let windows = try await ensureCurrentCycleWindows(now: now)
        return .range(window: windows.elapsed)
    }

    private func ensureCurrentCycleFullWindow(now: Date = Date()) async throws -> DateInterval {
        try await ensureCurrentCycleWindows(now: now).full
    }

    private func ensureCurrentCycleWindows(now: Date = Date()) async throws -> (full: DateInterval, elapsed: DateInterval) {
        // Guards the cost window, which is defined by Codex quota resets; a relay key
        // has none.
        guard !isAPIKeyAccount else { throw QuotaError.notApplicable }
        if let latestQuota, let windows = currentCycleWindows(from: latestQuota, now: now) {
            latestCurrentCycleFullWindow = windows.full
            return windows
        }
        beginCostProgress()
        defer { endCostProgress() }
        publishCostProgress(.preparing, force: true)
        let auth = try await loadValidAuth(preferCached: true)
        let generation = accountStateGeneration
        let quotaSnapshot: QuotaSnapshot
        do {
            quotaSnapshot = try await services.fetchQuota(auth)
        } catch {
            if isCurrentAccount(auth, generation: generation) { handleAuthenticationFailure(error) }
            throw error
        }
        guard isCurrentAccount(auth, generation: generation) else { throw CancellationError() }
        latestQuota = quotaSnapshot
        applyQuota(quotaSnapshot)
        if let windows = currentCycleWindows(from: quotaSnapshot, now: now) {
            latestCurrentCycleFullWindow = windows.full
            return windows
        }
        // Soft fallback: treat the last 7 days as the current cycle so local scans
        // still work when quota payloads omit reset/window metadata.
        let week: TimeInterval = 7 * 24 * 3_600
        let fallbackFull = DateInterval(start: now.addingTimeInterval(-week), end: now)
        latestCurrentCycleFullWindow = fallbackFull
        return (fallbackFull, fallbackFull)
    }

    private func performDetailCostQuery(range: ApiCostRange) async throws -> ApiEquivalentSummary {
        let now = Date()
        beginCostProgress()
        defer { endCostProgress() }
        publishCostProgress(.preparing, force: true)
        let auth = try await loadValidAuth(preferCached: true)
        return try await queryCost(range: range, auth: auth, now: now, useSharedFlight: true)
    }

    private func queryCost(
        range: ApiCostRange,
        auth: CodexAuth,
        now: Date,
        useSharedFlight: Bool
    ) async throws -> ApiEquivalentSummary {
        // Guard inverted/empty windows that always produce "unavailable".
        guard range.window.end > range.window.start else {
            throw CostRangeQueryError.usageUnavailable
        }
        let query = ApiCostQuery(id: Self.detailCostQueryID, window: range.window)
        let local: ApiEquivalentSummary?
        do {
            local = try await services.scanAPIEquivalent(
                [query],
                now,
                .ifChanged,
                useSharedFlight ? costProgressReporter : nil)[query.id]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            local = nil
        }
        return try await resolveCost(local: local, range: range, auth: auth, now: now)
    }

    private func resolveCost(
        local: ApiEquivalentSummary?,
        range: ApiCostRange,
        auth: CodexAuth,
        now: Date
    ) async throws -> ApiEquivalentSummary {
        try Task.checkCancellation()
        if let local, local.isDisplayableCost { return local }
        publishCostProgress(.fetchingOnline, force: true)
        do {
            let summary = try await services.fetchDailyWorkspaceUsage(
                auth,
                range.apiStartDate,
                range.apiEndDate,
                range.window,
                now)
            try Task.checkCancellation()
            if summary.isDisplayableCost { return summary }
            if let local { return local }
            return summary
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let local { return local }
            throw CostRangeQueryError.usageUnavailable
        }
    }

    private func beginCostProgress() {
        costProgressConsumers += 1
        if costProgressConsumers == 1 {
            publishCostProgress(.preparing, force: true)
        }
    }

    private func endCostProgress() {
        costProgressConsumers = max(0, costProgressConsumers - 1)
        if costProgressConsumers == 0 {
            publishCostProgress(.finished, force: true)
            // Idle shortly after so UI can clear loading chrome.
            costProgress.progress = .idle
        }
    }

    private func publishCostProgress(_ progress: CostScanProgress, force: Bool = false) {
        if force || progress.phase != costScanProgress.phase || progress.completedUnits != costScanProgress.completedUnits {
            costProgress.progress = progress
        }
    }

    private func storeDetailCostCache(_ summary: ApiEquivalentSummary, key: String) {
        // Do not pin failed/empty scans forever; empty ranges should re-query next visit.
        guard summary.isDisplayableCost else { return }
        if detailCostCache[key] == nil {
            detailCostCacheOrder.append(key)
        }
        detailCostCache[key] = summary
        while detailCostCacheOrder.count > Self.detailCostCacheLimit {
            let evicted = detailCostCacheOrder.removeFirst()
            detailCostCache.removeValue(forKey: evicted)
        }
    }

    private static func detailCacheKey(for range: ApiCostRange) -> String {
        "\(range.apiStartDate)|\(range.apiEndDate)|\(range.window.start.timeIntervalSince1970)|\(range.window.end.timeIntervalSince1970)"
    }

    private func loadValidAuth(preferCached: Bool) async throws -> CodexAuth {
        let generation = accountStateGeneration
        do {
            var auth = try await services.loadValidAuth(preferCached, latestAuth)
            if !auth.isAPIKeyAuth, TokenInspector.isExpired(auth.tokens.accessToken),
               let activeAccountId {
                auth = try await accountSwitcher.ensureValidCredential(accountId: activeAccountId)
            }
            guard generation == accountStateGeneration else { throw CancellationError() }
            let previousAccountId = accountIdentityKey(for: latestAuth)
            let nextAccountId = accountIdentityKey(for: auth)
            latestAuth = auth
            // Only attach quota plan when it belongs to the same account identity.
            // Otherwise a switch leaves the previous tier (e.g. Pro 5X) painted on Free.
            let planHint = (previousAccountId != nil && previousAccountId == nextAccountId)
                ? latestQuota?.plan
                : nil
            if previousAccountId != nextAccountId {
                clearAccountScopedState(keepingAuth: auth)
            } else {
                accountDisplay = CodexAccountDisplay.make(auth: auth, quotaPlan: planHint)
            }
            // The switcher owns token persistence. Polling must not mirror a
            // possibly stale credential back into the managed or official store.
            return auth
        } catch RunwayModelAuthError.load(let error) {
            guard generation == accountStateGeneration else { throw CancellationError() }
            clearAccountScopedState(keepingAuth: nil)
            lastError = humanizeAuthError(error)
            exportStatusIfNeeded()
            throw error
        } catch {
            guard generation == accountStateGeneration else { throw CancellationError() }
            handleAuthenticationFailure(error)
            throw error
        }
    }

    /// Wipe meters / quota / credits that are bound to the previously active account.
    private func clearAccountScopedState(keepingAuth auth: CodexAuth?) {
        accountStateGeneration += 1
        latestQuota = nil
        latestResetCredits = nil
        latestQuotaEstimateDaily = nil
        quotaEstimate = nil
        quotaEstimateError = nil
        latestCost = nil
        latestDisplayedCost = nil
        latestDisplayedCostRange = nil
        latestCurrentCycleFullWindow = nil
        lastCostRefreshCompletedAt = nil
        lastCostCycleIdentity = nil
        lastTokenHeatmapRefreshCompletedAt = nil
        detailCostCache = [:]
        detailCostCacheOrder = []
        tokenHeatmapAllDevicesTokens = [:]
        tokenHeatmapLocalTokens = [:]
        tokenHeatmapCalculatedAt = nil
        tokenHeatmapOfficialStatsAsOf = nil
        tokenHeatmapOfficialGeneratedAt = nil
        quotaMeters = []
        quotaLines = []
        resetCreditSummary = nil
        resetCreditDetails = []
        resetCreditLines = []
        costDetail = nil
        costText = l10n.text(.notScanned)
        costSubtitle = ""
        quotaText = l10n.text(.notLoaded)
        resetCreditsText = l10n.text(.notLoaded)
        // The label has to suit the account that is arriving, not the one that left.
        // A relay key has no ChatGPT session to be "not signed in" to, and the meters
        // below have just been cleared, so the old account's percentages must not stay
        // on screen under the new account's name.
        //
        // Read from the credential being installed rather than from `isAPIKeyAccount`:
        // this runs *before* the index is published, so `activeAccountId` still names
        // the account being left.
        statusText = (auth?.isAPIKeyAuth == true) ? l10n.text(.planAPI) : l10n.text(.statusLogin)
        latestAuth = auth
        accountDisplay = CodexAccountDisplay.make(auth: auth, quotaPlan: nil)
    }

    private func accountIdentityKey(for auth: CodexAuth?) -> String? {
        guard let auth else { return nil }
        return AccountIdentity.matchKey(for: auth)
    }

    private func isCurrentAccount(_ auth: CodexAuth, generation: Int) -> Bool {
        generation == accountStateGeneration
            && accountIdentityKey(for: auth) == accountIdentityKey(for: latestAuth)
    }

    private func applyQuota(_ quota: QuotaSnapshot) {
        accountDisplay = CodexAccountDisplay.make(auth: latestAuth, quotaPlan: quota.plan)
        statusText = menuBarText(for: quota, now: quota.updatedAt)
        let unknown = l10n.text(.unknown)
        let primaryTitle = quotaWindowTitle(quota.primary)
        let secondary = quota.secondary.map { "\(l10n.text(.weeklyUsage)) \($0.usedPercent)%" } ?? "\(l10n.text(.weeklyUsage)) n/a"
        quotaText = "\(l10n.text(.plan)) \(quota.plan ?? unknown) · \(primaryTitle) \(quota.primary.usedPercent)% · \(secondary)"
        quotaMeters = quotaMeters(from: quota)
        quotaLines = [
            DetailLine(title: l10n.text(.plan), value: quota.plan ?? unknown),
            DetailLine(title: primaryTitle, value: windowText(quota.primary, now: quota.updatedAt)),
        ]
        if let secondary = quota.secondary {
            quotaLines.append(DetailLine(title: l10n.text(.weeklyUsage), value: windowText(secondary, now: quota.updatedAt)))
        }
        for extra in visibleAdditionalQuotaWindows(from: quota) {
            quotaLines.append(DetailLine(title: extra.name, value: windowText(extra.window, now: quota.updatedAt)))
        }
        if let balance = quota.creditsBalance {
            quotaLines.append(DetailLine(title: l10n.text(.creditsBalance), value: String(format: "%.2f", balance)))
        }
    }

    private func applyResetCredits(_ snapshot: ResetCreditsSnapshot) {
        let next = snapshot.credits
            .filter { $0.status == "available" }
            .compactMap(\.expiresAt)
            .min()
        latestResetCredits = snapshot
        resetCreditSummary = ResetCreditSummary(snapshot: snapshot)
        let suffix = next.map { " · \(l10n.text(.left)) \(duration($0.timeIntervalSince(snapshot.updatedAt)))" } ?? ""
        resetCreditsText = "\(snapshot.availableCount) \(l10n.text(.available)) / \(snapshot.credits.count) \(l10n.text(.total))\(suffix)"
        resetCreditLines = [
            DetailLine(title: l10n.text(.available), value: "\(snapshot.availableCount)"),
            DetailLine(title: l10n.text(.total), value: "\(snapshot.credits.count)"),
        ]
        resetCreditLines.append(contentsOf: snapshot.credits.prefix(6).enumerated().map { index, credit in
            let expiry = credit.expiresAt.map {
                "\(Self.displayDate($0)) · \(duration($0.timeIntervalSince(snapshot.updatedAt))) \(l10n.text(.left))"
            } ?? l10n.text(.noExpiry)
            return DetailLine(title: "\(l10n.text(.credit)) \(index + 1)", value: "\(localizedStatus(credit.status)) · \(expiry)")
        })
        resetCreditDetails = ResetCreditSummary.sortedByExpiry(snapshot.credits).enumerated().map { index, credit in
            let remaining = max(0, credit.remainingSeconds)
            let hasExpiry = credit.expiresAt != nil
            return ResetCreditDetail(
                id: credit.id ?? "\(index)",
                title: "\(l10n.text(.credit)) \(index + 1)",
                statusText: localizedStatus(credit.status),
                state: resetCreditState(credit),
                expiresAt: credit.expiresAt,
                remainingDuration: remaining,
                remainingProgress: hasExpiry ? min(1, remaining / (30 * 24 * 3_600)) : 1)
        }
    }

    private func scanCostAndHeatmap(
        _ quota: QuotaSnapshot,
        auth: CodexAuth,
        policy: UsageCostRefreshPolicy,
        includeCost: Bool,
        includeHeatmap: Bool
    ) async {
        let expectedGeneration = accountStateGeneration
        guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
        let now = Date()
        let range = settings.preferences.apiCostSummaryRange
        let currentWindows = currentCycleWindows(from: quota, now: now)
        latestCurrentCycleFullWindow = currentWindows?.full
        let selectedRange = selectedCostRange(for: range, fullWindow: currentWindows?.full, now: now)
        var queries: [ApiCostQuery] = []
        if includeCost {
            queries.append(contentsOf: costQueries(
                currentWindow: currentWindows?.elapsed,
                selectedRange: selectedRange))
        }
        let heatmapWindow = TokenUsageHeatmapBuilder.utcYearToDateWindow(now: now)
        if includeHeatmap {
            queries.append(ApiCostQuery(
                id: Self.tokenHeatmapQueryID,
                window: heatmapWindow,
                dayBoundary: .utc))
        }
        guard !queries.isEmpty else { return }

        beginCostProgress()
        defer { endCostProgress() }
        publishCostProgress(.preparing, force: true)

        do {
            let local = try await localCostSummaries(queries: queries, now: now, policy: policy)
            guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
            if includeCost {
                let current = try await resolveCurrentCost(
                    window: currentWindows?.elapsed,
                    local: local[Self.currentCostQueryID],
                    auth: auth,
                    now: now)
                guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
                if let current {
                    applyCurrentCost(current)
                    if let elapsed = currentWindows?.elapsed {
                        storeDetailCostCache(current, key: Self.detailCacheKey(for: .range(window: elapsed)))
                    }
                }
                let summary = try await resolveDisplayedCost(
                    range: range,
                    selectedRange: selectedRange,
                    current: current,
                    local: local[Self.selectedCostQueryID],
                    auth: auth,
                    now: now)
                try Task.checkCancellation()
                guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
                applyDisplayedCost(summary, range: range, now: now)
                if let selectedRange {
                    storeDetailCostCache(summary, key: Self.detailCacheKey(for: selectedRange))
                }
            }
            if includeHeatmap {
                try Task.checkCancellation()
                let localMap = local[Self.tokenHeatmapQueryID].map(dailyTokenMap(from:)) ?? [:]
                guard isCurrentAccount(auth, generation: expectedGeneration) else {
                    throw CancellationError()
                }
                applyLocalTokenHeatmap(localMap, now: now)
                do {
                    try await fetchAndApplyProfileTokenHeatmap(TokenHeatmapRemoteRequest(
                        auth: auth,
                        localTokens: localMap,
                        calculatedAt: now,
                        accountGeneration: expectedGeneration))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
                    lastError = l10n.text(.tokenUsageHeatmapUnavailable)
                    if tokenHeatmapAllDevicesTokens.isEmpty, tokenHeatmapLocalTokens.isEmpty {
                        tokenHeatmapCalculatedAt = now
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(auth, generation: expectedGeneration) else { return }
            if includeCost {
                let text = costQueryErrorText(error)
                if latestDisplayedCost != nil, latestDisplayedCostRange == range {
                    noteCostScanFailure(text)
                } else {
                    clearDisplayedCost(text)
                }
            }
            if includeHeatmap,
               tokenHeatmapAllDevicesTokens.isEmpty,
               tokenHeatmapLocalTokens.isEmpty
            {
                tokenHeatmapCalculatedAt = now
            }
            if includeHeatmap {
                lastError = l10n.text(.tokenUsageHeatmapUnavailable)
            }
        }
    }

    private func fetchAndApplyProfileTokenHeatmap(
        _ request: TokenHeatmapRemoteRequest
    ) async throws {
        publishCostProgress(.fetchingOnline, force: true)
        let profileUsage = try await services.fetchCodexProfileTokenUsage(request.auth)
        try Task.checkCancellation()
        guard isCurrentAccount(request.auth, generation: request.accountGeneration) else {
            throw CancellationError()
        }
        applyTokenHeatmap(
            allDevices: profileUsage.dailyTokens,
            local: request.localTokens,
            officialStatsAsOf: profileUsage.statsAsOf,
            officialGeneratedAt: profileUsage.generatedAt,
            now: request.calculatedAt)
    }

    private func finishFullRefresh(id: UUID) {
        guard activeFullRefreshID == id else { return }
        activeFullRefreshID = nil
        fullRefreshWork = nil
        isRefreshingAll = false
        onFullRefreshCompleted?()
        // Piggybacks on the existing cadence: a window's end is not schedulable, so
        // it is discovered by re-reading usage at the same interval as everything
        // else. Detached so a slow CLI cannot hold the refresh pipeline open.
        Task.detached(priority: .utility) { [weak self] in
            await self?.sweepQuotaWindowAutoStart()
        }
    }

    private func finishTokenHeatmapRefresh(id: UUID) {
        guard activeTokenHeatmapRefreshID == id else { return }
        activeTokenHeatmapRefreshID = nil
        tokenHeatmapRefreshWork = nil
        refreshingSections.remove(.tokenHeatmap)
    }

    /// Signals in-flight account-scoped work to stop, without waiting for it.
    /// A full refresh rescans `~/.codex/sessions`, which can span gigabytes, so
    /// waiting here would stall the account switch (and the app relaunch behind
    /// it) for the whole scan. Call `drainAccountScopedRefreshes()` afterwards
    /// to wait the work out before starting new account-scoped work.
    private func signalAccountScopedRefreshCancellation() {
        fullRefreshWork?.cancel()
        tokenHeatmapRefreshWork?.cancel()
    }

    /// Waits for the cancelled refreshes to unwind and clears their bookkeeping.
    private func drainAccountScopedRefreshes() async {
        if let id = activeFullRefreshID, let work = fullRefreshWork {
            await work.value
            finishFullRefresh(id: id)
        }
        if let id = activeTokenHeatmapRefreshID, let work = tokenHeatmapRefreshWork {
            await work.value
            finishTokenHeatmapRefresh(id: id)
        }
    }

    private func cancelAccountScopedRefreshes() async {
        signalAccountScopedRefreshCancellation()
        await drainAccountScopedRefreshes()
    }

    func cancelCodexRefreshesForProviderSwitch() {
        fullRefreshWork?.cancel()
        tokenHeatmapRefreshWork?.cancel()
    }

    private func localCostSummaries(
        queries: [ApiCostQuery],
        now: Date,
        policy: UsageCostRefreshPolicy
    ) async throws -> [String: ApiEquivalentSummary] {
        guard !queries.isEmpty else { return [:] }
        do {
            return try await services.scanAPIEquivalent(queries, now, policy, costProgressReporter)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return [:]
        }
    }

    private func resolveCurrentCost(
        window: DateInterval?,
        local: ApiEquivalentSummary?,
        auth: CodexAuth,
        now: Date
    ) async throws -> ApiEquivalentSummary? {
        guard let window else { return nil }
        do {
            return try await resolveCost(
                local: local,
                range: .range(window: window),
                auth: auth,
                now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func resolveDisplayedCost(
        range: ApiCostSummaryRange,
        selectedRange: ApiCostRange?,
        current: ApiEquivalentSummary?,
        local: ApiEquivalentSummary?,
        auth: CodexAuth,
        now: Date
    ) async throws -> ApiEquivalentSummary {
        if range == .current {
            // Empty-but-successful current cycle is still a valid summary ("no usage").
            // Only fail hard when we could not resolve any summary at all.
            guard let current else {
                throw CostRangeQueryError.usageUnavailable
            }
            return current
        }
        if range == .previous, current == nil {
            throw CostRangeQueryError.usageUnavailable
        }
        guard let selectedRange else { throw CostRangeQueryError.usageUnavailable }
        // Pass through zero-usage results so the UI can show "no usage in range"
        // instead of conflating that with a fetch/analytics failure.
        return try await resolveCost(local: local, range: selectedRange, auth: auth, now: now)
    }

    private func selectedCostRange(
        for range: ApiCostSummaryRange,
        fullWindow: DateInterval?,
        now: Date
    ) -> ApiCostRange? {
        switch range {
        case .current:
            return nil
        case .previous:
            return fullWindow.map { ApiCostRange.previousCycle(from: $0) }
        case .today:
            return .today(now: now)
        case .thisMonth:
            return .thisMonth(now: now)
        }
    }

    private func costQueries(
        currentWindow: DateInterval?,
        selectedRange: ApiCostRange?
    ) -> [ApiCostQuery] {
        var queries: [ApiCostQuery] = []
        if let currentWindow {
            queries.append(ApiCostQuery(id: Self.currentCostQueryID, window: currentWindow))
        }
        if let selectedRange {
            queries.append(ApiCostQuery(id: Self.selectedCostQueryID, window: selectedRange.window))
        }
        return queries
    }

    private func currentCycleWindows(from quota: QuotaSnapshot, now: Date) -> (full: DateInterval, elapsed: DateInterval)? {
        quota.cycleWindows(now: now)
    }

    private func applyCurrentCost(_ summary: ApiEquivalentSummary) {
        if let latestCost, latestCost.pricingVersion != summary.pricingVersion {
            detailCostCache = [:]
            detailCostCacheOrder = []
        }
        latestCost = summary
        costDetail = summary
        cacheCost(summary)
    }

    private func applyDisplayedCost(_ summary: ApiEquivalentSummary, range: ApiCostSummaryRange, now: Date = Date(), clearsScanNote: Bool = true) {
        if clearsScanNote { costScanNote = nil }
        latestDisplayedCost = summary
        latestDisplayedCostRange = range
        // Successful scan with zero tokens is "no usage", not a fetch failure.
        if !summary.isDisplayableCost {
            costText = l10n.text(.usageAnalyticsEmpty)
            costSubtitle = costSubtitle(for: summary, range: range, now: now)
            costLines = [
                DetailLine(title: l10n.text(.apiCost), value: l10n.text(.usageAnalyticsEmpty)),
                DetailLine(title: l10n.text(.apiCostSource), value: sourceText(summary.source)),
            ]
            if let costScanNote {
                costLines.append(DetailLine(title: l10n.text(.costScanFailed), value: costScanNote))
            }
            return
        }
        let amount = summary.estimatedUSD.map(DurationFormatter.money) ?? "--"
        costText = "\(amount) \(l10n.text(.apiEquivalent)) · \(Self.compactNumber(summary.totals.totalTokens)) \(l10n.text(.tokens)) · \(sourceText(summary.source))"
        costSubtitle = costSubtitle(for: summary, range: range, now: now)
        costLines = [
            DetailLine(title: l10n.text(.estimatedAPICost), value: amount),
            DetailLine(title: l10n.text(.tokens), value: Self.compactNumber(summary.totals.totalTokens)),
            DetailLine(title: l10n.text(.inputCachedOutput), value: "\(Self.compactNumber(summary.totals.uncachedInputTokens)) / \(Self.compactNumber(summary.totals.cachedInputTokens)) / \(Self.compactNumber(summary.totals.outputTokens))"),
            DetailLine(title: l10n.text(.turns), value: "\(summary.totals.turns)"),
            DetailLine(title: l10n.text(.apiCostSource), value: sourceText(summary.source)),
            DetailLine(title: l10n.text(.pricingVersion), value: summary.pricingVersion),
        ]
        if summary.source == .onlineAnalytics {
            costLines.append(DetailLine(title: l10n.text(.rawAnalyticsCredits), value: Self.creditText(summary.rawCredits)))
        }
        if let costScanNote {
            costLines.append(DetailLine(title: l10n.text(.costScanFailed), value: costScanNote))
        }
    }

    private func clearDisplayedCost(_ text: String) {
        latestDisplayedCost = nil
        latestDisplayedCostRange = nil
        costScanNote = nil
        costText = text
        costSubtitle = ""
        costLines = [DetailLine(title: l10n.text(.apiCost), value: text)]
    }

    private func cacheCost(_ summary: ApiEquivalentSummary) {
        guard summary.isDisplayableCost else { return }
        try? costCacheStore.save(summary)
    }

    private func noteCostScanFailure(_ text: String) {
        guard let latestDisplayedCost, let latestDisplayedCostRange else { return }
        costScanNote = text
        applyDisplayedCost(latestDisplayedCost, range: latestDisplayedCostRange, clearsScanNote: false)
    }

    private func costQueryErrorText(_ error: Error) -> String {
        if error is CostRangeQueryError {
            return l10n.text(.usageAnalyticsUnavailable)
        }
        return error.localizedDescription
    }

    private func costSubtitle(for summary: ApiEquivalentSummary, range: ApiCostSummaryRange, now: Date) -> String {
        let pricing = summary.confidence == .tokensOnly ? l10n.text(.tokensOnly) : l10n.text(.apiTokenPricing)
        // Minute granularity so tick()'s equality guard suppresses per-second
        // subtitle writes (each write re-layouts the whole panel).
        let calculated = DurationFormatter.relativePast(
            since: summary.calculatedAt,
            now: now,
            language: l10n.language,
            includeSeconds: false)
        return "\(costRangeText(range)) · \(pricing) · \(summary.totals.turns) \(l10n.text(.turns)) · \(l10n.text(.calculatedAt)) \(calculated)"
    }

    private func costRangeText(_ range: ApiCostSummaryRange) -> String {
        switch range {
        case .today:
            return l10n.text(.today)
        case .current:
            return l10n.text(.currentCycle)
        case .previous:
            return l10n.text(.previousCycle)
        case .thisMonth:
            return l10n.text(.thisMonth)
        }
    }

    private func windowText(_ window: RateWindow, now: Date) -> String {
        let reset = window.resetsAt.map { " · \(l10n.text(.resetsIn)) \(duration($0.timeIntervalSince(now)))" } ?? ""
        return "\(window.usedPercent)% \(l10n.text(.used))\(reset)"
    }

    private func quotaMeters(from quota: QuotaSnapshot) -> [QuotaMeter] {
        var meters = [
            QuotaMeter(title: quotaWindowTitle(quota.primary), window: quota.primary, now: quota.updatedAt, markerPercents: [20, 50, 80]),
        ]
        if let secondary = quota.secondary {
            meters.append(QuotaMeter(title: l10n.text(.weeklyUsage), window: secondary, now: quota.updatedAt, markerPercents: [20, 50, 80]))
        }
        meters.append(contentsOf: visibleAdditionalQuotaWindows(from: quota).map {
            QuotaMeter(
                title: $0.name,
                window: $0.window,
                now: quota.updatedAt,
                markerPercents: [20, 50, 80],
                source: .modelSpecific)
        })
        return meters
    }

    private func visibleAdditionalQuotaWindows(from quota: QuotaSnapshot) -> [NamedRateWindow] {
        settings.preferences.showsModelSpecificQuotaUsage ? quota.additionalWindows : []
    }

    private func quotaWindowTitle(_ window: RateWindow) -> String {
        switch window.windowMinutes {
        case 300:
            return l10n.text(.fiveHourUsage)
        case 10_080:
            return l10n.text(.weeklyUsage)
        default:
            return l10n.text(.quota)
        }
    }

    private func localizedStatus(_ status: String) -> String {
        switch status {
        case "available":
            return l10n.text(.statusAvailable)
        case "used":
            return l10n.text(.statusUsed)
        default:
            return l10n.text(.statusUnknown)
        }
    }

    private func sessionStateText(_ state: SessionActivityState) -> String {
        switch state {
        case .recent:
            return l10n.text(.recent)
        case .needsAttention:
            return l10n.text(.needsAttention)
        case .failed:
            return l10n.text(.failed)
        }
    }

    private func resetCreditState(_ credit: ResetCredit) -> ResetCreditState {
        guard credit.status == "available" else { return .unavailable }
        guard credit.expiresAt != nil else { return .available }
        if credit.remainingSeconds <= 7 * 24 * 3_600 { return .expiring }
        return .available
    }

    private func menuBarText(for quota: QuotaSnapshot, now: Date) -> String {
        guard let reset = quota.primary.resetsAt else {
            return quota.primary.usedPercent >= 100 ? l10n.text(.statusWait) : "\(quota.primary.usedPercent)%"
        }
        let text = duration(reset.timeIntervalSince(now), includeSeconds: false)
        return quota.primary.usedPercent >= 100 ? "\(l10n.text(.statusWait)) \(text)" : text
    }

    private func duration(_ seconds: TimeInterval, includeSeconds: Bool = true) -> String {
        DurationFormatter.localized(seconds, language: l10n.language, includeSeconds: includeSeconds)
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func displayDateString(_ value: String) -> String {
        guard let date = apiDateFormatter.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func creditText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func sourceText(_ source: ApiEquivalentSource) -> String {
        switch source {
        case .localSessions:
            return l10n.text(.sourceLocalSessions)
        case .onlineAnalytics:
            return l10n.text(.sourceOnlineSupplement)
        case .unavailable:
            // Source is "unavailable" when a range resolved with zero tokens — not a hard failure.
            return l10n.text(.usageAnalyticsEmpty)
        }
    }

    static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
