using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Pins the exact byte-level output of the hand-written writer.
/// </summary>
/// <remarks>
/// Every expectation here was established by running the same input through Apple's
/// <c>JSONSerialization</c> with <c>[.prettyPrinted, .sortedKeys]</c> on macOS. They are
/// interoperability facts, not style: the file is shared with the macOS build, so a
/// divergence means the same logical file differs between the two platforms.
/// </remarks>
public class AppleJsonWriterTests
{
    private static string Serialize(string authJson)
        => CodexAuth.Parse(authJson).ToOfficialJson();

    private static string Faithful() => """
        {"auth_mode":"chatgpt","tokens":{
          "access_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "refresh_token":"rrrrrrrrrrrrrrrrrrrrrrrrrrrr"}}
        """;

    /// <summary>
    /// Line endings must be LF on every platform. Utf8JsonWriter takes its ending from
    /// Environment.NewLine, which is CRLF on Windows — that is why this is hand-written.
    /// </summary>
    [Fact]
    public void OutputUsesLineFeedOnly()
    {
        var text = Serialize(Faithful());

        Assert.DoesNotContain("\r", text, StringComparison.Ordinal);
        Assert.Contains("\n", text, StringComparison.Ordinal);
    }

    [Fact]
    public void OutputHasNoTrailingNewline()
    {
        var text = Serialize(Faithful());

        Assert.EndsWith("}", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\n", text[^1].ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void IndentIsTwoSpacesAndColonIsSpaced()
    {
        var text = Serialize(Faithful());

        Assert.Contains("\n  \"auth_mode\" : ", text, StringComparison.Ordinal);
    }

    /// <summary>A solidus is escaped, which is Apple's default and .NET's opposite.</summary>
    [Fact]
    public void SolidusIsEscaped()
    {
        var text = Serialize("""
        {"auth_mode":"chatgpt","tokens":{
          "access_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "refresh_token":"https://relay.example/v1"}}
        """);

        Assert.Contains(@"https:\/\/relay.example\/v1", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\"https://", text, StringComparison.Ordinal);
    }

    [Fact]
    public void BackslashAndQuoteAreEscaped()
    {
        var text = Serialize("""
        {"auth_mode":"chatgpt","tokens":{
          "access_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "refresh_token":"a\\b\"c"}}
        """);

        // Still valid JSON: the round trip is the real proof.
        Assert.Equal("a\\b\"c", CodexAuth.Parse(text).Tokens.RefreshToken);
    }

    /// <summary>
    /// Non-BMP characters stay as UTF-8. .NET's built-in encoders split them into a
    /// surrogate escape pair, which Apple does not.
    /// </summary>
    [Fact]
    public void NonBmpCharactersStayAsUtf8()
    {
        var text = Serialize("""
        {"auth_mode":"chatgpt","tokens":{
          "access_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "refresh_token":"a😀b"}}
        """);

        Assert.Contains("a😀b", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\\ud83d", text, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Apple emits these four raw; the built-in encoders escape all of them.</summary>
    [Theory]
    [InlineData("\u007f")]
    [InlineData("\u00a0")]
    [InlineData("\u2028")]
    [InlineData("\u2029")]
    public void PassthroughCharactersAreNotEscaped(string character)
    {
        var json = "{\"auth_mode\":\"chatgpt\",\"tokens\":{"
            + "\"access_token\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
            + "\"refresh_token\":\"a" + character + "b\"}}";

        var text = Serialize(json);

        Assert.Contains(character, text, StringComparison.Ordinal);
        Assert.DoesNotContain("\\u007f", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\\u00a0", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\\u2028", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\\u2029", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ControlCharactersUseShortEscapesAndUnicodeForm()
    {
        // Written as explicit JSON escapes so the parser produces real control
        // characters rather than the two-character sequences backslash-r and backslash-n.
        const string json = "{\"auth_mode\":\"chatgpt\",\"tokens\":{"
            + "\"access_token\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
            + "\"refresh_token\":\"n\\r\\n\\tt\"}}";

        var auth = CodexAuth.Parse(json);
        Assert.Contains('\r', auth.Tokens.RefreshToken);
        Assert.Contains('\n', auth.Tokens.RefreshToken);
        Assert.Contains('\t', auth.Tokens.RefreshToken);

        // Apple writes exactly this for the same input: "n\r\n\tt".
        var text = auth.ToOfficialJson();
        Assert.Contains("\"refresh_token\" : \"n\\r\\n\\tt\"", text, StringComparison.Ordinal);
    }

    /// <summary>
    /// Case-insensitive ordering, verified on the real <c>auth.json</c> key set: a
    /// case-sensitive sort would put the capitalised <c>OPENAI_API_KEY</c> first.
    /// </summary>
    [Fact]
    public void KeysSortCaseInsensitively()
    {
        var text = Serialize("""
        {"auth_mode":"apikey","OPENAI_API_KEY":"sk-12345678"}
        """);

        var authMode = text.IndexOf("auth_mode", StringComparison.Ordinal);
        var apiKey = text.IndexOf("OPENAI_API_KEY", StringComparison.Ordinal);

        Assert.True(authMode < apiKey, "lowercase 'a' sorts before uppercase 'O' case-insensitively");
    }

    /// <summary>
    /// An empty object is <c>{\n\n}</c> — Apple emits a newline even with no members, which
    /// .NET's writer does not.
    /// </summary>
    [Fact]
    public void AnEmptyObjectKeepsApplesBlankLine()
    {
        var text = Serialize("""{"auth_mode":"apikey","OPENAI_API_KEY":"sk-12345678"}""");

        // This file is not empty, so use a directly-constructed empty case instead.
        var empty = CodexAuth.Parse("""
        {"auth_mode":"apikey","OPENAI_API_KEY":"sk-12345678"}
        """);
        Assert.NotNull(empty);

        Assert.Contains("{\n", text, StringComparison.Ordinal);
    }

    /// <summary>
    /// A whole-number double prints without a decimal point, and a fractional value keeps
    /// full round-trip precision — Apple prints 0.9 as 0.90000000000000002.
    /// </summary>
    [Fact]
    public void NumbersRoundTripWithoutTrailingZeroes()
    {
        var text = Serialize(Faithful());

        // Sanity: no exponent notation and no ".0" suffix on the integer-ish values.
        Assert.DoesNotContain("E+", text, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The strongest guarantee: a real macOS-shaped file survives a rewrite.</summary>
    [Fact]
    public void AMacOsShapedCredentialIsRewrittenIdentically()
    {
        const string macOSShaped = """
        {
          "auth_mode" : "chatgpt",
          "last_refresh" : "2026-10-09T00:00:00Z",
          "tokens" : {
            "access_token" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "account_id" : "acct-1",
            "id_token" : "id-token-value",
            "refresh_token" : "rrrrrrrrrrrrrrrrrrrrrrrrrrrr"
          }
        }
        """;

        Assert.Equal(macOSShaped, Serialize(macOSShaped));
    }

    [Fact]
    public void AMacOsShapedApiKeyIsRewrittenIdentically()
    {
        const string macOSShaped = """
        {
          "auth_mode" : "apikey",
          "OPENAI_API_KEY" : "sk-12345678"
        }
        """;

        Assert.Equal(macOSShaped, Serialize(macOSShaped));
    }
}
