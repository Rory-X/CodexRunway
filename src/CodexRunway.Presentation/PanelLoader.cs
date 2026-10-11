using CodexRunway.Core;

namespace CodexRunway.Presentation;

/// <summary>
/// A cached quota reading, as the index stores it.
/// </summary>
/// <remarks>
/// Kept separate from <c>CodexRunway.Core</c>'s model so the presentation layer can be tested
/// without a file, and so a caller with quota from somewhere else — a live fetch, a fixture —
/// can supply it too.
/// </remarks>
public sealed record CachedQuotaView(
    string? Plan,
    int? PrimaryUsedPercent,
    int? PrimaryWindowMinutes,
    DateTimeOffset? PrimaryResetsAt,
    int? SecondaryUsedPercent,
    int? SecondaryWindowMinutes,
    DateTimeOffset? SecondaryResetsAt,
    DateTimeOffset? UpdatedAt)
{
    /// <summary>Builds the display form against a given moment.</summary>
    public AccountQuotaView ToView(DateTimeOffset now) => AccountQuotaView.From(
        Plan,
        PrimaryUsedPercent,
        PrimaryWindowMinutes,
        PrimaryResetsAt,
        SecondaryUsedPercent,
        SecondaryWindowMinutes,
        SecondaryResetsAt,
        UpdatedAt,
        now);
}

/// <summary>One account as read from disk, before presentation.</summary>
public sealed record StoredAccount(
    string Id,
    string? Alias,
    string? DisplayName,
    string? Email,
    bool RequiresReauth,
    double? UsedPercent = null,
    string? QuotaSummary = null,
    string? PlanType = null,
    int SortIndex = 0,
    CachedQuotaView? Quota = null,
    string? UserId = null,
    string? WorkspaceId = null,
    string? WorkspaceName = null,
    DateTimeOffset? SubscriptionExpiresAt = null);

/// <summary>
/// Reads accounts and produces the state the window draws.
/// </summary>
/// <remarks>
/// <para>
/// Kept separate from the window so it can be driven from a test with a temporary directory.
/// Its job is mostly to be careful about partial failure: one corrupt credential file must
/// not blank the whole panel, and the user must be able to tell "no accounts" apart from
/// "could not read your accounts".
/// </para>
/// <para>
/// Accounts whose credential cannot be read are skipped, and the fact that any were skipped
/// is reported — silently dropping them would look identical to the account never having
/// existed, which is the failure mode a user is least able to diagnose.
/// </para>
/// </remarks>
public sealed class PanelLoader
{
    private readonly CredentialStore _store;

    public PanelLoader(CredentialStore store) => _store = store;

    /// <summary>
    /// Builds the panel state.
    /// </summary>
    /// <param name="accounts">The accounts to show, in display order.</param>
    /// <param name="activeAccountId">Which one Codex is currently using, if known.</param>
    /// <param name="modules">The user's module order.</param>
    /// <param name="now">Injected so the result is deterministic under test.</param>
    public PanelState Load(
        IEnumerable<StoredAccount> accounts,
        string? activeAccountId,
        IReadOnlyList<PanelModule> modules,
        DateTimeOffset now)
    {
        var rows = new List<AccountRow>();
        var unreadable = 0;

        foreach (var account in accounts)
        {
            try
            {
                var auth = _store.LoadCredential(account.Id);
                rows.Add(AccountRow.From(
                    account.Id,
                    account.Alias,
                    account.DisplayName,
                    account.Email,
                    auth,
                    isActive: account.Id == activeAccountId,
                    needsReauth: account.RequiresReauth,
                    usedPercent: account.UsedPercent,
                    quotaSummary: account.QuotaSummary,
                    planType: account.PlanType,
                    quota: account.Quota?.ToView(now),
                    userId: account.UserId,
                    workspaceId: account.WorkspaceId,
                    workspaceName: account.WorkspaceName,
                    subscriptionExpiresAt: account.SubscriptionExpiresAt));
            }
            catch (CredentialStoreException)
            {
                unreadable++;
            }
        }

        if (rows.Count == 0 && unreadable > 0)
        {
            // Every account failed. Saying "empty" here would send the user looking for
            // accounts that exist but cannot be read.
            return PanelState.Failed("accounts_unreadable", modules);
        }

        var state = PanelState.Loaded(rows, modules, now);

        // Some succeeded, some did not: still show what is readable, but say so.
        return unreadable > 0
            ? state with { StatusMessageCode = "accounts_partially_unreadable" }
            : state;
    }
}
