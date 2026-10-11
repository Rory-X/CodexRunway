import Foundation
import Darwin

/// Serializes Runway's switch and OAuth refresh commits in this process. Each file
/// is atomically renamed; the group is recovered from snapshots on failure.
enum AccountSwitchTransaction {
    enum Failure: Error, Equatable {
        case externalModification
        case missingEndpoint
        case invalidEndpoint
        case unsupportedConfiguration
        case invalidConfiguration
        case injected(String)
    }

    struct Snapshot: Sendable {
        let url: URL
        let original: Data?
    }

    struct RecoveryIncomplete: Error, CustomStringConvertible, Sendable {
        let cause: String
        let failedPaths: [String]
        /// Original bytes are retained in memory for explicit recovery. The
        /// config backup remains on disk; credentials are never copied outside
        /// the account auth locations.
        let snapshots: [Snapshot]
        let configBackupURL: URL?

        var description: String {
            "switch_recovery_incomplete paths=\(failedPaths.joined(separator: ","))"
        }
    }

    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var generations: [String: UInt64] = [:]
    static let refreshFlights = RefreshFlights()

    static func generation(for store: AccountStore) -> UInt64 {
        synchronized { generations[store.indexURL.path, default: 0] }
    }

    static func advance(for store: AccountStore) {
        synchronized { generations[store.indexURL.path, default: 0] &+= 1 }
    }

