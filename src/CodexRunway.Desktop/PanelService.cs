using CodexRunway.Core;
using CodexRunway.Presentation;

namespace CodexRunway.Desktop;

/// <summary>
/// Supplies panel state to the window and remembers the user's module order.
/// </summary>
/// <remarks>
/// Kept out of the window so the loading behaviour is testable, and so both the panel and a
/// future settings window read accounts the same way rather than each re-implementing it.
/// </remarks>
public sealed class PanelService
{
    private readonly CredentialStore _store;
    private readonly AccountDiscovery _discovery;
    private readonly PanelLoader _loader;

    public PanelService(RunwayPaths paths, CredentialStore store, AccountDiscovery discovery)
    {
        Paths = paths;
        _store = store;
        _discovery = discovery;
        _loader = new PanelLoader(store);
    }

    public RunwayPaths Paths { get; }

    /// <summary>The user's module order. Shared with the macOS build through preferences.</summary>
    public IReadOnlyList<PanelModule> Modules { get; private set; } = PanelModuleNames.DefaultOrder;

    /// <summary>
    /// Reads the accounts and builds the state to render.
    /// </summary>
    /// <remarks>
    /// A failure here reports itself through the state rather than throwing: a tray application
    /// that dies because one credential file is unreadable is worse than one that says so and
    /// keeps running.
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

    /// <summary>Moves a module up or down and returns the new order.</summary>
    public IReadOnlyList<PanelModule> MoveModule(PanelModule module, int delta)
    {
        Modules = PanelModuleNames.Move(Modules, module, delta);
        return Modules;
    }
}
