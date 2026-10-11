using CodexRunway.Core;

namespace CodexRunway.Presentation;

/// <summary>
/// Finds accounts by looking at the accounts directory.
/// </summary>
/// <remarks>
/// <para>
/// Discovery reads the directory rather than the account index, because the index is not
/// ported yet and an app that shows nothing until it is would be useless in the meantime.
/// The directory is the authoritative record of what credentials exist, so this is a correct
/// source rather than a stopgap — the index only adds presentation metadata (alias, note,
/// chosen order) on top.
/// </para>
/// <para>
/// What that means for the user: titles fall back to a masked key or a derived name until the
/// index lands, and a deliberately hidden account would still appear. Both are recorded here
/// rather than left for someone to discover from the screen.
/// </para>
/// </remarks>
public sealed class AccountDiscovery
{
    private readonly RunwayPaths _paths;

    public AccountDiscovery(RunwayPaths paths) => _paths = paths;

    /// <summary>
    /// Lists the accounts that have a credential on disk, ordered stably by id.
    /// </summary>
    /// <remarks>
    /// A directory without a readable credential is still listed, so the panel can report it
    /// as unreadable rather than silently omitting it — a missing row is the hardest kind of
    /// problem for a user to diagnose.
    /// </remarks>
    public IReadOnlyList<StoredAccount> Discover()
    {
        if (!Directory.Exists(_paths.AccountsDirectory))
        {
            return Array.Empty<StoredAccount>();
        }

        var accounts = new List<StoredAccount>();
        foreach (var directory in Directory.GetDirectories(_paths.AccountsDirectory))
        {
            var id = Path.GetFileName(directory);
            if (id.Length == 0)
            {
                continue;
            }

            accounts.Add(new StoredAccount(
                Id: id,
                Alias: null,
                DisplayName: null,
                Email: null,
                RequiresReauth: false));
        }

        // Stable order so the panel does not reshuffle between refreshes, which would make
        // the list look alive when nothing changed.
        return accounts.OrderBy(a => a.Id, StringComparer.Ordinal).ToArray();
    }

    /// <summary>
    /// Reads the id Codex itself is using, by matching the live credential against the stored
    /// ones.
    /// </summary>
    /// <remarks>
    /// There is no pointer file to read: the active account is whichever stored credential is
    /// byte-identical to the live <c>auth.json</c>. An absent or unreadable live file means
    /// nothing is active, which is a normal state before the first switch.
    /// </remarks>
    public string? ActiveAccountId(CredentialStore store)
    {
        CodexAuth live;
        try
        {
            live = store.LoadOfficialAuth();
        }
        catch (CredentialStoreException)
        {
            return null;
        }

        foreach (var account in Discover())
        {
            try
            {
                if (CredentialEquals(store.LoadCredential(account.Id), live))
                {
                    return account.Id;
                }
            }
            catch (CredentialStoreException)
            {
                // Unreadable stored credential cannot be the active one.
            }
        }

        return null;
    }

    /// <summary>
    /// Whether two credentials identify the same account.
    /// </summary>
    /// <remarks>
    /// Compared on the credential material rather than on the whole record, because
    /// <c>last_refresh</c> and other bookkeeping differ between a stored copy and the live
    /// file even when they are the same login. Never compares or logs a full secret beyond
    /// what is needed to decide equality.
    /// </remarks>
    private static bool CredentialEquals(CodexAuth left, CodexAuth right)
    {
        if (left.IsApiKeyAuth != right.IsApiKeyAuth)
        {
            return false;
        }

        if (left.IsApiKeyAuth)
        {
            return string.Equals(left.OpenAiApiKey, right.OpenAiApiKey, StringComparison.Ordinal);
        }

        // The refresh token is the stable identifier for an OAuth login: the access token
        // rotates, and the account id can be shared by a workspace.
        return string.Equals(
            left.Tokens.RefreshToken,
            right.Tokens.RefreshToken,
            StringComparison.Ordinal);
    }
}
