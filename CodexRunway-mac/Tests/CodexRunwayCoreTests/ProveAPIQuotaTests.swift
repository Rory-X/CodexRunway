import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("PROVE API quota isolation")
struct ProveAPIQuotaTests {
    @Test("dashboard PAT and relay key yield account and per-key values")
    func dashboardAndKey() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.add(key: "sk-ABCDsecretWXYZ", url: "https://a.example/v1")
        let recorder = Recorder(mode: .dashboard)
        let result = await fixture.refresher(tokens: [account.id: "pat-A"], recorder: recorder)
            .refresh(accountId: account.id)
        let balance = try #require(result.account?.cachedQuota?.newAPI)
        #expect(balance.remainingUSD == 2)
        #expect(balance.usedUSD == 3)
        #expect(balance.totalUSD == 5)
        #expect(balance.keyUsedUSD == 12.34)
        #expect(balance.requestCount == 7)
        #expect(balance.tokenName == "this-key")
        #expect(balance.todayTokens == 30)
        let calls = await recorder.calls
        #expect(calls.contains { $0.path == "/api/user/self" && $0.auth == "Bearer pat-A" })
        #expect(calls.contains { $0.path == "/v1/dashboard/billing/usage" && $0.auth == "Bearer sk-ABCDsecretWXYZ" })
        #expect(calls.contains { $0.path == "/api/log/self" && $0.query.contains("token_name=this-key") })
        #expect(calls.allSatisfy { $0.host == "a.example" })
    }

    @Test("without PAT the key's spend remains available")
    func keyOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.add(key: "sk-key", url: "https://a.example/v1")
        let recorder = Recorder(mode: .keyOnly)
        let result = await fixture.refresher(tokens: [:], recorder: recorder).refresh(accountId: account.id)
        let balance = try #require(result.account?.cachedQuota?.newAPI)
        #expect(balance.keyUsedUSD == 12.34)
        #expect(balance.remainingUSD == nil)
        #expect(balance.todayTokens == nil)
        #expect(result.account?.lastError == nil)
        #expect(!(await recorder.calls).contains { $0.path == "/api/user/self" })
    }

    @Test("unknown API quota failures are neutral", arguments: [
        Recorder.Mode.unknownHTTP(401), .unknownHTTP(403), .unknownHTTP(429),
        .unknownHTTP(500), .unknownHTTP(404), .unknownMalformed,
        .unknownNetwork(.cannotConnectToHost), .unknownNetwork(.timedOut),
    ])
    private func unsupportedIsNeutral(mode: Recorder.Mode) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var account = try fixture.add(key: "sk-key", url: "https://a.example/v1")
        account.lastError = "invalid credential"
        account.requiresReauth = true
        account.cachedQuota = CachedAccountQuota(plan: "pro", primaryUsedPercent: 99)
        try fixture.store.updateMetadata(account)
        let recorder = Recorder(mode: mode)
        let result = await fixture.refresher(tokens: [:], recorder: recorder).refresh(accountId: account.id)
        let disk = try #require(fixture.store.loadIndex().account(id: account.id))
        #expect(result.errorDescription == nil)
        #expect(disk.cachedQuota == nil)
        #expect(disk.lastError == nil)
        #expect(!disk.requiresReauth)
        #expect(result.account?.cachedQuota == nil)
        #expect(result.account?.lastError == nil)
    }

    @Test("missing account-owned URL never sends the key to the shared active endpoint")
    func noForeignEndpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.add(key: "sk-A", url: nil)
        try "model_provider = \"custom\"\n[model_providers.custom]\nbase_url = \"https://b.example/v1\"\n"
            .write(to: fixture.store.officialConfigURL, atomically: true, encoding: .utf8)
        let recorder = Recorder(mode: .keyOnly)
        let result = await fixture.refresher(tokens: [:], recorder: recorder).refresh(accountId: account.id)
        #expect(result.account?.lastError == nil)
        #expect(result.account?.cachedQuota == nil)
        #expect((await recorder.calls).isEmpty)
    }

    @Test("confirmed New API status permits distinct authentication and network codes")
    func knownFailures() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.add(key: "sk-key", url: "https://a.example/v1")
        for (mode, expected) in [(Recorder.Mode.unauthorized, "relay_key_rejected"),
                                 (.network, "relay_refresh_failed")] {
            let result = await fixture.refresher(tokens: [:], recorder: Recorder(mode: mode))
                .refresh(accountId: account.id)
            #expect(result.errorDescription == expected)
            #expect(result.account?.lastError == expected)
        }
    }

    @Test("a late A response cannot overwrite B's active index or metadata")
    func lateRefreshCannotPublishOldAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.add(key: "sk-account-A", url: "https://a.example/v1")
        let b = try fixture.add(key: "sk-account-B", url: "https://b.example/v1")
        _ = try await AccountSwitcher(store: fixture.store).switchTo(accountId: a.id)
        let recorder = Recorder(mode: .delayed)
        let refresher = fixture.refresher(tokens: [:], recorder: recorder)
        let pending = Task { await refresher.refresh(accountId: a.id) }
        let deadline = Date().addingTimeInterval(10)
        while !(await recorder.isDelayed), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await recorder.isDelayed)
        _ = try await AccountSwitcher(store: fixture.store).switchTo(accountId: b.id)
        await recorder.release()
        _ = await pending.value
        let index = try fixture.store.loadIndex()
        #expect(index.activeAccountId == b.id)
        #expect(index.account(id: a.id)?.cachedQuota == nil)
        #expect((try fixture.store.loadOfficialAuth()).openAIAPIKey == "sk-account-B")
        #expect((await recorder.calls).allSatisfy { $0.host == "a.example" })
    }

    @Test("batch refresh keeps each URL, key and PAT paired with its account")
    func batchUsesOwnCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.add(key: "sk-ABCDsecretWXYZ", url: "https://a.example/v1")
        let b = try fixture.add(key: "sk-BBCDsecretZZZZ", url: "https://b.example/v1")
        let recorder = Recorder(mode: .multi)
        let results = await fixture.refresher(tokens: [a.id: "pat-A", b.id: "pat-B"], recorder: recorder)
            .refreshAll()
        #expect(results.count == 2)
        #expect(results.first(where: { $0.accountId == a.id })?.account?.cachedQuota?.newAPI?.remainingUSD == 2)
        #expect(results.first(where: { $0.accountId == b.id })?.account?.cachedQuota?.newAPI?.remainingUSD == 4)
        let calls = await recorder.calls
        #expect(calls.contains { $0.host == "a.example" && $0.path == "/api/user/self" && $0.auth == "Bearer pat-A" })
        #expect(calls.contains { $0.host == "b.example" && $0.path == "/api/user/self" && $0.auth == "Bearer pat-B" })
        #expect(calls.contains { $0.host == "a.example" && $0.path == "/v1/dashboard/billing/usage" && $0.auth == "Bearer sk-ABCDsecretWXYZ" })
        #expect(calls.contains { $0.host == "b.example" && $0.path == "/v1/dashboard/billing/usage" && $0.auth == "Bearer sk-BBCDsecretZZZZ" })
        #expect(calls.allSatisfy { $0.host == "a.example" || $0.host == "b.example" })
    }

    private final class Fixture {
        let root: URL
        let store: AccountStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("prove-api-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = AccountStore(rootURL: root.appendingPathComponent("accounts"),
                                 officialAuthURL: root.appendingPathComponent("auth.json"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func add(key: String, url: String?) throws -> ManagedAccount {
            var account = try store.upsert(auth: .apiKey(apiKey: key))
            account.relayBaseURL = url
            try store.updateMetadata(account)
            return account
        }
        func refresher(tokens: [String: String], recorder: Recorder) -> AccountQuotaRefresher {
            let tokenStore = NewAPITokenStore(
                read: { id, _ in
                    guard let value = tokens[id] else { throw NewAPITokenStoreError.unavailable }
                    return value
                }, write: { _, _ in }, remove: { _ in })
            return AccountQuotaRefresher(
                store: store, switcher: AccountSwitcher(store: store),
                newAPITokens: tokenStore,
                newAPIClient: { url in NewAPIClient(baseURL: url, transport: { request in
                    try await recorder.respond(request)
                }) })
        }
    }

    private actor Recorder {
        enum Mode: Sendable, Equatable {
            case dashboard, keyOnly, unauthorized, network, delayed, multi
            case unknownHTTP(Int), unknownMalformed, unknownNetwork(URLError.Code)
        }
        struct Call: Sendable {
            let host: String
            let path: String
            let query: String
            let auth: String
        }
        let mode: Mode
        private(set) var calls: [Call] = []
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var isDelayed = false
        init(mode: Mode) { self.mode = mode }
        func release() { gate?.resume(); gate = nil }
        func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            let path = url.path
            calls.append(Call(host: url.host ?? "", path: path,
                              query: url.query ?? "", auth: request.value(forHTTPHeaderField: "Authorization") ?? ""))
            guard url.host == "a.example" || (mode == .multi && url.host == "b.example") else {
                throw URLError(.badURL)
            }
            if mode == .network, path != "/api/status" {
                throw URLError(.cannotConnectToHost)
            }
            if case .unknownNetwork(let code) = mode, path != "/api/status" {
                throw URLError(code)
            }
            if mode == .delayed, path == "/v1/dashboard/billing/usage" {
                isDelayed = true
                await withCheckedContinuation { gate = $0 }
            }
            let status: Int
            let json: String
            switch path {
            case "/api/status":
                switch mode {
                case .unknownHTTP, .unknownMalformed, .unknownNetwork:
                    status = 404; json = "{}"
                default:
                    status = 200; json = #"{"data":{"quota_per_unit":500000}}"#
                }
            case "/api/user/self":
                status = 200
                json = url.host == "b.example"
                    ? #"{"data":{"quota":2000000,"used_quota":500000,"request_count":3}}"#
                    : #"{"data":{"quota":1000000,"used_quota":1500000,"request_count":7}}"#
            case "/v1/dashboard/billing/usage":
                if case .unknownHTTP(let code) = mode { status = code }
                else { status = mode == .unauthorized ? 401 : 200 }
                json = mode == .unknownMalformed ? "{}"
                    : url.host == "b.example" ? #"{"total_usage":5678}"# : #"{"total_usage":1234}"#
            case "/v1/dashboard/billing/subscription": status = 404; json = "{}"
            case "/api/token", "/api/token/":
                status = 200
                json = url.host == "b.example"
                    ? #"{"data":{"items":[{"name":"b-key","key":"BBCD****ZZZZ"}]}}"#
                    : #"{"data":{"items":[{"name":"this-key","key":"ABCD****WXYZ"}]}}"#
            case "/api/log/self":
                status = 200
                json = "{\"data\":{\"total\":1,\"items\":[{\"id\":1,\"created_at\":\(Int(Date().timeIntervalSince1970)),\"prompt_tokens\":20,\"completion_tokens\":10,\"token_name\":\"this-key\"}]}}"
            default: throw URLError(.badURL)
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
    }
}
