import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Codex config reader")
struct CodexConfigReaderTests {
    @Test("parses provider base URLs from a real-shaped config")
    func parsesProviderBaseURLs() {
        let toml = """
        model_provider = "custom"
        model = "gpt-5.6-sol"

        [model_providers.custom]
        name = "custom"
        wire_api = "responses"
        base_url = "https://ai.apizn.com/v1"

        [model_providers.codex_local_access]
        name = "Codex API Service"
        base_url = "https://ai.apizn.com/v1"
        """

        let urls = CodexConfigReader.providerBaseURLs(toml: toml)
        #expect(urls["custom"] == "https://ai.apizn.com/v1")
        #expect(urls["codex_local_access"] == "https://ai.apizn.com/v1")
        #expect(urls.count == 2)
    }

    @Test("reads the top-level selected provider, not one nested in a section")
    func readsSelectedProvider() {
        let toml = """
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        model_provider = "should-be-ignored"
        """
        #expect(CodexConfigReader.selectedProvider(toml: toml) == "custom")
    }

    @Test("a provider base_url after another section is not attributed to it")
    func doesNotLeakAcrossSections() {
        let toml = """
        [model_providers.alpha]
        base_url = "https://alpha.example/v1"

        [other_section]
        base_url = "https://should-not-appear/v1"

        [model_providers.beta]
        base_url = "https://beta.example/v1"
        """
        let urls = CodexConfigReader.providerBaseURLs(toml: toml)
        #expect(urls == [
            "alpha": "https://alpha.example/v1",
            "beta": "https://beta.example/v1",
        ])
    }

    @Test("handles comments, quotes, and spacing")
    func handlesCommentsAndQuotes() {
        let toml = """
        # leading comment
        model_provider = 'custom'   # trailing comment

        [model_providers.custom]  # section comment
        base_url = 'https://quoted.example/v1' # and here
        base_url_hash = "https://x/v1#frag"
        """
        let urls = CodexConfigReader.providerBaseURLs(toml: toml)
        #expect(urls["custom"] == "https://quoted.example/v1")
        #expect(CodexConfigReader.selectedProvider(toml: toml) == "custom")
    }

    @Test("a hash inside a quoted value is preserved")
    func preservesHashInsideQuotes() {
        let toml = """
        [model_providers.custom]
        base_url = "https://example.com/v1#anchor"
        """
        #expect(CodexConfigReader.providerBaseURLs(toml: toml)["custom"]
            == "https://example.com/v1#anchor")
    }

    @Test("a missing file yields no providers rather than throwing")
    func missingFileIsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).toml")
        #expect(CodexConfigReader.providerBaseURLs(configURL: url).isEmpty)
        #expect(CodexConfigReader.selectedProvider(configURL: url) == nil)
    }

    @Test("a provider name containing dots is reassembled")
    func dottedProviderName() {
        let toml = """
        [model_providers."my.relay"]
        base_url = "https://dotted.example/v1"
        """
        #expect(CodexConfigReader.providerBaseURLs(toml: toml)["my.relay"]
            == "https://dotted.example/v1")
    }
}
