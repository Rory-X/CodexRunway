import Foundation
import Testing
@testable import CodexRunwayCore

/// The codes are persisted in `index.json`, so they have to stay machine-readable;
/// rendering one directly puts an identifier where a person expects an explanation.
@Suite("Account error codes")
struct AccountErrorCodeTests {
    @Test("every code this app writes has localized text", arguments: AccountErrorCode.known.sorted())
    func knownCodesAreLocalized(code: String) {
        let l10n = L10n(language: .english)
        let text = AccountErrorCode.localizedText(for: code, l10n: l10n)
        #expect(text != nil, "\(code) has no localized text")
        // The point of the mapping: no internal identifier reaches the screen.
        #expect(text != code)
        #expect(!(text ?? "").contains("_"))
    }

    @Test("a rejected key and an unreachable relay read differently")
    func rejectedKeyIsDistinct() {
        let l10n = L10n(language: .english)
        let rejected = AccountErrorCode.localizedText(for: "relay_key_rejected", l10n: l10n)
        let unreachable = AccountErrorCode.localizedText(for: "relay_refresh_failed", l10n: l10n)
        #expect(rejected != nil)
        #expect(unreachable != nil)
        #expect(rejected != unreachable, "the two failures need different fixes, so different text")
    }

    /// Some errors are already user-facing, and replacing those with a generic string
    /// would drop the detail the caller supplied.
    @Test("an unrecognised value passes through untouched")
    func unknownCodePassesThrough() {
        #expect(AccountErrorCode.localizedText(
            for: "Import failed: file is not JSON", l10n: L10n(language: .english)) == nil)
    }

    @Test("every language renders the codes", arguments: ResolvedLanguage.allCases)
    func everyLanguageRenders(language: ResolvedLanguage) {
        let l10n = L10n(language: language)
        for code in AccountErrorCode.known {
            let text = AccountErrorCode.localizedText(for: code, l10n: l10n) ?? ""
            #expect(!text.isEmpty, "\(code) is empty for \(language.rawValue)")
            #expect(text != code, "\(code) leaks through for \(language.rawValue)")
        }
    }
}

/// The gate that keeps a relay key from reading ChatGPT quota, which is what made an
/// API-key account display another account's windows.
@Suite("Quota eligibility")
struct QuotaEligibilityTests {
    @Test("a relay key cannot report ChatGPT quota")
    func relayKeyCannotReport() {
        #expect(!QuotaEligibility.canReportQuota(.apiKey(apiKey: "sk-relay-key")))
    }

    @Test("a relay key with a leftover OAuth token still cannot report quota")
    func leftoverTokenDoesNotQualify() {
        // The real shape that caused another account's windows to appear: a key plus a
        // leftover `tokens` block that authenticates against a different account.
        let auth = CodexAuth(
            authMode: "apikey",
            tokens: CodexAuth.Tokens(
                idToken: nil,
                accessToken: String(repeating: "a", count: 1794),
                refreshToken: "",
                accountId: "someone-else"),
            lastRefresh: nil,
            planType: "api",
            authFilePlanType: "api",
            openAIAPIKey: "sk-relay-key")
        #expect(!QuotaEligibility.canReportQuota(auth))
    }

    @Test("an OAuth credential can report quota")
    func oauthCanReport() {
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: CodexAuth.Tokens(
                idToken: nil,
                accessToken: "access",
                refreshToken: "refresh",
                accountId: "acct"),
            lastRefresh: nil,
            planType: "plus",
            authFilePlanType: "plus",
            openAIAPIKey: nil)
        #expect(QuotaEligibility.canReportQuota(auth))
    }
}
