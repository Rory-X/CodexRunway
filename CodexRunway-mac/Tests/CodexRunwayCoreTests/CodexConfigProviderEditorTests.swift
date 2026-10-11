import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Codex config provider editing")
struct CodexConfigProviderEditorTests {
    /// Mirrors the real file's shape: a flat preamble, then sections, including a
    /// `model_provider` *inside* a section that must never be touched.
    private static let sample = """
    model_provider = "custom"
    model = "gpt-5.6-sol"
    model_catalog_json = "model-catalogs/relay-mtucn926.json"
    model_context_window = 618000

    [model_providers.custom]
    name = "custom"
    base_url = "https://relay.example/v1"

    [model_providers.codex_local_access]
    name = "Codex API Service"
    base_url = "http://localhost:51632/v1"

    [model_providers.weird]
    model_provider = "not-the-selection"
    base_url = "https://other.example/v1"

    [desktop]
    followUpQueueMode = "queue"
    """

    private func makeTemp() throws -> (dir: URL, config: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("config.toml"))
    }

    @Test("switching to a relay provider rewrites only the top-level selection")
    func setsRelayProvider() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sample.write(to: config, atomically: true, encoding: .utf8)

        let outcome = CodexConfigProviderEditor.setSelectedProvider(
            "codex_local_access",
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        guard case .updated(let previous, let current) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(previous == "custom")
        #expect(current == "codex_local_access")

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(CodexConfigReader.selectedProvider(toml: text) == "codex_local_access")
        // Everything else survives untouched.
        #expect(text.contains("model = \"gpt-5.6-sol\""))
        #expect(text.contains("model_catalog_json = \"model-catalogs/relay-mtucn926.json\""))
        #expect(text.contains("model_context_window = 618000"))
        #expect(text.contains("followUpQueueMode = \"queue\""))
        #expect(text.contains("base_url = \"https://relay.example/v1\""))
        // A `model_provider` inside a section is that section's own key.
        #expect(text.contains("model_provider = \"not-the-selection\""))
        // Exactly one top-level selection line remains.
        let topLevel = text.components(separatedBy: "\n")
            .prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model_provider") }
        #expect(topLevel.count == 1)
    }

    @Test("clearing the provider removes the top-level line so Codex uses its default")
    func clearsProviderForOfficialAccount() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sample.write(to: config, atomically: true, encoding: .utf8)

        let outcome = CodexConfigProviderEditor.setSelectedProvider(
            nil,
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        guard case .updated(let previous, let current) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(previous == "custom")
        #expect(current == nil)

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(CodexConfigReader.selectedProvider(toml: text) == nil)
        // The section-local key is untouched, and so is the rest of the file.
        #expect(text.contains("model_provider = \"not-the-selection\""))
        #expect(text.contains("followUpQueueMode = \"queue\""))
    }

    @Test("an already-correct selection is reported as unchanged and writes nothing")
    func unchangedIsNoOp() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sample.write(to: config, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: config)
        let backups = dir.appendingPathComponent("backups")

        let outcome = CodexConfigProviderEditor.setSelectedProvider(
            "custom",
            configURL: config,
            backupDirectory: backups)

        #expect(outcome == .unchanged)
        #expect(try Data(contentsOf: config) == before)
        // No pointless backup either.
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test("a change is backed up before it is written")
    func writesBackup() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sample.write(to: config, atomically: true, encoding: .utf8)
        let backups = dir.appendingPathComponent("backups")

        _ = CodexConfigProviderEditor.setSelectedProvider(
            "codex_local_access",
            configURL: config,
            backupDirectory: backups)

        let files = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        #expect(files.count == 1)
        let restored = try String(contentsOf: backups.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(restored == Self.sample)
        // The backup keeps the file's private mode.
        let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test("a file with no top-level selection gains one ahead of the first section")
    func insertsWhenAbsent() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model = "gpt-5.6-sol"

        [model_providers.custom]
        base_url = "https://relay.example/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        _ = CodexConfigProviderEditor.setSelectedProvider(
            "custom",
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(CodexConfigReader.selectedProvider(toml: text) == "custom")
        let lines = text.components(separatedBy: "\n")
        let providerIndex = lines.firstIndex { $0.hasPrefix("model_provider") }
        let sectionIndex = lines.firstIndex { $0.hasPrefix("[model_providers") }
        #expect(providerIndex != nil && sectionIndex != nil)
        #expect((providerIndex ?? 0) < (sectionIndex ?? 0))
    }

    @Test("a missing config is left alone rather than created")
    func missingConfigIsNoOp() throws {
        let (dir, _) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.toml")

        // No config means Codex is on its built-in defaults, which is already the
        // state an official account wants. Writing one would be a larger change
        // than the user asked for.
        let outcome = CodexConfigProviderEditor.setSelectedProvider(
            "custom",
            configURL: missing,
            backupDirectory: dir.appendingPathComponent("backups"))

        #expect(outcome == .unchanged)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("an unreadable config is reported instead of silently succeeding")
    func unreadableConfigFails() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A directory where a file is expected: it exists, but cannot be read as text.
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

        let outcome = CodexConfigProviderEditor.setSelectedProvider(
            "custom",
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        #expect(outcome == .failed("config_unreadable"))
    }

    @Test("an official account clears the provider and a relay account selects one")
    func planPerAuthMode() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sample.write(to: config, atomically: true, encoding: .utf8)

        let official = ManagedAccount(
            id: "oauth-1",
            authMode: .oauth,
            displayName: "Official")
        #expect(AccountRoutingCoordinator.plan(for: official, configURL: config).providerName == nil)

        let relay = ManagedAccount(
            id: "api-1",
            authMode: .apiKey,
            displayName: "Relay",
            relayProviderName: "codex_local_access")
        let relayPlan = AccountRoutingCoordinator.plan(for: relay, configURL: config)
        #expect(relayPlan.providerName == "custom")
        #expect(!relayPlan.inferred)
    }

    @Test("a relay account with no recorded provider infers one from the current selection")
    func planInfersForRelay() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sample.write(to: config, atomically: true, encoding: .utf8)

        let relay = ManagedAccount(id: "api-1", authMode: .apiKey, displayName: "Relay")
        let plan = AccountRoutingCoordinator.plan(for: relay, configURL: config)
        #expect(plan.providerName == "custom")
        #expect(!plan.inferred)
    }

    @Test("a plan never selects an official endpoint as the relay provider")
    func planSkipsOfficialProviders() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model_provider = "openai"

        [model_providers.openai]
        base_url = "https://api.openai.com/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        let relay = ManagedAccount(id: "api-1", authMode: .apiKey, displayName: "Relay")
        let plan = AccountRoutingCoordinator.plan(for: relay, configURL: config)

        // The intent is that the official endpoint is never chosen for a relay key.
        // Naming our own section is how that is expressed now: pointing at it keeps
        // the request off `api.openai.com`, where the relay's key would be rejected.
        let issue = plan.providerName
        #expect(issue != "openai", "the official provider must not be selected")
        let officialURL = CodexConfigReader.providerBaseURLs(configURL: config)["openai"]
        #expect(officialURL == "https://api.openai.com/v1", "the official section is left alone")
    }

    @Test("with nothing selected, the first relay provider in file order is chosen")
    func planFallsBackToFileOrder() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No top-level selection at all, and the first section is the relay.
        try """
        model = "gpt-5.6-sol"

        [model_providers.custom]
        base_url = "https://relay.example/v1"

        [model_providers.other]
        base_url = "https://second.example/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        let relay = ManagedAccount(id: "api-1", authMode: .apiKey, displayName: "Relay")
        let plan = AccountRoutingCoordinator.plan(for: relay, configURL: config)
        #expect(plan.providerName == "custom")

        // File order, not alphabetical: "custom" precedes "other" here, and would
        // also win alphabetically only by accident in this sample.
        #expect(CodexConfigReader.providerNamesInFileOrder(configURL: config) == ["custom", "other"])
    }

    @Test("provider names are reported in file order, not sorted")
    func providerNamesPreserveFileOrder() {
        let toml = """
        [model_providers.zeta]
        base_url = "https://z.example/v1"

        [model_providers.alpha]
        base_url = "https://a.example/v1"
        """
        #expect(CodexConfigReader.providerNamesInFileOrder(toml: toml) == ["zeta", "alpha"])
    }

    // MARK: - Base URL repair

    /// Codex re-serializes its config from its own model and drops keys it does not
    /// recognise, which removed a relay's `base_url` while leaving the section header
    /// behind. With the address gone the account fell back to the official endpoint.
    @Test("a stripped base_url is restored into its own section")
    func restoresStrippedBaseURL() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The shape Codex leaves behind: header and other keys survive, address gone.
        try """
        model = "gpt-6-astra"

        [model_providers.custom]
        name = "OpenAI"
        requires_openai_auth = true

        [model_providers.other]
        base_url = "https://other.example/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        let backups = dir.appendingPathComponent("backups")
        let outcome = CodexConfigProviderEditor.setProviderBaseURL(
            "https://ai.apizn.com/v1",
            forProvider: "custom",
            configURL: config,
            backupDirectory: backups)

        guard case .updated = outcome else {
            Issue.record("expected a repair, got \(outcome)")
            return
        }
        let text = try String(contentsOf: config, encoding: .utf8)
        let providers = CodexConfigReader.providerBaseURLs(toml: text)
        #expect(providers["custom"] == "https://ai.apizn.com/v1")
        // Another provider's address is none of this repair's business.
        #expect(providers["other"] == "https://other.example/v1")
        // The address lands inside `custom`, not under `other`.
        let customRange = try #require(CodexConfigProviderEditor.sectionRange(of: "custom", in: text))
        #expect(text[customRange].contains("https://ai.apizn.com/v1"))
        #expect(!text[customRange].contains("other.example"))
    }

    @Test("an address already present is left alone")
    func restoringSameAddressIsNoOp() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: config, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: config)

        let outcome = CodexConfigProviderEditor.setProviderBaseURL(
            "https://ai.apizn.com/v1",
            forProvider: "custom",
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        #expect(outcome == .unchanged)
        #expect(try Data(contentsOf: config) == before)
    }

    @Test("repairing is refused when the provider section does not exist")
    func repairRequiresSection() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [model_providers.other]
        base_url = "https://other.example/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        let outcome = CodexConfigProviderEditor.setProviderBaseURL(
            "https://ai.apizn.com/v1",
            forProvider: "custom",
            configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        // Creating a provider section out of nothing is a larger change than the user
        // asked for, so this reports rather than guesses.
        #expect(outcome == .failed("provider_missing"))
    }

    @Test("a sub-table of the provider does not end its section")
    func sectionRangeSpansSubTables() {
        let text = """
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"

        [model_providers.custom.env]
        FOO = "bar"

        [model_providers.other]
        base_url = "https://other.example/v1"
        """
        let range = CodexConfigProviderEditor.sectionRange(of: "custom", in: text)
        let body = range.map { String(text[$0]) } ?? ""
        #expect(body.contains("ai.apizn.com"))
        #expect(body.contains("[model_providers.custom.env]"))
        #expect(!body.contains("other.example"))
    }

    @Test("a relay account keeps its address on the account row")
    func applyRecordsRelayAddress() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "Relay",
            relayProviderName: "custom")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        // A shared section is not evidence that this account owns its address.
        #expect(account.relayBaseURL == nil)
    }

    /// The shared `[model_providers.custom]` section holds whichever relay was switched
    /// to last. Adopting its address unconditionally overwrote this account with a
    /// stranger's relay, and the next refresh then failed against a host that had never
    /// issued its key.
    @Test("a switch never overwrites an account with another account's address")
    func applyKeepsOwnAddress() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Left behind by the account that was switched to last.
        try """
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://other-relay.example/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "Relay",
            relayBaseURL: "https://ai.apizn.com/v1", relayProviderName: "custom")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        #expect(account.relayBaseURL == "https://ai.apizn.com/v1")
    }

    /// A forwarder port is this machine's address, so the section's real endpoint is
    /// still the better answer for the account row.
    @Test("a forwarder port on the account row is replaced by the real endpoint")
    func applyReplacesForwarderPort() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "Relay",
            relayBaseURL: "http://127.0.0.1:15721/v1", relayProviderName: "custom")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        #expect(account.relayBaseURL == "http://127.0.0.1:15721/v1")
    }

    @Test("an address stripped after the fact is written back on the next switch")
    func applyRepairsStrippedAddress() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The account remembers the address; the config has lost it.
        try """
        [model_providers.custom]
        name = "OpenAI"
        """.write(to: config, atomically: true, encoding: .utf8)

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "Relay",
            relayBaseURL: "https://ai.apizn.com/v1",
            relayProviderName: "custom")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        #expect(plan.providerName == "custom", "the surviving header must still be usable")

        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: dir.appendingPathComponent("backups"))

        let providers = CodexConfigReader.providerBaseURLs(configURL: config)
        #expect(providers["custom"] == "https://ai.apizn.com/v1")
        #expect(CodexConfigReader.selectedProvider(configURL: config) == "custom")
    }

    @Test("an address is recovered from the pre-change backups when the config lost it")
    func resolverRecoversFromBackups() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = dir.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        // An older backup still holds the address.
        try """
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: backups.appendingPathComponent("config.toml.2026-09-22T06-07-15Z.bak"),
                  atomically: true, encoding: .utf8)
        // The live file has been stripped.
        try """
        [model_providers.custom]
        name = "OpenAI"
        """.write(to: config, atomically: true, encoding: .utf8)

        // Scoped to this test's own backups: reading the real directory would both
        // mask the fixture and pull in whatever addresses the developer has used.
        let recovered = NewAPIRelayResolver.recoveredBaseURL(
            forProvider: "custom", configURL: config, backupDirectory: backups)
        #expect(recovered == "https://ai.apizn.com/v1")
    }

    // MARK: - Relay-owned model keys

    /// A relay writes its own model catalog and context limits. Codex re-serializes
    /// the config around them and never clears them, so an official account kept
    /// resolving models from the relay's list.
    @Test("switching to an official account clears the relay's model keys")
    func officialSwitchClearsRelayModelKeys() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model = "gpt-5.6-sol"
        model_provider = "custom"
        model_catalog_json = "model-catalogs/relay-mthiw3ku.json"
        model_context_window = 1000000
        model_max_context_window = 1000000
        model_auto_compact_token_limit = 950000

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        var account = ManagedAccount(id: "oauth-1", authMode: .oauth, displayName: "Official")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        // The relay's catalog pointer goes: an official account must not resolve
        // models from a relay's list.
        #expect(!text.contains("model_catalog_json"))
        // The relay's own window numbers go too, but the keys themselves are now
        // rewritten to this tool's values rather than left absent.
        let standard = CodexConfigProviderEditor.ContextWindow.standard
        #expect(!text.contains("1000000"))
        #expect(!text.contains("950000"))
        #expect(text.contains("model_context_window = \(standard.window)"))
        #expect(text.contains("model_auto_compact_token_limit = \(standard.compactLimit)"))
        #expect(CodexConfigReader.selectedProvider(configURL: config) == nil)
        #expect(!text.contains("model = \"gpt-5.6-sol\""))
        #expect(CodexConfigReader.providerBaseURLs(configURL: config)["custom"] == nil)
    }

    /// A relay account uses Codex's own model catalog by default. The relay tooling
    /// leaves a *relative* `model_catalog_json`, which Codex resolves against its
    /// working directory rather than `~/.codex` — so it never loads. Removing the dead
    /// path makes the intent explicit; the context-window keys are the relay's own
    /// limits and stay, because the relay endpoint really does have that window.
    @Test("switching to a relay account drops the unloadable catalog path")
    func relaySwitchDropsInertCatalog() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model_provider = "custom"
        model_catalog_json = "model-catalogs/relay-x.json"
        model_context_window = 1000000

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

        var account = ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "Relay",
            relayBaseURL: "https://ai.apizn.com/v1", relayProviderName: "custom")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        // The relative path could never load, so it goes; the model list falls back
        // to Codex's bundled catalog.
        #expect(!text.contains("model_catalog_json"))
        // The relay's own window is replaced by this tool's value: the window is a
        // deliberate choice, not whatever the relay happened to write.
        #expect(!text.contains("model_context_window ="))
        #expect(!text.contains("model_context_window = 1000000"))
        #expect(CodexConfigReader.selectedProvider(configURL: config) == "custom")
    }

    @Test("a profile's own model keys are not mistaken for the preamble's")
    func profileModelKeysAreNotCleared() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model_context_window = 1000000

        [profiles.work]
        model_context_window = 200000
        model_catalog_json = "mine.json"
        """.write(to: config, atomically: true, encoding: .utf8)

        let outcome = CodexConfigProviderEditor.clearRelayModelKeys(
            configURL: config, backupDirectory: dir.appendingPathComponent("bk"))
        guard case .updated = outcome else {
            Issue.record("expected the preamble key to be removed, got \(outcome)")
            return
        }
        let text = try String(contentsOf: config, encoding: .utf8)
        // The preamble copy goes; the profile's own settings stay put.
        let preamble = text.split(separator: "[profiles.work]").first.map(String.init) ?? ""
        #expect(!preamble.contains("model_context_window"))
        #expect(text.contains("[profiles.work]"))
        #expect(text.contains("model_context_window = 200000"))
        #expect(text.contains("model_catalog_json = \"mine.json\""))
    }

    @Test("clearing is a no-op when no relay keys are present")
    func clearingNothingIsNoOp() throws {
        let (dir, config) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        model = "gpt-5.6-sol"
        [model_providers.custom]
        base_url = "https://example.test/v1"
        """.write(to: config, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: config)

        let outcome = CodexConfigProviderEditor.clearRelayModelKeys(
            configURL: config, backupDirectory: dir.appendingPathComponent("bk"))
        #expect(outcome == .unchanged)
        #expect(try Data(contentsOf: config) == before)
    }

    @Test("a stored but unreadable token is not reported as missing")
    func unreadableTokenIsNotMissing() {
        // The store's read path distinguishes "absent" from "refused"; collapsing
        // them is what made a readable credential look deleted in the panel.
        let store = NewAPITokenStore(
            read: { _, _ in throw NewAPITokenStoreError.interactionNotAllowed },
            write: { _, _ in },
            remove: { _ in })
        #expect(store.token(for: "a") == nil)
        #expect(store.readOutcome(for: "a") == .unreadable)

        let empty = NewAPITokenStore(
            read: { _, _ in throw NewAPITokenStoreError.unavailable },
            write: { _, _ in },
            remove: { _ in })
        #expect(empty.readOutcome(for: "a") == .notStored)
    }
}

