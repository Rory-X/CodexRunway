import AppKit
import Foundation

public struct CodexAppRestartResult: Sendable, Equatable {
    public var terminatedCount: Int
    public var relaunched: Bool
    public var appPath: String?
    public var message: String?

    /// True only when the app was quit **and** a fresh instance came back.
    /// `terminatedCount > 0` alone is not success: the app can die without
    /// relaunching, and reporting that as success is what hid the original bug.
    public var didRestart: Bool { relaunched }

    public init(
        terminatedCount: Int,
        relaunched: Bool,
        appPath: String?,
        message: String? = nil)
    {
        self.terminatedCount = terminatedCount
        self.relaunched = relaunched
        self.appPath = appPath
        self.message = message
    }
}

/// Locates, quits, and relaunches the Codex desktop app so a new `auth.json` is picked up.
///
/// The desktop app ships as `/Applications/ChatGPT.app` with bundle id
/// `com.openai.codex`, and it is a Chromium app: one `NSRunningApplication`
/// fronts dozens of helper processes, and it takes seconds to unwind. Three
/// rules follow from that, and all are enforced here:
///
/// 1. Quitting is asynchronous — wait for the process to actually disappear
///    instead of sleeping a fixed amount and hoping.
/// 2. The wait must cover launchservicesd *unregistering* the bundle, not just
///    the process dying. The registration lags the death, and an open issued in
///    that window is refused with `kLSUnknownErr`.
/// 3. Launching an app that is still terminating can be refused, and the
///    refusal is transient, so a refused open is retried within the budget.
///    Success is decided by observing a *new* live process — never by asking
///    whether "a" Codex app is running, since a stale registration for the
///    instance we just killed answers yes.
public enum CodexAppRestarter {
    static let preferredBundleIdentifiers = [
        "com.openai.codex",
    ]

    static let preferredAppNames = [
        "Codex",
        "ChatGPT",
    ]

    /// Name of the on-disk bundle for the Codex desktop app.
    static let preferredBundleName = "ChatGPT"

    /// How long to wait for the old instance to be reaped *and* unregistered.
    /// `forceTerminate` reaps in ~10ms (measured), so this only covers the
    /// launchservicesd bookkeeping that follows it.
    static let quitTimeout: TimeInterval = 2
    /// How long to wait for a newly launched instance to appear.
    static let launchTimeout: TimeInterval = 10
    /// Poll interval for both waits, in seconds. Kept as a `TimeInterval` (the
    /// unit `Probe.sleep` takes) — a bare `20` here would sleep twenty *seconds*
    /// per poll and turn a sub-second restart into a twenty-second one.
    static let pollInterval: TimeInterval = 0.02
    /// How many times a refused `open` is retried before the restart is reported
    /// as failed. The refusal is transient (launchservicesd still unwinding), so
    /// a couple of attempts covers it; the cap keeps a genuinely broken bundle
    /// from being hammered for the whole launch budget.
    static let launchAttemptLimit = 5
    /// Delay between launch attempts, in seconds.
    static let launchRetryDelay: TimeInterval = 0.15

    /// Waits and poll cadence. Injectable so tests do not run in real time.
    struct Policy: Sendable {
        var quitTimeout: TimeInterval = CodexAppRestarter.quitTimeout
        var launchTimeout: TimeInterval = CodexAppRestarter.launchTimeout
        var pollInterval: TimeInterval = CodexAppRestarter.pollInterval

        static let `default` = Policy()
    }

    /// Test seams. Production uses the live implementations below.
    struct Probe: Sendable {
        var runningApplications: @MainActor @Sendable () -> [RunningApp]
        var quit: @MainActor @Sendable (pid_t, Bool) -> Bool
        var launch: @Sendable (URL) async -> Bool
        var sleep: @Sendable (TimeInterval) async -> Void
        /// Resolves the bundle to relaunch. Injectable so tests never depend on
        /// what happens to be installed on the machine running them.
        var resolveLaunchURL: @MainActor @Sendable (String?) -> URL? = {
            CodexAppRestarter.launchURL(for: $0)
        }
        /// Kernel-level liveness for one pid. Deliberately not main-actor bound:
        /// `kill(pid, 0)` is a direct syscall (~0.03ms, measured), so the wait
        /// loop never queues behind main-thread work.
        var isProcessAlive: @Sendable (pid_t) -> Bool = {
            kill($0, 0) == 0
        }
        /// Pid reported by the most recent launch, when the platform provides one.
        var launchedProcessIdentifier: @Sendable () -> pid_t? = {
            CodexAppRestarter.lastLaunchedProcessIdentifier
        }
        var policy: Policy = .default
    }

