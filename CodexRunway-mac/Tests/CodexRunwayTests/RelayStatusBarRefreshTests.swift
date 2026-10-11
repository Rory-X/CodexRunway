import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

/// Covers the two reasons a switched-to relay account looked stale:
/// the status item was never repainted, and the relay's own figures were never
/// fetched (only the Codex full-refresh path ran).
@Suite("Relay status bar refresh")
@MainActor
struct RelayStatusBarRefreshTests {
    @Test("account data landing notifies observers")
    func accountDataChangedNotifies() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let notified = Flag()
        fixture.model.onAccountDataChanged = { notified.set() }

        fixture.model.reloadAccountIndex()
        #expect(notified.isSet, "the status item must be told when account data lands")
    }

    @Test("a relay balance produces stacked status lines")
    func relayBalanceProducesLines() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        fixture.setActiveRelay(balance: CachedNewAPIBalance(
            remainingUSD: 1.91,
            usedUSD: 63.09,
            totalUSD: 65,
            keyUsedUSD: 61.75,
            todayTokens: 33_325,
            sevenDayTokens: 85_621_925,
            todayCostUSD: 0.01,
            sevenDayCostUSD: 28.97))

        let lines = fixture.model.statusBarRelayLines
        #expect(lines.count == 2)
        // Today's usage sits above the balance, and both carry a figure.
        #expect(lines.first?.contains("0.01") == true)
        #expect(lines.last?.contains("1.91") == true)

        let tip = fixture.model.statusBarToolTip
        #expect(tip.contains("0.01"))
        #expect(tip.contains("1.91"))
        #expect(!tip.contains("%"), "the tooltip must not list leftover Codex windows")
        #expect(fixture.model.isAPIKeyAccount)
    }

    @Test("a codex account produces no stacked lines")
    func codexAccountHasNoLines() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.setActiveCodexAccount()
        #expect(fixture.model.statusBarRelayLines.isEmpty)
        #expect(!fixture.model.isAPIKeyAccount)
        #expect(!fixture.model.statusBarToolTip.contains("1.91"))
    }

    @Test("the active relay account is exposed for the main panel")
    func activeRelayAccountExposed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(fixture.model.activeRelayAccount == nil)

        fixture.setActiveRelay(balance: CachedNewAPIBalance(remainingUSD: 5, usedUSD: 5))
        let relay = try #require(fixture.model.activeRelayAccount)
        #expect(relay.balance.remainingUSD == 5)
    }

    /// The state the menu bar was observed in: a relay key is active, its balance never
    /// arrived, and the item must still identify the account.
    @Test("an active relay with no balance is still identified as a relay")
    func activeRelayWithoutBalanceIsStillRelay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        fixture.setActiveRelayWithoutBalance()
        #expect(fixture.model.isAPIKeyAccount, "the account is a relay key")
        #expect(fixture.model.statusBarRelayLines.isEmpty, "no balance means no lines")
        // This is what the status item feeds the layout, and it is what decides
        // whether leftover meters can be drawn.
        #expect(fixture.model.isAPIKeyAccount, "and the layout must be told so")
    }

}

// MARK: - Fixture

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class Fixture {
    let root: URL
    let store: AccountStore
    let model: RunwayModel
    private var relayID = ""

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        let settings = RunwaySettings(store: PreferencesStore(
            defaults: UserDefaults(suiteName: "relay-status-\(UUID().uuidString)")!))
        let services = RunwayModelServices(
            loadValidAuth: { _, cached in
                guard let cached else { throw URLError(.userAuthenticationRequired) }
                return cached
            },
            fetchQuota: { _ in throw URLError(.unsupportedURL) },
            fetchResetCredits: { _ in throw URLError(.unsupportedURL) },
            fetchRateLimitResetToday: { throw URLError(.unsupportedURL) },
            scanAPIEquivalent: { _, _, _, _ in [:] },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.unsupportedURL) },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.unsupportedURL) },
            dryRunSessions: {
                SessionRepairReport(
                    missingIndexIDs: [], orphanIndexIDs: [], duplicateIndexIDs: [],
                    staleTitleIDs: [], backupPath: nil, plannedEntries: 0)
            },
            scanRecentSessions: { _ in SessionActivitySummary(items: []) })

        model = RunwayModel(
            settings: settings,
            services: services,
            accountStore: store,
            costCacheStore: UsageCostCacheStore(cacheURL: root.appendingPathComponent("cost.json")),
            quotaEstimateHistoryStore: QuotaEstimateHistoryStore(
                fileURL: root.appendingPathComponent("history.json")))
    }

    func setActiveRelay(balance: CachedNewAPIBalance) {
        let auth = CodexAuth.apiKey(apiKey: "sk-test-relay-key-value")
        guard var account = try? store.upsert(auth: auth, makeActive: true) else { return }
        account.authMode = .apiKey
        account.relayBaseURL = "https://relay.example.com"
        account.cachedQuota = CachedAccountQuota(
            plan: "default", primaryUsedPercent: 97, newAPI: balance)
        try? store.updateMetadata(account)
        relayID = account.id
        model.reloadAccountIndex()
    }

    /// A relay account whose balance never arrived.
    func setActiveRelayWithoutBalance() {
        let auth = CodexAuth.apiKey(apiKey: "sk-test-relay-no-balance")
        guard var account = try? store.upsert(auth: auth, makeActive: true) else { return }
        account.authMode = .apiKey
        account.relayBaseURL = "https://relay.example.com"
        // No `cachedQuota`: the relay never answered, as with a gateway that has no
        // dashboard API.
        account.cachedQuota = nil
        try? store.updateMetadata(account)
        relayID = account.id
        model.reloadAccountIndex()
    }

    func setActiveCodexAccount() {
        model.managedAccounts = []
        model.activeAccountId = nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}


/// The menu bar item must identify a relay account. It used to keep whatever label the
/// previous account left behind: `tick()` only ever refreshed the text when a Codex
/// quota was present, and a relay key never has one.
@Suite("Relay status item label")
@MainActor
struct RelayStatusItemLabelTests {
    @Test("an active relay account is labelled API")
    func relayIsLabelledAPI() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        fixture.setActiveRelayWithoutBalance()

        #expect(fixture.model.isAPIKeyAccount)
        // `tick` is what keeps the item honest between refreshes; the app calls it on a
        // timer and when account data lands.
        fixture.model.tick()
        #expect(
            fixture.model.statusText == "API",
            "expected the relay label, got \(fixture.model.statusText)")
    }

    @Test("the label survives repeated ticks")
    func labelIsStableAcrossTicks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.setActiveRelayWithoutBalance()

        for _ in 0..<5 { fixture.model.tick() }
        #expect(fixture.model.statusText == "API")
    }

    /// Switching away and back must not leave the relay labelled as a Codex account.
    @Test("the label follows the account across a switch")
    func labelFollowsAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        fixture.setActiveCodexAccount()
        fixture.model.tick()
        #expect(fixture.model.statusText != "API", "a Codex account is not labelled API")

        fixture.setActiveRelayWithoutBalance()
        fixture.model.tick()
        #expect(fixture.model.statusText == "API")
    }
}
