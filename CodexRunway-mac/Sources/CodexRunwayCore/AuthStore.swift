import Foundation

public struct CodexAuthStore: Sendable {
    public var authURL: URL

    public init(authURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")) {
        self.authURL = authURL
    }

    public func load() throws -> CodexAuth {
        let data = try Data(contentsOf: authURL)
        return try JSONDecoder().decode(CodexAuth.self, from: data)
    }

    /// - Parameter allowUnusable: When true, permits writing incomplete credentials into the
    ///   managed account library. Official `~/.codex/auth.json` must keep this false.
    public func save(_ auth: CodexAuth, allowUnusable: Bool = false) throws {
        // Hard stop for the official login file: never install placeholder / truncated tokens.
        if !allowUnusable, auth.loginUsability == .invalidTokens {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        // Auth fields are a complete replacement. Merging the old document carries
        // a previous account's API key or OAuth tokens into the new login.
        var object = try auth.officialAuthJSONObject()

        // Codex expects a refresh_token key even for session-style access tokens (may be "").
        if var tokens = object["tokens"] as? [String: Any] {
            if tokens["refresh_token"] == nil {
                tokens["refresh_token"] = ""
            }
            if let id = tokens["id_token"] as? String, id.isEmpty {
                tokens.removeValue(forKey: "id_token")
            }
            if let account = tokens["account_id"] as? String, account.isEmpty {
                tokens.removeValue(forKey: "account_id")
            }
            object["tokens"] = tokens
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: authURL)
    }

    /// Install an already-encoded auth.json payload (preferred for account switch).
    public func saveRawJSONData(_ data: Data) throws {
        try save(JSONDecoder().decode(CodexAuth.self, from: data))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AccountSwitchTransaction.atomicWrite(data, to: url, mode: 0o600)
    }
}