    /// Minimal view of a running app so the restart policy is testable without AppKit.
    struct RunningApp: Sendable, Equatable {
        var bundleIdentifier: String?
        var localizedName: String?
        var bundlePath: String?
        var isRegularOrAccessory: Bool
        var processIdentifier: pid_t

        var isTerminated: Bool
    }

    public static func restart() async -> CodexAppRestartResult {
        await restart(using: liveProbe())
    }

    static func restart(using probe: Probe) async -> CodexAppRestartResult {
        let policy = probe.policy
        // Drop the previous launch's pid so confirmation cannot match it.
        lastLaunchedProcessIdentifier = nil
        let running = await MainActor.run { probe.runningApplications() }
            .filter(isCodexApp)
        let targetPath = running.compactMap(\.bundlePath).first

        // Quit hard, immediately. A polite `terminate()` is an AppleEvent the
        // app may simply refuse: this app is a large Chromium bundle that often
        // has background work in flight, and a refusal costs the full grace
        // period before we force anyway (measured: 10s wasted, every switch).
        // `forceTerminate` reaps in ~10ms, and the point of the restart is that
        // the app must re-read `auth.json` on a fresh launch — a graceful
        // shutdown buys nothing here.
        var terminated = 0
        for app in running where !app.isTerminated {
            if await MainActor.run(body: { probe.quit(app.processIdentifier, true) }) {
                terminated += 1
            }
        }

        // Confirm the old instance is gone before launching. Two independent
        // conditions matter, and the kernel check alone is not enough:
        //
        // 1. The process must be reaped (`kill(pid, 0)` fails).
        // 2. LaunchServices must have *unregistered* the bundle. This lags the
        //    process death: the pid is already gone while launchservicesd still
        //    lists the app, and an open request issued in that window is refused
        //    outright with `kLSUnknownErr` (NSCocoaErrorDomain 256). The same
        //    stale registration is also what a bundle-id liveness query returns,
        //    so it corrupts relaunch confirmation too.
        let quitPids = running.filter { !$0.isTerminated }.map(\.processIdentifier)
        let settleDeadline = Date().addingTimeInterval(policy.quitTimeout)
        while true {
            let mainReaped = !quitPids.contains(where: probe.isProcessAlive)
            let stillRegistered = await MainActor.run {
                probe.runningApplications().contains { !$0.isTerminated }
            }
            if mainReaped, !stillRegistered { break }
            if Date() >= settleDeadline { break }
            await probe.sleep(policy.pollInterval)
        }

        guard let launchURL = await MainActor.run(body: { probe.resolveLaunchURL(targetPath) }) else {
            return CodexAppRestartResult(
                terminatedCount: terminated,
                relaunched: false,
                appPath: nil,
                message: "Codex app not found")
        }

        // LaunchServices can still refuse the open even after the bundle has
        // unregistered (observed as `kLSUnknownErr`, NSCocoaErrorDomain 256).
        // A refusal here is recoverable, so retry inside the launch budget
        // instead of reporting a restart failure the user cannot act on.
        var didLaunch = false
        var launchAttempts = 0
        let launchBudgetDeadline = Date().addingTimeInterval(policy.launchTimeout)
        while true {
            launchAttempts += 1
            didLaunch = await probe.launch(launchURL)
            if didLaunch { break }
            if launchAttempts >= Self.launchAttemptLimit { break }
            if Date() >= launchBudgetDeadline { break }
            // Let the registration churn finish before asking again.
            await probe.sleep(Self.launchRetryDelay)
        }

        // The launch callback proving no error is not proof of a relaunch:
        // observe a live process instead. This polls the kernel via
        // `kill(pid, 0)` rather than asking LaunchServices — a workspace scan
        // reads per-process `bundleURL`/`localizedName`, each a synchronous XPC
        // round trip that stalls while the system is churning through app
        // teardown, which is exactly when this loop runs.
        //
        // The fallback must exclude the pids we just killed: a stale
        // registration for a dead instance reads as "live" here, which is how a
        // refused launch used to be reported as a successful restart.
        let killedPIDs = Set(quitPids)
        var relaunched = false
        let launchDeadline = Date().addingTimeInterval(policy.launchTimeout)
        while Date() < launchDeadline {
            if let launchedPID = probe.launchedProcessIdentifier() {
                if probe.isProcessAlive(launchedPID), !killedPIDs.contains(launchedPID) {
                    relaunched = true
                    break
                }
            } else {
                let survivor = await MainActor.run { () -> pid_t? in
                    probe.runningApplications()
                        .first { !$0.isTerminated && !killedPIDs.contains($0.processIdentifier) }
                        .map(\.processIdentifier)
                }
                // A pid we never killed and that is still alive is the new
                // instance. Confirm it in the kernel too, so a stale entry that
                // has already died cannot end the wait early.
                if let survivor, probe.isProcessAlive(survivor) {
                    relaunched = true
                    break
                }
            }
            await probe.sleep(policy.pollInterval)
        }

        let message: String?
        if relaunched {
            message = nil
        } else if !didLaunch {
            message = "Could not relaunch \(launchURL.lastPathComponent)"
        } else {
            message = "\(launchURL.lastPathComponent) did not start"
        }

        return CodexAppRestartResult(
            terminatedCount: terminated,
            relaunched: relaunched,
            appPath: launchURL.path,
            message: message)
    }

