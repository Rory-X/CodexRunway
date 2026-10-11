using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// The stable hash and identity matching.
/// </summary>
/// <remarks>
/// These values decide which directory an account lives in, so they are shared with the macOS
/// build: a different result here means the same login lands in two folders and neither build
/// sees the other's credential. Every expected value below was produced by running the macOS
/// implementation, not by re-deriving it.
/// </remarks>
public class AccountIdentityTests
{
    [Theory]
    [InlineData("", "1505")]
    [InlineData("a", "a6ddc")]
    [InlineData("x", "a6df3")]
    [InlineData("abc", "29113c2dd")]
    [InlineData("sk-abc123", "8df057b23befd000")]
    [InlineData("oauth:user:u1|account:a1", "212bdd94cdaae276")]
    [InlineData("rt-token-value", "40ab33df249a1697")]
    [InlineData("0123456789abcdef", "97a7c015113b678d")]
    [InlineData("中文", "503d758746b883")]
    [InlineData("🙂", "1460a52601d")]
    [InlineData(
        "sk-4c8f2e9d1b7a6f3e5c2d8b4a9e7f1c3d5a8b2e4f6c9d1a3b5e7f9c2d4a6b8e0f",
        "65fefe479453ef06")]
    public void StableHashMatchesTheMacOsImplementation(string input, string expected)
        => Assert.Equal(expected, AccountIdentity.StableHash(input));

    /// <summary>
    /// The identifier must not change between runs. <c>GetHashCode</c> is randomised per
    /// process, so a port that reached for it would mint a fresh directory on every launch.
    /// </summary>
    [Fact]
    public void TheHashIsStableWithinAndAcrossInstances()
    {
        const string input = "sk-abc123";

        var first = AccountIdentity.StableHash(input);
        var second = AccountIdentity.StableHash(new string(input.ToCharArray()));

        Assert.Equal("8df057b23befd000", first);
        Assert.Equal(first, second);
    }

