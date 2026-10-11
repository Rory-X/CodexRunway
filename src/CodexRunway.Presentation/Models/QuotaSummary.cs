namespace CodexRunway.Presentation;

/// <summary>Which colour a quota reading should be drawn in.</summary>
/// <remarks>
/// The thresholds come from the macOS build's <c>QuotaHealth</c> and are expressed the same
/// way there: a proportion of what is <i>left</i>, not of what is used. Both readings are
/// equivalent, but stating one and computing the other is how the two platforms drift apart.
/// </remarks>
public enum QuotaHealth
{
    /// <summary>At least half the window remains.</summary>
    Green,

    /// <summary>Between a fifth and a half remains.</summary>
    Yellow,

    /// <summary>Less than a fifth remains.</summary>
    Red,

    /// <summary>Nothing is known, so nothing is coloured.</summary>
    Unknown,
}

/// <summary>
/// One quota window, ready to display.
/// </summary>
/// <remarks>
/// The window length decides its label, because the same account shows a five-hour and a
/// weekly window and they must not be confused. Everything here is derived from the cached
/// reading, so the panel needs no network call to draw itself.
/// </remarks>
public sealed record QuotaWindowView
{
    /// <summary>"5 hours", "Weekly", or a derived label for an unusual length.</summary>
    public required string Label { get; init; }

    /// <summary>How much is left, 0 to 100.</summary>
    public required int RemainingPercent { get; init; }

    public required QuotaHealth Health { get; init; }

    /// <summary>A short "resets in 4h 59m" style string, or null when unknown.</summary>
    public string? ResetLabel { get; init; }

    /// <summary>Remaining as a fraction for a progress bar.</summary>
    public double RemainingFraction => RemainingPercent / 100.0;

    /// <summary>
    /// Whether the bar is worth drawing.
    /// </summary>
    /// <remarks>
    /// Omitted at full remaining. Most accounts sit at 100%, and a screen of identical full bars
    /// carries no information while pushing the one bar that does matter out of view; the number
    /// says the same thing in less space.
    /// </remarks>
    public bool ShowBar => RemainingPercent < 100;

    /// <summary>
    /// Health for a used percentage, using the macOS thresholds.
    /// </summary>
    public static QuotaHealth HealthFor(int usedPercent)
    {
        var remaining = Math.Max(0, 100 - Math.Clamp(usedPercent, 0, 100));

        if (remaining >= 50)
        {
            return QuotaHealth.Green;
        }

        return remaining >= 20 ? QuotaHealth.Yellow : QuotaHealth.Red;
    }

    /// <summary>
    /// A name for a window length in minutes.
    /// </summary>
    /// <remarks>
    /// Matched by length rather than by position, because the API is not contractually ordered:
    /// a build that reads "the first window is the five-hour one" once reported a weekly window
    /// as five hours. The two lengths the service uses are 300 and 10080 minutes.
    /// </remarks>
    public static string LabelForWindow(int? windowMinutes) => windowMinutes switch
    {
        300 => "5-hour",
        10080 => "Weekly",
        null => "Quota",
        _ => $"{windowMinutes} min",
    };

    /// <summary>
    /// A compact "resets in …" string.
    /// </summary>
    /// <remarks>
    /// Seconds are shown only under an hour, where they are the part that changes; above that
    /// they are noise. A past timestamp says "now" rather than a negative duration.
    /// </remarks>
    public static string? ResetLabelFor(DateTimeOffset? resetsAt, DateTimeOffset now)
    {
        if (resetsAt is not { } reset)
        {
            return null;
        }

        var remaining = reset - now;
        if (remaining <= TimeSpan.Zero)
        {
            return "resetting now";
        }

        var days = (int)remaining.TotalDays;
        var hours = remaining.Hours;
        var minutes = remaining.Minutes;

        if (days > 0)
        {
            return $"resets in {days}d {hours}h";
        }

        if (hours > 0)
        {
            return $"resets in {hours}h {minutes}m";
        }

        return $"resets in {Math.Max(0, minutes)}m {remaining.Seconds}s";
    }
}

/// <summary>
/// The quota lines for one account: the five-hour window and the weekly one, when known.
/// </summary>
public sealed record AccountQuotaView
{
    /// <summary>Both windows, in the order the panel shows them.</summary>
    public IReadOnlyList<QuotaWindowView> Windows { get; init; } = Array.Empty<QuotaWindowView>();

    /// <summary>The plan name, when the reading carried one.</summary>
    public string? Plan { get; init; }

    /// <summary>When the reading was taken, so its age can be judged.</summary>
    public DateTimeOffset? UpdatedAt { get; init; }

    public bool HasAny => Windows.Count > 0;

    /// <summary>
    /// The best health across the windows, for colouring a collapsed row.
    /// </summary>
    /// <remarks>
    /// The worst of the two, not the best: a row is collapsed precisely so the user can spot
    /// the account that is about to run out, and averaging that away defeats the purpose.
    /// </remarks>
    public QuotaHealth WorstHealth => Windows.Count == 0
        ? QuotaHealth.Unknown
        : Windows.OrderByDescending(w => w.Health).First().Health;

    /// <summary>
    /// Builds the view from a cached reading.
    /// </summary>
    /// <remarks>
    /// A window with no percentage is skipped rather than shown as zero: "0% used" and "not
    /// reported" look identical on a progress bar and mean opposite things.
    /// </remarks>
    public static AccountQuotaView From(
        string? plan,
        int? primaryUsedPercent,
        int? primaryWindowMinutes,
        DateTimeOffset? primaryResetsAt,
        int? secondaryUsedPercent,
        int? secondaryWindowMinutes,
        DateTimeOffset? secondaryResetsAt,
        DateTimeOffset? updatedAt,
        DateTimeOffset now)
    {
        var windows = new List<QuotaWindowView>();

        void Add(int? used, int? minutes, DateTimeOffset? resets)
        {
            if (used is not { } usedPercent)
            {
                return;
            }

            windows.Add(new QuotaWindowView
            {
                Label = QuotaWindowView.LabelForWindow(minutes),
                RemainingPercent = Math.Max(0, 100 - Math.Clamp(usedPercent, 0, 100)),
                Health = QuotaWindowView.HealthFor(usedPercent),
                ResetLabel = QuotaWindowView.ResetLabelFor(resets, now),
            });
        }

        // The shorter window first: it resets sooner and is what a user checks first.
        var primaryMinutes = primaryWindowMinutes;
        var secondaryMinutes = secondaryWindowMinutes;
        if (primaryMinutes is not null && secondaryMinutes is not null
            && primaryMinutes > secondaryMinutes)
        {
            Add(secondaryUsedPercent, secondaryMinutes, secondaryResetsAt);
            Add(primaryUsedPercent, primaryMinutes, primaryResetsAt);
        }
        else
        {
            Add(primaryUsedPercent, primaryMinutes, primaryResetsAt);
            Add(secondaryUsedPercent, secondaryMinutes, secondaryResetsAt);
        }

        return new AccountQuotaView
        {
            Windows = windows,
            Plan = plan,
            UpdatedAt = updatedAt,
        };
    }
}
