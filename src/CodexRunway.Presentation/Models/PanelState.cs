using CodexRunway.Core;

namespace CodexRunway.Presentation;

/// <summary>What the window is currently doing, so the view can render one state at a time.</summary>
public enum PanelStatus
{
    /// <summary>Nothing loaded yet.</summary>
    Idle,

    /// <summary>Reading accounts.</summary>
    Loading,

    /// <summary>Loaded, with content.</summary>
    Ready,

    /// <summary>Loaded, but there is nothing to show.</summary>
    Empty,

    /// <summary>Something went wrong; <see cref="PanelState.Problem"/> says what.</summary>
    Failed,
}

/// <summary>
/// Everything the window needs to draw itself, as plain data.
/// </summary>
/// <remarks>
/// <para>
/// Immutable and free of any UI framework, so the whole of the window's behaviour can be
/// exercised in a unit test on any OS. The XAML layer only maps this onto controls.
/// </para>
/// <para>
/// Messages are codes, not sentences: the view resolves them through the localisation table,
/// which keeps the choice of language in one place and keeps this type testable without a
/// culture.
/// </para>
/// </remarks>
public sealed record PanelState
{
    public required PanelStatus Status { get; init; }

    /// <summary>Accounts, in the order they should appear.</summary>
    public IReadOnlyList<AccountRow> Accounts { get; init; } = Array.Empty<AccountRow>();

    /// <summary>Modules to render, in the user's chosen order.</summary>
    public IReadOnlyList<PanelModule> Modules { get; init; } = PanelModuleNames.DefaultOrder;

    /// <summary>A message code to resolve for display, when there is something to say.</summary>
    public string? StatusMessageCode { get; init; }

    /// <summary>A stable code describing a failure, or null.</summary>
    public string? Problem { get; init; }

    /// <summary>When the data was last refreshed.</summary>
    public DateTimeOffset? RefreshedAt { get; init; }

    public static PanelState Idle { get; } = new() { Status = PanelStatus.Idle };

    public bool HasAccounts => Accounts.Count > 0;

    /// <summary>The account Codex is using, if one is marked active.</summary>
    public AccountRow? ActiveAccount => Accounts.FirstOrDefault(a => a.IsActive);

    /// <summary>Accounts the user can switch to right now.</summary>
    public IReadOnlyList<AccountRow> SelectableAccounts
        => Accounts.Where(a => a.CanActivate).ToArray();

    /// <summary>Accounts that need the user to do something.</summary>
    public IReadOnlyList<AccountRow> AccountsNeedingAttention
        => Accounts.Where(a => a.Tone == RowTone.Problem).ToArray();

    /// <summary>
    /// Subscription accounts other than the one in use, for the compact list.
    /// </summary>
    /// <remarks>
    /// The panel gives the active account a full card and everything else one line, because
    /// twelve identical cards bury the two rows a user actually came to look at. Splitting here
    /// rather than in the view keeps the grouping rule testable and identical on both platforms.
    /// </remarks>
    public IReadOnlyList<AccountRow> OtherSubscriptionAccounts
        => Accounts.Where(a => !a.IsActive && !a.IsProblem && !a.IsApiKey).ToArray();

    /// <inheritdoc cref="OtherSubscriptionAccounts"/>
    public IReadOnlyList<AccountRow> RelayAccounts
        => Accounts.Where(a => !a.IsActive && !a.IsProblem && a.IsApiKey).ToArray();

    /// <summary>Whether the compact subscription list has anything in it.</summary>
    public bool HasOtherSubscriptionAccounts => OtherSubscriptionAccounts.Count > 0;

    /// <inheritdoc cref="HasOtherSubscriptionAccounts"/>
    public bool HasRelayAccounts => RelayAccounts.Count > 0;

    /// <summary>Whether the active account should be drawn as a card.</summary>
    public bool HasActiveAccount => ActiveAccount is not null;

    /// <summary>Now reading accounts.</summary>
    public static PanelState Loading(IReadOnlyList<PanelModule> modules)
        => new() { Status = PanelStatus.Loading, Modules = modules };

    /// <summary>Loaded successfully; empty accounts means there is nothing to show.</summary>
    public static PanelState Loaded(
        IReadOnlyList<AccountRow> accounts,
        IReadOnlyList<PanelModule> modules,
        DateTimeOffset refreshedAt)
        => new()
        {
            Status = accounts.Count > 0 ? PanelStatus.Ready : PanelStatus.Empty,
            Accounts = accounts,
            Modules = modules,
            RefreshedAt = refreshedAt,
        };

    /// <summary>Loaded, but every account had to be skipped. Reports why rather than
    /// pretending the list is simply empty.</summary>
    public static PanelState Failed(
        string problem,
        IReadOnlyList<PanelModule> modules,
        IReadOnlyList<AccountRow>? partial = null)
        => new()
        {
            Status = PanelStatus.Failed,
            Problem = problem,
            Modules = modules,
            Accounts = partial ?? Array.Empty<AccountRow>(),
        };
}
