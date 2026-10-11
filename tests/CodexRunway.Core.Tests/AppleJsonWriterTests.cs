using System.Text.Json.Nodes;
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
    /// Apple emits a newline between the braces of an empty object — <c>{\n\n}</c> — where
    /// .NET's writer does not. The account index holds empty objects in practice, so the file
    /// stops being byte-identical without this.
    /// </summary>
    /// <remarks>
    /// Exercised through the writer directly rather than through a credential, because
    /// <see cref="CodexAuth.ToOfficialJson"/> never produces an empty object — an earlier
    /// version of this test used a non-empty API-key file and asserted only that the text
    /// contained <c>"{\n"</c>, which the ordinary multi-member path emits anyway.
    /// </remarks>
    [Fact]
    public void AnEmptyObjectKeepsApplesBlankLine()
        => Assert.Equal("{\n\n}", AppleJsonWriter.Write(new JsonObject()));

    /// <summary>The same rule applies to an empty array: <c>[\n\n]</c>.</summary>
    [Fact]
    public void AnEmptyArrayKeepsApplesBlankLine()
        => Assert.Equal(
            "{\n  \"a\" : [\n\n  ]\n}",
            AppleJsonWriter.Write(new JsonObject { ["a"] = new JsonArray() }));

    /// <summary>
    /// An empty object nested inside a non-empty one still gets its blank line, and the closing
    /// brace is indented to its own depth.
    /// </summary>
    [Fact]
    public void ANestedEmptyObjectIsAlsoIndented()
        => Assert.Equal(
            "{\n  \"outer\" : {\n\n  }\n}",
            AppleJsonWriter.Write(new JsonObject { ["outer"] = new JsonObject() }));

    /// <summary>
    /// A whole-number double prints without a decimal point, and a fractional value keeps
    /// full round-trip precision — Apple prints 0.9 as 0.90000000000000002.
    /// </summary>
    /// <remarks>
    /// The fixture carries real numbers on purpose. An earlier version serialised a credential —
    /// which holds only strings — and then asserted that the text contained no <c>E+</c>, an
    /// assertion no implementation of the number path could ever break.
    /// </remarks>
    [Fact]
    public void WholeNumbersPrintWithoutADecimalPointAndFractionsKeepPrecision()
    {
        var text = AppleJsonWriter.Write(
            JsonNode.Parse("""{"frac":0.9,"whole":10000000000}""")!.AsObject());

        // 10000000000 is exactly representable, so it stays an integer literal — not 1E+10.
        Assert.Contains("\"whole\" : 10000000000", text, StringComparison.Ordinal);
        Assert.DoesNotContain("10000000000.0", text, StringComparison.Ordinal);
        Assert.DoesNotContain("1E+10", text, StringComparison.OrdinalIgnoreCase);

        // 0.9 is not exactly representable, and Apple writes the full 17 digits rather than 0.9.
        Assert.Contains("\"frac\" : 0.90000000000000002", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\"frac\" : 0.9,", text, StringComparison.Ordinal);

        // The document is still readable back as the same numbers.
        var reparsed = JsonNode.Parse(text)!.AsObject();
        Assert.Equal(10000000000L, reparsed["whole"]!.GetValue<long>());
        Assert.Equal(0.9, reparsed["frac"]!.GetValue<double>());
    }


    /// <summary>
    /// Doubles are printed with <c>%.17g</c> precision, not the shortest round-trip form.
    /// </summary>
    /// <remarks>
    /// Every expectation was produced by Apple's <c>JSONSerialization</c>. The distinction
    /// is easy to miss: .NET's <c>"R"</c> writes <c>0.9</c> where Apple writes
    /// <c>0.90000000000000002</c>, and the account index carries money as doubles, so the
    /// shorter form would stop the file being byte-identical. <c>G17</c> matches, except
    /// that .NET spells the exponent <c>E</c> and C spells it <c>e</c>.
    /// </remarks>
    [Theory]
    [InlineData(0.9, "0.90000000000000002")]
    [InlineData(0.05, "0.050000000000000003")]
    [InlineData(1e-7, "9.9999999999999995e-08")]
    [InlineData(1.5e-10, "1.5e-10")]
    [InlineData(1e21, "1e+21")]
    [InlineData(1e16, "10000000000000000")]
    [InlineData(123.456, "123.456")]
    [InlineData(0.25, "0.25")]
    [InlineData(400000, "400000")]
    [InlineData(0, "0")]
    [InlineData(-5, "-5")]
    [InlineData(360000, "360000")]
    public void DoublesUseApplesSeventeenDigitPrecision(double value, string expected)
        => Assert.Equal(expected, FormatNumber(value));

    /// <summary>
    /// Guards the specific mistake: the shortest round-trip form must NOT be used, because
    /// it is what .NET reaches for by default and it silently differs from Apple.
    /// </summary>
    [Fact]
    public void TheShortestRoundTripFormIsNotWhatAppleWrites()
    {
        Assert.NotEqual("0.9", FormatNumber(0.9));
        Assert.NotEqual("0.05", FormatNumber(0.05));
        // Lowercase exponent, not .NET's uppercase E.
        Assert.DoesNotContain("E", FormatNumber(1e21), StringComparison.Ordinal);
    }

    /// <summary>
    /// Calls the writer's internal number formatter through a real JSON round trip, so the
    /// node carries the same backing store it does in production.
    /// </summary>
    private static string FormatNumber(double value)
    {
        var node = System.Text.Json.Nodes.JsonNode.Parse(
            "{\"n\":" + value.ToString("R", System.Globalization.CultureInfo.InvariantCulture) + "}")!
            .AsObject()["n"]!;

        var method = typeof(CodexAuth).Assembly
            .GetType("CodexRunway.Core.AppleJsonWriter")!
            .GetMethod(
                "FormatNumber",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;

        return (string)method.Invoke(null, new object[] { node })!;
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
