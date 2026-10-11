import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("New API relay resolution")
struct NewAPIRelayResolverTests {
    private func account(
        relayBaseURL: String? = nil,
        relayProviderName: String? = nil
    ) -> ManagedAccount {
        ManagedAccount(
            id: "acct-1",
            authMode: .apiKey,
            displayName: "relay",
            relayBaseURL: relayBaseURL,
            relayProviderName: relayProviderName)
    }

    private func writeConfig(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-\(UUID().uuidString).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("an explicitly typed address wins over the config file")
    func typedAddressWins() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://from-config.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        let url = NewAPIRelayResolver.baseURL(
            for: account(relayBaseURL: "https://typed.example/v1"),
            configURL: config)
        #expect(url?.absoluteString == "https://typed.example")
    }

    @Test("the /v1 suffix is stripped so dashboard paths do not nest under it")
    func stripsV1Suffix() {
        #expect(NewAPIRelayResolver.normalize("https://r.example.com/v1")?.absoluteString
            == "https://r.example.com")
        #expect(NewAPIRelayResolver.normalize("https://r.example.com/v1/")?.absoluteString
            == "https://r.example.com")
        #expect(NewAPIRelayResolver.normalize("https://r.example.com")?.absoluteString
            == "https://r.example.com")
    }

    @Test("falls back to the recorded provider, then the selected one")
    func providerFallback() throws {
        let config = try writeConfig("""
        model_provider = "selected"
        [model_providers.recorded]
        base_url = "https://recorded.example/v1"
        [model_providers.selected]
        base_url = "https://selected.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        #expect(NewAPIRelayResolver.baseURL(
            for: account(relayProviderName: "recorded"), configURL: config)?.absoluteString
            == "https://recorded.example")
        #expect(NewAPIRelayResolver.baseURL(
            for: account(), configURL: config)?.absoluteString
            == "https://selected.example")
    }

    @Test("an official OpenAI endpoint is not treated as a relay")
    func officialEndpointIsNotARelay() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://api.openai.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        // Querying the official API for relay quota would be meaningless.
        #expect(NewAPIRelayResolver.baseURL(for: account(), configURL: config) == nil)
        #expect(NewAPIRelayResolver.isOfficial(URL(string: "https://api.openai.com")!))
        #expect(NewAPIRelayResolver.isOfficial(URL(string: "https://chatgpt.com")!))
        #expect(!NewAPIRelayResolver.isOfficial(URL(string: "https://ai.apizn.com")!))
    }

    @Test("an unrelated provider is never used as the relay")
    func unrelatedProviderIsNotUsed() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://api.openai.com/v1"
        [model_providers.other]
        base_url = "https://other.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        // `custom` is official and is the selected provider, so there is no relay —
        // falling back to `other` would silently query the wrong host.
        #expect(NewAPIRelayResolver.baseURL(for: account(), configURL: config) == nil)
    }

    @Test("no config file yields no relay")
    func missingConfig() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).toml")
        #expect(NewAPIRelayResolver.baseURL(for: account(), configURL: missing) == nil)
    }
}

/// One `[model_providers.custom]` section is shared by every relay account, so its
/// `base_url` describes whichever account was switched to last. Reading it for anyone
/// else put a stranger's relay on the account, which then failed a refresh against a
/// host that had never issued its key.
@Suite("Relay address belongs to its own account")
struct NewAPIRelayAccountIsolationTests {
    private func account(
        relayBaseURL: String? = nil,
        relayProviderName: String? = "custom"
    ) -> ManagedAccount {
        ManagedAccount(
            id: "api-1",
            authMode: .apiKey,
            displayName: "relay",
            relayBaseURL: relayBaseURL,
            relayProviderName: relayProviderName)
    }

    private func writeConfig(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-\(UUID().uuidString).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("another account's address in the shared section is not used")
    func foreignSectionAddressIsNotUsed() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://other-relay.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        // This account's own captured settings name the relay it actually belongs to.
        let url = NewAPIRelayResolver.baseURL(
            for: account(),
            configURL: config,
            backupDirectory: nil,
            profileBaseURL: "https://ai.apizn.com/v1")
        #expect(url?.absoluteString == "https://ai.apizn.com")
    }

    @Test("the account's own row still outranks its captured settings")
    func accountRowOutranksProfile() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://other-relay.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        let url = NewAPIRelayResolver.baseURL(
            for: account(relayBaseURL: "https://typed.example/v1"),
            configURL: config,
            backupDirectory: nil,
            profileBaseURL: "https://stale.example/v1")
        #expect(url?.absoluteString == "https://typed.example")
    }

    /// A captured official endpoint is not a relay; using it would query the official
    /// API for a key it never issued.
    @Test("an official captured address is not treated as a relay")
    func officialProfileAddressIsSkipped() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://api.openai.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        let url = NewAPIRelayResolver.baseURL(
            for: account(),
            configURL: config,
            backupDirectory: nil,
            profileBaseURL: "https://api.openai.com/v1")
        #expect(url == nil)
    }

    @Test("a forwarder port in the captured settings is skipped")
    func loopbackProfileAddressIsSkipped() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        let url = NewAPIRelayResolver.baseURL(
            for: account(),
            configURL: config,
            backupDirectory: nil,
            profileBaseURL: "http://127.0.0.1:15721/v1")
        #expect(url?.absoluteString == "https://ai.apizn.com")
    }

    @Test("without captured settings the shared section is still used")
    func sectionIsUsedWhenNothingIsKnown() throws {
        let config = try writeConfig("""
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config) }

        let url = NewAPIRelayResolver.baseURL(
            for: account(),
            configURL: config,
            backupDirectory: nil,
            profileBaseURL: nil)
        #expect(url?.absoluteString == "https://ai.apizn.com")
    }
}

