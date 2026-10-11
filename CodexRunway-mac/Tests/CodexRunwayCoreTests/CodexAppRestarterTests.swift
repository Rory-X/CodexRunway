import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Codex app restart")
struct CodexAppRestarterTests {
    private static let chatGPT = "/Applications/ChatGPT.app"

    private func app(
        pid: pid_t,
        terminated: Bool,
        bundleIdentifier: String? = "com.openai.codex",
        name: String? = "ChatGPT",
        path: String? = chatGPT,
        regular: Bool = true
    ) -> CodexAppRestarter.RunningApp {
        CodexAppRestarter.RunningApp(
            bundleIdentifier: bundleIdentifier,
            localizedName: name,
            bundlePath: path,
            isRegularOrAccessory: regular,
            processIdentifier: pid,
            isTerminated: terminated)
    }

    /// A mutable world the probe reads from, so tests can script quit/launch outcomes.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var apps: [CodexAppRestarter.RunningApp]
        private var launchError = false
        private var stalePids: Set<pid_t> = []
        private(set) var launchCount = 0

        init(apps: [CodexAppRestarter.RunningApp]) {
            self.apps = apps
        }

        var current: [CodexAppRestarter.RunningApp] {
            lock.lock(); defer { lock.unlock() }
            return apps
        }

        func terminateAll() {
            lock.lock(); defer { lock.unlock() }
            apps = apps.map { var copy = $0; copy.isTerminated = true; return copy }
        }

        /// Simulates the app dying but never coming back (the reported bug).
        func vanish() {
            lock.lock(); defer { lock.unlock() }
            apps = []
        }

        func relaunch(pid: pid_t) {
            lock.lock(); defer { lock.unlock() }
            apps = [CodexAppRestarter.RunningApp(
                bundleIdentifier: "com.openai.codex",
                localizedName: "ChatGPT",
                bundlePath: Self.path,
                isRegularOrAccessory: true,
                processIdentifier: pid,
                isTerminated: false)]
        }

        static let path = "/Applications/ChatGPT.app"

        func markLaunchAttempt() {
            lock.lock(); defer { lock.unlock() }
            launchCount += 1
        }

        var didAttemptLaunch: Bool {
            lock.lock(); defer { lock.unlock() }
            return launchCount > 0
        }

        /// Pid reported by the most recent simulated launch.
        var launchedPID: pid_t? {
            lock.lock(); defer { lock.unlock() }
            return apps.first { !$0.isTerminated }?.processIdentifier
        }

