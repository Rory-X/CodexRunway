namespace CodexRunway.Presentation;

/// <summary>
/// The blocks the status panel can show, in their default order.
/// </summary>
/// <remarks>
/// Mirrors the macOS app's <c>MainPanelModule</c>. The set is deliberately the same and the
/// stored names match, because the user's chosen order lives in shared preferences — a
/// module named differently here would silently fall back to the default order on one
/// platform and not the other.
/// </remarks>
public enum PanelModule
{
    Quota,
    TokenUsage,
    RateLimitResetToday,
    QuotaEstimate,
    ResetCredits,
    ApiCost,
    SessionRepair,
    RecentSessions,
    LocalAllowance,
}

/// <summary>Maps <see cref="PanelModule"/> to and from the name stored on disk.</summary>
public static class PanelModuleNames
{
    /// <summary>
    /// The stored spelling, matching the macOS raw values exactly.
    /// </summary>
    public static string ToStoredName(this PanelModule module) => module switch
    {
        PanelModule.Quota => "quota",
        PanelModule.TokenUsage => "tokenUsage",
        PanelModule.RateLimitResetToday => "rateLimitResetToday",
        PanelModule.QuotaEstimate => "quotaEstimate",
        PanelModule.ResetCredits => "resetCredits",
        PanelModule.ApiCost => "apiCost",
        PanelModule.SessionRepair => "sessionRepair",
        PanelModule.RecentSessions => "recentSessions",
        PanelModule.LocalAllowance => "localAllowance",
        _ => throw new ArgumentOutOfRangeException(nameof(module), module, "unmapped module"),
    };

    /// <summary>Parses a stored name. Unknown names are dropped rather than throwing.</summary>
    /// <remarks>
    /// A name this build does not know is most likely a module added by a newer version, so
    /// dropping it keeps the rest of the user's order intact instead of failing the whole
    /// preference.
    /// </remarks>
    public static PanelModule? FromStoredName(string? name) => name switch
    {
        "quota" => PanelModule.Quota,
        "tokenUsage" => PanelModule.TokenUsage,
        "rateLimitResetToday" => PanelModule.RateLimitResetToday,
        "quotaEstimate" => PanelModule.QuotaEstimate,
        "resetCredits" => PanelModule.ResetCredits,
        "apiCost" => PanelModule.ApiCost,
        "sessionRepair" => PanelModule.SessionRepair,
        "recentSessions" => PanelModule.RecentSessions,
        "localAllowance" => PanelModule.LocalAllowance,
        _ => null,
    };

    /// <summary>The default order, used when the user has not chosen one.</summary>
    public static IReadOnlyList<PanelModule> DefaultOrder { get; } = new[]
    {
        PanelModule.Quota,
        PanelModule.TokenUsage,
        PanelModule.RateLimitResetToday,
        PanelModule.QuotaEstimate,
        PanelModule.ResetCredits,
        PanelModule.ApiCost,
        PanelModule.SessionRepair,
        PanelModule.RecentSessions,
        PanelModule.LocalAllowance,
    };

    /// <summary>
    /// Normalises a stored order: unknown names dropped, duplicates removed, and any module
    /// the stored order forgot appended in its default position.
    /// </summary>
    /// <remarks>
    /// Appending rather than inserting is what stops a module silently disappearing after an
    /// upgrade: a user with a saved order from an older build would otherwise never see a
    /// newly added block.
    /// </remarks>
    public static IReadOnlyList<PanelModule> Normalize(IEnumerable<string>? stored)
    {
        if (stored is null)
        {
            return DefaultOrder;
        }

        var result = new List<PanelModule>();
        var seen = new HashSet<PanelModule>();
        foreach (var name in stored)
        {
            if (FromStoredName(name) is { } module && seen.Add(module))
            {
                result.Add(module);
            }
        }

        foreach (var module in DefaultOrder)
        {
            if (seen.Add(module))
            {
                result.Add(module);
            }
        }

        return result;
    }

    /// <summary>Moves one module within an order, returning the new list.</summary>
    public static IReadOnlyList<PanelModule> Move(
        IReadOnlyList<PanelModule> order,
        PanelModule module,
        int delta)
    {
        var list = order.ToList();
        var index = list.IndexOf(module);
        if (index < 0)
        {
            return order;
        }

        var target = index + delta;
        if (target < 0 || target >= list.Count)
        {
            return order;
        }

        (list[index], list[target]) = (list[target], list[index]);
        return list;
    }
}
