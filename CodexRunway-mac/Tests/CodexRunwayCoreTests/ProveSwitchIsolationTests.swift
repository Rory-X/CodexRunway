import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("PROVE switch isolation", .serialized)
struct ProveSwitchIsolationTests {
    @Test("Relay catalog is restored only for its owner across account switches")
    func relayCatalogRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oauth = try fixture.addOAuth("catalog-official", active: true)
        let a = try fixture.addAPI("catalog-a", url: "https://a.example.invalid/v1")
        let b = try fixture.addAPI("catalog-b", url: "https://b.example.invalid/v1")
        let catalog = fixture.configURL.deletingLastPathComponent()
            .appendingPathComponent("temporary-models.json")
        try Data("{\"models\":[]}".utf8).write(to: catalog)
        #expect(fixture.profiles.save(.init(modelCatalogPath: catalog.path), for: a.id))
        let switcher = fixture.switcher()
        _ = try await switcher.switchTo(accountId: a.id)
        #expect(try String(contentsOf: fixture.configURL).contains("model_catalog_json ="))
        _ = try await switcher.switchTo(accountId: b.id)
        #expect(try !String(contentsOf: fixture.configURL).contains("model_catalog_json"))
        _ = try await switcher.switchTo(accountId: a.id)
        #expect(try String(contentsOf: fixture.configURL).contains(catalog.path))
        _ = try await switcher.switchTo(accountId: oauth.id)
        #expect(try !String(contentsOf: fixture.configURL).contains("model_catalog_json"))
        try FileManager.default.removeItem(at: catalog)
        _ = try await switcher.switchTo(accountId: a.id)
        #expect(try !String(contentsOf: fixture.configURL).contains("model_catalog_json"))
    }

    @Test("REQ-1 mixed auth normalizes in both directions and files stay 0600")
    func mixedAuth() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CodexAuthStore(authURL: fixture.store.officialAuthURL)
        var oauth = Fixture.oauth("alpha")
        oauth.openAIAPIKey = "synthetic-old-api-key"
        try store.save(oauth)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.officialAuthURL)) as? [String: Any])
        #expect(object["OPENAI_API_KEY"] == nil)
        #expect(object["tokens"] != nil)
        var api = CodexAuth.apiKey(apiKey: "synthetic-new-api-key")
        api.tokens = oauth.tokens
        api.lastRefresh = "old-refresh-time"
        try store.save(api)
        object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.officialAuthURL)) as? [String: Any])
        #expect(object["tokens"] == nil)
        #expect(object["last_refresh"] == nil)
        #expect(object["OPENAI_API_KEY"] != nil)
        let raw = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "OPENAI_API_KEY": "synthetic-raw-key", "tokens": ["access_token": oauth.tokens.accessToken, "refresh_token": oauth.tokens.refreshToken]])
        try store.saveRawJSONData(raw)
        object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.officialAuthURL)) as? [String: Any])
        #expect(object["OPENAI_API_KEY"] == nil)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: fixture.store.officialAuthURL.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        oauth.authMode = nil
        #expect(throws: (any Error).self) { try store.save(oauth) }
    }

    @Test("REQ-2 REQ-3 OAuth custom A B OAuth preserves common tables and isolates endpoint model websocket")
    func fourWayRouting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oauth = try fixture.addOAuth("alpha", active: true)
        let a = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
        let b = try fixture.addAPI("b", url: "https://b.example.invalid/v2")
        let polluted = """
        model = "relay-old"
        model_reasoning_effort = "xhigh"
        model_provider = "custom"
        openai_base_url = "https://old.example.invalid/v1"
        model_catalog_json = "relay.json"
        model_context_window = 1000000
        model_max_context_window = 1000000
        model_auto_compact_token_limit = 950000
        [model_providers.openai]
        base_url = "https://old.example.invalid/v1"
        [model_providers.custom]
        base_url = "https://wrong.example.invalid/v1"
        env_key = "OLD_SECRET"
        experimental_bearer_token = "OLD_TOKEN"
        http_headers = { Authorization = "OLD_HEADER" }
        [model_providers.custom.auth]
        command = "old-command"
        [mcp_servers.example]
        command = "echo"
        [plugins.example]
        enabled = true
        [projects."/tmp/sample"]
        trust_level = "trusted"
        """
        try Data(polluted.utf8).write(to: fixture.configURL)
        _ = fixture.profiles.save(.init(model: "a-model", modelReasoningEffort: "high", baseURL: "https://a.example.invalid/old", supportsWebSockets: true), for: a.id)
        _ = fixture.profiles.save(.init(model: "b-model", modelReasoningEffort: "low", baseURL: "https://b.example.invalid/v2"), for: b.id)
        let switcher = fixture.switcher()
        _ = try await switcher.switchTo(accountId: oauth.id)
        var text = try String(contentsOf: fixture.configURL)
        if let output = ProcessInfo.processInfo.environment["PROVE_SWITCH_TOML_OUTPUT"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: output).appendingPathComponent("oauth.toml"))
        }
        #expect(text.contains("model_context_window = 400000"))
        #expect(text.contains("model_auto_compact_token_limit = 360000"))
        #expect(!text.contains("model_max_context_window"))
        #expect(!text.contains("model_providers.custom"))
        #expect(!text.contains("model_providers.openai"))
        #expect(!text.contains("supports_websockets = false"))
        #expect(!text.contains("openai_base_url"))
        #expect(!text.contains("model = \"relay-old\""))
        #expect(text.contains("[mcp_servers.example]"))
        #expect(text.contains("[plugins.example]"))
        #expect(text.contains("[projects.\"/tmp/sample\"]"))
        _ = try await switcher.switchTo(accountId: a.id)
        text = try String(contentsOf: fixture.configURL)
        if let output = ProcessInfo.processInfo.environment["PROVE_SWITCH_TOML_OUTPUT"] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: output).appendingPathComponent("custom.toml"))
        }
        #expect(text.contains("base_url = \"https://a.example.invalid/v1\""))
        #expect(text.contains("model = \"a-model\""))
        #expect(text.contains("supports_websockets = true"))
        #expect(CodexConfigReader.topLevelValues(toml: text)["model_context_window"] == "400000")
        #expect(CodexConfigReader.topLevelValues(toml: text)["model_auto_compact_token_limit"] == "360000")
        #expect(!text.contains("model_max_context_window"))
        #expect(!text.contains("OLD_SECRET"))
        #expect(!text.contains("OLD_TOKEN"))
        #expect(!text.contains("OLD_HEADER"))
        #expect(!text.contains("old-command"))
        _ = try await switcher.switchTo(accountId: b.id)
        text = try String(contentsOf: fixture.configURL)
        #expect(text.contains("base_url = \"https://b.example.invalid/v2\""))
        #expect(text.contains("model = \"b-model\""))
        #expect(text.contains("supports_websockets = false"))
        #expect(!text.contains("a.example.invalid"))
        #expect(CodexConfigReader.topLevelValues(toml: text)["model_context_window"] == "400000")
        #expect(CodexConfigReader.topLevelValues(toml: text)["model_auto_compact_token_limit"] == "360000")
        #expect(!text.contains("model_max_context_window"))
        _ = try await switcher.switchTo(accountId: b.id)
        text = try String(contentsOf: fixture.configURL)
        #expect(CodexConfigReader.topLevelValues(toml: text)["model_context_window"] == "400000")
        #expect(CodexConfigReader.topLevelValues(toml: text)["model_auto_compact_token_limit"] == "360000")
        #expect(text.components(separatedBy: "model_context_window =").count == 2)
        #expect(text.components(separatedBy: "model_auto_compact_token_limit =").count == 2)
        _ = try await switcher.switchTo(accountId: oauth.id)
        text = try String(contentsOf: fixture.configURL)
        #expect(!text.contains("model_provider ="))
        #expect(!text.contains("model_providers.custom"))
        #expect(text.contains("[mcp_servers.example]"))
        let before = Data(text.utf8)
        _ = try await switcher.switchTo(accountId: oauth.id)
        #expect(try Data(contentsOf: fixture.configURL) == before)
    }

    @Test("REQ-3 missing or invalid endpoint leaves official files untouched")
    func invalidEndpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.addOAuth("alpha", active: true)
        let a = try fixture.addAPI("a", url: nil)
        let switcher = fixture.switcher()
        let beforeAuth = try Data(contentsOf: fixture.store.officialAuthURL)
        let beforeIndex = try Data(contentsOf: fixture.store.indexURL)
        let beforeConfig = try Data(contentsOf: fixture.configURL)
        await #expect(throws: AccountSwitchTransaction.Failure.missingEndpoint) {
            try await switcher.switchTo(accountId: a.id)
        }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeAuth)
        #expect(try Data(contentsOf: fixture.store.indexURL) == beforeIndex)
        #expect(try Data(contentsOf: fixture.configURL) == beforeConfig)
        let weak = try fixture.store.upsert(auth: .apiKey(apiKey: "short"))
        await #expect(throws: AccountStoreError.notUsableAsCodexLogin) {
            try await switcher.switchTo(accountId: weak.id)
        }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeAuth)
        #expect(try Data(contentsOf: fixture.configURL) == beforeConfig)
        var row = try #require(fixture.store.loadIndex().account(id: a.id))
        row.relayBaseURL = "http://bad.example.invalid/v1"
        try fixture.store.updateMetadata(row)
        await #expect(throws: AccountSwitchTransaction.Failure.invalidEndpoint) {
            try await switcher.switchTo(accountId: a.id)
        }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeAuth)
    }

    @Test("REQ-5 each commit stage rolls back official files, index and profile")
    func rollbackStages() async throws {
        for stage in ["backup", "config", "auth", "managed", "profile", "index"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = try fixture.addOAuth("alpha", active: true)
            let a = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
            let beforeAuth = try Data(contentsOf: fixture.store.officialAuthURL)
            let beforeConfig = try Data(contentsOf: fixture.configURL)
            let beforeIndex = try Data(contentsOf: fixture.store.indexURL)
            var switcher = fixture.switcher()
            switcher.failCommitAt = { if $0 == stage { throw AccountSwitchTransaction.Failure.injected(stage) } }
            await #expect(throws: AccountSwitchTransaction.Failure.injected(stage)) {
                try await switcher.switchTo(accountId: a.id)
            }
            #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeAuth)
            #expect(try Data(contentsOf: fixture.configURL) == beforeConfig)
            #expect(try Data(contentsOf: fixture.store.indexURL) == beforeIndex)
            let backups = (try? FileManager.default.contentsOfDirectory(atPath: fixture.backupURL.path)) ?? []
            #expect(backups.isEmpty)
        }
    }

    @Test("REQ-5 config modification while quota is in flight aborts switch")
    func externalModification() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.addOAuth("alpha", active: true)
        let b = try fixture.addOAuth("beta")
        let configURL = fixture.configURL
        let switcher = fixture.switcher(fetchQuota: { _ in
            try Data("# external edit\n".utf8).write(to: configURL)
            return Fixture.quota
        })
        await #expect(throws: AccountSwitchTransaction.Failure.externalModification) {
            try await switcher.switchTo(accountId: b.id)
        }
        #expect(try fixture.store.loadIndex().activeAccountId == a.id)
        #expect(try fixture.store.loadOfficialAuth().tokens.accountId == "alpha")
        #expect(try String(contentsOf: configURL) == "# external edit\n")
    }

    @Test("REQ-5 target credential modified during quota cannot be replaced by stale switch data")
    func externalCredentialModification() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.addOAuth("alpha", active: true)
        let b = try fixture.addOAuth("beta")
        let store = fixture.store
        let beforeOfficial = try Data(contentsOf: store.officialAuthURL)
        let switcher = fixture.switcher(fetchQuota: { _ in
            var changed = Fixture.oauth("beta")
            changed.tokens.refreshToken = "external-rotated-refresh-token-123456"
            try store.saveCredential(id: b.id, auth: changed)
            return Fixture.quota
        })
        await #expect(throws: AccountSwitchTransaction.Failure.externalModification) {
            try await switcher.switchTo(accountId: b.id)
        }
        #expect(try Data(contentsOf: store.officialAuthURL) == beforeOfficial)
        #expect(try store.loadIndex().activeAccountId == a.id)
        #expect(try store.loadCredential(id: b.id).tokens.refreshToken == "external-rotated-refresh-token-123456")
    }

    @Test("REQ-2 REQ-3 dotted inline and parent provider aliases fail before OAuth or custom commit")
    func providerAliasPreflight() async throws {
        let aliases = [
            "model_providers.openai.base_url = \"https://old.example.invalid/v1\"",
            "model_providers = { openai = { base_url = \"https://old.example.invalid/v1\" } }",
            "[model_providers]\nopenai.base_url = \"https://old.example.invalid/v1\"",
            "model_providers.\"custom\".base_url = \"https://old.example.invalid/v1\"",
        ]
        for alias in aliases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let oauth = try fixture.addOAuth("alpha", active: true)
            let custom = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
            try Data((alias + "\n[mcp_servers.sample]\nargs = [\n  \"--one\",\n  \"--two\",\n]\n").utf8)
                .write(to: fixture.configURL)
            let auth = try Data(contentsOf: fixture.store.officialAuthURL)
            let index = try Data(contentsOf: fixture.store.indexURL)
            let config = try Data(contentsOf: fixture.configURL)
            for id in [oauth.id, custom.id] {
                await #expect(throws: AccountSwitchTransaction.Failure.unsupportedConfiguration) {
                    try await fixture.switcher().switchTo(accountId: id)
                }
                #expect(try Data(contentsOf: fixture.store.officialAuthURL) == auth)
                #expect(try Data(contentsOf: fixture.store.indexURL) == index)
                #expect(try Data(contentsOf: fixture.configURL) == config)
            }
        }
    }

    @Test("REQ-2 quoted provider override is removed while multiline MCP values survive")
    func quotedProviderAndMultilineMCP() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oauth = try fixture.addOAuth("alpha", active: true)
        let config = #"""
        model_provider = "custom"
        [model_providers."openai"]
        base_url = "https://old.example.invalid/v1"
        [model_providers.'custom']
        base_url = "https://old.example.invalid/v2"
        [mcp_servers.sample]
        args = [
          "--one", # retained comment
          "--two",
        ]
        description = """
        first line
        second line
        """
        """#
        try Data(config.utf8).write(to: fixture.configURL)
        _ = try await fixture.switcher().switchTo(accountId: oauth.id)
        let output = try String(contentsOf: fixture.configURL)
        #expect(!output.contains("old.example.invalid"))
        #expect(output.contains("--one"))
        #expect(output.contains("second line"))
        if let directory = ProcessInfo.processInfo.environment["PROVE_SWITCH_TOML_OUTPUT"] {
            try Data(output.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("multiline.toml"))
        }
    }

    @Test("REQ-5 write-after-rename index failure restores old active and all files")
    func indexPostWriteFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oauth = try fixture.addOAuth("alpha", active: true)
        let custom = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
        let beforeAuth = try Data(contentsOf: fixture.store.officialAuthURL)
        let beforeConfig = try Data(contentsOf: fixture.configURL)
        let beforeIndex = try Data(contentsOf: fixture.store.indexURL)
        var switcher = fixture.switcher()
        switcher.store.failIndexWriteAfterCommit = { throw AccountSwitchTransaction.Failure.injected("after-index-rename") }
        await #expect(throws: AccountSwitchTransaction.Failure.injected("after-index-rename")) {
            try await switcher.switchTo(accountId: custom.id)
        }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeAuth)
        #expect(try Data(contentsOf: fixture.configURL) == beforeConfig)
        #expect(try Data(contentsOf: fixture.store.indexURL) == beforeIndex)
        #expect(try fixture.store.loadIndex().activeAccountId == oauth.id)
    }

    @Test("REQ-5 one restore failure still restores other paths and retains snapshots")
    func incompleteRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.addOAuth("alpha", active: true)
        let custom = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
        let beforeAuth = try Data(contentsOf: fixture.store.officialAuthURL)
        let beforeConfig = try Data(contentsOf: fixture.configURL)
        let beforeIndex = try Data(contentsOf: fixture.store.indexURL)
        var switcher = fixture.switcher()
        let profileURL = fixture.profiles.profileURL(for: try fixture.store.loadIndex().activeAccountId!)
        switcher.failCommitAt = { if $0 == "index" { throw AccountSwitchTransaction.Failure.injected("index") } }
        switcher.failRestoreAt = { if $0 == profileURL { throw AccountSwitchTransaction.Failure.injected("restore-profile") } }
        do {
            _ = try await switcher.switchTo(accountId: custom.id)
            Issue.record("Expected incomplete recovery")
        } catch let failure as AccountSwitchTransaction.RecoveryIncomplete {
            #expect(failure.failedPaths == [profileURL.path])
            #expect(failure.snapshots.contains { $0.url == fixture.store.officialAuthURL && $0.original == beforeAuth })
            #expect(failure.configBackupURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeAuth)
        #expect(try Data(contentsOf: fixture.configURL) == beforeConfig)
        #expect(try Data(contentsOf: fixture.store.indexURL) == beforeIndex)
    }

    @Test("REQ-5 paused stale metadata update cannot replace a completed active switch")
    func staleMetadataAfterSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.addOAuth("alpha", active: true)
        let b = try fixture.addOAuth("beta")
        var stale = a
        stale.alias = "Updated after pause"
        let gate = AsyncPauseGate()
        let store = fixture.store
        let pending = Task.detached {
            await gate.pause()
            try store.updateMetadata(stale)
        }
        await gate.waitUntilPaused()
        _ = try await fixture.switcher().switchTo(accountId: b.id)
        await gate.release()
        try await pending.value
        let index = try fixture.store.loadIndex()
        #expect(index.activeAccountId == b.id)
        #expect(index.account(id: a.id)?.alias == "Updated after pause")
    }

    @Test("REQ-5 absent config is created for custom and malformed config is rejected")
    func absentAndMalformedConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.addOAuth("alpha", active: true)
        let a = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
        try FileManager.default.removeItem(at: fixture.configURL)
        _ = try await fixture.switcher().switchTo(accountId: a.id)
        #expect(try String(contentsOf: fixture.configURL).contains("https://a.example.invalid/v1"))
        let currentAuth = try Data(contentsOf: fixture.store.officialAuthURL)
        let currentIndex = try Data(contentsOf: fixture.store.indexURL)
        try Data("[model_providers.custom]\nname = \"a\"\n[model_providers.custom]\nname = \"b\"\n".utf8)
            .write(to: fixture.configURL)
        let invalid = try Data(contentsOf: fixture.configURL)
        await #expect(throws: AccountSwitchTransaction.Failure.invalidConfiguration) {
            try await fixture.switcher().switchTo(accountId: a.id)
        }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == currentAuth)
        #expect(try Data(contentsOf: fixture.store.indexURL) == currentIndex)
        #expect(try Data(contentsOf: fixture.configURL) == invalid)
        try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: fixture.configURL)
        await #expect(throws: AccountSwitchTransaction.Failure.unsupportedConfiguration) {
            try await fixture.switcher().switchTo(accountId: a.id)
        }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == currentAuth)
    }

    @Test("REQ-5 backup failure aborts before credential or config commit")
    func backupFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.addOAuth("alpha", active: true)
        let a = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
        let beforeAuth = try Data(contentsOf: fixture.store.officialAuthURL)
        let beforeConfig = try Data(contentsOf: fixture.configURL)
        let beforeIndex = try Data(contentsOf: fixture.store.indexURL)
        let obstruction = fixture.root.appendingPathComponent("backup-obstruction")
        try Data("file".utf8).write(to: obstruction)
        var switcher = fixture.switcher()
        switcher.routingBackupDirectory = obstruction
        await #expect(throws: (any Error).self) { try await switcher.switchTo(accountId: a.id) }
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeAuth)
        #expect(try Data(contentsOf: fixture.configURL) == beforeConfig)
        #expect(try Data(contentsOf: fixture.store.indexURL) == beforeIndex)
    }

    @Test("REQ-2 REQ-3 trusted model and reasoning snapshots restore symmetrically")
    func modelRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oauth = try fixture.addOAuth("alpha", active: true)
        let a = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
        try Data("model = \"official-model\"\nmodel_reasoning_effort = \"high\"\n[mcp_servers.example]\ncommand = \"echo\"\n".utf8)
            .write(to: fixture.configURL)
        let switcher = fixture.switcher()
        _ = try await switcher.switchTo(accountId: a.id)
        var text = try String(contentsOf: fixture.configURL)
        #expect(!text.contains("official-model"))
        // A user edits the active account's model; switching away captures it.
        text = text.replacingOccurrences(of: "model_provider = \"custom\"",
            with: "model_provider = \"custom\"\nmodel = \"a-model\"\nmodel_reasoning_effort = \"low\"")
        try Data(text.utf8).write(to: fixture.configURL)
        _ = try await switcher.switchTo(accountId: oauth.id)
        text = try String(contentsOf: fixture.configURL)
        #expect(text.contains("model = \"official-model\""))
        #expect(text.contains("model_reasoning_effort = \"high\""))
        _ = try await switcher.switchTo(accountId: a.id)
        text = try String(contentsOf: fixture.configURL)
        #expect(text.contains("model = \"a-model\""))
        #expect(text.contains("model_reasoning_effort = \"low\""))
        #expect(!text.contains("official-model"))
    }

    @Test("REQ-5 each successful switch keeps a unique original backup and no temporary files")
    func uniqueBackups() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.addOAuth("alpha", active: true)
        let a = try fixture.addAPI("a", url: "https://a.example.invalid/v1")
        let b = try fixture.addAPI("b", url: "https://b.example.invalid/v1")
        let initial = try Data(contentsOf: fixture.configURL)
        let counter = WriteCounter()
        var switcher = fixture.switcher()
        switcher.observeConfigCommit = { counter.increment() }
        _ = try await switcher.switchTo(accountId: a.id)
        #expect(counter.value == 1)
        let afterA = try Data(contentsOf: fixture.configURL)
        _ = try await switcher.switchTo(accountId: b.id)
        #expect(counter.value == 2)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.backupURL,
            includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        let contents = try files.map { try Data(contentsOf: $0) }
        #expect(contents.contains(initial))
        #expect(contents.contains(afterA))
        let configFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.configURL.deletingLastPathComponent().path)
        #expect(!configFiles.contains { $0.contains(".runway-") })
        let mode = try #require(FileManager.default.attributesOfItem(atPath: fixture.configURL.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
    }

    @Test("REQ-5 delayed A refresh after B switch writes only A managed copy and duplicate callers share one request")
    func delayedRefreshAndCoalescing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.addOAuth("alpha", active: true)
        let b = try fixture.addOAuth("beta")
        var expired = Fixture.oauth("alpha")
        expired.tokens.accessToken = Fixture.jwt(["exp": 1, "sub": "alpha"])
        try fixture.store.saveCredential(id: a.id, auth: expired)
        try fixture.store.saveOfficialAuth(expired)
        DelayedRefreshURLProtocol.reset()
        let switcher = fixture.switcher(tokenRefresher: DelayedRefreshURLProtocol.refresher())
        let first = Task { try await switcher.ensureValidCredential(accountId: a.id) }
        try await DelayedRefreshURLProtocol.waitForRequest()
        let second = Task { try await switcher.ensureValidCredential(accountId: a.id) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(DelayedRefreshURLProtocol.count == 1)
        _ = try await fixture.switcher().switchTo(accountId: b.id)
        DelayedRefreshURLProtocol.complete()
        let refreshedA = try await first.value
        let refreshedAgain = try await second.value
        #expect(refreshedA == refreshedAgain)
        #expect(DelayedRefreshURLProtocol.count == 1)
        #expect(try fixture.store.loadCredential(id: a.id).tokens.refreshToken == "rotated-refresh-token-for-prove-123456")
        #expect(try fixture.store.loadOfficialAuth().tokens.accountId == "beta")
        #expect(try fixture.store.loadIndex().activeAccountId == b.id)
    }

    @Test("REQ-5 A B A generation prevents late A result from replacing reactivated A")
    func refreshABA() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.addOAuth("alpha", active: true)
        let b = try fixture.addOAuth("beta")
        var expired = Fixture.oauth("alpha")
        expired.tokens.accessToken = Fixture.jwt(["exp": 1, "sub": "alpha"])
        try fixture.store.saveCredential(id: a.id, auth: expired)
        try fixture.store.saveOfficialAuth(expired)
        DelayedRefreshURLProtocol.reset()
        let delayed = fixture.switcher(tokenRefresher: DelayedRefreshURLProtocol.refresher())
        let pending = Task { try await delayed.ensureValidCredential(accountId: a.id) }
        try await DelayedRefreshURLProtocol.waitForRequest()
        _ = try await fixture.switcher().switchTo(accountId: b.id)
        var reactivated = Fixture.oauth("alpha")
        reactivated.tokens.accessToken = Fixture.jwt(["exp": 4_100_000_000, "sub": "alpha-reactivated"])
        try fixture.store.saveCredential(id: a.id, auth: reactivated)
        _ = try await fixture.switcher().switchTo(accountId: a.id)
        let beforeLate = try Data(contentsOf: fixture.store.officialAuthURL)
        DelayedRefreshURLProtocol.complete()
        _ = try await pending.value
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == beforeLate)
        #expect(try fixture.store.loadIndex().activeAccountId == a.id)
    }

    private struct Fixture: Sendable {
        let root: URL
        let store: AccountStore
        let configURL: URL
        let backupURL: URL
        let profiles: RelayConfigStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("prove-switch-\(UUID().uuidString)")
            let codex = root.appendingPathComponent("codex")
            store = AccountStore(rootURL: root.appendingPathComponent("runway/accounts"), officialAuthURL: codex.appendingPathComponent("auth.json"))
            configURL = codex.appendingPathComponent("config.toml")
            backupURL = root.appendingPathComponent("runway/backups")
            profiles = RelayConfigStore(directory: root.appendingPathComponent("runway/profiles"))
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            try Data("[mcp_servers.example]\ncommand = \"echo\"\n".utf8).write(to: configURL)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func addOAuth(_ name: String, active: Bool = false) throws -> ManagedAccount {
            let auth = Self.oauth(name)
            let account = try store.upsert(auth: auth, makeActive: active)
            if active { try store.saveOfficialAuth(auth) }
            return account
        }
        func addAPI(_ name: String, url: String?) throws -> ManagedAccount {
            let account = try store.upsert(auth: .apiKey(apiKey: "synthetic-\(name)-api-key-123456"))
            if let url {
                var row = account
                row.relayBaseURL = url
                try store.updateMetadata(row)
                return row
            }
            return account
        }
        func switcher(tokenRefresher: TokenRefresher = TokenRefresher(),
                      fetchQuota: @escaping @Sendable (CodexAuth) async throws -> QuotaSnapshot = { _ in Fixture.quota }) -> AccountSwitcher {
            AccountSwitcher(store: store, tokenRefresher: tokenRefresher,
                routingConfigURL: configURL, routingBackupDirectory: backupURL,
                relayConfigStore: profiles, fetchQuota: fetchQuota)
        }
        static let quota = QuotaSnapshot(plan: "plus", primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil), secondary: nil, additionalWindows: [], creditsBalance: nil, updatedAt: Date())
        static func oauth(_ name: String) -> CodexAuth {
            CodexAuth(authMode: "chatgpt", tokens: .init(idToken: nil,
                accessToken: jwt(["exp": 4_100_000_000, "sub": name]),
                refreshToken: "synthetic-\(name)-refresh-token-123456", accountId: name), lastRefresh: nil)
        }
        static func jwt(_ payload: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return [Data(#"{"alg":"none"}"#.utf8), data, Data()]
                .map { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
                .joined(separator: ".")
        }
    }
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func increment() { lock.lock(); defer { lock.unlock() }; writes += 1 }
}

private actor AsyncPauseGate {
    private var paused = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class DelayedRefreshURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: DelayedRefreshURLProtocol?
    nonisolated(unsafe) private static var requests = 0

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
        requests = 0
    }

    static func refresher() -> TokenRefresher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedRefreshURLProtocol.self]
        return TokenRefresher(session: URLSession(configuration: config),
            tokenURL: URL(string: "https://prove-refresh.invalid/token")!)
    }

    static func waitForRequest() async throws {
        for _ in 0..<300 {
            if count > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    static func complete() {
        lock.lock()
        let request = pending
        pending = nil
        lock.unlock()
        guard let request, let url = request.request.url else { return }
        let header = Data(#"{"alg":"none"}"#.utf8)
        let payload = Data(#"{"exp":4100000000,"sub":"rotated"}"#.utf8)
        let token = [header, payload, Data()].map {
            $0.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".")
        let body = try! JSONSerialization.data(withJSONObject: [
            "access_token": token, "refresh_token": "rotated-refresh-token-for-prove-123456",
        ])
        request.client?.urlProtocol(request,
            didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: body)
        request.client?.urlProtocolDidFinishLoading(request)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.pending = self
        Self.lock.unlock()
    }
    override func stopLoading() {}
}