        /// Liveness as the world sees it, so tests never consult real pids.
        func isAlive(pid: pid_t) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if stalePids.contains(pid) { return false }
            return apps.contains { $0.processIdentifier == pid && !$0.isTerminated }
        }

        /// Models launchservicesd during teardown: the kernel has already reaped
        /// the pid, but the bundle is *still listed as a running, live app*.
        /// That combination is what makes an open be refused, and what used to
        /// confirm a relaunch that never happened.
        func keepStaleRegistration(_ pids: [pid_t]) {
            lock.lock(); defer { lock.unlock() }
            stalePids = Set(pids)
            apps = apps.map { entry in
                guard pids.contains(entry.processIdentifier) else { return entry }
                var copy = entry
                copy.isTerminated = false
                return copy
            }
        }

        func clearStaleRegistration() {
            lock.lock(); defer { lock.unlock() }
            stalePids = []
        }
    }

    /// Thread-safe attempt counter for scripting transient launch refusals.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func probe(
        world: World,
        relaunches: Bool,
        launchReturnsError: Bool = false,
        quitAccepted: Bool = true
    ) -> CodexAppRestarter.Probe {
        CodexAppRestarter.Probe(
            runningApplications: { world.current },
            quit: { _, _ in
                guard quitAccepted else { return false }
                world.terminateAll()
                // A real quit unwinds helper processes over several seconds; the
                // relaunch path must not depend on a single fixed sleep.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if !relaunches { world.vanish() }
                }
                return true
            },
            launch: { _ in
                world.markLaunchAttempt()
                if launchReturnsError { return false }
                if relaunches { world.relaunch(pid: 99_001) }
                return true
            },
            sleep: { _ in
                try? await Task.sleep(nanoseconds: 20_000_000)
            },
            resolveLaunchURL: { _ in URL(fileURLWithPath: "/tmp/test/ChatGPT.app") },
            isProcessAlive: { world.isAlive(pid: $0) },
            launchedProcessIdentifier: { world.launchedPID },
            policy: CodexAppRestarter.Policy(
                quitTimeout: 1,
                launchTimeout: 0.5,
                pollInterval: 0.02))
    }

    @Test("a successful relaunch reports restarted")
    func successfulRelaunch() async {
        let world = World(apps: [app(pid: 100, terminated: false)])
        let result = await CodexAppRestarter.restart(using: probe(world: world, relaunches: true))

        #expect(result.relaunched)
        #expect(result.didRestart)
        #expect(result.terminatedCount == 1)
        #expect(result.message == nil)
    }

    @Test("quitting without a relaunch is reported as failure, not success")
    func quitWithoutRelaunchIsFailure() async {
        let world = World(apps: [app(pid: 100, terminated: false)])
        // Launch is accepted (no error) but no process ever appears — exactly the
        // LaunchServices "silently dropped" case that hid the bug.
        let result = await CodexAppRestarter.restart(using: probe(world: world, relaunches: false))

        #expect(!result.relaunched)
        #expect(!result.didRestart)
        #expect(result.terminatedCount == 1)
        #expect(result.message != nil)
    }

    @Test("a launch error is reported with its own message")
    func launchErrorIsReported() async {
        let world = World(apps: [app(pid: 100, terminated: false)])
        let result = await CodexAppRestarter.restart(
            using: probe(world: world, relaunches: false, launchReturnsError: true))

        #expect(!result.relaunched)
        #expect(world.didAttemptLaunch)
        #expect(result.message?.contains("Could not relaunch") == true)
    }

    @Test("no running app still attempts a launch and reports missing target")
    func noRunningApp() async {
        let world = World(apps: [])
        let result = await CodexAppRestarter.restart(using: probe(world: world, relaunches: false))

        #expect(result.terminatedCount == 0)
        #expect(!result.relaunched)
    }

    @Test("a refused graceful quit does not stall the restart")
    func refusedGracefulQuitDoesNotStall() async {
        // Regression: the app is a large Chromium bundle that often refuses a
        // polite terminate (AppleEvent), which used to burn the whole 10s grace
        // period before forcing anyway. The restart must force up front and
        // confirm the process is gone quickly.
        let world = World(apps: [app(pid: 100, terminated: false)])
        let seen = MutationRecorder()

        let result = await CodexAppRestarter.restart(using: CodexAppRestarter.Probe(
            runningApplications: { world.current },
            quit: { _, force in
                seen.record(force: force)
                // A graceful request is refused; only the forced one lands.
                guard force else { return true }
                world.terminateAll()
                // Arrange the relaunch on a background queue: the policy polls
                // through MainActor.run, so a main-queue delay would be starved
                // by those hops and make this test measure the scheduler.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    world.relaunch(pid: 99_001)
                }
                return true
            },
            launch: { _ in
                world.markLaunchAttempt()
                return true
            },
            sleep: { _ in
                seen.recordSleep()
                try? await Task.sleep(nanoseconds: 10_000_000)
            },
            resolveLaunchURL: { _ in URL(fileURLWithPath: "/tmp/test/ChatGPT.app") },
            isProcessAlive: { world.isAlive(pid: $0) },
            launchedProcessIdentifier: { world.launchedPID },
            policy: CodexAppRestarter.Policy(
                quitTimeout: 5,
                launchTimeout: 5,
                pollInterval: 0.02)))

        #expect(result.relaunched)
        // Only the forced quit is attempted: no grace period is spent on a
        // polite request that this app would refuse. Elapsed time is not
        // asserted here because the suite runs in parallel with other tests
        // that contend for the main thread.
        #expect(seen.forcedOnly)
    }

    private final class MutationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var forced = 0
        private var polite = 0
        private var sleepCount = 0

        func record(force: Bool) {
            lock.lock(); defer { lock.unlock() }
            if force { forced += 1 } else { polite += 1 }
        }

        func recordSleep() {
            lock.lock(); defer { lock.unlock() }
            sleepCount += 1
        }

        var forcedOnly: Bool {
            lock.lock(); defer { lock.unlock() }
            return forced == 1 && polite == 0
        }

        var sleeps: Int {
            lock.lock(); defer { lock.unlock() }
            return sleepCount
        }
    }

    @Test("the default poll cadence is milliseconds, not seconds")
    func defaultPollCadenceIsMilliseconds() {
        // Regression: `pollInterval` was written as `20` while `Probe.sleep`
        // takes *seconds*, so every poll slept twenty seconds and a restart that
        // should take ~0.2s took ~20s.
        //
        // The cadence is asserted directly rather than by measuring wall-clock time:
        // this suite runs in parallel with others, and a timing bound on a real
        // sleep is not reproducible under that contention.
        let policy = CodexAppRestarter.Policy.default
        #expect(policy.pollInterval > 0)
        #expect(policy.pollInterval < 1, "poll cadence must be sub-second, not seconds")
        #expect(policy.quitTimeout > 0)
        #expect(policy.launchTimeout > 0)
        // A cadence that is an integral number of seconds is the exact bug shape:
        // the value was previously meaningful as milliseconds.
        #expect(policy.pollInterval != policy.pollInterval.rounded())
    }

    @Test("the probe is polled with the configured cadence")
    func probeSleepReceivesConfiguredCadence() async {
        // The confirmation loop must pass the policy's cadence to `sleep`, so a
        // unit mix-up there would be caught without depending on timing.
        let world = World(apps: [app(pid: 100, terminated: false)])
        let recorded = SleepRecorder()
        _ = await CodexAppRestarter.restart(using: CodexAppRestarter.Probe(
            runningApplications: { world.current },
            quit: { _, _ in
                world.terminateAll()
                return true
            },
            launch: { _ in
                world.markLaunchAttempt()
                world.relaunch(pid: 99_001)
                return true
            },
            sleep: { seconds in
                recorded.record(seconds)
                try? await Task.sleep(nanoseconds: 1_000_000)
            },
            resolveLaunchURL: { _ in URL(fileURLWithPath: "/tmp/test/ChatGPT.app") },
            isProcessAlive: { world.isAlive(pid: $0) },
            launchedProcessIdentifier: { world.launchedPID },
            policy: .default))
        #expect(recorded.values.allSatisfy { $0 == CodexAppRestarter.Policy.default.pollInterval })
    }

    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TimeInterval] = []
        func record(_ value: TimeInterval) { lock.lock(); recorded.append(value); lock.unlock() }
        var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    @Test("only the Codex app is matched")
    func identityMatching() {
        #expect(CodexAppRestarter.isCodexApp(app(pid: 1, terminated: false)))
        #expect(CodexAppRestarter.isCodexApp(
            app(pid: 2, terminated: false, bundleIdentifier: "com.openai.codex.helper")))
        // Activation policy rules out background-only helpers.
        #expect(!CodexAppRestarter.isCodexApp(
            app(pid: 3, terminated: false, regular: false)))
        // An unrelated app that merely mentions Codex in its name is not the target.
        #expect(!CodexAppRestarter.isCodexApp(
            app(pid: 4, terminated: false,
                bundleIdentifier: "com.bigpizzav3.codexplusplus",
                name: "Codex++")))
        // The real app ships as ChatGPT.app, so a bundle-less instance named
        // ChatGPT must still be recognised.
        #expect(CodexAppRestarter.isCodexApp(
            app(pid: 5, terminated: false, bundleIdentifier: nil, name: "ChatGPT")))
        #expect(!CodexAppRestarter.isCodexApp(
            app(pid: 6, terminated: false, bundleIdentifier: nil, name: "ChatGPT Helper")))
    }

    @Test("an already-terminated instance is not counted as quit")
    func alreadyTerminatedIsNotCounted() async {
        let world = World(apps: [app(pid: 100, terminated: true)])
        let result = await CodexAppRestarter.restart(using: probe(world: world, relaunches: true))

        #expect(result.terminatedCount == 0)
        #expect(result.relaunched)
    }

    /// The reported bug: the old pid is reaped, but launchservicesd still lists
    /// the bundle, so an open issued now is refused. The wait must cover the
    /// unregistration, not just the process death.
    @Test("the old bundle is allowed to unregister before the launch is attempted")
    func waitsForLaunchServicesUnregistration() async {
        let world = World(apps: [app(pid: 100, terminated: false)])
        let launchedWhileRegistered = Counter()

        let probe = CodexAppRestarter.Probe(
            runningApplications: { world.current },
            quit: { _, _ in
                world.terminateAll()
                // Kernel reaps the pid immediately; the registration lingers.
                world.keepStaleRegistration([100])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    world.vanish()
                    world.clearStaleRegistration()
                }
                return true
            },
            launch: { _ in
                // Record whether the bundle was still registered at launch time.
                if !world.current.isEmpty { _ = launchedWhileRegistered.increment() }
                world.relaunch(pid: 99_001)
                return true
            },
            sleep: { _ in try? await Task.sleep(nanoseconds: 20_000_000) },
            resolveLaunchURL: { _ in URL(fileURLWithPath: "/tmp/test/ChatGPT.app") },
            isProcessAlive: { world.isAlive(pid: $0) },
            launchedProcessIdentifier: { world.launchedPID },
            policy: CodexAppRestarter.Policy(
                quitTimeout: 2,
                launchTimeout: 0.5,
                pollInterval: 0.02))

        let result = await CodexAppRestarter.restart(using: probe)

        #expect(launchedWhileRegistered.count == 0)
        #expect(result.relaunched)
    }

    /// A stale registration for the instance we just killed must never confirm a
    /// relaunch, otherwise a refused launch is reported as a success.
    @Test("a stale registration for the killed pid does not count as a relaunch")
    func staleRegistrationIsNotRelaunch() async {
        let world = World(apps: [app(pid: 100, terminated: false)])

        let probe = CodexAppRestarter.Probe(
            runningApplications: { world.current },
            quit: { _, _ in
                world.terminateAll()
                // The dead instance stays listed for the whole confirmation
                // window, and the kernel agrees the pid is gone.
                world.keepStaleRegistration([100])
                return true
            },
            launch: { _ in false },
            sleep: { _ in try? await Task.sleep(nanoseconds: 10_000_000) },
            resolveLaunchURL: { _ in URL(fileURLWithPath: "/tmp/test/ChatGPT.app") },
            isProcessAlive: { world.isAlive(pid: $0) },
            launchedProcessIdentifier: { nil },
            policy: CodexAppRestarter.Policy(
                quitTimeout: 0.1,
                launchTimeout: 0.2,
                pollInterval: 0.02))

        let result = await CodexAppRestarter.restart(using: probe)

        #expect(!result.relaunched)
        #expect(!result.didRestart)
        #expect(result.message?.contains("Could not relaunch") == true)
    }

    /// A refused open is transient, so the restart retries within its budget.
    @Test("a transiently refused launch is retried and can still succeed")
    func refusedLaunchIsRetried() async {
        let world = World(apps: [app(pid: 100, terminated: false)])
        let attempts = Counter()

        let probe = CodexAppRestarter.Probe(
            runningApplications: { world.current },
            quit: { _, _ in
                world.terminateAll()
                world.vanish()
                return true
            },
            launch: { _ in
                // Refuse the first two opens (kLSUnknownErr window), then accept.
                if attempts.increment() < 3 { return false }
                world.relaunch(pid: 99_001)
                return true
            },
            sleep: { _ in try? await Task.sleep(nanoseconds: 10_000_000) },
            resolveLaunchURL: { _ in URL(fileURLWithPath: "/tmp/test/ChatGPT.app") },
            isProcessAlive: { world.isAlive(pid: $0) },
            launchedProcessIdentifier: { world.launchedPID },
            policy: CodexAppRestarter.Policy(
                quitTimeout: 0.5,
                launchTimeout: 2,
                pollInterval: 0.02))

        let result = await CodexAppRestarter.restart(using: probe)

        #expect(result.relaunched)
        #expect(attempts.count == 3)
    }

    /// The retry must stay bounded rather than hammer a genuinely broken bundle.
    @Test("a permanently refused launch gives up and reports failure")
    func refusedLaunchIsBounded() async {
        let world = World(apps: [app(pid: 100, terminated: false)])
        let attempts = Counter()

        let probe = CodexAppRestarter.Probe(
            runningApplications: { world.current },
            quit: { _, _ in
                world.terminateAll()
                world.vanish()
                return true
            },
            launch: { _ in
                _ = attempts.increment()
                return false
            },
            sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000) },
            resolveLaunchURL: { _ in URL(fileURLWithPath: "/tmp/test/ChatGPT.app") },
            isProcessAlive: { world.isAlive(pid: $0) },
            launchedProcessIdentifier: { nil },
            policy: CodexAppRestarter.Policy(
                quitTimeout: 0.1,
                launchTimeout: 0.05,
                pollInterval: 0.02))

        let result = await CodexAppRestarter.restart(using: probe)

        #expect(!result.relaunched)
        #expect(attempts.count >= 1)
        #expect(attempts.count <= CodexAppRestarter.launchAttemptLimit)
    }
}
