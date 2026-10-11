import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Relay config persistence")
struct RelayConfigProfileTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayprof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The date strategy must match on both sides: `capturedAt` is written as an
    /// ISO-8601 string, and a default (numeric) decoder rejects every file this store
    /// writes — saving appeared to work while loading always returned nil.
    @Test("a saved profile can be read back")
    func roundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RelayConfigStore(directory: dir)

        let profile = RelayConfigProfile(
            model: "gpt-6-astra",
            modelReasoningEffort: "xhigh",
            providerName: "custom",
            displayName: "apizn",
            baseURL: "https://ai.apizn.com/v1",
            wireAPI: "responses",
            requiresOpenAIAuth: true,
            supportsWebSockets: false)

        #expect(store.save(profile, for: "api-1"))
        let loaded = try #require(store.load(for: "api-1"))
        #expect(loaded.model == "gpt-6-astra")
        #expect(loaded.wireAPI == "responses")
        #expect(loaded.displayName == "apizn")
        #expect(loaded.requiresOpenAIAuth == true)
        #expect(loaded.supportsWebSockets == false)
    }

    @Test("an account with no profile reads as nil rather than failing")
    func missingProfileIsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(RelayConfigStore(directory: dir).load(for: "absent") == nil)
    }

    /// A crafted id must not be able to reach outside the store's directory.
    @Test("an account id cannot escape the storage directory")
    func idCannotEscapeDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RelayConfigStore(directory: dir)
        let hostile = "../../etc/passwd"

        #expect(store.save(RelayConfigProfile(model: "m"), for: hostile))
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.count == 1)
        #expect(!contents[0].contains("/"))
        #expect(store.load(for: hostile)?.model == "m")
    }

    @Test("a file from a newer schema is ignored rather than misread")
    func futureSchemaIgnored() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RelayConfigStore(directory: dir)
        _ = store.save(RelayConfigProfile(schemaVersion: 99, model: "m"), for: "api-1")
        #expect(store.load(for: "api-1") == nil)
    }

    @Test("an empty profile reports itself as empty")
    func emptyDetection() {
        #expect(RelayConfigProfile().isEmpty)
        #expect(!RelayConfigProfile(model: "m").isEmpty)
        #expect(!RelayConfigProfile(providerName: "custom").isEmpty)
    }

    // MARK: - Capture

    private func writeConfig(_ text: String) throws -> URL {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("config.toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("capture reads the provider section and the preamble")
    func capturesEverything() throws {
        let config = try writeConfig("""
        model = "gpt-6-astra"
        model_reasoning_effort = "xhigh"
        model_provider = "custom"

        [model_providers.custom]
        name = "apizn"
        wire_api = "responses"
        requires_openai_auth = true
        supports_websockets = false
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayProviderName: "custom")
        let profile = try #require(
            AccountRoutingCoordinator.captureProfile(account: account, configURL: config))

        #expect(profile.model == "gpt-6-astra")
        #expect(profile.modelReasoningEffort == "xhigh")
        // The section key and the display name are different fields.
        #expect(profile.providerName == "custom")
        #expect(profile.displayName == "apizn")
        #expect(profile.baseURL == "https://ai.apizn.com/v1")
        #expect(profile.wireAPI == "responses")
        #expect(profile.requiresOpenAIAuth == true)
        #expect(profile.supportsWebSockets == false)
    }

    /// An official account is defined by the absence of a provider; capturing the
    /// official endpoint as if it were a relay would then restore it later.
    @Test("an official account captures nothing")
    func officialCapturesNothing() throws {
        let config = try writeConfig("""
        model = "gpt-5.6-sol"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let account = ManagedAccount(id: "o-1", authMode: .oauth, displayName: "Official")
        #expect(AccountRoutingCoordinator.captureProfile(account: account, configURL: config) == nil)
    }

    @Test("a key inside a profile table is not captured as an account setting")
    func profileKeysAreNotCaptured() throws {
        let config = try writeConfig("""
        model = "gpt-6-astra"
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"

        [profiles.work]
        model_reasoning_effort = "low"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayProviderName: "custom")
        let profile = try #require(
            AccountRoutingCoordinator.captureProfile(account: account, configURL: config))
        #expect(profile.modelReasoningEffort == nil)
    }

    // MARK: - Restore

    /// The scenario the feature exists for: another tool rewrites the file, then the
    /// account is switched back and its own settings must return.
    @Test("stored settings are restored after another tool rewrites the file")
    func restoresAfterOverwrite() throws {
        let config = try writeConfig("""
        model = "gpt-6-astra"
        model_reasoning_effort = "xhigh"
        model_provider = "custom"

        [model_providers.custom]
        name = "apizn"
        wire_api = "responses"
        requires_openai_auth = true
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayBaseURL: "https://ai.apizn.com/v1", relayProviderName: "custom")
        let profile = try #require(
            AccountRoutingCoordinator.captureProfile(account: account, configURL: config))

        // Another tool replaces everything with its own idea of the settings.
        try """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "max"
        model_provider = "custom"

        [model_providers.custom]
        name = "OpenAI"
        wire_api = "chat"
        base_url = "https://aihub.dog/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        var target = account
        let plan = AccountRoutingCoordinator.plan(for: target, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &target, configURL: config,
            backupDirectory: config.deletingLastPathComponent().appendingPathComponent("bk"),
            profile: profile)

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.contains("https://ai.apizn.com/v1"), "the relay address must come back")
        #expect(text.contains("wire_api = \"responses\""), "the wire protocol must come back")
        #expect(text.contains("name = \"apizn\""), "the display name must come back")
        #expect(text.contains("gpt-6-astra"), "the model must come back")
        #expect(text.contains("xhigh"), "the reasoning effort must come back")
        // The other tool's values are gone, not shadowed.
        #expect(!text.contains("aihub.dog"))
        #expect(!text.contains("wire_api = \"chat\""))
        // Exactly one of each, so no duplicate decides the outcome.
        #expect(text.components(separatedBy: "base_url =").count == 2)
        #expect(text.components(separatedBy: "wire_api =").count == 2)
        #expect(text.components(separatedBy: "name =").count == 2)
    }

    // MARK: - Cross-account isolation

    /// The distinction the detail view depends on: the captured profile reports what the
    /// file says, while resolution of *this account's* endpoint goes through
    /// `attributableBaseURL`. Substituting one for the other made the "current config.toml"
    /// column show a value the file did not contain.
    @Test("capture reports the file's real address even when it belongs to another account")
    func captureReportsFileTruth() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        name = "custom"
        wire_api = "responses"
        base_url = "https://other-relay.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayBaseURL: "https://ai.apizn.com/v1", relayProviderName: "custom")
        let profile = try #require(
            AccountRoutingCoordinator.captureProfile(account: account, configURL: config))

        // Read-only view of the file: it must not pretend the file holds our address.
        #expect(profile.baseURL == "https://other-relay.example/v1")
        // Resolution, by contrast, follows the account.
        let resolved = NewAPIRelayResolver.baseURL(
            for: account, configURL: config, backupDirectory: nil,
            profileBaseURL: "https://ai.apizn.com/v1")
        #expect(resolved?.absoluteString == "https://ai.apizn.com")
    }

    /// A forwarder port is this machine's address, not the account's, so the section's
    /// real endpoint is still the better answer.
    @Test("capture prefers the real endpoint over the account's forwarder port")
    func capturePrefersRealEndpointOverForwarder() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayBaseURL: "http://127.0.0.1:15721/v1", relayProviderName: "custom")
        let profile = try #require(
            AccountRoutingCoordinator.captureProfile(account: account, configURL: config))

        #expect(profile.baseURL == "https://ai.apizn.com/v1")
    }

    /// A first switch has no address of its own, so the section still teaches it one.
    @Test("capture learns the address when the account has none")
    func captureLearnsAddressWhenUnknown() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayProviderName: "custom")
        let profile = try #require(
            AccountRoutingCoordinator.captureProfile(account: account, configURL: config))

        #expect(profile.baseURL == "https://ai.apizn.com/v1")
    }

    /// The mistake would otherwise be self-reinforcing: an account with no address of
    /// its own adopts whatever the shared section holds, and the next capture then
    /// saves that stranger's relay as the account's own setting.
    @Test("a switch seeds the account from its own settings, not the shared section")
    func switchSeedsFromOwnSettings() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://other-relay.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayProviderName: "custom")
        let stored = RelayConfigProfile(
            model: "gpt-6-astra", providerName: "custom",
            baseURL: "https://ai.apizn.com/v1", wireAPI: "responses", capturedAt: Date())

        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: config.deletingLastPathComponent().appendingPathComponent("bk"),
            profile: stored)

        #expect(account.relayBaseURL == nil)
        // And what gets captured next agrees, so the mistake cannot compound.
        let captured = try #require(
            AccountRoutingCoordinator.captureProfile(account: account, configURL: config))
        #expect(captured.baseURL == "https://ai.apizn.com/v1")
    }

    // MARK: - WebSocket default

    /// Relays commonly advertise WebSocket support without implementing it, and the
    /// failure names no cause. Off is therefore the default, and it is written on every
    /// switch rather than inherited: the section is shared, so an inherited value
    /// belongs to whichever account or tool touched it last.
    @Test("a switch writes WebSockets off when the account has no choice of its own")
    func switchDefaultsWebSocketsOff() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        supports_websockets = true
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayBaseURL: "https://ai.apizn.com/v1", relayProviderName: "custom")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: config.deletingLastPathComponent().appendingPathComponent("bk"),
            profile: nil)

        let text = try String(contentsOf: config, encoding: .utf8)
        let ws = CodexConfigReader.sectionValues(
            "model_providers.custom", toml: text)["supports_websockets"]
        #expect(ws == "false", "the file's stale `true` must not be inherited")
    }

    @Test("an account that chose WebSockets keeps them on across a switch")
    func switchPreservesAccountWebSocketChoice() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        supports_websockets = false
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayBaseURL: "https://ai.apizn.com/v1", relayProviderName: "custom")
        let stored = RelayConfigProfile(
            providerName: "custom", baseURL: "https://ai.apizn.com/v1",
            supportsWebSockets: true, capturedAt: Date())
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: config.deletingLastPathComponent().appendingPathComponent("bk"),
            profile: stored)

        let text = try String(contentsOf: config, encoding: .utf8)
        let ws = CodexConfigReader.sectionValues(
            "model_providers.custom", toml: text)["supports_websockets"]
        #expect(ws == "true")
    }

    @Test("a switch corrects a wrong address, not only a missing one")
    func switchCorrectsWrongAddress() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://previous-account-relay.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "apizn",
            relayBaseURL: "https://ai.apizn.com/v1", relayProviderName: "custom")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: config.deletingLastPathComponent().appendingPathComponent("bk"),
            profile: nil)

        // A present-but-wrong address sends this account's key to the previous
        // account's relay, which fails exactly like a missing one.
        let providers = CodexConfigReader.providerBaseURLs(configURL: config)
        #expect(providers["custom"] == "https://ai.apizn.com/v1")
    }

    /// The mechanism that corrupted a working account: a switch wrote the row's address
    /// and then a stored profile — captured from the shared section, so possibly another
    /// account's — overwrote it. The account then failed against a relay that had never
    /// issued its key.
    @Test("a stored profile never overrides the address the user entered")
    func profileDoesNotOverrideAccountRow() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "b893",
            relayBaseURL: "https://correct.example/v1", relayProviderName: "custom")
        let polluted = RelayConfigProfile(
            providerName: "custom", baseURL: "https://stranger.example/v1",
            capturedAt: Date())

        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: config.deletingLastPathComponent().appendingPathComponent("bk"),
            profile: polluted)

        let providers = CodexConfigReader.providerBaseURLs(configURL: config)
        #expect(providers["custom"] == "https://correct.example/v1")
        #expect(account.relayBaseURL == "https://correct.example/v1")
    }

    // MARK: - Reading the file as the file

    /// The file names one provider, so the answer belongs to whichever account is
    /// selected. Reading it through an account's recorded provider name could report a
    /// section the file does not actually select — and substituting that account's own
    /// stored address made the display contradict the file it claims to quote.
    @Test("the live read follows the file's own provider, not an account record")
    func liveReadUsesFileProvider() throws {
        let config = try writeConfig("""
        model = "gpt-6-astra"
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://file-says-this.example/v1"
        supports_websockets = false
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        let live = try #require(AccountRoutingCoordinator.liveProfile(configURL: config))
        #expect(live.providerName == "custom")
        #expect(live.baseURL == "https://file-says-this.example/v1")
        #expect(live.model == "gpt-6-astra")
    }

    @Test("with no provider selected there is no live relay to report")
    func liveReadWithoutSelection() throws {
        let config = try writeConfig("""
        model = "gpt-6-astra"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        // Codex is on its built-in endpoint; no relay section describes that state.
        #expect(AccountRoutingCoordinator.liveProfile(configURL: config) == nil)
    }

    /// The endpoint Codex itself will use. For the active account this outranks any
    /// record this app keeps, because it describes the request that will really be made.
    @Test("the selected provider's address is readable from the file alone")
    func configFileAddress() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://file-says-this.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        #expect(NewAPIRelayResolver.configFileBaseURL(configURL: config)?.absoluteString
            == "https://file-says-this.example")
    }

    @Test("an official endpoint is not reported as a relay address")
    func configFileSkipsOfficial() throws {
        let config = try writeConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://api.openai.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        #expect(NewAPIRelayResolver.configFileBaseURL(configURL: config) == nil)
    }
}
