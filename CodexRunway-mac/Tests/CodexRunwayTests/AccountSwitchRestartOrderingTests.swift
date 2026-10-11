import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

/// Locks in the ordering fix for account switching: the Codex app relaunch must
/// not wait on an in-flight refresh.
///
/// A full refresh rescans `~/.codex/sessions`, which reaches gigabytes on a
/// long-lived install. The switch used to await that scan before relaunching, so
/// the app came back late and the UI sat on "switching account..." for the whole
/// scan. The relaunch now runs first.
@Suite("Account switch restart ordering")
@MainActor
struct AccountSwitchRestartOrderingTests {
    @Test("the relaunch does not wait for an in-flight full refresh")
    func relaunchDoesNotWaitForRefresh() async throws {
        let blocker = SessionScanBlocker()
        let fixture = try Fixture(blockSessionScan: blocker)
        defer { fixture.remove() }

        // Start a full refresh and hold it open inside the session scan. This is
        // the slow phase that used to delay the relaunch.
        fixture.model.refresh(policy: .force)
        try await waitUntil("session scan entry") { await blocker.hasEntered }

        let restarted = RestartRecorder()
        fixture.model.codexAppRestarter = {
            await restarted.mark()
            return CodexAppRestartResult(
                terminatedCount: 1,
                relaunched: true,
                appPath: "/Applications/ChatGPT.app")
        }

        fixture.model.switchAccount(id: fixture.targetAccountID, restartCodex: true)

        // The relaunch must land while the scan is still blocked. Under the old
        // ordering this awaited the drain first, so the restart could not appear
        // until the blocker was released.
        try await waitUntil("restart before scan release") { await restarted.didRestart }
        #expect(fixture.model.lastError == nil, "switch error: \(fixture.model.lastError ?? "none")")
        #expect(await blocker.stillBlocked)

        await blocker.release()
    }

    @Test("a relaunch that fails is reported as a failure, not a success")
    func failedRelaunchIsReported() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        fixture.model.codexAppRestarter = {
            CodexAppRestartResult(
                terminatedCount: 1,
                relaunched: false,
                appPath: "/Applications/ChatGPT.app",
                message: "ChatGPT did not start")
        }

        fixture.model.switchAccount(id: fixture.targetAccountID, restartCodex: true)
        try await waitUntil("failed restart error") { fixture.model.lastError != nil }

        // Quitting without a relaunch must not read as success.
        #expect(fixture.model.accountOperationMessage == nil)
        #expect(fixture.model.lastError?.contains("ChatGPT did not start") == true)
    }

    @Test("a confirmed relaunch reports success")
    func successfulRelaunchReportsSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        fixture.model.codexAppRestarter = {
            CodexAppRestartResult(
                terminatedCount: 1,
                relaunched: true,
                appPath: "/Applications/ChatGPT.app")
        }

        fixture.model.switchAccount(id: fixture.targetAccountID, restartCodex: true)
        try await waitUntil("successful restart message") {
            fixture.model.accountOperationMessage == fixture.model.l10n.text(
                .accountsRestartCodexSucceeded)
        }
        #expect(fixture.model.lastError == nil)
    }

    // MARK: - Fixture

    @MainActor
    final class Fixture {
        let root: URL
        let store: AccountStore
        let model: RunwayModel
        let targetAccountID: String

        init(blockSessionScan blocker: SessionScanBlocker? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("switch-order-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = AccountStore(
                rootURL: root.appendingPathComponent("accounts", isDirectory: true),
                officialAuthURL: root.appendingPathComponent("auth.json"))

            _ = try store.upsert(auth: try Self.auth("source"), makeActive: true)
            targetAccountID = try store.upsert(auth: try Self.auth("target"), makeActive: false).id

            let suiteName = "switch-order-\(UUID().uuidString)"
            let settings = RunwaySettings(
                store: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!))

            let services = RunwayModelServices(
                loadValidAuth: { _, cached in
                    guard let cached else { throw URLError(.userAuthenticationRequired) }
                    return cached
                },
                fetchQuota: { _ in
                    QuotaSnapshot(
                        plan: "plus",
                        primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
                        secondary: nil,
                        additionalWindows: [],
                        creditsBalance: nil,
                        updatedAt: Date())
                },
                fetchResetCredits: { _ in throw URLError(.unsupportedURL) },
                fetchRateLimitResetToday: { throw URLError(.unsupportedURL) },
                scanAPIEquivalent: { _, _, _, _ in [:] },
                fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.unsupportedURL) },
                fetchCodexProfileTokenUsage: { _ in throw URLError(.unsupportedURL) },
                dryRunSessions: {
                    // The session scan is the phase that can take a very long time.
                    if let blocker { await blocker.enter() }
                    return SessionRepairReport(
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

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func auth(_ id: String) throws -> CodexAuth {
            let payload: [String: Any] = [
                "exp": 4_100_000_000,
                "email": "\(id)@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": id],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let token = [Data(#"{"alg":"none"}"#.utf8), data, Data()]
                .map {
                    $0.base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                }
                .joined(separator: ".")
            return CodexAuth(
                authMode: "chatgpt",
                tokens: .init(
                    idToken: token,
                    accessToken: token,
                    refreshToken: "review-only-dummy-refresh-token-\(id)",
                    accountId: id),
                lastRefresh: nil)
        }
    }

    actor RestartRecorder {
        private(set) var didRestart = false
        func mark() { didRestart = true }
    }

    /// Holds the session scan open until the test releases it.
    actor SessionScanBlocker {
        private(set) var hasEntered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        var stillBlocked: Bool { !released }

        func enter() async {
            hasEntered = true
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// Polls until `condition` holds.
    ///
    /// The timeout is deliberately generous and the poll interval short: this suite
    /// runs alongside the rest of the test bundle, and under that contention a task
    /// hop can take far longer than it would in isolation. A tight timeout here
    /// produced intermittent failures that had nothing to do with the behaviour
    /// under test.
    private func waitUntil(
        _ context: String,
        timeout: TimeInterval = 30,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Timed out waiting for \(context).")
    }
}