@Suite("New API usage math")
struct NewAPIUsageTests {
    @Test("quota units convert with the relay's own divisor")
    func quotaConversion() {
        let usage = NewAPIAccountUsage(
            remainingQuota: 954_911,
            usedQuota: 31_545_089,
            quotaPerUnit: 500_000)
        #expect(usage.remainingUSD == Decimal(string: "1.909822"))
        #expect(usage.usedUSD == Decimal(string: "63.090178"))
        // The real relay's grant came out to a whole dollar figure, which is the
        // signal that the divisor is right.
        #expect(usage.totalUSD == Decimal(65))
        #expect(usage.hasBalance)
    }

    @Test("the consumed fraction is derived from both halves")
    func usedFraction() {
        let usage = NewAPIAccountUsage(remainingQuota: 10, usedQuota: 90, quotaPerUnit: 1)
        let fraction = try? #require(usage.usedFraction)
        #expect(abs((fraction ?? 0) - 0.9) < 0.0001)
    }

    @Test("an unlimited key has no meaningful fraction")
    func unlimitedHasNoFraction() {
        let usage = NewAPIAccountUsage(
            remainingQuota: 10,
            usedQuota: 90,
            keyIsUnlimited: true,
            quotaPerUnit: 1)
        #expect(usage.usedFraction == nil)
    }

    @Test("the billing endpoint's total_usage is in cents")
    func billingUsageIsCents() {
        // Upstream multiplies USD by 100 before returning it.
        #expect(NewAPIUnits.usdFromBillingTotalUsage(6174.6386) == Decimal(string: "61.746386"))
    }

    @Test("a zero or missing grant does not divide by zero")
    func zeroGrantIsSafe() {
        #expect(NewAPIAccountUsage(remainingQuota: 0, usedQuota: 0, quotaPerUnit: 1).usedFraction == nil)
        #expect(NewAPIAccountUsage(remainingQuota: nil, usedQuota: nil, quotaPerUnit: 0).usedUSD == nil)
    }
}

/// A switcher app rewrites `base_url` to its own local port and forwards `/v1/*`
/// upstream. Model requests work through it, but the relay's dashboard API lives at
/// `/api/*` on the real site and answers 404 through a `/v1` forwarder — which made a
/// refresh fail while a perfectly good token was stored.
@Suite("Relay resolution through a local forwarder")
struct NewAPIRelayForwarderTests {
    private func account(
        relayBaseURL: String? = nil,
        relayProviderName: String? = nil
    ) -> ManagedAccount {
        ManagedAccount(
            id: "acct-1",
            authMode: .apiKey,
            displayName: "relay",
            relayBaseURL: relayBaseURL,
            relayProviderName: relayProviderName)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a loopback address is skipped in favour of the last real one")
    func loopbackIsSkipped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        try """
        model_provider = "custom"
        [model_providers.custom]
        base_url = "http://127.0.0.1:15721/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        // A backup still holds the real site the forwarder sits in front of.
        let backups = dir.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try """
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: backups.appendingPathComponent("config.toml.2026-09-22T06-07-15Z.bak"),
                  atomically: true, encoding: .utf8)

        let url = NewAPIRelayResolver.baseURL(
            for: account(relayProviderName: "custom"),
            configURL: config,
            backupDirectory: backups)
        #expect(url?.absoluteString == "https://ai.apizn.com")
    }

    @Test("a loopback address on the account row is skipped too")
    func loopbackOnAccountIsSkipped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        try """
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        // The account row itself was poisoned with the forwarder's port.
        let url = NewAPIRelayResolver.baseURL(
            for: account(relayBaseURL: "http://127.0.0.1:15721/v1", relayProviderName: "custom"),
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))
        #expect(url?.absoluteString == "https://ai.apizn.com")
    }

    @Test("a real typed address is still honoured")
    func realTypedAddressStands() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        try """
        [model_providers.custom]
        base_url = "https://from-config.example/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        let url = NewAPIRelayResolver.baseURL(
            for: account(relayBaseURL: "https://typed.example/v1"),
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))
        #expect(url?.absoluteString == "https://typed.example")
    }

    @Test("with no real address anywhere, the loopback one is better than nothing")
    func loopbackIsLastResort() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        try """
        model_provider = "custom"
        [model_providers.custom]
        base_url = "http://127.0.0.1:15721/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        // Nothing older to recover from: the forwarder address is returned so the
        // account is still usable for model traffic.
        let url = NewAPIRelayResolver.baseURL(
            for: account(relayProviderName: "custom"),
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))
        #expect(url?.absoluteString == "http://127.0.0.1:15721")
    }

    @Test("loopback detection covers localhost and 127.0.0.0/8")
    func loopbackDetection() {
        #expect(NewAPIRelayResolver.isLoopback(URL(string: "http://127.0.0.1:15721")!))
        #expect(NewAPIRelayResolver.isLoopback(URL(string: "http://127.1.2.3")!))
        #expect(NewAPIRelayResolver.isLoopback(URL(string: "http://localhost:3000")!))
        #expect(!NewAPIRelayResolver.isLoopback(URL(string: "https://ai.apizn.com")!))
        // A hostname that merely starts with 127 is not loopback.
        #expect(!NewAPIRelayResolver.isLoopback(URL(string: "https://127.example.com")!))
    }
}
