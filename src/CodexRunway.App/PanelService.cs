using System.IO;
using CodexRunway.Core;
using CodexRunway.Presentation;

namespace CodexRunway.App;

/// <summary>
/// Supplies panel state to a window.
/// </summary>
/// <remarks>
/// Kept out of the window so loading behaviour is testable and so both the panel and any future
/// window read accounts the same way rather than each re-implementing it.
/// </remarks>
public sealed class PanelService
{
    private readonly CredentialStore _store;
    private readonly AccountDiscovery _discovery;
    private readonly PanelLoader _loader;
    private readonly AccountSwitcher _switcher;

    public PanelService(RunwayPaths paths, CredentialStore store, AccountDiscovery discovery)
    {
        Paths = paths;
        _store = store;
        _discovery = discovery;
        _loader = new PanelLoader(store);
        _switcher = new AccountSwitcher(paths, store);
    }

    public RunwayPaths Paths { get; }

    /// <summary>The user's module order, shared with the macOS build through preferences.</summary>
    public IReadOnlyList<PanelModule> Modules { get; private set; } = PanelModuleNames.DefaultOrder;

    /// <summary>
    /// Reads the accounts and builds the state to render.
    /// </summary>
    /// <remarks>
    /// A failure reports itself through the state rather than throwing: a tray application that
    /// dies because one credential file is unreadable is worse than one that says so and keeps
    /// running.
    /// </remarks>
    public PanelState Load()
    {
        try
        {
            var state = _loader.Load(
                _discovery.Discover(),
                _discovery.ActiveAccountId(_store),
                Modules,
                DateTimeOffset.Now);

            return _discovery.IndexUnavailable
                ? state with { StatusMessageCode = "index_unavailable" }
                : state;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return PanelState.Failed("accounts_unreadable", Modules);
        }
    }

    /// <summary>
    /// Makes an account the one Codex uses.
    /// </summary>
    /// <remarks>
    /// Returns the outcome rather than throwing, because a refused switch is a normal result —
    /// an unusable credential, a config that cannot be written — and the window needs to say
    /// which one happened. Codex is not restarted here: whether to restart is a product decision,
    /// and this only guarantees the files agree.
    /// </remarks>
    public SwitchOutcome SwitchTo(AccountRow row)
    {
        var provider = AccountSwitcher.ProviderFor(
            _store.LoadCredential(row.Id),
            row.IsApiKey ? "custom" : null);

        var result = _switcher.SwitchTo(row.Id, provider);

        return result;
    }

    /// <summary>
    /// Moves an account up or down in the user's order and persists it.
    /// </summary>
    /// <remarks>
    /// Written through the compare-and-swap save, so a concurrent writer in another process is
    /// not silently overwritten. On a conflict the change is simply not applied — the panel
    /// reloads and shows the true order, which is better than forcing a stale arrangement over
    /// somebody else's.
    /// </remarks>
    public bool MoveAccount(string accountId, int delta)
    {
        try
        {
            var (index, snapshot) = AccountIndexCodec.LoadWithSnapshot(Paths);
            var moved = index.MoveAccount(accountId, delta);
            if (ReferenceEquals(moved, index))
            {
                return false;
            }

            AccountIndexCodec.Save(moved, Paths, snapshot);
            return true;
        }
        catch (Exception error) when (error is AccountIndexConflictException
            or AccountIndexFormatException
            or IOException
            or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// Removes an account from the index.
    /// </summary>
    /// <param name="deleteCredential">
    /// Whether to delete the stored credential as well. False keeps the file, so a removal is
    /// recoverable.
    /// </param>
    /// <remarks>
    /// The index entry goes first: if the credential were deleted and the index write then failed,
    /// the account would still be listed with nothing behind it.
    /// </remarks>
    public bool RemoveAccount(string accountId, bool deleteCredential)
    {
        try
        {
            var (index, snapshot) = AccountIndexCodec.LoadWithSnapshot(Paths);
            var trimmed = index.WithoutAccount(accountId);
            if (ReferenceEquals(trimmed, index))
            {
                return false;
            }

            AccountIndexCodec.Save(trimmed, Paths, snapshot);
        }
        catch (Exception error) when (error is AccountIndexConflictException
            or AccountIndexFormatException
            or IOException
            or UnauthorizedAccessException)
        {
            return false;
        }

        if (deleteCredential)
        {
            try
            {
                _store.DeleteCredential(accountId);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // The index no longer lists it, which is the part the user asked for; a file left
                // behind is reported by the caller if it matters.
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Asks GitHub whether a newer release has been published.
    /// </summary>
    /// <remarks>
    /// Returns a result rather than throwing: this runs from a button, and "could not reach
    /// GitHub" is a normal outcome that the panel should be able to say.
    /// </remarks>
    public Task<UpdateCheckResult> CheckForUpdateAsync()
        => UpdateCheck.CheckAsync(UpdateCheck.CurrentVersion);

    /// <summary>Moves a module and returns the new order.</summary>
    public IReadOnlyList<PanelModule> MoveModule(PanelModule module, int delta)
    {
        Modules = PanelModuleNames.Move(Modules, module, delta);
        return Modules;
    }
}
