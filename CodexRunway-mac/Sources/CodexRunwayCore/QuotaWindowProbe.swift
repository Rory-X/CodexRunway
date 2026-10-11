import Foundation
import OSLog

/// Why a start attempt did or did not happen.
///
/// Every outcome is reported, including the refusals: a probe that silently decides
/// not to act is indistinguishable from one that is broken, and this one spends the
/// user's quota when it acts.
public enum QuotaWindowStartOutcome: Sendable, Equatable {
    /// A window is already running, so there was nothing to start.
    case windowAlreadyActive
    /// The meter's own percentage is already at the cap; a new window cannot start
    /// until the current one resets.
    case quotaExhausted
    /// Usage could not be read, so the state is unknown and the probe stands down.
    case stateUnavailable
    /// A start ran very recently; the lock prevents a second one.
    case recentlyStarted(secondsAgo: Int)
    /// Auto-start is switched off for this account.
    case disabled
    /// The CLI could not be located, so nothing was attempted.
    case cliUnavailable
    /// The start was attempted and the CLI reported success.
    case started(tokensUsed: Int?)
    /// The start was attempted and failed.
    case failed(String)
}

/// Configuration for a start, kept as data so the guards are testable without
/// running a process.
public struct QuotaWindowProbePolicy: Sendable, Equatable {
    /// The model used for the trigger message. Must be one the subscription accepts:
    /// the server rejects an unknown model with HTTP 400 and no window opens, so a
    /// cheap *supported* model is the requirement, not the cheapest listed anywhere.
    public var model: String
    /// Reasoning effort, kept minimal because the reply is discarded.
    public var reasoningEffort: String
    /// The prompt. One short word is enough to open a window.
    public var prompt: String
    /// The provider the trigger must use.
    ///
    /// Pinned rather than inherited, because the CLI would otherwise take it from
    /// `~/.codex/config.toml` — a file this app writes to when switching accounts. A
    /// relay selection there would send the trigger to a relay, where no subscription
    /// window exists to open.
    public var provider: String
    /// How long a start suppresses the next one.
    ///
    /// Slightly under the 5-hour window: the point is to start each window once, and
    /// a running window already blocks a start, so this is only a backstop against a
    /// request storm or a clock skew.
    public var lockInterval: TimeInterval

    public init(
        model: String = "gpt-5.6-luna",
        reasoningEffort: String = "low",
        provider: String = "openai",
        prompt: String = "ok",
        lockInterval: TimeInterval = 4 * 3600 + 50 * 60
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.provider = provider
        self.prompt = prompt
        self.lockInterval = lockInterval
    }

    public static let `default` = QuotaWindowProbePolicy()
}

/// Opens a fresh 5-hour quota window by sending one minimal message through the
/// official CLI.
///
/// A Codex usage window does not run on a schedule; it starts with the first request
/// and then stays fixed for its full length. That means an idle account is not
/// accumulating any progress toward its next reset, and the window that follows a
/// long break starts only when work resumes. Starting it deliberately, while the
/// account would otherwise be idle, moves the reset earlier.
///
/// The trigger is a real inference request: the read-only usage endpoint does **not**
/// start a window (verified — `reset_after_seconds` stays equal to the window length
/// across repeated reads). So this costs a small amount of quota, roughly one minimal
/// turn.
public struct QuotaWindowProbe: Sendable {
    public var policy: QuotaWindowProbePolicy
    /// Resolves the `codex` executable. Injectable so tests never spawn a process.
    public var resolveCLI: @Sendable () -> URL?
    /// Runs one start and reports the token count the CLI printed, when available.
    ///
    /// Takes the credential to use, because the CLI reads it from a CODEX_HOME
    /// rather than from an argument.
    public var runStart: @Sendable (URL, QuotaWindowProbePolicy, URL, CodexAuth) async throws -> Int?
    /// Where the CLI is run. A dedicated empty directory, so the trigger cannot pick
    /// up a project's files or leave artefacts in one.
    public var workingDirectory: URL
    /// Persisted time of the last start, per account.
    public var lastStartStore: ProbeStartStore

    public init(
        policy: QuotaWindowProbePolicy = .default,
        resolveCLI: @escaping @Sendable () -> URL? = QuotaWindowProbe.defaultCLI,
        runStart: @escaping @Sendable (URL, QuotaWindowProbePolicy, URL, CodexAuth) async throws -> Int? = QuotaWindowProbe.runCLIStart,
        workingDirectory: URL? = nil,
        lastStartStore: ProbeStartStore = ProbeStartStore()
    ) {
        self.policy = policy
        self.resolveCLI = resolveCLI
        self.runStart = runStart
        self.workingDirectory = workingDirectory ?? QuotaWindowProbe.defaultWorkingDirectory
        self.lastStartStore = lastStartStore
    }

