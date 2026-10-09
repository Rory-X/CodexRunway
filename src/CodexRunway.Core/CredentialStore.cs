using System.Text;
using System.Text.Json.Nodes;

namespace CodexRunway.Core;

/// <summary>
/// Reads and writes credentials: this tool's per-account copies and Codex's live
/// <c>auth.json</c>.
/// </summary>
/// <remarks>
/// <para>
/// Ported from the macOS app's <c>AccountStore</c> credential methods, minus the account
/// index (a separate module).
/// </para>
/// <para>
/// <b>Storage decision.</b> Credentials are written as plaintext JSON under
/// <c>%USERPROFILE%\.codex-runway\accounts\&lt;id&gt;\auth.json</c>, relying on the user
/// profile's ACL rather than per-file encryption. This is a deliberate product choice,
/// and it is also what makes the two platforms interoperable: the macOS build stores
/// plaintext under the same relative layout, so a directory copied either way is readable
/// by both. Encrypting with DPAPI on this side alone would silently break that.
/// </para>
/// </remarks>
public sealed class CredentialStore
{
    private readonly RunwayPaths _paths;

    public CredentialStore(RunwayPaths paths) => _paths = paths;

    /// <summary>Loads one account's stored credential.</summary>
    /// <exception cref="CredentialStoreException">Missing or unparseable.</exception>
    public CodexAuth LoadCredential(string accountId)
    {
        var path = _paths.CredentialPath(accountId);
        if (!File.Exists(path))
        {
            throw new CredentialStoreException(CredentialProblem.Missing, path);
        }

        try
        {
            return CodexAuth.Parse(File.ReadAllText(path, Encoding.UTF8));
        }
        catch (CodexAuthFormatException error)
        {
            throw new CredentialStoreException(CredentialProblem.Invalid, path, error);
        }
        catch (IOException error)
        {
            throw new CredentialStoreException(CredentialProblem.Unreadable, path, error);
        }
    }

    /// <summary>True when a stored credential exists and parses.</summary>
    public bool HasCredential(string accountId)
    {
        try
        {
            _ = LoadCredential(accountId);
            return true;
        }
        catch (CredentialStoreException)
        {
            return false;
        }
    }

    /// <summary>Stores one account's credential copy.</summary>
    /// <param name="allowUnusable">
    /// When true, permits saving an incomplete credential into the account library. Must
    /// stay false for Codex's own <c>auth.json</c>: installing a placeholder there signs
    /// the user out.
    /// </param>
    public void SaveCredential(string accountId, CodexAuth auth, bool allowUnusable = false)
    {
        if (!allowUnusable && auth.GetLoginUsability() == LoginUsability.InvalidTokens)
        {
            throw new CredentialStoreException(CredentialProblem.Unusable, _paths.CredentialPath(accountId));
        }

        var path = _paths.CredentialPath(accountId);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        CodexConfigProviderEditor.AtomicWrite(CodexAuth.Serialize(auth.ToOfficialJsonObject()), path);
    }

    /// <summary>Removes an account's stored credential and its directory.</summary>
    public void DeleteCredential(string accountId)
    {
        var directory = _paths.AccountDirectory(accountId);
        if (Directory.Exists(directory))
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    // ------------------------------------------------------------------ Codex's own auth.json

    /// <summary>Reads Codex's live credential.</summary>
    /// <exception cref="CredentialStoreException">Missing or unparseable.</exception>
    public CodexAuth LoadOfficialAuth()
    {
        var path = _paths.OfficialAuthPath;
        if (!File.Exists(path))
        {
            throw new CredentialStoreException(CredentialProblem.Missing, path);
        }

        try
        {
            return CodexAuth.Parse(File.ReadAllText(path, Encoding.UTF8));
        }
        catch (CodexAuthFormatException error)
        {
            throw new CredentialStoreException(CredentialProblem.Invalid, path, error);
        }
        catch (IOException error)
        {
            throw new CredentialStoreException(CredentialProblem.Unreadable, path, error);
        }
    }

    /// <summary>
    /// Installs a credential as Codex's live <c>auth.json</c> — the step that makes a
    /// switch take effect.
    /// </summary>
    /// <remarks>
    /// Merges into the file's existing keys so extras a given Codex build keeps there
    /// survive. Prefer <see cref="InstallOfficialAuthClean"/> when nothing from the
    /// previous account may remain.
    /// </remarks>
    public void InstallOfficialAuth(CodexAuth auth)
    {
        RequireUsable(auth, _paths.OfficialAuthPath);

        var existing = TryReadOfficialObject() ?? new JsonObject();
        var merged = auth.MergedInto(existing);
        CodexConfigProviderEditor.AtomicWrite(CodexAuth.Serialize(merged), _paths.OfficialAuthPath);
    }

    /// <summary>
    /// Installs a credential as Codex's live <c>auth.json</c>, discarding whatever the
    /// file held before.
    /// </summary>
    /// <remarks>
    /// The variant to prefer when the two accounts differ in kind. A merged write of an
    /// API key into a file still holding a ChatGPT session leaves both present: the file
    /// then carries a key <i>and</i> a working OAuth token for a different account, and
    /// anything that reads the token — a quota call, for instance — silently acts as that
    /// other account.
    /// </remarks>
    public void InstallOfficialAuthClean(CodexAuth auth)
    {
        RequireUsable(auth, _paths.OfficialAuthPath);
        CodexConfigProviderEditor.AtomicWrite(
            CodexAuth.Serialize(auth.ToOfficialJsonObject()), _paths.OfficialAuthPath);
    }

    /// <summary>Backs up Codex's live auth file next to this tool's data.</summary>
    /// <returns>The backup path, or null when there was nothing to back up.</returns>
    public string? BackupOfficialAuth()
    {
        if (!File.Exists(_paths.OfficialAuthPath))
        {
            return null;
        }

        var directory = Path.Combine(_paths.BackupDirectory, "auth");
        Directory.CreateDirectory(directory);
        var target = Path.Combine(
            directory,
            $"auth.json.{RunwayDates.FileStamp(DateTimeOffset.UtcNow)}.bak");
        File.Copy(_paths.OfficialAuthPath, target, overwrite: true);
        return target;
    }

    private static void RequireUsable(CodexAuth auth, string path)
    {
        if (auth.GetLoginUsability() == LoginUsability.InvalidTokens)
        {
            throw new CredentialStoreException(CredentialProblem.Unusable, path);
        }
    }

    private JsonObject? TryReadOfficialObject()
    {
        if (!File.Exists(_paths.OfficialAuthPath))
        {
            return null;
        }

        try
        {
            return JsonNode.Parse(File.ReadAllText(_paths.OfficialAuthPath, Encoding.UTF8)) as JsonObject;
        }
        catch (Exception error) when (error is IOException or System.Text.Json.JsonException)
        {
            // Unreadable or malformed is treated as absent: the caller is about to replace
            // it, and refusing here would strand a switch behind a corrupt file the user
            // cannot repair through this app.
            return null;
        }
    }
}

/// <summary>How a credential read or write failed.</summary>
public enum CredentialProblem
{
    Missing,
    Invalid,
    Unreadable,
    Unusable,
}

/// <summary>A credential could not be read or installed.</summary>
public sealed class CredentialStoreException : Exception
{
    public CredentialStoreException(CredentialProblem problem, string path, Exception? inner = null)
        : base($"credential {problem.ToString().ToLowerInvariant()}: {path}", inner)
    {
        Problem = problem;
        Path = path;
    }

    public CredentialProblem Problem { get; }

    /// <summary>The file involved. Never contains a secret — only its location.</summary>
    public string Path { get; }
}