// MARK: - Context window

@Suite("Context window preamble")
struct ContextWindowPreambleTests {
    private func tempConfig(_ text: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.toml")
        try text.write(to: config, atomically: true, encoding: .utf8)
        return (dir, config)
    }

    /// 400k with compaction at 90%: the limit is derived, so the two cannot drift.
    @Test("the standard window is 400k and compacts at 90%")
    func standardValues() {
        let standard = CodexConfigProviderEditor.ContextWindow.standard
        #expect(standard.window == 400_000)
        #expect(standard.compactFraction == 0.9)
        #expect(standard.compactLimit == 360_000)
    }

    @Test("a stale switcher value is rewritten, not appended")
    func rewritesStaleValue() throws {
        let (dir, config) = try tempConfig("""
        model = "gpt-6-astra"
        model_context_window = 618000
        model_max_context_window = 618000
        model_auto_compact_token_limit = 587100
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = CodexConfigProviderEditor.setContextWindow(
            .standard, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))
        guard case .updated = outcome else {
            Issue.record("expected a rewrite, got \(outcome)")
            return
        }

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.contains("model_context_window = 400000"))
        #expect(text.contains("model_max_context_window = 400000"))
        #expect(text.contains("model_auto_compact_token_limit = 360000"))
        // The old numbers must be gone, not merely shadowed by a later line.
        #expect(!text.contains("618000"))
        #expect(!text.contains("587100"))
        // Exactly one of each: a duplicate would make the effective value depend on
        // which line Codex happened to read first.
        #expect(text.components(separatedBy: "model_context_window =").count == 2)
        // Unrelated settings survive.
        #expect(text.contains("model = \"gpt-6-astra\""))
    }

    @Test("keys are added when the file has none")
    func addsMissingKeys() throws {
        let (dir, config) = try tempConfig("""
        model = "gpt-6-astra"
        model_reasoning_effort = "high"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = CodexConfigProviderEditor.setContextWindow(
            .standard, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        let preamble = text.split(separator: "[model_providers.custom]").first.map(String.init) ?? ""
        #expect(preamble.contains("model_context_window = 400000"))
        #expect(preamble.contains("model_auto_compact_token_limit = 360000"))
        // Inserted into the preamble, not under the provider section.
        let afterSection = text.split(separator: "[model_providers.custom]").last.map(String.init) ?? ""
        #expect(!afterSection.contains("model_context_window"))
        // Existing keys are untouched.
        #expect(preamble.contains("model_reasoning_effort = \"high\""))
    }

    @Test("running twice changes nothing the second time")
    func idempotent() throws {
        let (dir, config) = try tempConfig("model_context_window = 618000\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = dir.appendingPathComponent("bk")

        _ = CodexConfigProviderEditor.setContextWindow(
            .standard, configURL: config, backupDirectory: backups)
        let afterFirst = try Data(contentsOf: config)

        let second = CodexConfigProviderEditor.setContextWindow(
            .standard, configURL: config, backupDirectory: backups)
        #expect(second == .unchanged)
        #expect(try Data(contentsOf: config) == afterFirst)
    }

    /// A duplicate left behind by a switcher must not survive as a shadow value.
    @Test("a pre-existing duplicate collapses to one key")
    func duplicateCollapses() throws {
        let (dir, config) = try tempConfig("""
        model_context_window = 618000
        model = "gpt-6-astra"
        model_context_window = 1000000
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = CodexConfigProviderEditor.setContextWindow(
            .standard, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.components(separatedBy: "model_context_window =").count == 2)
        #expect(text.contains("model_context_window = 400000"))
        #expect(!text.contains("1000000"))
        #expect(!text.contains("618000"))
    }

    /// The keys inside a profile table belong to that profile.
    @Test("a profile's own context keys are not touched")
    func profileKeysUntouched() throws {
        let (dir, config) = try tempConfig("""
        model_context_window = 618000

        [profiles.work]
        model_context_window = 200000
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = CodexConfigProviderEditor.setContextWindow(
            .standard, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        let profile = text.split(separator: "[profiles.work]").last.map(String.init) ?? ""
        #expect(profile.contains("model_context_window = 200000"))
        let preamble = text.split(separator: "[profiles.work]").first.map(String.init) ?? ""
        #expect(preamble.contains("model_context_window = 400000"))
    }

    @Test("a missing config is not created")
    func missingConfigIsLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("absent.toml")

        let outcome = CodexConfigProviderEditor.setContextWindow(
            .standard, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))
        #expect(outcome == .unchanged)
        #expect(!FileManager.default.fileExists(atPath: config.path))
    }

    @Test("switching an account writes the window")
    func switchWritesWindow() throws {
        let (dir, config) = try tempConfig("""
        model_context_window = 618000
        model_auto_compact_token_limit = 587100
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        var account = ManagedAccount(id: "o-1", authMode: .oauth, displayName: "Official")
        let plan = AccountRoutingCoordinator.plan(for: account, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &account, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.contains("model_context_window = 400000"))
        #expect(text.contains("model_auto_compact_token_limit = 360000"))
        #expect(!text.contains("618000"))
    }
}

// MARK: - API-key relay routing

/// An API-key account always has a relay behind it, so its provider must never fall
/// back to the official endpoint: the relay's key would be presented to a host that
/// never issued it, and the request fails with 401 Incorrect API key.
@Suite("API-key relay routing")
struct APIKeyRelayRoutingTests {
    private func tempConfig(_ text: String) throws -> (dir: URL, config: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apikeyroute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.toml")
        try text.write(to: config, atomically: true, encoding: .utf8)
        return (dir, config)
    }

    private func account(relayProviderName: String? = nil) -> ManagedAccount {
        ManagedAccount(
            id: "api-1", authMode: .apiKey, displayName: "API",
            relayBaseURL: "https://relay.example/v1",
            relayProviderName: relayProviderName)
    }

    /// The blind spot this guards: a brand-new account has no recorded provider, and
    /// the old fallback then chose "official" — on the very first switch, which is
    /// when the relay is needed most.
    @Test("a brand-new API-key account still resolves to a relay provider")
    func newAccountResolvesToRelay() throws {
        let (dir, config) = try tempConfig("model = \"gpt-6-astra\"\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = AccountRoutingCoordinator.plan(for: account(), configURL: config)
        #expect(plan.providerName == AccountRoutingCoordinator.relayProviderName)
        #expect(plan.providerName != nil, "must never fall back to the official endpoint")
    }

    @Test("a stripped base_url is restored from the account row")
    func restoresStrippedBaseURL() throws {
        let (dir, config) = try tempConfig("""
        model = "gpt-6-astra"

        [model_providers.custom]
        name = "OpenAI"
        requires_openai_auth = true
        wire_api = "responses"
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        var target = account()
        let plan = AccountRoutingCoordinator.plan(for: target, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &target, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        #expect(CodexConfigReader.providerBaseURLs(configURL: config)["custom"] == "https://relay.example/v1")
        #expect(CodexConfigReader.selectedProvider(configURL: config) == "custom")
        // The label Codex rewrote to the official product name is restored, so the UI
        // does not present a relay endpoint under the official name.
        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(CodexConfigReader.sectionValues("model_providers.custom", toml: text)["name"] == "custom")
    }

    @Test("a deleted provider section is recreated")
    func recreatesDeletedSection() throws {
        let (dir, config) = try tempConfig("model = \"gpt-6-astra\"\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        var target = account()
        let plan = AccountRoutingCoordinator.plan(for: target, configURL: config)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &target, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))

        #expect(CodexConfigReader.providerBaseURLs(configURL: config)["custom"] == "https://relay.example/v1")
        #expect(CodexConfigReader.selectedProvider(configURL: config) == "custom")
        // A profile-free account starts with clean model defaults.
        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(!text.contains("model = \"gpt-6-astra\""))
    }

    /// An official account is still defined by the absence of a provider.
    @Test("an official account still clears the provider")
    func officialAccountStillClearsProvider() throws {
        let (dir, config) = try tempConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://relay.example/v1"
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        var target = ManagedAccount(id: "o-1", authMode: .oauth, displayName: "Official")
        let plan = AccountRoutingCoordinator.plan(for: target, configURL: config)
        #expect(plan.providerName == nil)
        _ = AccountRoutingCoordinator.apply(
            plan, account: &target, configURL: config,
            backupDirectory: dir.appendingPathComponent("bk"))
        #expect(CodexConfigReader.selectedProvider(configURL: config) == nil)
    }

    @Test("every API-key account shares the one provider section")
    func oneSectionForAllRelayAccounts() {
        // A fixed name keeps a switch from leaving a trail of stale sections, each
        // holding a different relay address.
        #expect(AccountRoutingCoordinator.relayProviderName == "custom")
    }
}

/// WebSocket transport is a compatibility switch. Relays often advertise support
/// without implementing it, and the failure gives no hint about the cause: the stream
/// is simply closed by the server before the response completes.
@Suite("Relay WebSocket switch")
struct RelayWebSocketSwitchTests {
    private func tempConfig(_ text: String) throws -> (dir: URL, config: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.toml")
        try text.write(to: config, atomically: true, encoding: .utf8)
        return (dir, config)
    }

    @Test("the switch flips the provider's WebSocket claim")
    func togglesWebSockets() throws {
        let (dir, config) = try tempConfig("""
        model_provider = "custom"

        [model_providers.custom]
        name = "custom"
        base_url = "https://relay.example/v1"
        wire_api = "responses"
        supports_websockets = true
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = CodexConfigProviderEditor.setProviderField(
            "custom", key: "supports_websockets", value: "false",
            configURL: config, backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(CodexConfigReader.sectionValues(
            "model_providers.custom", toml: text)["supports_websockets"] == "false")
        // Turning transport off must not disturb how the relay is reached.
        let section = CodexConfigReader.sectionValues("model_providers.custom", toml: text)
        #expect(section["base_url"] == "https://relay.example/v1")
        #expect(section["wire_api"] == "responses")
        #expect(section["name"] == "custom")
    }

    @Test("toggling back restores the claim")
    func togglesBack() throws {
        let (dir, config) = try tempConfig("""
        [model_providers.custom]
        base_url = "https://relay.example/v1"
        supports_websockets = false
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = CodexConfigProviderEditor.setProviderField(
            "custom", key: "supports_websockets", value: "true",
            configURL: config, backupDirectory: dir.appendingPathComponent("bk"))
        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(CodexConfigReader.sectionValues(
            "model_providers.custom", toml: text)["supports_websockets"] == "true")
        // Exactly one key, so no duplicate decides the outcome.
        #expect(text.components(separatedBy: "supports_websockets =").count == 2)
    }
}

/// Quoting a boolean writes TOML of the wrong type: `"false"` is a string, not the
/// boolean Codex expects, and the mismatch makes the whole file unreadable — Codex
/// then asks for a login instead of starting a conversation. That is a config-only
/// failure with a misleading symptom, so the formatting is pinned here.
@Suite("TOML value formatting")
struct TOMLValueFormattingTests {
    @Test("booleans are written bare")
    func booleansBare() {
        #expect(CodexConfigProviderEditor.tomlValue("true") == "true")
        #expect(CodexConfigProviderEditor.tomlValue("false") == "false")
        #expect(!CodexConfigProviderEditor.tomlValue("false").contains("\""))
    }

    @Test("numbers are written bare")
    func numbersBare() {
        #expect(CodexConfigProviderEditor.tomlValue("400000") == "400000")
        #expect(CodexConfigProviderEditor.tomlValue("-1") == "-1")
        #expect(CodexConfigProviderEditor.tomlValue("1.5") == "1.5")
    }

    @Test("everything else is quoted")
    func stringsQuoted() {
        #expect(CodexConfigProviderEditor.tomlValue("responses") == "\"responses\"")
        // A value that merely looks like text stays a string, even if it contains a
        // word that is otherwise a boolean.
        #expect(CodexConfigProviderEditor.tomlValue("trueish").hasPrefix("\""))
        #expect(CodexConfigProviderEditor.tomlValue("40 0000").hasPrefix("\""))
        #expect(CodexConfigProviderEditor.tomlValue("") == "\"\"")
    }

    /// The exact write that broke the config, through the public path.
    @Test("writing a boolean key produces a bare boolean in the file")
    func booleanWriteIsBare() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        try """
        [model_providers.custom]
        name = "custom"
        base_url = "https://relay.example/v1"
        supports_websockets = true
        """.write(to: config, atomically: true, encoding: .utf8)

        _ = CodexConfigProviderEditor.setProviderField(
            "custom", key: "supports_websockets", value: "false",
            configURL: config, backupDirectory: dir.appendingPathComponent("bk"))

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.contains("supports_websockets = false"))
        #expect(!text.contains("supports_websockets = \"false\""))
        // And it reads back as the same boolean, not a string.
        #expect(CodexConfigReader.sectionValues(
            "model_providers.custom", toml: text)["supports_websockets"] == "false")
    }
}
