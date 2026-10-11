using CodexRunway.Core;
using CodexRunway.Presentation;
using Xunit;

namespace CodexRunway.Presentation.Tests;

/// <summary>
/// The window shows account rows, so this is where a secret could escape.
/// </summary>
public class AccountRowTests
{
    private const string Key = "sk-abcdefghijklmnopqrstuvwxyz0123456789";
    private const string Access = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Refresh = "rrrrrrrrrrrrrrrrrrrrrrrrrrrr";

    private static CodexAuth ApiKey(string key = Key) => CodexAuth.ApiKey(key);

    private static CodexAuth OAuth(string? plan = "plus") => CodexAuth.Parse(
        "{\"auth_mode\":\"chatgpt\",\"plan_type\":\"" + (plan ?? "") + "\",\"tokens\":{"
        + "\"access_token\":\"" + Access + "\",\"refresh_token\":\"" + Refresh + "\","
        + "\"account_id\":\"acct-1\"}}");

    [Fact]
    public void AnApiKeyIsMaskedToFourCharacters()
    {
        var row = AccountRow.From("acct-1", null, null, null, ApiKey(), false, false);

        // The first four characters survive so the user can match the row against the panel
        // that issued the key; the rest never reaches the view.
        Assert.StartsWith("sk-a", row.Title, StringComparison.Ordinal);
        Assert.DoesNotContain(Key, row.Title, StringComparison.Ordinal);
        Assert.DoesNotContain(Key, row.Subtitle ?? string.Empty, StringComparison.Ordinal);
    }

    /// <summary>
    /// A whole secret must never appear anywhere on the row, including the subtitle.
    /// </summary>
    [Fact]
    public void AFullKeyNeverAppearsOnTheRow()
    {
        var row = AccountRow.From("acct-1", "my relay", "My Relay", "me@example.com",
            ApiKey(), true, false, usedPercent: 42, quotaSummary: "42%");

        var everything = string.Join('|', row.Title, row.Subtitle, row.QuotaSummary, row.ToString());

        Assert.DoesNotContain(Key, everything, StringComparison.Ordinal);
    }

    /// <summary>Tokens are never a row's content, whatever the credential holds.</summary>
    [Fact]
    public void OAuthTokensNeverAppearOnTheRow()
    {
        var row = AccountRow.From("acct-1", "work", "Work", "me@example.com", OAuth(), false, false);

        var everything = string.Join('|', row.Title, row.Subtitle, row.ToString());

        Assert.DoesNotContain(Access, everything, StringComparison.Ordinal);
        Assert.DoesNotContain(Refresh, everything, StringComparison.Ordinal);
    }

    /// <summary>A short key masked by keeping four characters would hardly be masked at all.</summary>
    [Fact]
    public void AShortKeyIsMaskedEntirely()
    {
        var row = AccountRow.From("acct-1", null, null, null, ApiKey("sk-1234"), false, false);

        Assert.DoesNotContain("sk-1234", row.Title, StringComparison.Ordinal);
    }

    [Fact]
    public void TheUserAliasWinsOverADerivedTitle()
    {
        var row = AccountRow.From("acct-1", "工作号", "Me@Example.com", "me@example.com",
            OAuth(), false, false);

        Assert.Equal("工作号", row.Title);
    }

    [Fact]
    public void AnOAuthAccountShowsItsPlanAndIdentity()
    {
        var row = AccountRow.From("acct-1", null, "Me", "me@example.com", OAuth("plus"), false, false);

        Assert.Contains("plus", row.Subtitle!, StringComparison.Ordinal);
        Assert.Contains("me@example.com", row.Subtitle!, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------- tone

    [Fact]
    public void AnActiveUsableAccountIsTonedActive()
        => Assert.Equal(RowTone.Active, AccountRow.From("a", null, null, null, OAuth(), true, false).Tone);

    [Fact]
    public void AnInactiveUsableAccountIsTonedNormal()
        => Assert.Equal(RowTone.Normal, AccountRow.From("a", null, null, null, OAuth(), false, false).Tone);

    [Fact]
    public void AnAccountNeedingReauthIsTonedProblem()
        => Assert.Equal(RowTone.Problem, AccountRow.From("a", null, null, null, OAuth(), false, true).Tone);

    /// <summary>
    /// A credential that cannot be used must read as a problem even when it is the active
    /// one — otherwise the panel would present a broken account as the working choice.
    /// </summary>
    [Fact]
    public void AnUnusableActiveAccountIsTonedProblem()
    {
        var broken = CodexAuth.Parse("{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"sk-1\"}");

        Assert.Equal(RowTone.Problem, AccountRow.From("a", null, null, null, broken, true, false).Tone);
    }

    [Fact]
    public void AnAccountNearItsLimitIsTonedCaution()
        => Assert.Equal(RowTone.Caution,
            AccountRow.From("a", null, null, null, OAuth(), false, false, usedPercent: 85).Tone);

    [Fact]
    public void AnAccountWellUnderItsLimitIsTonedNormal()
        => Assert.Equal(RowTone.Normal,
            AccountRow.From("a", null, null, null, OAuth(), false, false, usedPercent: 20).Tone);

    // ---------------------------------------------------------------- actionability

    [Fact]
    public void AnExpiredSessionAccountCannotBeActivated()
    {
        var past = DateTimeOffset.UtcNow.AddHours(-1).ToUnixTimeSeconds();
        static string Segment(string t) => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(t))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var jwt = $"{Segment("{\"alg\":\"none\"}")}.{Segment("{\"exp\":" + past + "}")}.sig";
        var expired = CodexAuth.Parse("{\"auth_mode\":\"chatgpt\",\"tokens\":{"
            + "\"access_token\":\"" + jwt + "\",\"refresh_token\":\"\"}}");

        var row = AccountRow.From("a", null, null, null, expired, false, false);

        Assert.Equal(LoginUsability.ExpiredAccessWithoutRefresh, row.Usability);
        Assert.False(row.CanActivate);
    }

    [Fact]
    public void AUsableAccountCanBeActivated()
        => Assert.True(AccountRow.From("a", null, null, null, OAuth(), false, false).CanActivate);

    [Fact]
    public void AnUnnamedAccountStillGetsATitle()
    {
        var row = AccountRow.From("acct-1", null, null, null, OAuth(), false, false);

        Assert.False(string.IsNullOrWhiteSpace(row.Title));
    }
}
