using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Ported from the macOS app's <c>CodexConfigReaderTests</c>. Keeping the same cases is
/// the point: identical inputs must produce identical results, or the port has drifted.
/// </summary>
public class CodexConfigReaderTests
{
    [Fact]
    public void ParsesProviderBaseUrlsFromARealShapedConfig()
    {
        const string toml = """
        model_provider = "custom"
        model = "gpt-5.6-sol"

        [model_providers.custom]
        name = "custom"
        wire_api = "responses"
        base_url = "https://ai.apizn.com/v1"

        [model_providers.codex_local_access]
        name = "Codex API Service"
        base_url = "https://ai.apizn.com/v1"
        """;

        var urls = CodexConfigReader.ProviderBaseUrlsFromToml(toml);

        Assert.Equal("https://ai.apizn.com/v1", urls["custom"]);
        Assert.Equal("https://ai.apizn.com/v1", urls["codex_local_access"]);
        Assert.Equal(2, urls.Count);
    }

    [Fact]
    public void ReadsTheTopLevelSelectedProviderNotOneNestedInASection()
    {
        const string toml = """
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        model_provider = "should-be-ignored"
        """;

        Assert.Equal("custom", CodexConfigReader.SelectedProviderFromToml(toml));
    }

    [Fact]
    public void AProviderBaseUrlAfterAnotherSectionIsNotAttributedToIt()
    {
        const string toml = """
        [model_providers.alpha]
        base_url = "https://alpha.example/v1"

        [other_section]
        base_url = "https://should-not-appear/v1"

        [model_providers.beta]
        base_url = "https://beta.example/v1"
        """;

        var urls = CodexConfigReader.ProviderBaseUrlsFromToml(toml);

        Assert.Equal(2, urls.Count);
        Assert.Equal("https://alpha.example/v1", urls["alpha"]);
        Assert.Equal("https://beta.example/v1", urls["beta"]);
        Assert.False(urls.ContainsKey("other_section"));
    }

    [Fact]
    public void HandlesCommentsQuotesAndSpacing()
    {
        const string toml = """
        # a leading comment

        [model_providers.spaced]
          base_url   =   "https://spaced.example/v1"    # trailing comment

        [model_providers.single]
        base_url = 'https://single.example/v1'

        [model_providers.hashed]
        base_url = "https://hashed.example/v1#fragment"
        """;

        var urls = CodexConfigReader.ProviderBaseUrlsFromToml(toml);

        Assert.Equal("https://spaced.example/v1", urls["spaced"]);
        Assert.Equal("https://single.example/v1", urls["single"]);
        // A `#` inside quotes is part of the value, not the start of a comment.
        Assert.Equal("https://hashed.example/v1#fragment", urls["hashed"]);
    }

    [Fact]
    public void TheBareModelProvidersTableYieldsNoProviderName()
    {
        const string toml = """
        [model_providers]
        base_url = "https://ignored.example/v1"
        """;

        Assert.Empty(CodexConfigReader.ProviderBaseUrlsFromToml(toml));
    }

    [Fact]
    public void ProviderNamesKeepFileOrderAndDropDuplicates()
    {
        const string toml = """
        [model_providers.zeta]
        base_url = "https://z.example/v1"

        [model_providers.alpha]
        base_url = "https://a.example/v1"

        [model_providers.zeta]
        base_url = "https://z2.example/v1"

        [other]
        x = 1
        """;

        var names = CodexConfigReader.ProviderNamesInFileOrder(toml);

        Assert.Equal(new[] { "zeta", "alpha" }, names);
    }

    [Fact]
    public void TopLevelValuesStopAtTheFirstSection()
    {
        const string toml = """
        model = "gpt-6-astra"
        model_reasoning_effort = "high"

        [model_providers.custom]
        model = "should-be-ignored"
        """;

        var top = CodexConfigReader.TopLevelValues(toml);

        Assert.Equal("gpt-6-astra", top["model"]);
        Assert.Equal("high", top["model_reasoning_effort"]);
        Assert.Equal(2, top.Count);
    }

    [Fact]
    public void SectionValuesReportOnlyThatTable()
    {
        const string toml = """
        model = "top"

        [model_providers.custom]
        name = "custom"
        base_url = "https://r.example/v1"

        [model_providers.other]
        name = "other"
        """;

        var section = CodexConfigReader.SectionValues("model_providers.custom", toml);

        Assert.Equal("custom", section["name"]);
        Assert.Equal("https://r.example/v1", section["base_url"]);
        Assert.Equal(2, section.Count);
    }

    /// <summary>
    /// Windows-authored config files normally use CRLF. This pins that CRLF input still
    /// parses correctly, so a future change that strips the <c>\r</c> normalisation
    /// cannot silently start emitting values with embedded carriage returns.
    /// </summary>
    [Fact]
    public void HandlesCrlfLineEndings()
    {
        const string toml =
            "model_provider = \"custom\"\r\n" +
            "\r\n" +
            "[model_providers.custom]\r\n" +
            "base_url = \"https://crlf.example/v1\"\r\n";

        Assert.Equal("custom", CodexConfigReader.SelectedProviderFromToml(toml));
        Assert.Equal("https://crlf.example/v1",
            CodexConfigReader.ProviderBaseUrlsFromToml(toml)["custom"]);
    }

    [Fact]
    public void AMissingFileReadsAsEmptyRatherThanThrowing()
    {
        var missing = Path.Combine(Path.GetTempPath(), $"nope-{Guid.NewGuid():N}", "config.toml");

        Assert.Null(CodexConfigReader.SelectedProvider(missing));
        Assert.Empty(CodexConfigReader.ProviderBaseUrls(missing));
        Assert.Empty(CodexConfigReader.ProviderNamesInFileOrderFromFile(missing));
    }

    [Fact]
    public void ReadsFromDiskIncludingCrlf()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"cfg-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "config.toml");
        try
        {
            File.WriteAllText(path,
                "model_provider = \"custom\"\r\n" +
                "[model_providers.custom]\r\n" +
                "base_url = \"https://disk.example/v1\"\r\n");

            Assert.Equal("custom", CodexConfigReader.SelectedProvider(path));
            Assert.Equal("https://disk.example/v1",
                CodexConfigReader.ProviderBaseUrls(path)["custom"]);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
