import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Business client network routing")
struct ClientNetworkRoutingTests {
    @Test("an existing quota client follows context changes while explicit sessions stay fixed")
    func quotaClientResolvesContextPerRequest() async throws {
        let client = QuotaClient()
        let explicitSession = routingSession(route: "explicit")
        defer { explicitSession.invalidateAndCancel() }
        let explicitClient = QuotaClient(session: explicitSession)
        let first = try routingContext(route: "first")
        let second = try routingContext(route: "second")
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(accessToken: "fixture-access", refreshToken: "", accountId: "workspace"),
            lastRefresh: nil)

        try await RunwayNetwork.$scopedContext.withValue(first) { () async throws -> Void in
            #expect(try await client.fetchWorkspaceName(auth: auth) == "first")
            try await RunwayNetwork.$scopedContext.withValue(second) { () async throws -> Void in
                #expect(try await client.fetchWorkspaceName(auth: auth) == "second")
                #expect(try await explicitClient.fetchWorkspaceName(auth: auth) == "explicit")
            }
            #expect(try await client.fetchWorkspaceName(auth: auth) == "first")
        }
    }

    @Test("reaction GET and POST use the current context with automatic cookies disabled")
    func reactionsKeepCookiePolicyWhenContextChanges() async throws {
        let root = routingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RateLimitResetTodayReactionClient(
            cookieStore: .init(fileURL: root.appendingPathComponent("visitor.json")),
            devMockKind: nil)
        for route in ["first", "second"] {
            let context = try routingContext(route: route)
            try await RunwayNetwork.$scopedContext.withValue(context) { () async throws -> Void in
                let snapshot = try await client.fetch()
                let result = try await client.click()
                #expect(snapshot.count == (route == "first" ? 1 : 2))
                #expect(result.ok)
                #expect(result.data?.count == snapshot.count)
            }
        }
    }

    @Test("Codex OAuth and the default pricing fetcher use the current network context")
    func oauthAndPricingHaveNoSharedSessionBypass() async throws {
        let root = routingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = OpenAIPricingCatalogProvider(
            cacheURL: root.appendingPathComponent("pricing.json"),
            refreshInterval: 0)
        let oauth = try CodexOAuthLogin.startSession()
        for route in ["first", "second"] {
            let context = try routingContext(route: route)
            try await RunwayNetwork.$scopedContext.withValue(context) { () async throws -> Void in
                let exchanged = try await CodexOAuthLogin.exchangeCode("fixture-code", session: oauth)
                let priceBook = await provider.priceBook()
                #expect(exchanged.auth.tokens.accessToken == "\(route)-access")
                #expect(priceBook.version == "openai-docs-\(route)")
            }
        }
    }
}

private func routingTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-runway-client-routing-\(UUID().uuidString)", isDirectory: true)
}

private func routingContext(route: String) throws -> RunwayNetworkContext {
    try RunwayNetworkContext(sessionFactory: { configuration, delegate in
        routingSession(route: route, configuration: configuration, delegate: delegate)
    })
}

private func routingSession(
    route: String,
    configuration: URLSessionConfiguration = .ephemeral,
    delegate: (any URLSessionDelegate)? = nil) -> URLSession
{
    let configured = configuration.copy() as! URLSessionConfiguration
    configured.protocolClasses = [ClientRoutingURLProtocol.self]
    let cookiesDisabled = !configured.httpShouldSetCookies
        && configured.httpCookieAcceptPolicy == .never
        && configured.httpCookieStorage == nil
    configured.httpAdditionalHeaders = [
        "X-Test-Route": route,
        "X-Test-Cookies": cookiesDisabled ? "disabled" : "enabled",
    ]
    return URLSession(configuration: configured, delegate: delegate, delegateQueue: nil)
}

private final class ClientRoutingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url, let route = request.value(forHTTPHeaderField: "X-Test-Route") else {
                throw URLError(.badURL)
            }
            let body = try Self.body(for: request, route: route)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "ETag": route])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func body(for request: URLRequest, route: String) throws -> String {
        switch request.url?.path {
        case "/backend-api/accounts":
            return "{\"items\":[{\"id\":\"workspace\",\"name\":\"\(route)\"}]}"
        case "/v1/settings":
            return "{\"subscription_tier_display\":\"\(route)\"}"
        case "/prod_mc_billing.ConsumerUiSvc/GetRemainingResets":
            return "{}"
        case "/api/reaction":
            guard request.value(forHTTPHeaderField: "X-Test-Cookies") == "disabled" else {
                throw URLError(.badServerResponse)
            }
            return """
            {"ok":true,"data":{"enabled":true,"ready":true,"polarity":"no","epochId":"fixture","seed":0,"count":\(route == "first" ? 1 : 2),"remaining":null,"dailyLimit":0,"pollMs":5000}}
            """
        case "/oauth/token", "/oauth2/token":
            return """
            {"access_token":"\(route)-access","refresh_token":"fixture-refresh","email":"\(route)@example.com","sub":"fixture-user","expires_in":3600}
            """
        case "/api/docs/pricing.md":
            return """
            ### Standard pricing data
            | Model | Input | Cached input | Cache writes | Output | Long input | Long cached | Long writes | Long output |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- |
            | gpt-5.6-sol | $5 | $0.5 | $6.25 | $30 | $10 | $1 | $12.5 | $45 |
            """
        default:
            throw URLError(.unsupportedURL)
        }
    }
}
