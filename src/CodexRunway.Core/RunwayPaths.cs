namespace CodexRunway.Core;

/// <summary>
/// Where Codex and this tool keep their files.
/// </summary>
/// <remarks>
/// <para>
/// Ported from the paths the macOS app uses, with the two root conventions swapped for
/// Windows ones. Nothing here is hard-coded to a drive or user name: every path is
/// derived from the user profile, so a roaming profile or a relocated home works.
/// </para>
/// <para>
/// <b>Cross-platform data sharing.</b> The two builds point at the same relative layout
/// inside each platform's user profile, so a directory copied between them is understood
/// by both. There is no platform-specific file name and no encrypted container — files
/// are plaintext JSON on both sides, which is what makes sharing possible at all.
/// </para>
/// </remarks>
public sealed record RunwayPaths
{
    public RunwayPaths(string codexHome, string appHome)
    {
        CodexHome = codexHome;
        AppHome = appHome;
    }

    /// <summary>Codex's own directory: config.toml, auth.json, sessions.</summary>
    public string CodexHome { get; init; }

    /// <summary>This tool's directory. Never written into by Codex.</summary>
    public string AppHome { get; init; }

    public string ConfigPath => Path.Combine(CodexHome, "config.toml");

    /// <summary>The live credential Codex reads. Swapping this is how a switch works.</summary>
    public string OfficialAuthPath => Path.Combine(CodexHome, "auth.json");

    public string AccountsDirectory => Path.Combine(AppHome, "accounts");

    public string IndexPath => Path.Combine(AccountsDirectory, "index.json");

    /// <summary>
    /// One account's directory inside <see cref="AccountsDirectory"/>.
    /// </summary>
    /// <remarks>
    /// The id is sanitised before use. Account ids are hashes in practice, but they are
    /// read from a file another tool can write, and the value goes straight into a path —
    /// an unescaped <c>../..</c> would place a credential outside the accounts directory,
    /// and on Windows a <c>\</c> would do the same. Folding to a safe alphabet closes
    /// both, and both platforms fold identically so the directory a given account lands
    /// in is the same either side.
    /// </remarks>
    public string AccountDirectory(string accountId)
        => Path.Combine(AccountsDirectory, PathSanitizer.Sanitize(accountId));

    public string CredentialPath(string accountId)
        => Path.Combine(AccountDirectory(accountId), "auth.json");

    public string BackupDirectory => Path.Combine(AppHome, "config-backups");

    public string RelayConfigDirectory => Path.Combine(AppHome, "relay-configs");

    public string RelayConfigPath(string accountId)
        => Path.Combine(RelayConfigDirectory, $"{PathSanitizer.Sanitize(accountId)}.json");

    /// <summary>
    /// The defaults for the current user.
    /// </summary>
    /// <remarks>
    /// <c>USERPROFILE</c> is used rather than <c>SpecialFolder.ApplicationData</c>: the
    /// latter resolves to <c>%APPDATA%</c> (Roaming), whereas Codex follows the Unix
    /// convention of a dot-directory directly under the user profile. The two are
    /// different directories on Windows, and picking the wrong one reads a config that is
    /// never the one in use.
    /// </remarks>
    public static RunwayPaths Default()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrEmpty(profile))
        {
            profile = Environment.GetEnvironmentVariable("USERPROFILE")
                ?? Environment.GetEnvironmentVariable("HOME")
                ?? Directory.GetCurrentDirectory();
        }

        return new RunwayPaths(
            Path.Combine(profile, ".codex"),
            Path.Combine(profile, ".codex-runway"));
    }

    /// <summary>
    /// The layout for this machine, honouring <c>CODEX_HOME</c>.
    /// </summary>
    /// <remarks>
    /// Codex itself honours <c>CODEX_HOME</c>, so a user who relocated their Codex
    /// directory gets this tool looking in the same place instead of at a stale default.
    /// </remarks>
    public static RunwayPaths FromEnvironment()
    {
        var defaults = Default();
        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        return string.IsNullOrWhiteSpace(codexHome)
            ? defaults
            : defaults with { CodexHome = codexHome };
    }

    /// <summary>
    /// Creates the app's own directory tree.
    /// </summary>
    /// <remarks>
    /// Deliberately does not create <see cref="CodexHome"/>: that directory belongs to
    /// Codex, and creating it here would make the app look installed and configured when
    /// it is not.
    /// </remarks>
    public void EnsureAppDirectories()
    {
        Directory.CreateDirectory(AppHome);
        Directory.CreateDirectory(AccountsDirectory);
        Directory.CreateDirectory(BackupDirectory);
        Directory.CreateDirectory(RelayConfigDirectory);
    }
}

/// <summary>Keeps an account id from escaping the directory it names.</summary>
internal static class PathSanitizer
{
    /// <summary>
    /// Reduces an id to a safe directory name, matching the macOS build's rule.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Interoperability.</b> The two builds share one <c>accounts/</c> directory, so the
    /// fold must be identical or the same account lands in two different folders and one
    /// platform cannot find the other's credential. The macOS rule is
    /// <c>CharacterSet.alphanumerics ∪ "-_."</c>, with everything else replaced by an
    /// underscore and an empty result becoming <c>account</c>. That means dots and
    /// non-ASCII letters are <i>kept</i>: <c>café</c> stays <c>café</c>, <c>a.b</c> stays
    /// <c>a.b</c>, and <c>用户</c> stays <c>用户</c>. An earlier version of this folded to
    /// ASCII and dropped dots, which silently produced a different directory.
    /// </para>
    /// <para>
    /// <b>Departure from macOS.</b> The macOS rule returns <c>..</c> unchanged, which its
    /// own <c>appendingPathComponent</c> then resolves to the parent directory — a genuine
    /// escape, though unreachable in practice because real ids are hashes like
    /// <c>oauth-4f8dc043cb2f3bdc</c>. Those two names are folded here, because matching a
    /// latent traversal bug is not worth the interoperability it would buy: no real
    /// account id is <c>.</c> or <c>..</c>, so both platforms still agree on every id that
    /// can actually occur.
    /// </para>
    /// </remarks>
    public static string Sanitize(string value)
    {
        var chars = value.Select(c =>
            char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_').ToArray();
        var cleaned = new string(chars);

        if (cleaned.Length == 0)
        {
            return "account";
        }

        // The one deliberate divergence: these resolve to a parent or current directory.
        return cleaned is "." or ".." ? "__" : cleaned;
    }
}
