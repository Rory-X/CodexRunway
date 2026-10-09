using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Behaviours ported from the macOS app's <c>CodexAuth</c> / <c>AccountStore</c> tests,
/// plus the Windows-specific path and plaintext-storage decisions.
/// </summary>
public class CodexAuthTests
{
    private const string LongToken = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string LongRefresh = "rrrrrrrrrrrrrrrrrrrrrrrrrrrr";

    private static string ChatGptJson(
        string accountId = "acct-1",
        string accessToken = LongToken,
        string refreshToken = LongRefresh) =>
        $$"""
        {
          "auth_mode": "chatgpt",
          "last_refresh": "2026-10-09T00:00:00Z",
          "tokens": {
            "access_token": "{{accessToken}}",
            "refresh_token": "{{refreshToken}}",
            "account_id": "{{accountId}}"
          }
        }
        """;

    // ------------------------------------------------------------------ parsing

    [Fact]
    public void ParsesAChatGptCredential()
    {
        var auth = CodexAuth.Parse(ChatGptJson());

        Assert.Equal("chatgpt", auth.AuthMode);
        Assert.False(auth.IsApiKeyAuth);
        Assert.Equal("acct-1", auth.Tokens.AccountId);
        Assert.Equal(LongToken, auth.Tokens.AccessToken);
        Assert.Equal(LoginUsability.Usable, auth.GetLoginUsability());
    }

    [Fact]
    public void ParsesAnApiKeyCredential()
    {
        var auth = CodexAuth.Parse("""{"auth_mode":"apikey","OPENAI_API_KEY":"sk-abcdefgh"}""");

        Assert.True(auth.IsApiKeyAuth);
        Assert.Equal("sk-abcdefgh", auth.OpenAiApiKey);
        Assert.Equal(LoginUsability.Usable, auth.GetLoginUsability());
    }

    [Fact]
    public void AKeyPlusLeftoverOAuthTokensIsStillAnApiKeyCredential()
    {
        // The real shape that caused another account's quota to be displayed: a key and a
        // working OAuth token in one file. The explicit mode decides which one Codex uses.
        var auth = CodexAuth.Parse($$"""
        {
          "auth_mode": "apikey",
          "OPENAI_API_KEY": "sk-relay-key-value",
          "tokens": {
            "access_token": "{{LongToken}}",
            "refresh_token": "{{LongRefresh}}",
            "account_id": "someone-else"
          }
        }
        """);

        Assert.True(auth.IsApiKeyAuth, "the key must win over the leftover tokens");
        Assert.True(auth.Tokens.HasOAuthTokens, "the leftover token is still present in the file");
    }

    [Fact]
    public void AnEmptyPayloadIsRejected()
    {
        Assert.Throws<CodexAuthFormatException>(() => CodexAuth.Parse("{}"));
    }

    [Fact]
    public void MalformedJsonIsRejectedWithAClearError()
    {
        var error = Assert.Throws<CodexAuthFormatException>(() => CodexAuth.Parse("not json"));
        Assert.Contains("not valid JSON", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ANonObjectPayloadIsRejected()
    {
        Assert.Throws<CodexAuthFormatException>(() => CodexAuth.Parse("[1,2,3]"));
    }

    // ------------------------------------------------------------------ usability

    [Theory]
    // The boundary is inclusive: exactly 8 characters is accepted, 7 is not.
    [InlineData("sk-1234", LoginUsability.InvalidTokens)]
    [InlineData("sk-12345", LoginUsability.Usable)]
    public void AnApiKeyIsUsableOnlyWhenLongEnough(string key, LoginUsability expected)
    {
        var auth = CodexAuth.Parse($$"""{"auth_mode":"apikey","OPENAI_API_KEY":"{{key}}"}""");
        Assert.Equal(expected, auth.GetLoginUsability());
    }

    [Fact]
    public void AShortAccessTokenIsInvalid()
    {
        var auth = CodexAuth.Parse(ChatGptJson(accessToken: "tooshort"));
        Assert.Equal(LoginUsability.InvalidTokens, auth.GetLoginUsability());
    }

    [Fact]
    public void AShortRefreshTokenIsInvalid()
    {
        var auth = CodexAuth.Parse(ChatGptJson(refreshToken: "short"));
        Assert.Equal(LoginUsability.InvalidTokens, auth.GetLoginUsability());
    }

    [Fact]
    public void AFutureDatedAccessOnlyCredentialIsUsable()
    {
        var future = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();
        var jwt = MakeJwt(JwtWithExp(future));
        var auth = CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"" + jwt
            + "\",\"refresh_token\":\"\"}}");

        Assert.True(auth.IsAccessTokenOnly);
        Assert.Equal(LoginUsability.Usable, auth.GetLoginUsability());
    }

    [Fact]
    public void AnExpiredAccessOnlyCredentialReportsWhyItCannotBeUsed()
    {
        var past = DateTimeOffset.UtcNow.AddHours(-1).ToUnixTimeSeconds();
        var jwt = MakeJwt(JwtWithExp(past));
        var auth = CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"" + jwt
            + "\",\"refresh_token\":\"\"}}");

        Assert.Equal(LoginUsability.ExpiredAccessWithoutRefresh, auth.GetLoginUsability());
    }

