using CodexRunway.Core;

namespace CodexRunway.Presentation;

/// <summary>
/// Finds accounts by looking at the accounts directory.
/// </summary>
/// <remarks>
/// <para>
/// The account index supplies names, plans and the user's order; the directory supplies the
/// credentials. Both are needed, and they routinely disagree: an index entry can exist with no
/// credential (an interrupted import) and a credential can exist with no entry (a file copied
/// in, or an interrupted write). The directory wins on which accounts exist, because a row
/// whose credential is missing cannot be switched to; the index wins on how they are
/// presented.
/// </para>
/// <para>
/// If the index cannot be read at all, discovery still succeeds from the directory alone. That
/// is deliberate: losing the names is a cosmetic problem, and refusing to start over it would
/// turn a cosmetic problem into an outage.
/// </para>
/// </remarks>
public sealed class AccountDiscovery
{
    private readonly RunwayPaths _paths;

    public AccountDiscovery(RunwayPaths paths) => _paths = paths;

    /// <summary>
    /// Raised when the index could not be read, so a caller can say so.
    /// </summary>
    /// <remarks>
    /// Reported rather than thrown: the panel is more useful with unnamed accounts than absent
    /// ones, but a user whose aliases vanished deserves to know why.
    /// </remarks>
    public bool IndexUnavailable { get; private set; }

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
        var ids = CredentialAccountIds();

        // The index supplies presentation metadata and the user's order.
        AccountIndex index;
        try
        {
            index = AccountIndexCodec.Load(_paths);
            IndexUnavailable = false;
        }
        catch (AccountIndexFormatException)
        {
            index = AccountIndex.Empty;
            IndexUnavailable = true;
        }

        var byId = index.Accounts.ToDictionary(a => a.Id, StringComparer.Ordinal);
        var rows = new List<StoredAccount>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        // First the index's order, so the user's arrangement is honoured.
        foreach (var account in index.OrderedForDisplay())
        {
            if (ids.Contains(account.Id) && seen.Add(account.Id))
            {
                rows.Add(From(account));
            }
        }

        // Then anything the index did not mention, so a copied-in credential is still usable.
        foreach (var id in ids.Where(id => !seen.Contains(id)).OrderBy(id => id, StringComparer.Ordinal))
        {
            rows.Add(new StoredAccount(id, null, null, null, RequiresReauth: false));
        }

        return rows;
    }

    private static StoredAccount From(ManagedAccount account) => new(
        Id: account.Id,
        Alias: account.Alias,
        DisplayName: account.ResolvedDisplayName,
        Email: account.Email,
        RequiresReauth: account.RequiresReauth,
        PlanType: account.PlanType,
        SortIndex: account.SortIndex);

    /// <summary>Ids that actually have a directory, and therefore possibly a credential.</summary>
    private HashSet<string> CredentialAccountIds()
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        if (!Directory.Exists(_paths.AccountsDirectory))
        {
            return ids;
        }

        foreach (var directory in Directory.GetDirectories(_paths.AccountsDirectory))
        {
            var id = Path.GetFileName(directory);
            if (id.Length > 0)
            {
                ids.Add(id);
            }
        }

        return ids;
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
