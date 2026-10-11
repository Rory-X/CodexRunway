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
    /// The index supplies the presentation metadata — the alias a user set, the plan, the
    /// workspace and the cached quota — while the directory supplies which accounts exist.
    /// </summary>
    /// <remarks>
    /// Both halves are needed and they routinely disagree, so this pins that a discovered row
    /// carries the index's data rather than a bare id.
    /// </remarks>
    [Fact]
    public void AStoredAccountCarriesTheIndexsMetadata()
    {
        SaveKey("api-1", "sk-abcdefghijklmnop");
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[]
            {
                new ManagedAccount
                {
                    Id = "api-1",
                    Alias = "工作号",
                    Email = "me@example.com",
                    PlanType = "plus",
                    AccountId = "ws-1",
                    WorkspaceName = "Team",
                    CachedQuota = new CachedQuota
                    {
                        Plan = "plus",
                        PrimaryUsedPercent = 12,
                        PrimaryWindowMinutes = 300,
                    },
                },
            },
        }, _paths);

        var row = Assert.Single(_discovery.Discover());

        Assert.Equal("工作号", row.Alias);
        Assert.Equal("plus", row.PlanType);
        Assert.Equal("ws-1", row.WorkspaceId);
        Assert.Equal("Team", row.WorkspaceName);
        Assert.NotNull(row.Quota);
        Assert.Equal(12, row.Quota!.PrimaryUsedPercent);
    }

    /// <summary>
    /// An index that cannot be read is reported rather than thrown, and the accounts are still
    /// discovered from the directory — losing the names is cosmetic, refusing to start is not.
    /// </summary>
    [Fact]
    public void AnUnreadableIndexIsReportedButDiscoveryStillSucceeds()
    {
        SaveKey("api-1", "sk-abcdefghijklmnop");
        File.WriteAllText(_paths.IndexPath, "{ not json");

        var rows = _discovery.Discover();

        Assert.True(_discovery.IndexUnavailable);
        var row = Assert.Single(rows);
        Assert.Equal("api-1", row.Id);
        // The metadata is gone with the index, so the presentation falls back to the id.
        Assert.Null(row.Alias);
    }

    /// <summary>
    /// A credential the index does not mention is still discovered, so a copied-in file is usable
    /// rather than invisible.
    /// </summary>
    [Fact]
    public void ACredentialMissingFromTheIndexIsStillDiscovered()
    {
        SaveKey("api-1", "sk-abcdefghijklmnop");
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[] { new ManagedAccount { Id = "some-other-account" } },
        }, _paths);

        var row = Assert.Single(_discovery.Discover());

        Assert.Equal("api-1", row.Id);
        // Nothing in the index described it, so no presentation metadata was invented.
        Assert.Null(row.Alias);
        Assert.Null(row.DisplayName);
        Assert.Null(row.Quota);
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
    /// A credential whose kind differs from the live file must not match, even when the field
    /// the comparison would otherwise use is equal.
    /// </summary>
    /// <remarks>
    /// Three earlier versions of this test passed with the kind check removed, each for a
    /// different reason, and the fixture is shaped to avoid all three:
    /// <list type="number">
    /// <item><description>
    /// the live credential had a real refresh token, so it differed from the API key's empty
    /// one and the comparison rejected it anyway;
    /// </description></item>
    /// <item><description>
    /// the live credential was a session one with an empty refresh token — equal on both sides,
    /// but the key comparison then rejected them on two different key strings;
    /// </description></item>
    /// <item><description>
    /// the same key was set on both sides, which cannot be built through
    /// <c>InstallOfficialAuth</c>: an OAuth-mode credential deliberately does not serialise its
    /// API key, so the value never reaches the file.
    /// </description></item>
    /// </list>
    /// This version writes the live file directly, bypassing serialisation, so the stored key
    /// and the live key are byte-identical and the kind check is the only thing left that can
    /// decide the outcome.
    /// </remarks>
    [Fact]
    public void AnApiKeyCannotMatchAnOauthLiveCredential()
    {
        const string shared = "sk-identicalonbothsides";

        SaveKey("api-a", shared);

        Directory.CreateDirectory(_paths.CodexHome);
        // Written by hand rather than through the store, because the store's encoder drops the
        // API key for an OAuth-mode credential — which is correct behaviour, and exactly what
        // makes this fixture impossible to build the normal way.
        File.WriteAllText(_paths.OfficialAuthPath,
            "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":\"" + shared + "\","
            + "\"tokens\":{\"access_token\":\"" + SessionAccessToken()
            + "\",\"refresh_token\":\"\"}}");

        // Preconditions. Both must hold or this test stops testing the guard: the two differ in
        // kind, and the comparison would reach the same string on both sides.
        Assert.True(_store.LoadCredential("api-a").IsApiKeyAuth);
        Assert.False(_store.LoadOfficialAuth().IsApiKeyAuth);
        Assert.Equal(shared, _store.LoadOfficialAuth().OpenAiApiKey);

        Assert.Null(_discovery.ActiveAccountId(_store));
    }

    /// <summary>
    /// The mirror direction: a live API key must not be attributed to a stored session
    /// credential that also has an empty refresh token.
    /// </summary>
    [Fact]
    public void AnOauthLiveCredentialCannotMatchAnApiKeyStoredAccount()
    {
        SaveOAuth("oauth-session", refresh: string.Empty);

        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuth(CodexAuth.ApiKey("sk-abcdefghijklmnop"));

        Assert.Null(_discovery.ActiveAccountId(_store));
    }

    /// <summary>
    /// A valid, unexpired access JWT.
    /// </summary>
    /// <remarks>
    /// It has to be a real JWT shape and not an expiry in the past: <c>InstallOfficialAuth</c>
    /// refuses a session credential whose access token is expired and which has no refresh
    /// token, so a placeholder string would make the install throw rather than exercise the
    /// behaviour under test.
    /// </remarks>
    private static string SessionAccessToken()
    {
        static string Segment(string text) => Convert.ToBase64String(
                System.Text.Encoding.UTF8.GetBytes(text))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

        var future = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();
        return $"{Segment("{\"alg\":\"none\"}")}.{Segment("{\"exp\":" + future + "}")}.sig";
    }

    /// <summary>
    /// A session-style credential: a valid access JWT and no refresh token, which is what
    /// <c>InstallOfficialAuth</c> accepts as usable.
    /// </summary>
    private static CodexAuth SessionOnlyOAuth()
        => CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\""
            + SessionAccessToken() + "\",\"refresh_token\":\"\"}}");

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
