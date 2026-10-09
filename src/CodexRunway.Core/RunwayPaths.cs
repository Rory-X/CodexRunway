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
    /// Reduces an id to a safe file name.
    /// </summary>
    /// <remarks>
    /// Account ids are hashes in practice, but they arrive from a file another tool can
    /// write, so a crafted id must not traverse out of the accounts directory. The
    /// alphabet is deliberately the same on both platforms — Windows additionally rejects
    /// a trailing dot or space, which is why those are folded rather than preserved.
    /// </remarks>
    public static string Sanitize(string value)
    {
        var chars = value.Select(c =>
            char.IsAsciiLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray();
        var result = new string(chars).TrimEnd('.', ' ');
        return result.Length == 0 ? "_" : result;
    }
}
