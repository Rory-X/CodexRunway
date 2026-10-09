using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Locks in the encoding guarantees that let one credential file be shared between the
/// macOS build and this one without either rewriting it.
/// </summary>
/// <remarks>
/// These are interoperability facts, not style preferences. The macOS build writes
/// credentials with <c>JSONSerialization</c> using <c>[.prettyPrinted, .sortedKeys]</c>, and
/// each of the three details below was established by reading a real file rather than
/// assumed — so they are pinned here, where a future refactor will trip over them instead
/// of silently breaking sharing.
/// </remarks>
public class InteropEncodingTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;
    private readonly CredentialStore _store;

    public InteropEncodingTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"interop-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(Path.Combine(_root, ".codex"), Path.Combine(_root, ".codex-runway"));
        _store = new CredentialStore(_paths);
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

    private string Write(string json)
    {
        File.WriteAllText(_paths.OfficialAuthPath, json);
        _store.InstallOfficialAuthClean(CodexAuth.Parse(json));
        return File.ReadAllText(_paths.OfficialAuthPath);
    }

    private const string Token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Refresh = "rrrrrrrrrrrrrrrrrrrrrrrrrrrr";

    /// <summary>Apple separates key and value with spaces on both sides of the colon.</summary>
    [Fact]
    public void KeysAreSeparatedTheWayAppleWritesThem()
    {
        var rewritten = Write("""
        {
          "auth_mode" : "chatgpt",
          "tokens" : {
            "access_token" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "refresh_token" : "rrrrrrrrrrrrrrrrrrrrrrrrrrrr"
          }
        }
        """);

        Assert.Contains("\"auth_mode\" : ", rewritten, StringComparison.Ordinal);
        // The .NET default would be no space before the colon.
        Assert.DoesNotContain("\"auth_mode\": ", rewritten, StringComparison.Ordinal);
    }

    /// <summary>
    /// The sort is recursive. Nested keys are checked through a ChatGPT credential,
    /// because an API-key one deliberately omits <c>tokens</c> altogether.
    /// </summary>
    [Fact]
    public void NestedKeysAreSortedToo()
    {
        var rewritten = Write("""
        {
          "auth_mode" : "chatgpt",
          "tokens" : {
            "refresh_token" : "rrrrrrrrrrrrrrrrrrrrrrrrrrrr",
            "access_token" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "account_id" : "zzz"
          }
        }
        """);

        // Observed order in a real file: access_token, account_id, refresh_token.
        var access = rewritten.IndexOf("access_token", StringComparison.Ordinal);
        var accountId = rewritten.IndexOf("account_id", StringComparison.Ordinal);
        var refresh = rewritten.IndexOf("refresh_token", StringComparison.Ordinal);
        Assert.True(access < accountId && accountId < refresh, "nested keys must be sorted too");
    }

    /// <summary>
    /// The top-level sort is case-<i>insensitive</i>: a real API-key file lists
    /// <c>auth_mode</c> before <c>OPENAI_API_KEY</c>, which an ordinal sort would reverse.
    /// </summary>
    [Fact]
    public void TopLevelKeysSortCaseInsensitively()
    {
        var rewritten = Write("""
        {
          "OPENAI_API_KEY" : "sk-abcdefgh",
          "auth_mode" : "apikey"
        }
        """);

        var authMode = rewritten.IndexOf("auth_mode", StringComparison.Ordinal);
        var apiKey = rewritten.IndexOf("OPENAI_API_KEY", StringComparison.Ordinal);
        Assert.True(authMode < apiKey, "a case-sensitive sort would put the capital key first");
    }

    /// <summary>
    /// An API-key credential carries no <c>tokens</c> block, so an empty one can never
    /// blank out a ChatGPT session.
    /// </summary>
    [Fact]
    public void AnApiKeyCredentialOmitsTheTokensBlockEntirely()
    {
        var rewritten = Write("""
        {
          "auth_mode" : "apikey",
          "OPENAI_API_KEY" : "sk-abcdefgh"
        }
        """);

        Assert.DoesNotContain("tokens", rewritten, StringComparison.Ordinal);
    }

    /// <summary>
    /// A credential written by the macOS build must survive a Windows rewrite unchanged,
    /// which is what makes a shared file safe to open on both sides.
    /// </summary>
    [Fact]
    public void AMacOsShapedFileIsRewrittenByteIdentically()
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
        File.WriteAllText(_paths.OfficialAuthPath, macOSShaped);

        _store.InstallOfficialAuthClean(CodexAuth.Parse(macOSShaped));

        Assert.Equal(macOSShaped, File.ReadAllText(_paths.OfficialAuthPath));
    }

    [Fact]
    public void TheApiKeyModeKeyOrderMatchesAMacOSFile()
    {
        const string macOSShaped = """
        {
          "auth_mode" : "apikey",
          "OPENAI_API_KEY" : "sk-abcdefgh"
        }
        """;
        File.WriteAllText(_paths.OfficialAuthPath, macOSShaped);

        _store.InstallOfficialAuthClean(CodexAuth.Parse(macOSShaped));

        Assert.Equal(macOSShaped, File.ReadAllText(_paths.OfficialAuthPath));
    }
}
