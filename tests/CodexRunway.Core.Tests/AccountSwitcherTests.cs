using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Switching the active account.
/// </summary>
/// <remarks>
/// A switch is two writes that must agree, and a half-applied one is worse than none: a relay
/// credential paired with an official endpoint, or the reverse, fails in a way that looks like a
/// broken key rather than a broken switch. These tests pin the order and the refusal cases.
/// </remarks>
public class AccountSwitcherTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;
    private readonly CredentialStore _store;
    private readonly AccountSwitcher _switcher;

    private const string Access = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Refresh = "rrrrrrrrrrrrrrrrrrrrrrrrrrrr";

    public AccountSwitcherTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"switch-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(Path.Combine(_root, ".codex"), Path.Combine(_root, ".codex-runway"));
        _store = new CredentialStore(_paths);
        _switcher = new AccountSwitcher(_paths, _store);
        Directory.CreateDirectory(_paths.CodexHome);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private void SaveOAuth(string id, string refresh = Refresh)
        => _store.SaveCredential(id, CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"" + Access
            + "\",\"refresh_token\":\"" + refresh + "\"}}"));

    private void SaveKey(string id, string key = "sk-abcdefghijklmnop")
        => _store.SaveCredential(id, CodexAuth.ApiKey(key));

    private void WriteConfig(string text) => File.WriteAllText(_paths.ConfigPath, text);

    // ---------------------------------------------------------------- switching

    [Fact]
    public void SwitchingInstallsTheCredential()
    {
        SaveOAuth("acct-1");

        var result = _switcher.SwitchTo("acct-1", providerName: null);

        Assert.True(result.Succeeded);
        Assert.Equal(SwitchOutcomeKind.Switched, result.Kind);
        Assert.True(_store.HasCredential("acct-1"));
        Assert.Equal(
            _store.LoadCredential("acct-1").Tokens.RefreshToken,
            _store.LoadOfficialAuth().Tokens.RefreshToken);
    }

    /// <summary>
    /// A subscription account must clear the provider so Codex uses its own endpoint. Leaving a
    /// relay's provider selected sends an official credential to a third party.
    /// </summary>
    [Fact]
    public void SwitchingToASubscriptionAccountClearsTheProvider()
    {
        SaveOAuth("acct-1");
        WriteConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://relay.example/v1"
        """);

        var result = _switcher.SwitchTo("acct-1", providerName: null);

        Assert.True(result.Succeeded);
        Assert.Null(CodexConfigReader.SelectedProvider(_paths.ConfigPath));
        // And the relay's own section is left intact.
        Assert.Contains("https://relay.example/v1",
            File.ReadAllText(_paths.ConfigPath), StringComparison.Ordinal);
    }

    [Fact]
    public void SwitchingToARelayAccountSelectsTheProvider()
    {
        SaveKey("api-1");
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://relay.example/v1"
        """);

        var result = _switcher.SwitchTo("api-1", providerName: "custom");

        Assert.True(result.Succeeded);
        Assert.Equal("custom", CodexConfigReader.SelectedProvider(_paths.ConfigPath));
        Assert.True(result.ConfigUpdated);
    }

    /// <summary>A missing config is not an error: Codex runs on its defaults.</summary>
    [Fact]
    public void AMissingConfigDoesNotBlockASwitch()
    {
        SaveOAuth("acct-1");

        var result = _switcher.SwitchTo("acct-1", providerName: null);

        Assert.True(result.Succeeded);
        Assert.False(result.ConfigUpdated);
        Assert.False(File.Exists(_paths.ConfigPath));
    }

    // ---------------------------------------------------------------- refusal

    [Fact]
    public void SwitchingToAnUnknownAccountFails()
    {
        var result = _switcher.SwitchTo("does-not-exist", providerName: null);

        Assert.Equal(SwitchOutcomeKind.Failed, result.Kind);
        Assert.Equal("account_credential_missing", result.Reason);
    }

    [Fact]
    public void SwitchingToACorruptAccountFails()
    {
        var path = _paths.CredentialPath("broken");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{ not json");

        var result = _switcher.SwitchTo("broken", providerName: null);

        Assert.Equal(SwitchOutcomeKind.Failed, result.Kind);
        Assert.Equal("account_credential_invalid", result.Reason);
    }

    /// <summary>
    /// An unusable credential must be refused rather than installed: installing it signs the
    /// user out of Codex.
    /// </summary>
    [Fact]
    public void SwitchingToAnUnusableCredentialFailsAndLeavesCodexAuthAlone()
    {
        SaveOAuth("good");
        _switcher.SwitchTo("good", null);
        var before = File.ReadAllText(_paths.OfficialAuthPath);

        _store.SaveCredential("placeholder",
            CodexAuth.Parse("{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"sk-1\"}"),
            allowUnusable: true);

        var result = _switcher.SwitchTo("placeholder", providerName: null);

        Assert.Equal(SwitchOutcomeKind.Failed, result.Kind);
        Assert.Equal("account_credential_unusable", result.Reason);
        // The working credential is untouched.
        Assert.Equal(before, File.ReadAllText(_paths.OfficialAuthPath));
    }

    /// <summary>
    /// Order matters: on a config failure the credential must NOT have been installed, or the
    /// two files would disagree.
    /// </summary>
    [Fact]
    public void AConfigFailureLeavesTheCredentialUninstalled()
    {
        SaveOAuth("good");
        _switcher.SwitchTo("good", null);

        SaveKey("api-1");
        // A config that cannot be written: a directory sits where the file belongs.
        File.Delete(_paths.ConfigPath);
        Directory.CreateDirectory(_paths.ConfigPath);

        var result = _switcher.SwitchTo("api-1", providerName: "custom");

        Assert.Equal(SwitchOutcomeKind.Failed, result.Kind);
        Assert.False(result.CredentialInstalled);
        // Still the original account.
        Assert.Equal(
            _store.LoadCredential("good").Tokens.RefreshToken,
            _store.LoadOfficialAuth().Tokens.RefreshToken);
    }

    // ---------------------------------------------------------------- replacement semantics

    /// <summary>
    /// The switch must replace, not merge. A merged write leaves the previous account's tokens in
    /// the file, and anything reading them acts as the wrong account.
    /// </summary>
    [Fact]
    public void SwitchingToARelayAccountRemovesThePreviousAccountsTokens()
    {
        SaveOAuth("sub", refresh: "refresh-aaaaaaaaaaaaaaaaaaaa");
        _switcher.SwitchTo("sub", null);

        SaveKey("api-1", "sk-abcdefghijklmnop");
        var result = _switcher.SwitchTo("api-1", providerName: "custom");

        Assert.True(result.Succeeded);
        var text = File.ReadAllText(_paths.OfficialAuthPath);
        Assert.Contains("sk-abcdefghijklmnop", text, StringComparison.Ordinal);
        Assert.DoesNotContain("refresh-aaaaaaaaaaaaaaaaaaaa", text, StringComparison.Ordinal);
    }

    [Fact]
    public void SwitchingBetweenSubscriptionAccountsReplacesTheCredential()
    {
        SaveOAuth("a", refresh: "refresh-aaaaaaaaaaaaaaaaaaaa");
        SaveOAuth("b", refresh: "refresh-bbbbbbbbbbbbbbbbbbbb");

        _switcher.SwitchTo("a", null);
        _switcher.SwitchTo("b", null);

        var live = _store.LoadOfficialAuth().Tokens.RefreshToken;
        Assert.Equal("refresh-bbbbbbbbbbbbbbbbbbbb", live);
    }

    // ---------------------------------------------------------------- provider choice

    [Fact]
    public void ASubscriptionAccountClearsTheProvider()
    {
        var auth = CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"" + Access
            + "\",\"refresh_token\":\"" + Refresh + "\"}}");

        Assert.Null(AccountSwitcher.ProviderFor(auth, "custom"));
    }

    [Fact]
    public void ARelayAccountSelectsTheRelayProvider()
        => Assert.Equal("custom", AccountSwitcher.ProviderFor(CodexAuth.ApiKey("sk-abcdefgh"), "custom"));

    /// <summary>A relay account with no recorded provider still needs one, or its key never reaches the relay.</summary>
    [Fact]
    public void ARelayAccountWithoutARecordedProviderGetsTheDefault()
        => Assert.Equal("custom", AccountSwitcher.ProviderFor(CodexAuth.ApiKey("sk-abcdefgh"), null));
}
