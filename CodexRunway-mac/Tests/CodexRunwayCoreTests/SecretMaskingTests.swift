import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Secret masking")
struct SecretMaskingTests {
    @Test("a long secret keeps only a short head and tail")
    func masksLongSecret() throws {
        let key = "sk-KOEfRFYdpEXAMPLElongsecretvalue1234567890abcd"
        let masked = try #require(SecretMasking.mask(key))
        #expect(masked.hasPrefix("sk-K"))
        // The body must not survive: a screenshot or bug report would leak it.
        #expect(!masked.contains("EXAMPLE"))
        #expect(!masked.contains("1234567890"))
        // Length is still reported, so a truncated paste is visible.
        #expect(masked.contains("\(key.count)"))
    }

    /// Revealing the head of an 8-character value would reveal most of it.
    @Test("a short secret is masked entirely")
    func masksShortSecret() throws {
        #expect(try #require(SecretMasking.mask("abc123")).contains("abc") == false)
        #expect(SecretMasking.mask("abc12345") == "••••••••")
    }

    @Test("nothing to mask yields nil")
    func emptyYieldsNil() {
        #expect(SecretMasking.mask(nil) == nil)
        #expect(SecretMasking.mask("") == nil)
        #expect(SecretMasking.mask("   ") == nil)
    }

    @Test("credentials embedded in a URL are stripped")
    func stripsURLUserInfo() throws {
        let sanitized = try #require(
            SecretMasking.sanitizedURL("https://user:secret@relay.example/v1"))
        #expect(!sanitized.contains("secret"))
        #expect(sanitized.contains("relay.example"))
    }

    @Test("a credential in a query string is redacted, other parameters kept")
    func redactsQueryCredential() throws {
        let sanitized = try #require(
            SecretMasking.sanitizedURL("https://relay.example/v1?key=sk-abcdef&model=gpt"))
        #expect(!sanitized.contains("sk-abcdef"))
        #expect(sanitized.contains("model=gpt"))
    }

    @Test("a plain address is returned unchanged")
    func plainAddressUnchanged() {
        #expect(SecretMasking.sanitizedURL("https://ai.apizn.com/v1") == "https://ai.apizn.com/v1")
    }
}
