using CodexRunway.Core;
using CodexRunway.Presentation;
using Xunit;

namespace CodexRunway.Presentation.Tests;

/// <summary>
/// Account discovery reads the directory rather than the index, so these tests pin what that
/// means: everything with a credential shows up, and the active account is found by comparing
/// the live credential against the stored copies.
/// </summary>
public class AccountDiscoveryTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;
    private readonly CredentialStore _store;
    private readonly AccountDiscovery _discovery;

    private const string Access = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Refresh = "rrrrrrrrrrrrrrrrrrrrrrrrrrrr";

    public AccountDiscoveryTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"disc-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(Path.Combine(_root, ".codex"), Path.Combine(_root, ".codex-runway"));
        _store = new CredentialStore(_paths);
        _discovery = new AccountDiscovery(_paths);
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

    [Fact]
    public void NoAccountsDirectoryDiscoversNothing()
        => Assert.Empty(_discovery.Discover());

    [Fact]
    public void AccountsAreDiscovered()
    {
        SaveOAuth("oauth-1");
        SaveKey("api-1");

        Assert.Equal(2, _discovery.Discover().Count);
    }

    /// <summary>
    /// A stable order matters: a list that reshuffles between refreshes looks like it changed
    /// when nothing did.
    /// </summary>
    [Fact]
    public void OrderIsStableAcrossCalls()
    {
        SaveOAuth("zeta");
        SaveOAuth("alpha");
        SaveOAuth("mid");

        Assert.Equal(
            _discovery.Discover().Select(a => a.Id),
            _discovery.Discover().Select(a => a.Id));
    }

    [Fact]
    public void OrderIsSortedById()
    {
        SaveOAuth("zeta");
        SaveOAuth("alpha");

        Assert.Equal(new[] { "alpha", "zeta" }, _discovery.Discover().Select(a => a.Id));
    }

    /// <summary>
    /// A directory with no readable credential is still listed, so the panel can report it
    /// instead of silently omitting a row the user expects to see.
    /// </summary>
    [Fact]
    public void ADirectoryWithoutACredentialIsStillListed()
    {
        Directory.CreateDirectory(_paths.AccountDirectory("empty-1"));

        var discovered = _discovery.Discover();

        Assert.Single(discovered);
        Assert.Equal("empty-1", discovered[0].Id);
    }

    // ---------------------------------------------------------------- active account

    [Fact]
    public void NoLiveCredentialMeansNothingIsActive()
        => Assert.Null(_discovery.ActiveAccountId(_store));

    [Fact]
    public void TheActiveAccountIsFoundByItsRefreshToken()
    {
        SaveOAuth("acct-a", "refresh-aaaaaaaaaaaaaaaaaaaa");
        SaveOAuth("acct-b", "refresh-bbbbbbbbbbbbbbbbbbbb");

        // The live file holds a copy of acct-b's credential.
        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuth(_store.LoadCredential("acct-b"));

        Assert.Equal("acct-b", _discovery.ActiveAccountId(_store));
    }

    [Fact]
    public void AnApiKeyAccountIsMatchedByItsKey()
    {
        SaveKey("api-a", "sk-aaaaaaaaaaaaaaaa");
        SaveKey("api-b", "sk-bbbbbbbbbbbbbbbb");

        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuth(_store.LoadCredential("api-b"));

        Assert.Equal("api-b", _discovery.ActiveAccountId(_store));
    }

    [Fact]
    public void ALiveCredentialMatchingNothingLeavesNothingActive()
    {
        SaveOAuth("acct-a", "refresh-aaaaaaaaaaaaaaaaaaaa");

        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuth(CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"" + Access
            + "\",\"refresh_token\":\"refresh-zzzzzzzzzzzzzzzzzzzz\"}}"));

        Assert.Null(_discovery.ActiveAccountId(_store));
    }

    /// <summary>
    /// A credential whose kind differs from the live file must not match, even if some field
    /// happens to be equal.
    /// </summary>
    [Fact]
    public void AnApiKeyCannotMatchAnOauthLiveCredential()
    {
        SaveKey("api-a", "sk-aaaaaaaaaaaaaaaa");

        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuth(CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"" + Access
            + "\",\"refresh_token\":\"" + Refresh + "\"}}"));

        Assert.Null(_discovery.ActiveAccountId(_store));
    }

    [Fact]
    public void ACorruptLiveCredentialIsTreatedAsNothingActive()
    {
        SaveOAuth("acct-a");
        Directory.CreateDirectory(_paths.CodexHome);
        File.WriteAllText(_paths.OfficialAuthPath, "{ corrupt");

        Assert.Null(_discovery.ActiveAccountId(_store));
    }

    /// <summary>An unreadable stored credential must not stop the scan or throw.</summary>
    [Fact]
    public void AnUnreadableStoredCredentialIsSkipped()
    {
        SaveOAuth("acct-a", "refresh-aaaaaaaaaaaaaaaaaaaa");
        Directory.CreateDirectory(_paths.AccountDirectory("broken"));
        File.WriteAllText(_paths.CredentialPath("broken"), "{ not json");

        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuth(_store.LoadCredential("acct-a"));

        Assert.Equal("acct-a", _discovery.ActiveAccountId(_store));
    }
}
