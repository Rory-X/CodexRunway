import Foundation

/// Minimal reader for the `[model_providers.<name>]` sections of Codex's
/// `~/.codex/config.toml`.
///
/// A full TOML parser is not warranted: the app needs exactly one thing from this
/// file — which provider names map to which `base_url`, so a managed account can be
/// matched to the relay it actually talks to. Anything the parser does not
/// understand is skipped rather than guessed at.
public enum CodexConfigReader {
    /// Provider name → base URL, in file order.
    public static func providerBaseURLs(configURL: URL) -> [String: String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
        return providerBaseURLs(toml: text)
    }

    /// The provider currently selected by `model_provider`, when present.
    public static func selectedProvider(configURL: URL) -> String? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return selectedProvider(toml: text)
    }

    public static func selectedProvider(toml text: String) -> String? {
        var currentSection: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                currentSection = sectionName(from: line)
                continue
            }
            // Only a top-level key counts; a `model_provider` inside a section is
            // a provider's own setting, not the selection.
            guard currentSection == nil else { continue }
            guard let (key, value) = keyValue(from: line), key == "model_provider" else { continue }
            return unquote(value)
        }
        return nil
    }

    public static func providerBaseURLs(toml text: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentProvider: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                currentProvider = providerName(fromSection: sectionName(from: line))
                continue
            }
            guard let provider = currentProvider,
                  let (key, value) = keyValue(from: line),
                  key == "base_url"
            else { continue }

            let url = unquote(value).trimmingCharacters(in: .whitespaces)
            if !url.isEmpty { result[provider] = url }
        }
        return result
    }

    /// Provider names in the order their `[model_providers.<name>]` sections appear.
    ///
    /// Callers that must pick a provider need a stable choice, and a dictionary
    /// gives them none: file order keeps the selection matching what the user sees
    /// at the top of their own config.
    /// Every top-level `key = value` in the file's preamble, excluding sections.
    ///
    /// Used to capture an account's own settings before another tool rewrites the
    /// file. Only the preamble is read: a key inside `[profiles.*]` or a provider
    /// section belongs to that table, not to the account.
    public static func topLevelValues(toml text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") { break }
            guard let (key, value) = keyValue(from: line) else { continue }
            result[key] = unquote(value).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// The keys of one `[<section>]` table, header excluded.
    public static func sectionValues(
        _ section: String,
        toml text: String
    ) -> [String: String] {
        var result: [String: String] = [:]
        var inside = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                // A sub-table of the wanted section keeps us inside it; any other
                // header ends the search.
                inside = sectionName(from: line) == section
                continue
            }
            guard inside, let (key, value) = keyValue(from: line) else { continue }
            result[key] = unquote(value).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    public static func providerNamesInFileOrder(toml text: String) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }
            guard let name = providerName(fromSection: sectionName(from: line)) else { continue }
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    public static func providerNamesInFileOrder(configURL: URL) -> [String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return providerNamesInFileOrder(toml: text)
    }

    // MARK: - Line parsing

    /// The provider name when the section is `model_providers.<name>`;
    /// nil for any other section (including the bare `[model_providers]`).
    static func providerName(fromSection section: String) -> String? {
        let parts = section.split(separator: ".").map(String.init)
        guard parts.count >= 2, parts[0] == "model_providers" else { return nil }
        // A quoted provider name may itself contain dots.
        let name = parts.dropFirst().joined(separator: ".")
        let trimmed = unquote(name)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sectionName(from line: String) -> String {
        var text = line
        if text.hasPrefix("[[") {
            text = String(text.dropFirst(2))
        } else if text.hasPrefix("[") {
            text = String(text.dropFirst())
        }
        if text.hasSuffix("]]") {
            text = String(text.dropLast(2))
        } else if text.hasSuffix("]") {
            text = String(text.dropLast())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func keyValue(from line: String) -> (String, String)? {
        guard let index = line.firstIndex(of: "=") else { return nil }
        let key = line[..<index].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    /// Drops a trailing `#` comment that is not inside a quoted string.
    static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var result = ""
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inDouble:
                result.append(character)
                escaped = true
            case "\"" where !inSingle:
                inDouble.toggle()
                result.append(character)
            case "'" where !inDouble:
                inSingle.toggle()
                result.append(character)
            case "#" where !inSingle && !inDouble:
                return result
            default:
                result.append(character)
            }
        }
        return result
    }

    static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        } else if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
