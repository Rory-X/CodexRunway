import Foundation
import Testing
@testable import CodexRunwayCore

/// Counts starts across concurrency domains. A plain captured `var` cannot be
/// mutated inside a `@Sendable` closure under Swift 6's isolation rules.
private final class StartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Captures the credential a start was given, across concurrency domains.
private final class CredentialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func record(_ token: String) {
        lock.lock(); value = token; lock.unlock()
    }
    var last: String? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

@Suite("Quota window probe")
struct QuotaWindowProbeTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A window that has not started reports `reset_after_seconds` equal to the whole
    /// window; that equality is what makes a start meaningful.
    private func idleWindow(limit: Int = 18_000) -> RateWindow {
        RateWindow(usedPercent: 0, limitWindowSeconds: limit, resetAfterSeconds: limit)
    }

    private func runningWindow(elapsed: Int, limit: Int = 18_000) -> RateWindow {
        RateWindow(usedPercent: 40, limitWindowSeconds: limit, resetAfterSeconds: limit - elapsed)
    }

    /// A credential the guards never inspect, only forward.
    private func credential() -> CodexAuth {
        CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: nil, accessToken: "test-access", refreshToken: "test-refresh",
                accountId: "acct"),
            lastRefresh: nil)
    }

    private func probe(
        counting counter: StartCounter,
        cli: URL? = URL(fileURLWithPath: "/bin/echo"),
        store: ProbeStartStore
    ) -> QuotaWindowProbe {
        QuotaWindowProbe(
            resolveCLI: { cli },
            runStart: { _, _, _, _ in
                counter.increment()
                return 42
            },
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            lastStartStore: store)
    }

    // MARK: - The idle rule

    @Test("an unstarted window is idle and a running one is not")
    func idleDetection() {
        #expect(idleWindow().isIdle)
        #expect(!runningWindow(elapsed: 60).isIdle)
        // A few seconds of reporting jitter must not read as "running", or the probe
        // would skip the exact moment the window becomes free.
        let nearlyIdle = RateWindow(
            usedPercent: 0, limitWindowSeconds: 18_000, resetAfterSeconds: 17_990)
        #expect(nearlyIdle.isIdle)
        // Without the fields the state is unknown, and unknown is not idle.
        #expect(!RateWindow(usedPercent: 0).isIdle)
    }

    @Test("elapsed is derived rather than guessed")
    func elapsedSeconds() {
        #expect(runningWindow(elapsed: 300).elapsedSeconds == 300)
        #expect(idleWindow().elapsedSeconds == 0)
        #expect(RateWindow(usedPercent: 0).elapsedSeconds == nil)
    }

    // MARK: - Guards

    @Test("a running window is left alone")
    func runningWindowIsLeftAlone() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = StartCounter()
        let p = probe(counting: counter, store: ProbeStartStore(directory: dir))

        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: runningWindow(elapsed: 600), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        #expect(outcome == .windowAlreadyActive)
        #expect(counter.count == 0, "must not spend quota while a window is running")
    }

    @Test("an exhausted weekly allowance blocks the start")
    func exhaustedWeeklyBlocks() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = StartCounter()
        let p = probe(counting: counter, store: ProbeStartStore(directory: dir))

        let weekly = RateWindow(
            usedPercent: 100, limitWindowSeconds: 604_800, resetAfterSeconds: 10_000)
        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: weekly,
            usageReadAt: Date(), autoStartEnabled: true)
        #expect(outcome == .quotaExhausted)
        #expect(counter.count == 0, "a new 5h window cannot help while the weekly cap is spent")
    }

    /// A stale reading may describe a state that has already changed, so it never acts.
    @Test("a stale reading stands down")
    func staleReadingStandsDown() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = StartCounter()
        let p = probe(counting: counter, store: ProbeStartStore(directory: dir))

        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date().addingTimeInterval(-10 * 60), autoStartEnabled: true)
        #expect(outcome == .stateUnavailable)
        #expect(counter.count == 0)
    }

    @Test("a missing reading stands down rather than guessing")
    func missingReadingStandsDown() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = StartCounter()
        let p = probe(counting: counter, store: ProbeStartStore(directory: dir))

        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: nil, dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        #expect(outcome == .stateUnavailable)
        #expect(counter.count == 0)
    }

    @Test("auto-start off means nothing happens")
    func disabledDoesNothing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = StartCounter()
        let p = probe(counting: counter, store: ProbeStartStore(directory: dir))

        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: false)
        #expect(outcome == .disabled)
        #expect(counter.count == 0)
    }

    @Test("a missing CLI is reported instead of silently skipped")
    func missingCLIReported() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = probe(counting: StartCounter(), cli: nil, store: ProbeStartStore(directory: dir))

        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        #expect(outcome == .cliUnavailable)
    }

    // MARK: - The happy path and the lock

    @Test("an idle window with every guard satisfied starts once")
    func startsWhenIdle() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProbeStartStore(directory: dir)
        let counter = StartCounter()
        let p = probe(counting: counter, store: store)

        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        #expect(outcome == .started(tokensUsed: 42))
        #expect(counter.count == 1)

        // The lock then suppresses an immediate second start, which would be a wasted
        // request at best.
        let again = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        if case .recentlyStarted = again {} else {
            Issue.record("expected the lock to hold, got \(again)")
        }
        #expect(counter.count == 1)
    }

    /// A failed run must not arm the lock, or one bad attempt would block the next
    /// five hours.
    @Test("a failed start does not arm the lock")
    func failureDoesNotLock() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProbeStartStore(directory: dir)
        let p = QuotaWindowProbe(
            resolveCLI: { URL(fileURLWithPath: "/bin/false") },
            runStart: { _, _, _, _ in throw QuotaWindowProbe.ProbeError.timedOut },
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            lastStartStore: store)

        let outcome = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        if case .failed = outcome {} else {
            Issue.record("expected failure, got \(outcome)")
        }
        #expect(store.lastStart(accountID: "a") == nil)

        // A later attempt is therefore still allowed.
        let retry = await p.start(
            accountID: "a",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        if case .failed = retry {} else {
            Issue.record("expected the retry to run, got \(retry)")
        }
    }

    @Test("the lock is per account")
    func lockIsPerAccount() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProbeStartStore(directory: dir)
        #expect(store.recordStart(accountID: "a", at: Date()))

        let counter = StartCounter()
        let p = probe(counting: counter, store: store)
        _ = await p.start(
            accountID: "b",
            credential: credential(), window: idleWindow(), dailyWindow: nil,
            usageReadAt: Date(), autoStartEnabled: true)
        #expect(counter.count == 1, "one account's lock must not silence another")
    }

    /// The credential reaching the runner must be the one belonging to the account
    /// being started. Getting this wrong spends another account's quota and opens
    /// that other account's window, while recording the result here.
    @Test("the account's own credential is the one handed to the CLI")
    func startUsesOwnCredential() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = CredentialRecorder()
        let mine = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(idToken: nil, accessToken: "mine", refreshToken: "r", accountId: "a1"),
            lastRefresh: nil)

        let p = QuotaWindowProbe(
            resolveCLI: { URL(fileURLWithPath: "/bin/echo") },
            runStart: { _, _, _, credential in
                seen.record(credential.tokens.accessToken)
                return 7
            },
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            lastStartStore: ProbeStartStore(directory: dir))

        let outcome = await p.start(
            accountID: "a",
            credential: mine,
            window: idleWindow(),
            dailyWindow: nil,
            usageReadAt: Date(),
            autoStartEnabled: true)
        #expect(outcome == .started(tokensUsed: 7))
        #expect(seen.last == "mine")
    }

    // MARK: - Support

    @Test("an account id cannot escape the lock directory")
    func lockIDCannotEscape() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProbeStartStore(directory: dir)
        let hostile = "../../etc/passwd"
        #expect(store.recordStart(accountID: hostile, at: Date()))
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.count == 1)
        #expect(!contents[0].contains("/"))
        #expect(store.lastStart(accountID: hostile) != nil)
    }

    @Test("the token count the CLI prints is read when present")
    func parsesTokenCount() {
        let output = """
        codex
        ok
        hook: Stop
        tokens used
        9,241
        ok
        """
        #expect(QuotaWindowProbe.parseTokenCount(from: output) == 9_241)
        #expect(QuotaWindowProbe.parseTokenCount(from: "no figure here") == nil)
    }

    /// The default model must be one a subscription accepts: an unsupported model is
    /// rejected with HTTP 400 and no window opens at all.
    @Test("the default policy uses the verified supported model")
    func defaultPolicyModel() {
        let policy = QuotaWindowProbePolicy.default
        #expect(policy.model == "gpt-5.6-luna")
        #expect(policy.reasoningEffort == "low")
        // Pinned so the trigger cannot be routed to a relay by the config file this
        // app rewrites on account switch: a relay has no subscription window to open.
        #expect(policy.provider == "openai")
        // Slightly under a full window, since a running window is the real guard.
        #expect(policy.lockInterval < 5 * 3600)
        #expect(policy.lockInterval > 4 * 3600)
    }

    @Test("the CLI is found where the verified binary lives")
    func resolvesCLI() {
        if let found = QuotaWindowProbe.defaultCLI() {
            #expect(FileManager.default.isExecutableFile(atPath: found.path))
        }
    }
}
