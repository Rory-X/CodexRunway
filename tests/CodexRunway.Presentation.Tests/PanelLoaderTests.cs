using CodexRunway.Core;
using CodexRunway.Presentation;
using Xunit;

namespace CodexRunway.Presentation.Tests;

/// <summary>
/// Loading the panel, including what happens when some accounts cannot be read.
/// </summary>
/// <remarks>
/// The failure modes matter more than the happy path here. "You have no accounts" and "your
/// accounts could not be read" look identical on screen but call for completely different
/// user actions, so they must not collapse into the same state.
/// </remarks>
public class PanelLoaderTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;
    private readonly CredentialStore _store;
    private readonly PanelLoader _loader;

    private const string Access = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Refresh = "rrrrrrrrrrrrrrrrrrrrrrrrrrrr";

    public PanelLoaderTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"panel-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(Path.Combine(_root, ".codex"), Path.Combine(_root, ".codex-runway"));
        _store = new CredentialStore(_paths);
        _loader = new PanelLoader(_store);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private void SaveOAuth(string id)
        => _store.SaveCredential(id, CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"plan_type\":\"plus\",\"tokens\":{"
            + "\"access_token\":\"" + Access + "\",\"refresh_token\":\"" + Refresh + "\","
            + "\"account_id\":\"" + id + "\"}}"));

    private void SaveKey(string id, string key = "sk-abcdefghijklmnop")
        => _store.SaveCredential(id, CodexAuth.ApiKey(key));

    private void Corrupt(string id)
    {
        var path = _paths.CredentialPath(id);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{ this is not json");
    }

    private PanelState Load(params StoredAccount[] accounts)
        => _loader.Load(accounts, null, PanelModuleNames.DefaultOrder, DateTimeOffset.UnixEpoch);

    private static StoredAccount Row(string id, bool reauth = false)
        => new(id, Alias: null, DisplayName: null, Email: null, RequiresReauth: reauth);

    [Fact]
    public void NoAccountsIsEmptyNotFailed()
    {
        var state = Load();

        Assert.Equal(PanelStatus.Empty, state.Status);
        Assert.False(state.HasAccounts);
    }

    [Fact]
    public void AccountsLoadIntoReadyState()
    {
        SaveOAuth("acct-1");
        SaveOAuth("acct-2");

        var state = Load(Row("acct-1"), Row("acct-2"));

        Assert.Equal(PanelStatus.Ready, state.Status);
        Assert.Equal(2, state.Accounts.Count);
    }

    /// <summary>
    /// When every account fails the state must say so. Reporting "empty" would send the user
    /// looking for accounts that exist but cannot be read.
    /// </summary>
    [Fact]
    public void EveryAccountUnreadableIsFailedNotEmpty()
    {
        Corrupt("acct-1");

        var state = Load(Row("acct-1"));

        Assert.Equal(PanelStatus.Failed, state.Status);
        Assert.Equal("accounts_unreadable", state.Problem);
    }

    /// <summary>
    /// One bad file must not blank the panel: the readable accounts still show, and the user
    /// is told that something was skipped.
    /// </summary>
    [Fact]
    public void OneUnreadableAccountKeepsTheRestVisible()
    {
        SaveOAuth("acct-1");
        Corrupt("acct-2");

        var state = Load(Row("acct-1"), Row("acct-2"));

        Assert.Equal(PanelStatus.Ready, state.Status);
        Assert.Single(state.Accounts);
        Assert.Equal("acct-1", state.Accounts[0].Id);
        Assert.Equal("accounts_partially_unreadable", state.StatusMessageCode);
    }

    [Fact]
    public void APartialFailureDoesNotClaimToBeClean()
    {
        SaveOAuth("acct-1");
        Corrupt("acct-2");

        var state = Load(Row("acct-1"), Row("acct-2"));

        Assert.NotNull(state.StatusMessageCode);
    }

    [Fact]
    public void AMissingCredentialCountsAsUnreadableRatherThanAbsent()
    {
        // Listed in the index but with no file on disk — the same user-visible situation as
        // a corrupt file, and equally worth reporting.
        var state = Load(Row("acct-missing"));

        Assert.Equal(PanelStatus.Failed, state.Status);
    }

    [Fact]
    public void TheActiveAccountIsMarked()
    {
        SaveOAuth("acct-1");
        SaveOAuth("acct-2");

        var state = _loader.Load(
            new[] { Row("acct-1"), Row("acct-2") },
            "acct-2",
            PanelModuleNames.DefaultOrder,
            DateTimeOffset.UnixEpoch);

        Assert.Equal("acct-2", state.ActiveAccount?.Id);
        Assert.Single(state.Accounts, a => a.IsActive);
    }

    [Fact]
    public void AnUnknownActiveIdMarksNothing()
    {
        SaveOAuth("acct-1");

        var state = _loader.Load(
            new[] { Row("acct-1") },
            "acct-does-not-exist",
            PanelModuleNames.DefaultOrder,
            DateTimeOffset.UnixEpoch);

        Assert.Null(state.ActiveAccount);
    }

    [Fact]
    public void AccountsNeedingReauthAreSurfacedSeparately()
    {
        SaveOAuth("acct-1");
        SaveOAuth("acct-2");

        var state = Load(Row("acct-1"), Row("acct-2", reauth: true));

        Assert.Single(state.AccountsNeedingAttention);
        Assert.Equal("acct-2", state.AccountsNeedingAttention[0].Id);
    }

    /// <summary>
    /// A relay key must never be selectable as a ChatGPT-quota account, so an unusable one
    /// stays out of the switchable list.
    /// </summary>
    [Fact]
    public void UnusableAccountsAreNotSelectable()
    {
        SaveOAuth("acct-1");
        _store.SaveCredential("acct-2", CodexAuth.Parse(
            "{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"sk-1\"}"), allowUnusable: true);

        var state = Load(Row("acct-1"), Row("acct-2"));

        Assert.Single(state.SelectableAccounts);
        Assert.Equal("acct-1", state.SelectableAccounts[0].Id);
    }

    [Fact]
    public void TheTimestampIsCarriedThrough()
    {
        SaveOAuth("acct-1");
        var when = DateTimeOffset.Parse("2026-10-11T12:00:00Z");

        var state = _loader.Load(
            new[] { Row("acct-1") }, null, PanelModuleNames.DefaultOrder, when);

        Assert.Equal(when, state.RefreshedAt);
    }

    /// <summary>Display order is the caller's, not the file system's.</summary>
    [Fact]
    public void TheGivenOrderIsPreserved()
    {
        SaveOAuth("acct-1");
        SaveOAuth("acct-2");
        SaveOAuth("acct-3");

        var state = Load(Row("acct-3"), Row("acct-1"), Row("acct-2"));

        Assert.Equal(new[] { "acct-3", "acct-1", "acct-2" }, state.Accounts.Select(a => a.Id));
    }
}
