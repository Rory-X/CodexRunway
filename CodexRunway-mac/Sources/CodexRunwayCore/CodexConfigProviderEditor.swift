import Foundation

/// Rewrites **only** the top-level `model_provider` line of Codex's
/// `~/.codex/config.toml`.
///
/// Why this exists: `model_provider` is the single global switch for *where*
/// traffic goes, while `auth.json` only says *which credential* to present. A
/// relay account and an official account need different providers, but switching
/// accounts used to leave this line untouched — so an official OAuth credential
/// kept talking to the relay address. Every other line in the file (plugins,
/// mcp_servers, projects, desktop settings, model, catalogs) is preserved
/// byte-for-byte, because the file belongs to Codex and is re-serialized by it.
public enum CodexConfigProviderEditor {
    public enum Outcome: Sendable, Equatable {
        /// The file already said what it needed to say.
        case unchanged
        case updated(previous: String?, current: String?)
        case failed(String)
    }

    /// Backups live in CodexRunway's own directory: `~/.codex/config.toml` is
    /// Codex's file, and it is already littered with other tools' `.bak` files.
    public static func defaultBackupDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway/config-backups", isDirectory: true)
    }

    /// Sets the top-level `model_provider` to `name`, or removes the line when
    /// `name` is nil (which restores Codex's own default provider — the official
    /// endpoint for a ChatGPT login).
    @discardableResult
    public static func setSelectedProvider(
        _ name: String?,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil

        // No config file means Codex is running on its built-in defaults, which is
        // exactly the state we would write for an official account. Creating the file
        // ourselves would be a far larger step than the user asked for.
        guard fileManager.fileExists(atPath: configURL.path) else {
            return .unchanged
        }

        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }

        let previous = CodexConfigReader.selectedProvider(toml: text)
        if previous == normalized { return .unchanged }

        let rewritten = replacingTopLevelProvider(in: text, with: normalized)

        // Only pay for a backup when the content actually changes.
        do {
            try backup(text, directory: backupDirectory ?? defaultBackupDirectory(fileManager: fileManager),
                       fileManager: fileManager)
        } catch {
            return .failed("config_backup_failed")
        }
        do {
            try atomicWrite(rewritten, to: configURL, fileManager: fileManager)
        } catch {
            return .failed("config_write_failed")
        }
        return .updated(previous: previous, current: normalized)
    }

    /// Restores the `base_url` of one `[model_providers.<name>]` section.
    ///
    /// Codex re-serializes `config.toml` from its own model, and that rewrite drops
    /// keys it does not recognise — a relay's `base_url` disappears while the
    /// Creates a `[model_providers.<name>]` section when the file has none.
    ///
    /// Codex re-serializes `config.toml` from its own model, and a section it does not
    /// recognise can be dropped entirely rather than merely emptied. Without the
    /// section there is nowhere to put `base_url`, so a relay account would fall back
    /// to the official endpoint while still presenting its relay key — the request
    /// then fails authentication against a host that never issued the key.
    @discardableResult
    public static func ensureProviderSection(
        _ name: String,
        baseURL: String,
        wireAPI: String? = "responses",
        requiresOpenAIAuth: Bool? = true,
        displayName: String? = nil,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        let provider = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !address.isEmpty else { return .failed("invalid_argument") }
        guard fileManager.fileExists(atPath: configURL.path) else { return .unchanged }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }
        // An existing section is left to the field setters, which keep its other keys.
        guard sectionRange(of: provider, in: text) == nil else { return .unchanged }

        var block = "\n[model_providers.\(provider)]\n"
        block += "name = \(quoted(displayName ?? provider))\n"
        if let requiresOpenAIAuth {
            block += "requires_openai_auth = \(requiresOpenAIAuth)\n"
        }
        if let wireAPI, !wireAPI.isEmpty {
            block += "wire_api = \(quoted(wireAPI))\n"
        }
        block += "base_url = \(quoted(address))\n"

        var rewritten = text
        if !rewritten.hasSuffix("\n") { rewritten += "\n" }
        rewritten += block

        return writeOutcome(
            rewritten, original: text, configURL: configURL,
            backupDirectory: backupDirectory, fileManager: fileManager,
            previous: nil, current: address)
    }

    /// section header and its other keys survive. Since the relay address is what
    /// makes a relay account work at all, it has to be recoverable from somewhere
    /// that outlives that rewrite.
    ///
    /// Returns `.unchanged` when the section already declares the same address, so
    /// this is safe to call on every switch.
    @discardableResult
    public static func setProviderBaseURL(
        _ rawURL: String,
        forProvider name: String,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        let address = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !name.isEmpty else { return .failed("invalid_argument") }
        guard fileManager.fileExists(atPath: configURL.path) else { return .unchanged }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }

        // Only touch the section for this provider; a same-named key elsewhere is
        // another provider's business.
        guard let range = sectionRange(of: name, in: text) else { return .failed("provider_missing") }
        let section = String(text[range])
        if existingBaseURL(in: section) == address { return .unchanged }

        let rewritten = replacingBaseURL(in: text, section: range, with: address)

        do {
            try backup(text, directory: backupDirectory ?? defaultBackupDirectory(fileManager: fileManager),
                       fileManager: fileManager)
        } catch {
            return .failed("config_backup_failed")
        }
        do {
            try atomicWrite(rewritten, to: configURL, fileManager: fileManager)
        } catch {
            return .failed("config_write_failed")
        }
        return .updated(previous: existingBaseURL(in: section), current: address)
    }

    /// Character range of a `[model_providers.<name>]` section body, header included.
    ///
    /// When a file declares the same section twice — which a sequence of tools
    /// rewriting the same file does produce — later declarations override earlier
    /// ones, because that is how a TOML reader resolves duplicate tables. Writing into
    /// the first would edit a section Codex ignores, so the *last* one is returned.
    static func sectionRange(of name: String, in text: String) -> Range<String.Index>? {
        let all = sectionRanges(of: name, in: text)
        // The effective section: a later duplicate wins.
        return all.last
    }

    /// Every declaration of `[model_providers.<name>]`, in file order.
    static func sectionRanges(of name: String, in text: String) -> [Range<String.Index>] {
        let header = "[model_providers.\(name)]"
        let subHeaderPrefix = "[model_providers.\(name)."
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex

        func close(at end: String.Index) {
            if let opened = start { ranges.append(opened..<end) }
            start = nil
        }

        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let trimmed = text[index..<lineEnd].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if let _ = start {
                    // A sub-table of ours does not end the section; any other header,
                    // including a repeat of the same one, does.
                    if !trimmed.hasPrefix(subHeaderPrefix) {
                        close(at: index)
                        if trimmed == header || trimmed.hasPrefix(header + " ") {
                            start = index
                        }
                    }
                } else if trimmed == header || trimmed.hasPrefix(header + " ") {
                    start = index
                }
            }
            guard lineEnd < text.endIndex else { break }
            index = text.index(after: lineEnd)
        }
        close(at: text.endIndex)
        return ranges
    }

    /// Collapses duplicate sections, keeping the last declaration's values.
    ///
    /// Codex reads the last table, so the earlier ones are dead weight that make the
    /// file lie about where a value comes from.
    @discardableResult
    public static func collapseDuplicateSections(
        _ name: String,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }
        let ranges = sectionRanges(of: name, in: text)
        guard ranges.count > 1 else { return .unchanged }

        // Keep the last; drop the earlier ones entirely.
        var result = text
        for range in ranges.dropLast().reversed() {
            result.removeSubrange(range)
        }
        // Tidy any blank run the removal left behind.
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return writeOutcome(
            result, original: text, configURL: configURL,
            backupDirectory: backupDirectory, fileManager: fileManager,
            previous: "\(ranges.count) sections", current: "1")
    }

    static func existingBaseURL(in section: String) -> String? {
        for line in section.split(separator: "\n", omittingEmptySubsequences: false) {
            let cleaned = CodexConfigReader.stripComment(String(line))
                .trimmingCharacters(in: .whitespaces)
            guard let (key, value) = CodexConfigReader.keyValue(from: cleaned), key == "base_url" else { continue }
            return CodexConfigReader.unquote(value).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func replacingBaseURL(
        in text: String,
        section: Range<String.Index>,
        with address: String
    ) -> String {
        let body = String(text[section])
        var lines = body.components(separatedBy: "\n")
        var replaced = false
        for (index, raw) in lines.enumerated() {
            let cleaned = CodexConfigReader.stripComment(raw).trimmingCharacters(in: .whitespaces)
            guard let (key, _) = CodexConfigReader.keyValue(from: cleaned), key == "base_url" else { continue }
            lines[index] = "base_url = \(quoted(address))"
            replaced = true
            break
        }
        if !replaced {
            // No address line survived the rewrite: put one directly under the header
            // so the section reads normally.
            if lines.count > 1 {
                lines.insert("base_url = \(quoted(address))", at: 1)
            } else {
                lines.append("base_url = \(quoted(address))")
            }
        }
        return String(text[text.startIndex..<section.lowerBound])
            + lines.joined(separator: "\n")
            + String(text[section.upperBound...])
    }

    /// `model_catalog_json` values that are dead weight rather than a real choice.
    ///
    /// The relay tooling writes a *relative* path (`model-catalogs/relay-x.json`),
    /// which Codex resolves against its working directory rather than `~/.codex`.
    /// It therefore never loads: launching with that value fails outright
    /// ("No such file or directory"), so Codex has always fallen back to its bundled
    /// catalog. Such a value changes nothing and is removed so the intent is honest —
    /// a relay account uses Codex's own model list unless the user points at a real
    /// file.
    static func isInertCatalogPath(_ value: String) -> Bool {
        let unquoted = CodexConfigReader.unquote(value).trimmingCharacters(in: .whitespaces)
        guard !unquoted.isEmpty else { return false }
        // Only a bare relative path is inert; anything absolute or `~`-rooted is a
        // deliberate, loadable choice and is left alone.
        if unquoted.hasPrefix("/") || unquoted.hasPrefix("~") { return false }
        if unquoted.hasPrefix("./") || unquoted.hasPrefix("../") { return false }
        return true
    }

    /// Top-level keys a relay sets that must not survive a switch to an official
    /// account.
    ///
    /// The three context-window keys are listed because a relay writes its own
    /// numbers here; `AccountRoutingCoordinator.apply` then writes this tool's values
    /// over them, so for an official account they are cleared and immediately
    /// replaced rather than left absent.
    ///
    /// A relay points Codex at its own model list, so it also writes
    /// `model_catalog_json` and the matching context-window limits. Those are relay
    /// facts, not user preferences: left in place, an official account keeps
    /// resolving models from a five-entry relay catalog and inherits a context
    /// window that belongs to someone else's endpoint. Codex never clears them (it
    /// re-serializes the file around them), so the switch has to.
    public static let relayOwnedModelKeys = [
        "model_catalog_json",
        "model_context_window",
        "model_max_context_window",
        "model_auto_compact_token_limit",
    ]

    /// Drops an unloadable `model_catalog_json` so a relay account falls back to
    /// Codex's own model list.
    @discardableResult
    public static func clearInertModelCatalog(
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard fileManager.fileExists(atPath: configURL.path) else { return .unchanged }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }
        guard let current = topLevelValue(of: "model_catalog_json", in: text),
              isInertCatalogPath(current)
        else { return .unchanged }
        guard let rewritten = removingTopLevelKeys(["model_catalog_json"], from: text) else {
            return .unchanged
        }

        do {
            try backup(text, directory: backupDirectory ?? defaultBackupDirectory(fileManager: fileManager),
                       fileManager: fileManager)
        } catch {
            return .failed("config_backup_failed")
        }
        do {
            try atomicWrite(rewritten, to: configURL, fileManager: fileManager)
        } catch {
            return .failed("config_write_failed")
        }
        return .updated(previous: current, current: nil)
    }

    /// The preamble's value for `key`, or nil when absent.
    static func topLevelValue(of key: String, in text: String) -> String? {
        var inSection = false
        for raw in text.components(separatedBy: "\n") {
            let cleaned = CodexConfigReader.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if cleaned.hasPrefix("[") { inSection = true }
            guard !inSection, let (name, value) = CodexConfigReader.keyValue(from: cleaned) else { continue }
            if name == key { return value }
        }
        return nil
    }

    /// Removes `relayOwnedModelKeys` from the top-level preamble.
    @discardableResult
    public static func clearRelayModelKeys(
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard fileManager.fileExists(atPath: configURL.path) else { return .unchanged }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }
        guard let rewritten = removingTopLevelKeys(relayOwnedModelKeys, from: text) else {
            return .unchanged
        }

        do {
            try backup(text, directory: backupDirectory ?? defaultBackupDirectory(fileManager: fileManager),
                       fileManager: fileManager)
        } catch {
            return .failed("config_backup_failed")
        }
        do {
            try atomicWrite(rewritten, to: configURL, fileManager: fileManager)
        } catch {
            return .failed("config_write_failed")
        }
        return .updated(previous: relayOwnedModelKeys.joined(separator: ","), current: nil)
    }

    /// Drops the named keys from the preamble, or nil when none were present.
    ///
    /// Only the preamble is touched. The same names can legitimately appear inside a
    /// `[profiles.*]` or project table, where they are that table's own settings.
    static func removingTopLevelKeys(_ keys: [String], from text: String) -> String? {
        let wanted = Set(keys)
        var lines = text.components(separatedBy: "\n")
        var removed = false
        var inSection = false
        var kept: [String] = []

        for raw in lines {
            let cleaned = CodexConfigReader.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if cleaned.hasPrefix("[") { inSection = true }
            if !inSection, let (key, _) = CodexConfigReader.keyValue(from: cleaned), wanted.contains(key) {
                removed = true
                continue
            }
            kept.append(raw)
        }
        guard removed else { return nil }
        lines = kept
        return lines.joined(separator: "\n")
    }

    /// Writes one `[model_providers.<name>]` field, leaving the rest of the section
    /// alone.
    ///
    /// A relay's section is created by whichever tool set that provider up, and those
    /// fields decide whether requests work at all (`wire_api`, and whether the
    /// endpoint wants the ChatGPT auth flow). Restoring only `base_url` left the
    /// others as whatever the last writer left behind.
    @discardableResult
    public static func setProviderField(
        _ name: String?,
        key: String,
        value: String?,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        let address = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider = name, !provider.isEmpty, !key.isEmpty else { return .failed("invalid_argument") }
        guard let address, !address.isEmpty else { return .unchanged }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }
        guard let range = sectionRange(of: provider, in: text) else { return .failed("provider_missing") }

        let existing = CodexConfigReader.sectionValues(
            "model_providers.\(provider)", toml: text)[key]
        if existing == address { return .unchanged }

        let rewritten = settingKey(key, to: address, inSection: range, of: text)

        do {
            try backup(text, directory: backupDirectory ?? defaultBackupDirectory(fileManager: fileManager),
                       fileManager: fileManager)
        } catch {
            return .failed("config_backup_failed")
        }
        do {
            try atomicWrite(rewritten, to: configURL, fileManager: fileManager)
        } catch {
            return .failed("config_write_failed")
        }
        return .updated(previous: existing, current: address)
    }

    /// Sets `key = value` inside a section, replacing all occurrences there.
    static func settingKey(
        _ key: String,
        to value: String,
        inSection range: Range<String.Index>,
        of text: String
    ) -> String {
        let body = String(text[range])
        var lines = body.components(separatedBy: "\n")
        var firstIndex: Int?
        var duplicates: [Int] = []

        for (index, raw) in lines.enumerated() {
            let cleaned = CodexConfigReader.stripComment(raw).trimmingCharacters(in: .whitespaces)
            // Line 0 is the section's own `[header]`. Skipping only that one, rather
            // than breaking on any `[`, is what lets the scan reach the section's keys:
            // a later `[` really is a sub-table and does end them.
            if index > 0, cleaned.hasPrefix("[") { break }
            guard let (name, _) = CodexConfigReader.keyValue(from: cleaned), name == key else { continue }
            if firstIndex == nil { firstIndex = index } else { duplicates.append(index) }
        }
        for index in duplicates.reversed() { lines.remove(at: index) }

        let replacement = "\(key) = \(tomlValue(value))"
        if let firstIndex {
            lines[firstIndex] = replacement
        } else if lines.count > 1 {
            lines.insert(replacement, at: 1)
        } else {
            lines.append(replacement)
        }
        return String(text[text.startIndex..<range.lowerBound])
            + lines.joined(separator: "\n")
            + String(text[range.upperBound...])
    }

    /// The context-window preamble this tool applies to every account.
    ///
    /// One window is used for all models on purpose. The bundled catalog advertises
    /// 272k for the current models, but the endpoints actually accept more, and a
    /// per-model figure would have to be refreshed every time the catalog changes.
    /// A single explicit value also stops a switcher's stale number (618k, 1000k) or
    /// a relay's own figure from silently deciding how much history Codex keeps.
    public struct ContextWindow: Sendable, Equatable {
        public var window: Int
        /// Fraction of the window at which Codex compacts, 0...1.
        public var compactFraction: Double
        /// What Codex advertises as the maximum, for endpoints that ask.
        public var maximum: Int

        public init(window: Int, compactFraction: Double, maximum: Int? = nil) {
            self.window = window
            self.compactFraction = compactFraction
            self.maximum = maximum ?? window
        }

        /// 400k with compaction at 90%.
        public static let standard = ContextWindow(window: 400_000, compactFraction: 0.9)

        /// The token count Codex compacts at, derived rather than hardcoded so the
        /// two values can never drift apart.
        public var compactLimit: Int { Int((Double(window) * compactFraction).rounded()) }

        /// The keys this writes, in the order they are written.
        var entries: [(key: String, value: Int)] {
            [
                ("model_context_window", window),
                ("model_max_context_window", maximum),
                ("model_auto_compact_token_limit", compactLimit),
            ]
        }
    }

    /// Writes the context-window preamble, replacing any existing values.
    ///
    /// Rewrites rather than appends: a switcher tool leaves its own numbers here, and
    /// a duplicate key would make Codex's behaviour depend on which line it reads
    /// first.
    @discardableResult
    public static func setContextWindow(
        _ settings: ContextWindow,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard fileManager.fileExists(atPath: configURL.path) else { return .unchanged }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }

        let previous = settings.entries.compactMap { entry in
            topLevelValue(of: entry.key, in: text)
        }.joined(separator: ",")
        let alreadyApplied = settings.entries.allSatisfy { entry in
            topLevelValue(of: entry.key, in: text)
                .map { CodexConfigReader.unquote($0).trimmingCharacters(in: .whitespaces) }
                == String(entry.value)
        }
        if alreadyApplied { return .unchanged }

        var rewritten = text
        for entry in settings.entries {
            rewritten = settingTopLevelKey(
                entry.key, to: String(entry.value), in: rewritten)
        }

        do {
            try backup(text, directory: backupDirectory ?? defaultBackupDirectory(fileManager: fileManager),
                       fileManager: fileManager)
        } catch {
            return .failed("config_backup_failed")
        }
        do {
            try atomicWrite(rewritten, to: configURL, fileManager: fileManager)
        } catch {
            return .failed("config_write_failed")
        }
        return .updated(previous: previous, current: settings.entries.map(\.value).map(String.init).joined(separator: ","))
    }

    /// Sets the top-level `model`.
    @discardableResult
    public static func setSelectedModel(
        _ model: String,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        setTopLevelKey("model", to: model, configURL: configURL,
                       backupDirectory: backupDirectory, fileManager: fileManager)
    }

    /// Sets one preamble key to a string value.
    @discardableResult
    public static func setTopLevelKey(
        _ key: String,
        to value: String,
        configURL: URL,
        backupDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failed("config_unreadable")
        }
        let previous = CodexConfigReader.topLevelValues(toml: text)[key]
        if previous == value { return .unchanged }
        let rewritten = settingTopLevelKey(key, to: quoted(value), in: text)
        return writeOutcome(
            rewritten, original: text, configURL: configURL,
            backupDirectory: backupDirectory, fileManager: fileManager,
            previous: previous, current: value)
    }

    /// Writes a rewritten file, backing up the original first.
    private static func writeOutcome(
        _ rewritten: String,
        original: String,
        configURL: URL,
        backupDirectory: URL?,
        fileManager: FileManager,
        previous: String?,
        current: String?
    ) -> Outcome {
        do {
            try backup(original, directory: backupDirectory ?? defaultBackupDirectory(fileManager: fileManager),
                       fileManager: fileManager)
        } catch {
            return .failed("config_backup_failed")
        }
        do {
            try atomicWrite(rewritten, to: configURL, fileManager: fileManager)
        } catch {
            return .failed("config_write_failed")
        }
        return .updated(previous: previous, current: current)
    }

    /// Sets one preamble key, replacing every existing occurrence.
    ///
    /// All duplicates are removed before the new value goes in at the first
    /// occurrence's position, so a file that already had the key twice ends up with
    /// exactly one.
    static func settingTopLevelKey(_ key: String, to value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inSection = false
        var firstIndex: Int?
        var duplicates: [Int] = []

        for (index, rawLine) in lines.enumerated() {
            let line = CodexConfigReader.stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = true; continue }
            guard !inSection, let (name, _) = CodexConfigReader.keyValue(from: line), name == key else { continue }
            if firstIndex == nil { firstIndex = index } else { duplicates.append(index) }
        }

        // Remove later duplicates first so the earlier indices stay valid.
        for index in duplicates.reversed() { lines.remove(at: index) }

        let replacement = "\(key) = \(value)"
        if let firstIndex {
            lines[firstIndex] = replacement
        } else {
            // No such key yet: place it after the last existing preamble line, so it
            // joins the other top-level settings instead of landing above them.
            var insertAt = 0
            for (index, rawLine) in lines.enumerated() {
                let line = CodexConfigReader.stripComment(rawLine).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                if !line.isEmpty { insertAt = index + 1 }
            }
            lines.insert(replacement, at: insertAt)
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces or removes the `model_provider` key that appears *before the
    /// first `[section]` header. A `model_provider` inside a section belongs to
    /// that section and is left alone.
    static func replacingTopLevelProvider(in text: String, with name: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        var inSection = false
        var replaced = false
        var insertAt: Int?

        for (index, rawLine) in lines.enumerated() {
            let line = CodexConfigReader.stripComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                inSection = true
                if insertAt == nil { insertAt = index }
                continue
            }
            guard !inSection else { continue }
            guard let (key, _) = CodexConfigReader.keyValue(from: line), key == "model_provider" else { continue }
            if let name {
                lines[index] = "model_provider = \(quoted(name))"
            } else {
                lines.remove(at: index)
            }
            replaced = true
            break
        }

        if !replaced, let name {
            // No top-level key yet: put it at the very top, ahead of the first
            // section, so the file keeps reading as a flat preamble.
            let at = insertAt ?? 0
            lines.insert("model_provider = \(quoted(name))", at: at)
        }

        return lines.joined(separator: "\n")
    }

    /// Formats a value for a TOML assignment.
    ///
    /// Quoting everything is the trap this avoids: `supports_websockets = "false"` is a
    /// *string*, not the boolean Codex expects, and the mismatch makes the whole config
    /// unreadable — Codex falls back to asking for a login instead of starting a
    /// conversation. Booleans and numbers are written bare; everything else is quoted.
    static func tomlValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" || trimmed == "false" { return trimmed }
        // An integer or decimal, with an optional sign, and nothing else in between.
        if trimmed.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil {
            return trimmed
        }
        return quoted(raw)
    }

    static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func backup(_ text: String, directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try AccountSwitchTransaction.atomicWrite(Data(text.utf8),
            to: directory.appendingPathComponent("config.toml.\(UUID().uuidString).bak"))
    }

    private static func atomicWrite(
        _ text: String,
        to url: URL,
        fileManager: FileManager
    ) throws {
        guard let data = text.data(using: .utf8) else { throw CocoaError(.fileWriteUnknown) }
        _ = fileManager
        try AccountSwitchTransaction.atomicWrite(data, to: url)
    }
}

extension CodexConfigProviderEditor {
    /// `~/.codex/config.toml` — Codex's own config, the single source of truth for
    /// which provider is selected.
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }
}