    /// Decides and, when every guard passes, performs one start.
    ///
    /// - Parameters:
    ///   - window: the 5-hour window as last read. Its `isIdle` decides whether a
    ///     start is meaningful.
    ///   - dailyWindow: the weekly window, used to refuse a start while the weekly
    ///     allowance is already spent.
    ///   - usageReadAt: when that reading was taken. A stale reading is not acted on;
    ///     the state it describes may already have changed.
    ///   - autoStartEnabled: the per-account switch.
    public func start(
        accountID: String,
        credential: CodexAuth,
        window: RateWindow?,
        dailyWindow: RateWindow?,
        usageReadAt: Date,
        autoStartEnabled: Bool,
        now: Date = Date()
    ) async -> QuotaWindowStartOutcome {
        guard autoStartEnabled else { return .disabled }

        // Only act on a reading taken just now. A window may have opened since, and
        // starting again would be a wasted request at best.
        guard now.timeIntervalSince(usageReadAt) < Self.stalenessLimit else {
            return .stateUnavailable
        }
        guard let window, window.limitWindowSeconds != nil, window.resetAfterSeconds != nil else {
            return .stateUnavailable
        }

        // A window that is running needs nothing. Checked before the weekly guard so
        // an active window reports as such rather than as an exhausted quota.
        guard window.isIdle else { return .windowAlreadyActive }

        // The weekly cap is the harder limit: while it is spent, a new 5-hour window
        // cannot help, and the request would be charged for nothing.
        if let dailyWindow, dailyWindow.usedPercentExact >= 100 {
            return .quotaExhausted
        }

        if let last = lastStartStore.lastStart(accountID: accountID) {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < policy.lockInterval {
                return .recentlyStarted(secondsAgo: Int(elapsed))
            }
        }

        guard let cli = resolveCLI() else { return .cliUnavailable }

        do {
            let tokens = try await runStart(cli, policy, workingDirectory, credential)
            // Recorded only on success: a failed run must not suppress the next try.
            lastStartStore.recordStart(accountID: accountID, at: now)
            return .started(tokensUsed: tokens)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A reading older than this is not trusted to describe the present.
    static let stalenessLimit: TimeInterval = 5 * 60
}

// MARK: - CLI plumbing

public extension QuotaWindowProbe {
    /// Where the CLI is looked for, in order of preference.
    public static let cliSearchPaths: [String] = [
        "~/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]

    public static let defaultCLI: @Sendable () -> URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in cliSearchPaths {
            let expanded = (path as NSString).expandingTildeInPath
            let url = path.hasPrefix("~") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: expanded)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static var defaultWorkingDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexRunway/probe-workdir", isDirectory: true)
    }

    /// Runs one `codex exec` and returns the token count it reported.
    ///
    /// `--ephemeral` keeps the exchange out of the user's conversation history, and
    /// the dedicated working directory keeps it away from any project.
    ///
    /// The credential is supplied through a throwaway `CODEX_HOME`, not by writing the
    /// real `~/.codex/auth.json`. That file belongs to whichever account is active, so
    /// using it would mean every account's probe actually spent the active account's
    /// quota and opened the active account's window. A private home also means a
    /// crash or a cancellation mid-run cannot leave the user's own sign-in pointing at
    /// the wrong account.
    public static let runCLIStart: @Sendable (URL, QuotaWindowProbePolicy, URL, CodexAuth) async throws -> Int? = { cli, policy, workdir, credential in
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: workdir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("codex-runway-probe-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: sandbox, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: sandbox) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(credential).write(
            to: sandbox.appendingPathComponent("auth.json"), options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sandbox.appendingPathComponent("auth.json").path)

        // `model_provider=openai` is not decoration: the CLI otherwise resolves the
        // provider from `~/.codex/config.toml`, which this app itself rewrites when the
        // user switches to a relay account. With a relay selected the request would be
        // sent to that relay, and a relay has no 5-hour window to open — the probe
        // would spend a request and achieve nothing, silently. Pinning the provider
        // keeps the trigger on the subscription endpoint regardless of which account
        // is active in Codex.
        let arguments = [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "-C", workdir.path,
            "-m", policy.model,
            "-c", "model_reasoning_effort=\"\(policy.reasoningEffort)\"",
            "-c", "model_provider=\"\(policy.provider)\"",
            policy.prompt,
        ]

        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.currentDirectoryURL = workdir
        // Scoped sign-in: the child sees only this account's credential.
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = sandbox.path
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Close stdin so the CLI cannot block waiting for input.
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // A bounded wait: this runs in the background, but it must not hang forever.
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw ProbeError.timedOut
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            // The server's own message is the useful part, so it is surfaced verbatim
            // but trimmed: it can be long and may echo request details.
            let detail = (err + out)
                .split(separator: "\n")
                .first { $0.contains("ERROR") || $0.contains("error") }
                .map { String($0).prefix(200) }
            throw ProbeError.cliFailed(
                status: process.terminationStatus,
                detail: detail.map(String.init) ?? "exit \(process.terminationStatus)")
        }
        return parseTokenCount(from: out)
    }

    /// Reads the `tokens used` figure the CLI prints, when present.
    static func parseTokenCount(from output: String) -> Int? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = lines.firstIndex(where: { $0.lowercased() == "tokens used" }),
              index + 1 < lines.count
        else { return nil }
        return Int(lines[index + 1].replacingOccurrences(of: ",", with: ""))
    }

    enum ProbeError: Error, LocalizedError {
        case cliFailed(status: Int32, detail: String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .cliFailed(let status, let detail): return "codex exit \(status): \(detail)"
            case .timedOut: return "codex timed out"
            }
        }
    }
}

// MARK: - Start lock

/// Remembers when each account last had a window started, so the probe cannot run
/// twice in a row.
public struct ProbeStartStore: Sendable {
    public var directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway/window-probe", isDirectory: true)
    }

    private func url(for accountID: String) -> URL {
        let safe = accountID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent("\(String(safe)).json")
    }

    public func lastStart(accountID: String) -> Date? {
        guard let data = try? Data(contentsOf: url(for: accountID)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["lastStart"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    @discardableResult
    public func recordStart(accountID: String, at date: Date) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(
                withJSONObject: ["lastStart": date.timeIntervalSince1970], options: [.sortedKeys])
            try data.write(to: url(for: accountID), options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url(for: accountID).path)
            return true
        } catch {
            Logger(subsystem: "com.github.codex-runway", category: "window-probe")
                .error("probe_lock_write_failed")
            return false
        }
    }
}