    // MARK: - Identity

    static func isCodexApp(_ app: RunningApp) -> Bool {
        guard app.isRegularOrAccessory else { return false }
        if let bundle = app.bundleIdentifier?.lowercased() {
            if preferredBundleIdentifiers.contains(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) {
                return true
            }
            // OpenAI Codex builds sometimes ship under product-specific ids.
            if bundle.contains("codex"), bundle.contains("openai") {
                return true
            }
        }
        guard let name = app.localizedName else { return false }
        return preferredAppNames.contains { name.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// Resolves the bundle to relaunch, preferring the instance we just quit and
    /// falling back to a bundle-id lookup before any hard-coded path.
    @MainActor
    static func launchURL(for bundlePath: String?) -> URL? {
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath) {
            return URL(fileURLWithPath: bundlePath)
        }
        for identifier in preferredBundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
               FileManager.default.fileExists(atPath: url.path)
            {
                return url
            }
        }
        for directory in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in [preferredBundleName, "Codex"] {
                let url = URL(fileURLWithPath: "\(directory)/\(name).app")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    // MARK: - Quit / launch

    /// Snapshots only what the restart policy needs. `bundleURL` is resolved
    /// lazily and at most once per instance, because reading it is an XPC round
    /// trip to launchservicesd.
    @MainActor
    private static func snapshot(of app: NSRunningApplication) -> RunningApp {
        RunningApp(
            bundleIdentifier: app.bundleIdentifier,
            localizedName: nil,
            bundlePath: app.bundleURL?.path,
            isRegularOrAccessory: app.activationPolicy == .regular
                || app.activationPolicy == .accessory,
            processIdentifier: app.processIdentifier,
            isTerminated: app.isTerminated)
    }

    // MARK: - Live probe

    private static func liveProbe() -> Probe {
        Probe(
            runningApplications: {
                // Resolve the Codex app by bundle identifier, which is a targeted
                // query. Scanning every running process instead would read
                // `bundleURL`/`localizedName` per process, and each of those is a
                // synchronous XPC round trip to launchservicesd. While the system
                // is busy tearing an app down, those replies stall — that is what
                // made a restart take ~10s in practice.
                preferredBundleIdentifiers
                    .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                    .map(Self.snapshot(of:))
            },
            quit: { pid, force in
                guard let live = NSWorkspace.shared.runningApplications.first(where: {
                    $0.processIdentifier == pid
                }) else { return false }
                return force ? live.forceTerminate() : live.terminate()
            },
            launch: { url in await openApplication(at: url) },
            sleep: { seconds in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            })
    }

    /// Pid handed back by the most recent successful launch.
    nonisolated(unsafe) private static var lastLaunchedProcessIdentifier: pid_t?

    private static func openApplication(at url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    // Set only on success: a stale pid from a previous launch
                    // would otherwise be mistaken for the new instance.
                    lastLaunchedProcessIdentifier = error == nil ? app?.processIdentifier : nil
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }
}