    // ------------------------------------------------------------------ encoding

    [Fact]
    public void AnApiKeyIsEncodedWithoutATokensBlock()
    {
        var json = CodexAuth.ApiKey("sk-abcdefgh").ToOfficialJson();
        var parsed = CodexAuth.Parse(json);

        Assert.True(parsed.IsApiKeyAuth);
        Assert.Equal("sk-abcdefgh", parsed.OpenAiApiKey);
        // Deliberately absent: writing an empty `tokens` would blank a ChatGPT session.
        Assert.DoesNotContain("\"tokens\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void AChatGptCredentialAlwaysCarriesARefreshTokenKey()
    {
        var json = CodexAuth.Parse(ChatGptJson(refreshToken: string.Empty)).ToOfficialJson();
        // Codex expects the key to exist even when empty.
        Assert.Contains("\"refresh_token\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void RunwayOnlyMetadataIsNeverWrittenToCodexFiles()
    {
        var auth = CodexAuth.ApiKey("sk-abcdefgh") with
        {
            PlanType = "plus",
            AuthFilePlanType = "plus",
        };

        var json = auth.ToOfficialJson();
        Assert.DoesNotContain("plan_type", json, StringComparison.Ordinal);
        Assert.DoesNotContain("auth_file_plan_type", json, StringComparison.Ordinal);
    }

    [Fact]
    public void MixedAuthWithoutAnExplicitModeIsRefused()
    {
        // Both a session and a key, with nothing saying which is authoritative: writing
        // this out would leave Codex to guess.
        var auth = new CodexAuth
        {
            AuthMode = null,
            Tokens = new CodexTokens { AccessToken = LongToken, RefreshToken = LongRefresh },
            OpenAiApiKey = "sk-abcdefgh",
        };

        Assert.Throws<CodexAuthFormatException>(() => auth.ToOfficialJson());
    }

    [Fact]
    public void AMixedFileWithAnExplicitModeEncodes()
    {
        var auth = new CodexAuth
        {
            AuthMode = "apikey",
            Tokens = new CodexTokens { AccessToken = LongToken, RefreshToken = LongRefresh },
            OpenAiApiKey = "sk-abcdefgh",
        };

        var parsed = CodexAuth.Parse(auth.ToOfficialJson());
        Assert.True(parsed.IsApiKeyAuth);
    }

    [Fact]
    public void RoundTripsThroughJsonWithoutLosingFields()
    {
        var original = CodexAuth.Parse(ChatGptJson(accountId: "acct-9"));
        var reparsed = CodexAuth.Parse(original.ToOfficialJson());

        Assert.Equal(original.AuthMode, reparsed.AuthMode);
        Assert.Equal(original.Tokens.AccessToken, reparsed.Tokens.AccessToken);
        Assert.Equal(original.Tokens.RefreshToken, reparsed.Tokens.RefreshToken);
        Assert.Equal(original.Tokens.AccountId, reparsed.Tokens.AccountId);
        Assert.Equal(original.LastRefresh, reparsed.LastRefresh);
    }

    [Fact]
    public void ToStringNeverLeaksASecret()
    {
        var auth = CodexAuth.Parse(ChatGptJson());
        var text = auth.ToString();

        Assert.DoesNotContain(LongToken, text, StringComparison.Ordinal);
        Assert.DoesNotContain(LongRefresh, text, StringComparison.Ordinal);
        Assert.Contains("<redacted>", text, StringComparison.Ordinal);
    }

    // ------------------------------------------------------------------ merge semantics

    [Fact]
    public void MergingPreservesOtherKeysTheAuthFileCarried()
    {
        var existing = System.Text.Json.Nodes.JsonNode.Parse("""
        {"auth_mode":"chatgpt","some_build_specific_key":"keep-me"}
        """)!.AsObject();

        var merged = CodexAuth.ApiKey("sk-abcdefgh").MergedInto(existing);

        Assert.Equal("keep-me", merged["some_build_specific_key"]!.GetValue<string>());
        Assert.True(merged.ContainsKey("OPENAI_API_KEY"));
    }

    /// <summary>
    /// The trap the merge path creates: installing a key into a file that still holds a
    /// ChatGPT session leaves a working OAuth token for a different account in place.
    /// </summary>
    [Fact]
    public void MergingAKeyLeavesAStaleTokensBlockInPlace()
    {
        var existing = System.Text.Json.Nodes.JsonNode.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"" + LongToken
            + "\",\"refresh_token\":\"" + LongRefresh + "\"}}")!.AsObject();

        var merged = CodexAuth.ApiKey("sk-abcdefgh").MergedInto(existing);

        var tokens = merged["tokens"]!.AsObject();
        Assert.Equal(LongToken, tokens["access_token"]!.GetValue<string>());
        Assert.Equal("apikey", merged["auth_mode"]!.GetValue<string>());
        // Both credentials are now present: a key and somebody's live session.
        Assert.True(merged.ContainsKey("OPENAI_API_KEY"));
    }

    [Fact]
    public void ARefreshResponseUpdatesOnlyTheTokensItCarries()
    {
        var original = CodexAuth.Parse(ChatGptJson());
        var refreshed = original.WithRefreshResponse(
            idToken: "new-id", accessToken: "new-access", refreshToken: null,
            now: DateTimeOffset.Parse("2026-10-09T12:00:00Z"));

        Assert.Equal("new-access", refreshed.Tokens.AccessToken);
        // A null refresh token means "unchanged", not "clear it".
        Assert.Equal(LongRefresh, refreshed.Tokens.RefreshToken);
        Assert.Equal("new-id", refreshed.Tokens.IdToken);
        Assert.Equal("2026-10-09T12:00:00Z", refreshed.LastRefresh);
    }

    // ------------------------------------------------------------------ token inspection

    [Fact]
    public void AnUnparseableTokenCountsAsExpired()
    {
        Assert.True(TokenInspector.IsExpired("garbage"));
        Assert.True(TokenInspector.IsExpired(string.Empty));
        Assert.True(TokenInspector.IsExpired(null));
    }

    [Fact]
    public void ATokenInsideTheSkewWindowCountsAsExpired()
    {
        var soon = DateTimeOffset.UtcNow.AddSeconds(30).ToUnixTimeSeconds();
        var jwt = MakeJwt($$"""{"exp":{{soon}}}""");

        // Refreshing slightly early is cheaper than a request that races the expiry.
        Assert.True(TokenInspector.IsExpired(jwt));
    }

    [Fact]
    public void AComfortablyFutureTokenIsNotExpired()
    {
        var later = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();
        Assert.False(TokenInspector.IsExpired(MakeJwt(JwtWithExp(later))));
    }

    [Fact]
    public void Base64UrlDecodesUnpaddedSegments()
    {
        // JWT segments omit padding, and Convert.FromBase64String rejects that.
        var decoded = System.Text.Encoding.UTF8.GetString(Base64Url.Decode("eyJhIjoxfQ"));
        Assert.Equal("""{"a":1}""", decoded);
    }

    private static string JwtWithExp(long unixSeconds)
        => "{\"exp\":" + unixSeconds + "}";

    private static string MakeJwt(string payloadJson)
    {
        static string Seg(string s) => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(s))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

        return $"{Seg("{\"alg\":\"none\"}")}.{Seg(payloadJson)}.sig";
    }
}
