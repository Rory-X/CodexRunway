using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Path resolution and credential storage.
/// </summary>
/// <remarks>
/// The paths are the part of the port most likely to be silently wrong: a wrong root does
/// not throw, it just reads a config that is never the one in use. These tests pin the
/// layout, and the storage tests pin the plaintext-under-the-user-profile decision.
/// </remarks>
public class CredentialStoreTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;
    private readonly CredentialStore _store;

    public CredentialStoreTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"runway-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(
            Path.Combine(_root, ".codex"),
            Path.Combine(_root, ".codex-runway"));
        _store = new CredentialStore(_paths);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private const string LongToken = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string LongRefresh = "rrrrrrrrrrrrrrrrrrrrrrrrrrrr";

    private static CodexAuth ChatGpt(string accountId = "acct-1") => CodexAuth.Parse(
        "{\"auth_mode\":\"chatgpt\",\"tokens\":{"
        + "\"access_token\":\"" + LongToken + "\","
        + "\"refresh_token\":\"" + LongRefresh + "\","
        + "\"account_id\":\"" + accountId + "\"}}");

    // ------------------------------------------------------------------ layout

    [Fact]
    public void TheLayoutMatchesTheCodexConvention()
    {
        Assert.Equal(Path.Combine(_root, ".codex", "config.toml"), _paths.ConfigPath);
        Assert.Equal(Path.Combine(_root, ".codex", "auth.json"), _paths.OfficialAuthPath);
        Assert.Equal(Path.Combine(_root, ".codex-runway", "accounts"),
            _paths.AccountsDirectory.TrimEnd(Path.DirectorySeparatorChar));
        Assert.Equal(
            Path.Combine(_root, ".codex-runway", "accounts", "acct-1", "auth.json"),
            _paths.CredentialPath("acct-1"));
    }

    /// <summary>
    /// Codex follows the Unix dot-directory convention rather than the Windows Roaming
    /// convention, so the app must look under the user profile — a different directory
    /// from %APPDATA%.
    /// </summary>
    [Fact]
    public void TheDefaultCodexHomeIsUnderTheUserProfileNotAppData()
    {
        var defaults = RunwayPaths.Default();
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        Assert.StartsWith(profile, defaults.CodexHome, StringComparison.Ordinal);
        Assert.Equal(Path.Combine(profile, ".codex"), defaults.CodexHome);

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (!string.IsNullOrEmpty(appData))
        {
            Assert.DoesNotContain(appData, defaults.CodexHome, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void AConfigPathIsNotCreatedByMerelyResolvingPaths()
    {
        _paths.EnsureAppDirectories();

        // Codex's own directory is Codex's business; creating it would make the app look
        // installed when it is not.
        Assert.False(Directory.Exists(_paths.CodexHome));
        Assert.True(Directory.Exists(_paths.AccountsDirectory));
        Assert.True(Directory.Exists(_paths.BackupDirectory));
    }

    [Fact]
    public void AnAccountIdCannotEscapeTheAccountsDirectory()
    {
        // Dots are preserved to match the macOS fold, so the assertion is containment
        // rather than "no dots": what matters is that the resolved path cannot leave.
        foreach (var hostile in new[] { "../../../evil", @"..\..\evil", "..", "." })
        {
            var resolved = Path.GetFullPath(_paths.CredentialPath(hostile));
            Assert.StartsWith(
                _paths.AccountsDirectory + Path.DirectorySeparatorChar,
                resolved,
                StringComparison.Ordinal);
        }
    }

    [Fact]
    public void ACraftedProviderNameCannotTraverseEither()
    {
        foreach (var hostile in new[] { "..\\..\\evil", "../..", ".." })
        {
            var resolved = Path.GetFullPath(_paths.RelayConfigPath(hostile));
            Assert.StartsWith(
                _paths.RelayConfigDirectory + Path.DirectorySeparatorChar,
                resolved,
                StringComparison.Ordinal);
        }
    }

    /// <summary>
    /// The fold must match the macOS build's rule exactly, because the two share one
    /// accounts directory: a different fold means the same account lands in two folders.
    /// Every expectation here was produced by running the macOS implementation.
    /// </summary>
    [Theory]
    [InlineData("acct-1", "acct-1")]
    [InlineData("a.b", "a.b")]
    [InlineData("café", "café")]
    [InlineData("用户", "用户")]
    [InlineData("1e2.5", "1e2.5")]
    [InlineData("A_b-9.ز", "A_b-9.ز")]
    [InlineData("a/b", "a_b")]
    [InlineData("a\\b", "a_b")]
    [InlineData("oauth-4f8dc043cb2f3bdc", "oauth-4f8dc043cb2f3bdc")]
    public void SanitizingMatchesTheMacOsRule(string input, string expected)
        => Assert.Equal(expected, PathSanitizer.Sanitize(input));

    /// <summary>
    /// The two names that differ from macOS on purpose: macOS returns them unchanged and
    /// its own path append then resolves the parent directory.
    /// </summary>
    [Theory]
    [InlineData(".")]
    [InlineData("..")]
    public void ARelativeDirectoryNameIsFoldedRatherThanResolved(string input)
    {
        var folded = PathSanitizer.Sanitize(input);

        Assert.NotEqual(input, folded);
        Assert.Equal("__", folded);
    }

    [Fact]
    public void AnEmptyIdBecomesTheMacOsPlaceholder()
        => Assert.Equal("account", PathSanitizer.Sanitize(string.Empty));

    // ------------------------------------------------------------------ credential storage

    [Fact]
    public void StoresAndLoadsACredential()
    {
        _store.SaveCredential("acct-1", ChatGpt());

        Assert.True(_store.HasCredential("acct-1"));
        var loaded = _store.LoadCredential("acct-1");
        Assert.Equal("acct-1", loaded.Tokens.AccountId);
        Assert.Equal(LongToken, loaded.Tokens.AccessToken);
    }

    /// <summary>
    /// The storage decision: credentials sit as plaintext JSON beside the app's data, so a
    /// file copied to another machine is directly readable.
    /// </summary>
    [Fact]
    public void CredentialsAreStoredAsReadableJson()
    {
        _store.SaveCredential("acct-1", ChatGpt());

        var text = File.ReadAllText(_paths.CredentialPath("acct-1"));
        Assert.Contains("\"access_token\"", text, StringComparison.Ordinal);

        // And nothing else is needed to read it back.
        Assert.Equal(LongToken, CodexAuth.Parse(text).Tokens.AccessToken);
    }

    [Fact]
    public void AStoredCredentialRoundTripsThroughTheCodec()
    {
        var original = ChatGpt("acct-7");
        _store.SaveCredential("acct-7", original);

        var loaded = _store.LoadCredential("acct-7");
        Assert.Equal(original.Tokens.AccessToken, loaded.Tokens.AccessToken);
        Assert.Equal(original.Tokens.RefreshToken, loaded.Tokens.RefreshToken);
        Assert.Equal(original.AuthMode, loaded.AuthMode);
    }

    [Fact]
    public void AnUnusableCredentialIsRefusedForTheAccountLibrary()
    {
        var placeholder = CodexAuth.Parse("""{"auth_mode":"apikey","OPENAI_API_KEY":"sk-1234"}""");

        var error = Assert.Throws<CredentialStoreException>(
            () => _store.SaveCredential("acct-1", placeholder));

        Assert.Equal(CredentialProblem.Unusable, error.Problem);
    }

    [Fact]
    public void AnUnusableCredentialIsPermittedWhenExplicitlyAllowed()
    {
        // The account library is allowed to hold an incomplete credential; Codex's own
        // auth.json is not.
        var placeholder = CodexAuth.Parse("""{"auth_mode":"apikey","OPENAI_API_KEY":"sk-1234"}""");
        _store.SaveCredential("acct-1", placeholder, allowUnusable: true);

        Assert.True(_store.HasCredential("acct-1"));
    }

    [Fact]
    public void LoadingAMissingCredentialReportsMissing()
    {
        var error = Assert.Throws<CredentialStoreException>(() => _store.LoadCredential("nope"));
        Assert.Equal(CredentialProblem.Missing, error.Problem);
    }

    [Fact]
    public void LoadingACorruptCredentialReportsInvalid()
    {
        var path = _paths.CredentialPath("acct-1");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{ not json");

        var error = Assert.Throws<CredentialStoreException>(() => _store.LoadCredential("acct-1"));
        Assert.Equal(CredentialProblem.Invalid, error.Problem);
    }

    [Fact]
    public void DeletingRemovesTheWholeAccountDirectory()
    {
        _store.SaveCredential("acct-1", ChatGpt());
        _store.DeleteCredential("acct-1");

        Assert.False(Directory.Exists(_paths.AccountDirectory("acct-1")));
    }

    [Fact]
    public void DeletingSomethingAbsentIsHarmless()
        => _store.DeleteCredential("never-existed");

    // ------------------------------------------------------------------ Codex's own auth.json

    [Fact]
    public void InstallsAndReadsBackCodexOwnAuthFile()
    {
        Directory.CreateDirectory(_paths.CodexHome);

        _store.InstallOfficialAuth(ChatGpt("acct-official"));

        Assert.Equal("acct-official", _store.LoadOfficialAuth().Tokens.AccountId);
    }

    [Fact]
    public void AMergedInstallKeepsForeignKeysTheBuildStored()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        File.WriteAllText(_paths.OfficialAuthPath, """
        {"auth_mode":"chatgpt","build_extra":"keep-me"}
        """);

        _store.InstallOfficialAuth(ChatGpt());

        var text = File.ReadAllText(_paths.OfficialAuthPath);
        Assert.Contains("keep-me", text, StringComparison.Ordinal);
    }

    /// <summary>
    /// The trap a merged install creates, and the reason the clean variant exists.
    /// </summary>
    [Fact]
    public void AMergedInstallOfAKeyLeavesThePreviousAccountsSessionInPlace()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuthClean(ChatGpt("previous-account"));

        _store.InstallOfficialAuth(CodexAuth.ApiKey("sk-abcdefgh"));

        var text = File.ReadAllText(_paths.OfficialAuthPath);
        // Both a key and a live session for a different account are now in the file.
        Assert.Contains("sk-abcdefgh", text, StringComparison.Ordinal);
        Assert.Contains(LongToken, text, StringComparison.Ordinal);
    }

    [Fact]
    public void ACleanInstallLeavesNothingFromThePreviousAccount()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuthClean(ChatGpt("previous-account"));

        _store.InstallOfficialAuthClean(CodexAuth.ApiKey("sk-abcdefgh"));

        var text = File.ReadAllText(_paths.OfficialAuthPath);
        Assert.Contains("sk-abcdefgh", text, StringComparison.Ordinal);
        Assert.DoesNotContain(LongToken, text, StringComparison.Ordinal);
        Assert.DoesNotContain("previous-account", text, StringComparison.Ordinal);
    }

    [Fact]
    public void InstallingUnusableCredentialIntoCodexIsRefused()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        var placeholder = CodexAuth.Parse("""{"auth_mode":"apikey","OPENAI_API_KEY":"sk-1234"}""");

        var error = Assert.Throws<CredentialStoreException>(
            () => _store.InstallOfficialAuth(placeholder));

        Assert.Equal(CredentialProblem.Unusable, error.Problem);
        Assert.False(File.Exists(_paths.OfficialAuthPath));
    }

    [Fact]
    public void AMalformedAuthFileDoesNotBlockAReplacement()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        File.WriteAllText(_paths.OfficialAuthPath, "{ corrupt");

        // Refusing here would strand the switch behind a file the user cannot repair.
        _store.InstallOfficialAuth(ChatGpt("recovered"));

        Assert.Equal("recovered", _store.LoadOfficialAuth().Tokens.AccountId);
    }

    [Fact]
    public void BackingUpTheAuthFileProducesACopy()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuthClean(ChatGpt());

        var backup = _store.BackupOfficialAuth();

        Assert.NotNull(backup);
        Assert.True(File.Exists(backup));
        Assert.Equal(
            File.ReadAllText(_paths.OfficialAuthPath),
            File.ReadAllText(backup!));
    }

    [Fact]
    public void BackingUpWithNothingToBackUpReturnsNull()
        => Assert.Null(_store.BackupOfficialAuth());

    [Fact]
    public void AnOfficialAuthWriteLeavesNoTemporaryFiles()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        _store.InstallOfficialAuthClean(ChatGpt());

        Assert.Single(Directory.GetFiles(_paths.CodexHome, "*.json"));
    }
}