    /// <summary>Lowercase hex, and unpadded — the macOS form.</summary>
    [Fact]
    public void TheHashIsLowercaseUnpaddedHex()
    {
        var hash = AccountIdentity.StableHash("a");

        Assert.DoesNotContain("0X", hash, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(hash, hash.ToLowerInvariant());
        Assert.DoesNotContain(" ", hash, StringComparison.Ordinal);
    }

    [Fact]
    public void AnApiKeyIsHashedAfterTrimming()
    {
        Assert.Equal(
            AccountIdentity.ApiKeyFingerprint("sk-abc123"),
            AccountIdentity.ApiKeyFingerprint("  sk-abc123\n"));
    }

    // ---------------------------------------------------------------- fingerprint prefixes

    [Fact]
    public void TheRefreshTokenIsPreferredAndPrefixed()
        => Assert.StartsWith("rt-", AccountIdentity.OAuthFingerprint(OAuth(
            refresh: "refresh-token-value", access: "access-token-value")), StringComparison.Ordinal);

    [Fact]
    public void WithoutARefreshTokenTheAccessTokenIsUsedAndPrefixed()
        => Assert.StartsWith("at-", AccountIdentity.OAuthFingerprint(OAuth(
            refresh: null, access: "access-token-value")), StringComparison.Ordinal);

    /// <summary>
    /// A credential with no token at all cannot be parsed from JSON — <c>Parse</c> rightly
    /// rejects it — so the object is built directly here to reach the branch.
    /// </summary>
    [Fact]
    public void WithNeitherTokenTheFingerprintCannotCollide()
    {
        var empty = new CodexAuth
        {
            AuthMode = "chatgpt",
            Tokens = new CodexTokens { AccessToken = string.Empty, RefreshToken = string.Empty },
        };

        var fingerprint = AccountIdentity.OAuthFingerprint(empty);

        Assert.StartsWith("unknown-", fingerprint, StringComparison.Ordinal);
        // Two such credentials must not share an id, or they would claim the same directory.
        Assert.NotEqual(fingerprint, AccountIdentity.OAuthFingerprint(empty));
    }

    /// <summary>
    /// The same text used as a refresh token and as an access token must not collide, which is
    /// the whole reason for the prefix.
    /// </summary>
    [Fact]
    public void TheSameTextAsEitherTokenYieldsDifferentFingerprints()
    {
        const string text = "identical-value";

        Assert.NotEqual(
            AccountIdentity.OAuthFingerprint(OAuth(refresh: text, access: null)),
            AccountIdentity.OAuthFingerprint(OAuth(refresh: null, access: text)));
    }

    // ---------------------------------------------------------------- managed ids

    [Fact]
    public void AnApiKeyAccountGetsTheApiPrefix()
        => Assert.StartsWith("api-", AccountIdentity.ManagedAccountId(
            CodexAuth.ApiKey("sk-abcdefgh")), StringComparison.Ordinal);

    [Fact]
    public void AnOAuthAccountGetsTheOauthPrefix()
        => Assert.StartsWith("oauth-", AccountIdentity.ManagedAccountId(OAuth(
            refresh: "refresh-token-value", access: "access-token-value")), StringComparison.Ordinal);

    /// <summary>
    /// The shape has to match the directories already on disk, or an existing account would be
    /// duplicated rather than adopted.
    /// </summary>
    [Fact]
    public void AManagedIdLooksLikeTheExistingDirectories()
    {
        var id = AccountIdentity.ManagedAccountId(CodexAuth.ApiKey("sk-abcdefgh"));

        Assert.StartsWith("api-", id, StringComparison.Ordinal);
        Assert.Matches("^api-[0-9a-f]+$", id);
    }

    [Fact]
    public void TheSameCredentialAlwaysYieldsTheSameId()
    {
        var auth = CodexAuth.ApiKey("sk-abcdefgh");

        Assert.Equal(AccountIdentity.ManagedAccountId(auth), AccountIdentity.ManagedAccountId(auth));
    }

    [Fact]
    public void DifferentCredentialsYieldDifferentIds()
        => Assert.NotEqual(
            AccountIdentity.ManagedAccountId(CodexAuth.ApiKey("sk-aaaaaaaa")),
            AccountIdentity.ManagedAccountId(CodexAuth.ApiKey("sk-bbbbbbbb")));

    // ---------------------------------------------------------------- matching

    [Fact]
    public void AnApiKeyMatchesItsOwnRow()
    {
        var auth = CodexAuth.ApiKey("sk-abcdefgh");
        var id = AccountIdentity.ManagedAccountId(auth);

        Assert.True(AccountIdentity.Matches(id, null, null, null, auth));
    }

    [Fact]
    public void AnApiKeyDoesNotMatchAnotherRowsId()
    {
        var auth = CodexAuth.ApiKey("sk-abcdefgh");

        Assert.False(AccountIdentity.Matches("api-1234abcd", null, null, null, auth));
    }

    /// <summary>
    /// A re-login keeps the user id even though the tokens are new, so matching on it is what
    /// lets a credential be filed against the row the user is repairing.
    /// </summary>
    [Fact]
    public void AnOAuthCredentialMatchesOnItsUserId()
    {
        var auth = OAuth(
            refresh: "refresh-token-value",
            access: "access-token-value",
            userId: "user-1",
            accountId: "acct-1");

        Assert.True(AccountIdentity.Matches("oauth-oldid", "user-1", null, null, auth));
    }

    [Fact]
    public void AnOAuthCredentialMatchesOnItsSubject()
    {
        var auth = OAuth(
            refresh: "refresh-token-value",
            access: "access-token-value",
            subject: "subject-1",
            accountId: "acct-1");

        Assert.True(AccountIdentity.Matches("oauth-oldid", null, "subject-1", null, auth));
    }

    [Fact]
    public void AnOAuthCredentialMatchesOnItsEmail()
    {
        var auth = OAuth(
            refresh: "refresh-token-value",
            access: "access-token-value",
            email: "me@example.com",
            accountId: "acct-1");

        Assert.True(AccountIdentity.Matches("oauth-oldid", null, null, "me@example.com", auth));
    }

    /// <summary>
    /// A credential with no comparable claim falls back to its derived id, so a repair is not
    /// refused merely because the token carried nothing to compare.
    /// </summary>
    [Fact]
    public void ACredentialWithNoClaimsFallsBackToItsDerivedId()
    {
        var auth = OAuth(refresh: "refresh-token-value", access: "access-token-value");
        var id = AccountIdentity.ManagedAccountId(auth);

        Assert.True(AccountIdentity.Matches(id, "someone-else", "other", "other@example.com", auth));
    }

    [Fact]
    public void ADifferentUserIdDoesNotMatchWhenTheDerivedIdAlsoDiffers()
    {
        var auth = OAuth(
            refresh: "refresh-token-value",
            access: "access-token-value",
            userId: "user-1",
            accountId: "acct-1");

        Assert.False(AccountIdentity.Matches("oauth-different", "user-2", null, null, auth));
    }

    // ---------------------------------------------------------------- helpers

    private static CodexAuth OAuth(
        string? refresh,
        string? access,
        string? userId = null,
        string? subject = null,
        string? email = null,
        string? accountId = null)
    {
        var authClaims = new List<string>();
        if (userId is not null)
        {
            authClaims.Add("\"chatgpt_user_id\":\"" + userId + "\"");
        }

        if (accountId is not null)
        {
            authClaims.Add("\"chatgpt_account_id\":\"" + accountId + "\"");
        }

        var rootClaims = new List<string>();
        if (subject is not null)
        {
            rootClaims.Add("\"sub\":\"" + subject + "\"");
        }

        if (email is not null)
        {
            rootClaims.Add("\"email\":\"" + email + "\"");
        }

        if (authClaims.Count > 0)
        {
            rootClaims.Add("\"https://api.openai.com/auth\":{" + string.Join(",", authClaims) + "}");
        }

        var idToken = rootClaims.Count > 0 ? Jwt("{" + string.Join(",", rootClaims) + "}") : null;

        var tokenJson = new List<string>
        {
            "\"access_token\":\"" + (access ?? string.Empty) + "\"",
            "\"refresh_token\":\"" + (refresh ?? string.Empty) + "\"",
        };
        if (idToken is not null)
        {
            tokenJson.Add("\"id_token\":\"" + idToken + "\"");
        }

        if (accountId is not null)
        {
            tokenJson.Add("\"account_id\":\"" + accountId + "\"");
        }

        return CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{" + string.Join(",", tokenJson) + "}}");
    }

    private static string Jwt(string payload)
    {
        static string Segment(string text) => Convert.ToBase64String(
                System.Text.Encoding.UTF8.GetBytes(text))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

        return Segment("{\"alg\":\"none\"}") + "." + Segment(payload) + ".sig";
    }
}