    static func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func read(_ url: URL) throws -> Data? {
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        return try Data(contentsOf: url)
    }

    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).runway-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd); Darwin.unlink(temporary.path) }
        guard Darwin.fchmod(fd, mode) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard Darwin.fsync(fd) == 0, Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    static func restore(_ original: Data?, at url: URL) throws {
        if let original {
            try atomicWrite(original, to: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func renderConfig(
        original: String?,
        account: ManagedAccount,
        profile: RelayConfigProfile?
    ) throws -> String {
        let text = original ?? ""
        let statements = try scan(text)
        var lines = text.components(separatedBy: "\n")
        let managedTop: Set<String> = [
            "model_provider", "openai_base_url", "chatgpt_base_url", "model",
            "model_reasoning_effort", "model_catalog_json", "model_context_window",
            "model_max_context_window", "model_auto_compact_token_limit",
        ]
        var remove = Set<Int>()
        for statement in statements {
            let channelSection = statement.section.map {
                $0 == "model_providers.custom" || $0.hasPrefix("model_providers.custom.")
                    || $0 == "model_providers.openai" || $0.hasPrefix("model_providers.openai.")
            } ?? false
            let managedKey = statement.section == nil && statement.key.map(managedTop.contains) == true
            if channelSection || managedKey {
                for line in statement.start...statement.end { remove.insert(line) }
            }
        }
        lines = lines.enumerated().compactMap { remove.contains($0.offset) ? nil : $0.element }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        let oauth = account.authMode == .oauth
        let context = CodexConfigProviderEditor.ContextWindow.standard
        var preamble = [
            "model_context_window = \(context.window)",
            "model_auto_compact_token_limit = \(context.compactLimit)",
        ]
        if !oauth {
            let raw = account.relayBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? profile?.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, !raw.isEmpty else { throw Failure.missingEndpoint }
            guard let endpoint = URLComponents(string: raw), endpoint.scheme?.lowercased() == "https",
                  endpoint.host?.isEmpty == false, endpoint.user == nil, endpoint.password == nil,
                  endpoint.fragment == nil else { throw Failure.invalidEndpoint }
            preamble.append("model_provider = \"custom\"")
            if let model = profile?.model, !model.isEmpty { preamble.append("model = \(quote(model))") }
            if let effort = profile?.modelReasoningEffort, !effort.isEmpty {
                preamble.append("model_reasoning_effort = \(quote(effort))")
            }
            // Restore only this account's explicit catalog; never inherit another
            // relay's catalog or leave Codex pointing at a missing local file.
            if let catalog = profile?.modelCatalogPath, catalog.hasPrefix("/"),
               FileManager.default.isReadableFile(atPath: catalog) {
                preamble.append("model_catalog_json = \(quote(catalog))")
            }
            let provider = [
                "[model_providers.custom]",
                "name = \(quote(profile?.displayName ?? "custom"))",
                "base_url = \(quote(raw))",
                "wire_api = \(quote(profile?.wireAPI ?? "responses"))",
                "requires_openai_auth = true",
                "supports_websockets = \(profile?.supportsWebSockets == true ? "true" : "false")",
            ]
            lines += [""] + provider
        }
        if oauth {
            if let model = profile?.model, !model.isEmpty { preamble.append("model = \(quote(model))") }
            if let effort = profile?.modelReasoningEffort, !effort.isEmpty {
                preamble.append("model_reasoning_effort = \(quote(effort))")
            }
        }
        let output = (preamble + [""] + lines).joined(separator: "\n")
        _ = try scan(output)
        return output.hasSuffix("\n") ? output : output + "\n"
    }

    private static func quote(_ value: String) -> String {
        CodexConfigProviderEditor.quoted(value)
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"\s*\.\s*"#, with: ".", options: .regularExpression)
    }

    private struct Statement {
        let start: Int
        let end: Int
        let section: String?
        let key: String?
    }

    /// Recognizes whole TOML assignments, including multiline arrays and strings.
    /// Channel aliases we cannot safely rewrite are rejected before any file write.
    private static func scan(_ text: String) throws -> [Statement] {
        let lines = text.components(separatedBy: "\n")
        var result: [Statement] = []
        var tables: Set<String> = []
        var keys: Set<String> = []
        var section: String?
        var index = 0
        while index < lines.count {
            let line = CodexConfigReader.stripComment(lines[index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                result.append(Statement(start: index, end: index, section: section, key: nil))
                index += 1
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw Failure.invalidConfiguration }
                let name = normalized(CodexConfigReader.sectionName(from: line))
                guard !name.isEmpty else { throw Failure.invalidConfiguration }
                if !line.hasPrefix("[["), !tables.insert(name).inserted {
                    throw Failure.invalidConfiguration
                }
                section = name
                keys = []
                result.append(Statement(start: index, end: index, section: section, key: nil))
                index += 1
                continue
            }
            guard let (rawKey, value) = CodexConfigReader.keyValue(from: line),
                  !value.isEmpty else { throw Failure.invalidConfiguration }
            let key = normalized(rawKey)
            guard keys.insert(key).inserted else { throw Failure.invalidConfiguration }
            if section == nil {
                if key == "model_providers" || key.hasPrefix("model_providers.") {
                    throw Failure.unsupportedConfiguration
                }
                if ["cli_auth_credentials_store", "forced_login_method", "forced_chatgpt_workspace_id"].contains(key) {
                    throw Failure.unsupportedConfiguration
                }
            } else if section == "model_providers" {
                // TOML allows openai.base_url and openai={...} in the parent table.
                // They must never survive beside the generated provider table.
                throw Failure.unsupportedConfiguration
            }
            let end = try logicalEnd(lines: lines, first: index, value: value)
            result.append(Statement(start: index, end: end, section: section, key: key))
            index = end + 1
        }
        return result
    }

    private static func logicalEnd(lines: [String], first: Int, value: String) throws -> Int {
        let initial = value.trimmingCharacters(in: .whitespaces)
        guard let firstCharacter = initial.first else { throw Failure.invalidConfiguration }
        if !["\"", "'", "[", "{"].contains(firstCharacter) {
            let bare = CodexConfigReader.stripComment(initial).trimmingCharacters(in: .whitespaces)
            let valid = ["true", "false", "inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(bare)
                || bare.range(of: #"^[+-]?(?:0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?|[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt ][0-9:.+\-Zz]+)?|[0-9]{2}:[0-9]{2}:[0-9.]+)$"#, options: .regularExpression) != nil
            guard valid else { throw Failure.invalidConfiguration }
        }
        var arrayDepth = 0
        var tableDepth = 0
        var quote: Character?
        var triple: Character?
        var escaped = false
        for lineNumber in first..<lines.count {
            let fragment = lineNumber == first ? value : lines[lineNumber]
            let characters = Array(fragment)
            var cursor = 0
            while cursor < characters.count {
                let character = characters[cursor]
                if let activeTriple = triple {
                    if escaped { escaped = false; cursor += 1; continue }
                    if activeTriple == "\"", character == "\\" { escaped = true; cursor += 1; continue }
                    if character == activeTriple, cursor + 2 < characters.count,
                       characters[cursor + 1] == activeTriple, characters[cursor + 2] == activeTriple {
                        triple = nil
                        cursor += 3
                    } else { cursor += 1 }
                    continue
                }
                if let activeQuote = quote {
                    if escaped { escaped = false; cursor += 1; continue }
                    if activeQuote == "\"", character == "\\" { escaped = true; cursor += 1; continue }
                    if character == activeQuote { quote = nil }
                    cursor += 1
                    continue
                }
                if character == "#" { break }
                if character == "\"" || character == "'" {
                    if cursor + 2 < characters.count,
                       characters[cursor + 1] == character, characters[cursor + 2] == character {
                        triple = character
                        cursor += 3
                    } else {
                        quote = character
                        cursor += 1
                    }
                    continue
                }
                switch character {
                case "[": arrayDepth += 1
                case "]": arrayDepth -= 1
                case "{": tableDepth += 1
                case "}": tableDepth -= 1
                default: break
                }
                guard arrayDepth >= 0, tableDepth >= 0 else { throw Failure.invalidConfiguration }
                cursor += 1
            }
            guard quote == nil else { throw Failure.invalidConfiguration }
            if triple == nil, arrayDepth == 0, tableDepth == 0 { return lineNumber }
        }
        throw Failure.invalidConfiguration
    }

}

actor RefreshFlights {
    private var flights: [String: Task<CodexAuth, Error>] = [:]

    func run(key: String, operation: @escaping @Sendable () async throws -> CodexAuth) async throws -> CodexAuth {
        if let existing = flights[key] { return try await existing.value }
        let task = Task { try await operation() }
        flights[key] = task
        defer { flights[key] = nil }
        return try await task.value
    }
}
