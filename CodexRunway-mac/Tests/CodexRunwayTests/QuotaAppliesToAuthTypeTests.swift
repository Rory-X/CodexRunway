import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

/// A relay key must never read ChatGPT quota.
///
/// The failure this guards was subtle: `auth.json` can carry a leftover `tokens` block
/// beside the `OPENAI_API_KEY`, so a request made with the key's credential still
/// authenticates against whichever account that token belongs to. The quota that came
/// back was a *different* account's windows, and the menu bar showed them under the
/// relay account's name.
@Suite("Quota applies to the credential's type")
struct QuotaAppliesToAuthTypeTests {
    /// The shape that caused it: a key plus a leftover OAuth token, in one file.
    private func keyWithLeftoverTokens() throws -> CodexAuth {
        let json: [String: Any] = [
            "auth_mode": "apikey",
            "OPENAI_API_KEY": "sk-relay-key-value",
            "tokens": [
                "access_token": String(repeating: "a", count: 1794),
                "refresh_token": String(repeating: "r", count: 196),
                "account_id": "cc593648-1779-4e4c-9d7d-befa15f3a4e0",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(CodexAuth.self, from: data)
    }

    @Test("a key carrying leftover OAuth tokens is still an API-key credential")
    func keyWithLeftoverTokensIsAPIKey() throws {
        let auth = try keyWithLeftoverTokens()
        #expect(auth.isAPIKeyAuth, "the key must win over the leftover tokens")
        // The leftover token is exactly what made the old code's quota request succeed.
        #expect(auth.tokens.accessToken.count == 1794)
    }

    /// The rule the model applies before every quota read.
    @Test("a relay key is not eligible for a quota read")
    func relayKeyCannotReportQuota() throws {
        #expect(!QuotaEligibility.canReportQuota(try keyWithLeftoverTokens()))
    }

    @Test("a ChatGPT credential is still eligible")
    func chatGPTCredentialCanReportQuota() throws {
        let json: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": String(repeating: "a", count: 1794),
                "refresh_token": String(repeating: "r", count: 196),
                "account_id": "acct",
            ],
        ]
        let auth = try JSONDecoder().decode(
            CodexAuth.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(QuotaEligibility.canReportQuota(auth))
    }

    @Test("a refusal is distinguishable from a failure")
    func notApplicableIsItsOwnError() {
        // The refresh path returns this instead of throwing, so callers can tell "there
        // is no quota here" apart from "reading it went wrong".
        let refusal: Error = QuotaError.notApplicable
        #expect(refusal as? QuotaError == .notApplicable)
        #expect((URLError(.badServerResponse) as? QuotaError) == nil)
    }

    /// A plain `Error` bridges to an `NSError` whose description is the framework's
    /// own "The operation couldn't be completed. (… error 0.)" — a sentence naming an
    /// internal type instead of saying what happened.
    @Test("the refusal reads as a sentence, not a bridged NSError")
    func refusalIsLocalized() throws {
        let description = try #require(QuotaError.notApplicable.errorDescription)
        #expect(!description.isEmpty)
        #expect(!description.contains("QuotaError"))
        #expect(!description.lowercased().contains("couldn’t be completed"))
        #expect(!description.lowercased().contains("couldn't be completed"))
    }
}
