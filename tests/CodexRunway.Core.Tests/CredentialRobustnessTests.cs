using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// How the port behaves on malformed or hostile input.
/// </summary>
/// <remarks>
/// <c>auth.json</c> is a foreign file: Codex itself, the desktop app, and other switcher
/// tools all write it, and a user can edit it by hand. These cases pin the failure
/// behaviour, because the danger here is not a wrong answer but an undeclared exception
/// escaping a query that should merely have reported "no usable credential".
/// </remarks>
public class CredentialRobustnessTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;
    private readonly CredentialStore _store;

    public CredentialRobustnessTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"robust-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(Path.Combine(_root, ".codex"), Path.Combine(_root, ".codex-runway"));
        _store = new CredentialStore(_paths);
        Directory.CreateDirectory(_paths.CodexHome);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            // A file made unreadable by a test must be handed back before the delete, but
            // Unix permission bits do not exist on Windows.
            if (!OperatingSystem.IsWindows())
            {
                try
                {
                    foreach (var file in Directory.GetFiles(_root, "*", SearchOption.AllDirectories))
                    {
                        File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    // Best effort; the temp directory is disposable.
                }
            }

            Directory.Delete(_root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private static string Jwt(long exp)
    {
        static string Segment(string text) => Convert.ToBase64String(
                System.Text.Encoding.UTF8.GetBytes(text))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

        return $"{Segment("{\"alg\":\"none\"}")}.{Segment("{\"exp\":" + exp + "}")}.sig";
    }

    private static string RawJwt(string payloadJson)
    {
        static string Segment(string text) => Convert.ToBase64String(
                System.Text.Encoding.UTF8.GetBytes(text))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

        return $"{Segment("{\"alg\":\"none\"}")}.{Segment(payloadJson)}.sig";
    }

    // ---------------------------------------------------------------- duplicate keys

    /// <summary>
    /// <c>JsonNode</c> rejects a duplicate key with <c>ArgumentException</c>, which is not a
    /// <c>JsonException</c> — so it used to escape every caller's catch and turn a boolean
    /// "is there a credential?" query into an unhandled crash.
    /// </summary>
    [Fact]
    public void ADuplicateKeyIsReportedAsAFormatError()
    {
        const string duplicated =
            "{\"auth_mode\":\"chatgpt\",\"auth_mode\":\"apikey\","
            + "\"OPENAI_API_KEY\":\"sk-12345678\"}";

        Assert.Throws<CodexAuthFormatException>(() => CodexAuth.Parse(duplicated));
    }

    [Fact]
    public void AFileWithADuplicateKeyReportsNoUsableCredentialRatherThanThrowing()
    {
        var path = _paths.CredentialPath("acct-1");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path,
            "{\"auth_mode\":\"chatgpt\",\"auth_mode\":\"apikey\","
            + "\"OPENAI_API_KEY\":\"sk-12345678\"}");

        Assert.False(_store.HasCredential("acct-1"));
    }

    // ---------------------------------------------------------------- permissions

    /// <summary>
    /// <c>UnauthorizedAccessException</c> is not an <c>IOException</c>, so catching only the
    /// latter let a permissions problem escape and left the Unreadable problem unreachable.
    /// </summary>
    [Fact]
    public void AnUnreadableCredentialIsReportedAsUnreadable()
    {
        // Root bypasses the permission bits, and Windows has none to set, so there is
        // nothing to assert on either. Skipping is honest here; asserting would be a lie.
        if (OperatingSystem.IsWindows() || Environment.UserName == "root")
        {
            return;
        }

        var path = _paths.CredentialPath("acct-1");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path,
            "{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"sk-12345678\"}");
        File.SetUnixFileMode(path, UnixFileMode.None);

        var error = Assert.Throws<CredentialStoreException>(() => _store.LoadCredential("acct-1"));
        Assert.Equal(CredentialProblem.Unreadable, error.Problem);

        // And a boolean query stays a boolean query.
        Assert.False(_store.HasCredential("acct-1"));
    }

    // ---------------------------------------------------------------- expiry

    /// <summary>
    /// An absurd expiry must not throw. <c>DateTimeOffset</c> cannot represent 1e300, so
    /// building one threw <c>ArgumentOutOfRangeException</c> out of <c>GetLoginUsability</c>;
    /// the macOS implementation simply compares and reports "not expired".
    /// </summary>
    [Fact]
    public void AnAbsurdExpiryIsNotExpired()
    {
        var jwt = RawJwt("{\"exp\":1e300}");

        Assert.False(TokenInspector.IsExpired(jwt));
    }

    /// <summary>
    /// A numeric string is not a number. The macOS decoder reads <c>exp</c> with
    /// <c>as? Double</c>, which fails for a string and falls through to "expired";
    /// accepting it here would report the opposite verdict for the same token.
    /// </summary>
    [Fact]
    public void ANumericStringExpiryIsTreatedAsExpired()
    {
        var jwt = RawJwt("{\"exp\":\"9999999999\"}");

        Assert.True(TokenInspector.IsExpired(jwt));
    }

    [Fact]
    public void ANonNumericExpiryIsTreatedAsExpired()
    {
        Assert.True(TokenInspector.IsExpired(RawJwt("{\"exp\":true}")));
        Assert.True(TokenInspector.IsExpired(RawJwt("{\"exp\":null}")));
        Assert.True(TokenInspector.IsExpired(RawJwt("{}")));
    }

    [Fact]
    public void AReasonableFutureExpiryIsNotExpired()
    {
        var soon = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();

        Assert.False(TokenInspector.IsExpired(Jwt(soon)));
    }

    // ---------------------------------------------------------------- redaction

    /// <summary>
    /// A record's generated <c>ToString</c> prints every property. Leaving the nested token
    /// record unredacted defeated <see cref="CodexAuth"/>'s own redaction, so interpolating
    /// <c>auth.Tokens</c> leaked the whole credential.
    /// </summary>
    [Fact]
    public void TokensToStringRedactsEverySecret()
    {
        var tokens = new CodexTokens
        {
            AccessToken = "SECRET-ACCESS",
            RefreshToken = "SECRET-REFRESH",
            IdToken = "SECRET-ID",
            AccountId = "acct-1",
        };

        var text = tokens.ToString();

        Assert.DoesNotContain("SECRET", text, StringComparison.Ordinal);
        Assert.Contains("<redacted>", text, StringComparison.Ordinal);
        // The account id is not a secret and stays legible for diagnostics.
        Assert.Contains("acct-1", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AuthToStringRedactsItsNestedTokens()
    {
        var auth = CodexAuth.Parse(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"SECRET-ACCESS\","
            + "\"refresh_token\":\"SECRET-REFRESH\"}}");

        var text = auth.ToString();

        Assert.DoesNotContain("SECRET", text, StringComparison.Ordinal);
    }
}
