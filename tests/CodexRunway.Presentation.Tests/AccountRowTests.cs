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

    /// <summary>
    /// A short key masked by keeping its first four characters would hardly be masked at all:
    /// <c>sk-1</c> from a five-character key is most of the secret.
    /// </summary>
    /// <remarks>
    /// The whole row is checked, not just the title's prefix, and a boundary either side of the
    /// eight-character rule is covered. An earlier version asserted only that the full key was
    /// absent from the title using a seven-character input, which holds both when the key is
    /// masked entirely and when four of its seven characters are kept — the assertion never
    /// depended on the rule.
    /// </remarks>
    [Theory]
    [InlineData("sk-1234")]     // 7 characters: below the rule, masked whole
    [InlineData("sk-12345")]    // 8 characters: still masked whole
    public void AShortKeyIsMaskedEntirely(string key)
    {
        var row = AccountRow.From("acct-1", null, null, null, ApiKey(key), false, false);

        Assert.DoesNotContain(key, row.Title, StringComparison.Ordinal);
        Assert.DoesNotContain(key, row.Subtitle ?? string.Empty, StringComparison.Ordinal);
        // No part of the key survives, so the mask is all that is left.
        Assert.Equal(new string('•', 8), row.Title);
    }

    /// <summary>
    /// Just above the rule, the first four characters are kept and the remainder is masked with
    /// bullets, so the masked label still reveals the key's length — the property the rule exists
    /// for — without revealing anything past the fourth character.
    /// </summary>
    [Fact]
    public void AKeyJustLongerThanTheRuleKeepsOnlyItsFirstFourCharacters()
    {
        const string key = "sk-123456";
        var row = AccountRow.From("acct-1", null, null, null, ApiKey(key), false, false);

        Assert.Equal("sk-1" + new string('•', key.Length - 4), row.Title);
        Assert.DoesNotContain(key, row.Title, StringComparison.Ordinal);
        // Same length as the original, so a user can still compare it against the issuing panel.
        Assert.Equal(key.Length, row.Title.Length);
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
    // ---------------------------------------------------------------- view-facing flags

    /// <summary>
    /// A switch button belongs on an account the user can actually move to, and nowhere else.
    /// </summary>
    /// <remarks>
    /// Present-but-refusing looks broken, and a button on the account already in use implies a
    /// change that would not happen. Decided here rather than in XAML so both platforms agree.
    /// </remarks>
    [Fact]
    public void AUsableInactiveAccountOffersASwitch()
        => Assert.True(AccountRow.From("a", null, null, null, OAuth(), isActive: false, needsReauth: false)
            .ShowSwitchAction);

    [Fact]
    public void TheActiveAccountDoesNotOfferASwitch()
        => Assert.False(AccountRow.From("a", null, null, null, OAuth(), isActive: true, needsReauth: false)
            .ShowSwitchAction);

    [Fact]
    public void AnAccountNeedingReauthDoesNotOfferASwitch()
        => Assert.False(AccountRow.From("a", null, null, null, OAuth(), isActive: false, needsReauth: true)
            .ShowSwitchAction);

    /// <summary>
    /// An unusable credential must not offer a switch: the switch would be refused, so the button
    /// would look broken rather than the account.
    /// </summary>
    [Fact]
    public void AnUnusableCredentialDoesNotOfferASwitch()
    {
        var broken = CodexAuth.Parse("{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"sk-1\"}");

        Assert.False(AccountRow.From("a", null, null, null, broken, isActive: false, needsReauth: false)
            .ShowSwitchAction);
    }

    /// <summary>
    /// "No quota data" is worth saying for a subscription account and misleading for a relay
    /// account, which has a balance rather than a quota.
    /// </summary>
    [Fact]
    public void ASubscriptionAccountWithoutQuotaExplainsItself()
        => Assert.True(AccountRow.From("a", null, null, null, OAuth(), false, false).NeedsQuotaNotice);

    [Fact]
    public void ARelayAccountDoesNotClaimToHaveNoQuota()
        => Assert.False(AccountRow.From("a", null, null, null, ApiKey(), false, false).NeedsQuotaNotice);

    [Fact]
    public void AnAccountNeedingReauthIsNotAlsoToldItHasNoQuota()
        => Assert.False(AccountRow.From("a", null, null, null, OAuth(), false, true).NeedsQuotaNotice);
}
