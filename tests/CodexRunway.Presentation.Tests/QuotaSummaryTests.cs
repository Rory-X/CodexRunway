using CodexRunway.Presentation;
using Xunit;

namespace CodexRunway.Presentation.Tests;

/// <summary>
/// The quota display: window labels, health colours and reset wording.
/// </summary>
/// <remarks>
/// Everything here is derived from a cached reading so the panel needs no network call, which
/// makes it the part of the display a user sees on every launch — and the part most likely to
/// drift from the macOS build silently, because the thresholds and labels are restated there
/// rather than shared.
/// </remarks>
public class QuotaSummaryTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-11T00:00:00Z");

    // ---------------------------------------------------------------- health

    /// <summary>
    /// The thresholds are a proportion of what is <i>left</i>, at 50% and 20%, and they are
    /// inclusive at the boundary — the off-by-one that would miscolour a row.
    /// </summary>
    [Theory]
    [InlineData(0, QuotaHealth.Green)]     // 100 remaining
    [InlineData(50, QuotaHealth.Green)]    // exactly 50 remaining: still green
    [InlineData(51, QuotaHealth.Yellow)]   // 49 remaining
    [InlineData(80, QuotaHealth.Yellow)]   // exactly 20 remaining: still yellow
    [InlineData(81, QuotaHealth.Red)]      // 19 remaining
    [InlineData(100, QuotaHealth.Red)]
    public void HealthFollowsTheMacOsThresholdsOnRemainingQuota(int usedPercent, QuotaHealth expected)
        => Assert.Equal(expected, QuotaWindowView.HealthFor(usedPercent));

    /// <summary>An out-of-range reading is clamped rather than colouring oddly.</summary>
    [Theory]
    [InlineData(-5, QuotaHealth.Green)]
    [InlineData(150, QuotaHealth.Red)]
    public void AnOutOfRangeUsedPercentIsClamped(int usedPercent, QuotaHealth expected)
        => Assert.Equal(expected, QuotaWindowView.HealthFor(usedPercent));

    // ---------------------------------------------------------------- window labels

    /// <summary>
    /// The label comes from the window's length rather than its position, because the API is not
    /// contractually ordered — reading "the first window is the five-hour one" once reported a
    /// weekly window as five hours.
    /// </summary>
    [Theory]
    [InlineData(300, "5-hour")]
    [InlineData(10080, "Weekly")]
    [InlineData(null, "Quota")]
    [InlineData(60, "60 min")]
    [InlineData(1440, "1440 min")]
    public void WindowLabelsMatchTheMacOsNames(int? minutes, string expected)
        => Assert.Equal(expected, QuotaWindowView.LabelForWindow(minutes));

    // ---------------------------------------------------------------- reset wording

    [Fact]
    public void AnAbsentResetTimeHasNoLabel()
        => Assert.Null(QuotaWindowView.ResetLabelFor(null, Now));

    /// <summary>A reset already in the past says so rather than showing a negative duration.</summary>
    [Theory]
    [InlineData(-1)]
    [InlineData(-600)]
    public void APastResetSaysItIsResettingNow(int secondsAgo)
        => Assert.Equal(
            "resetting now",
            QuotaWindowView.ResetLabelFor(Now.AddSeconds(secondsAgo), Now));

    /// <summary>Under an hour the seconds are shown, because they are the part that changes.</summary>
    [Fact]
    public void AResetUnderAnHourShowsMinutesAndSeconds()
        => Assert.Equal(
            "resets in 4m 30s",
            QuotaWindowView.ResetLabelFor(Now.AddSeconds(270), Now));

    [Fact]
    public void AResetUnderADayShowsHoursAndMinutes()
        => Assert.Equal(
            "resets in 1h 30m",
            QuotaWindowView.ResetLabelFor(Now.AddMinutes(90), Now));

    [Fact]
    public void AResetOverADayShowsDaysAndHours()
        => Assert.Equal(
            "resets in 2d 3h",
            QuotaWindowView.ResetLabelFor(Now.AddDays(2).AddHours(3).AddMinutes(20), Now));

    // ---------------------------------------------------------------- the assembled view

    /// <summary>
    /// The shorter window is listed first: it resets sooner and is what a user checks first, even
    /// when the service reported it second.
    /// </summary>
    [Fact]
    public void TheShorterWindowIsListedFirstEvenWhenReportedSecond()
    {
        var view = AccountQuotaView.From(
            "plus",
            primaryUsedPercent: 80, primaryWindowMinutes: 10080, primaryResetsAt: Now.AddDays(1),
            secondaryUsedPercent: 10, secondaryWindowMinutes: 300, secondaryResetsAt: Now.AddHours(1),
            updatedAt: Now,
            now: Now);

        Assert.Equal(new[] { "5-hour", "Weekly" }, view.Windows.Select(w => w.Label));
        // And each window kept its own numbers, rather than being swapped along with the order.
        Assert.Equal(90, view.Windows[0].RemainingPercent);
        Assert.Equal(20, view.Windows[1].RemainingPercent);
    }

    /// <summary>
    /// A window with no percentage is left out rather than drawn as zero: "0% used" and "not
    /// reported" look identical on a progress bar and mean opposite things.
    /// </summary>
    [Fact]
    public void AWindowWithoutAPercentageIsOmittedRatherThanShownAsZero()
    {
        var view = AccountQuotaView.From(
            null,
            primaryUsedPercent: null, primaryWindowMinutes: 10080, primaryResetsAt: null,
            secondaryUsedPercent: 40, secondaryWindowMinutes: 300, secondaryResetsAt: null,
            updatedAt: null,
            now: Now);

        var only = Assert.Single(view.Windows);
        Assert.Equal("5-hour", only.Label);
        Assert.Equal(60, only.RemainingPercent);
        Assert.True(view.HasAny);
    }

    /// <summary>
    /// The collapse colour is the <i>worst</i> of the windows: a row is collapsed so the user can
    /// spot the account about to run out, and averaging that away defeats the purpose.
    /// </summary>
    [Fact]
    public void TheWorstWindowDecidesTheCollapsedColour()
    {
        var view = AccountQuotaView.From(
            "plus",
            primaryUsedPercent: 5, primaryWindowMinutes: 300, primaryResetsAt: null,
            secondaryUsedPercent: 95, secondaryWindowMinutes: 10080, secondaryResetsAt: null,
            updatedAt: null,
            now: Now);

        Assert.Equal(2, view.Windows.Count);
        Assert.Equal(QuotaHealth.Red, view.WorstHealth);
    }

    [Fact]
    public void AReadingWithNoWindowsIsUnknown()
    {
        var view = AccountQuotaView.From(
            null, null, null, null, null, null, null, null, Now);

        Assert.Empty(view.Windows);
        Assert.False(view.HasAny);
        Assert.Equal(QuotaHealth.Unknown, view.WorstHealth);
    }

    /// <summary>The plan and the reading's age travel with the windows.</summary>
    [Fact]
    public void ThePlanAndUpdateTimeAreCarriedThrough()
    {
        var taken = DateTimeOffset.Parse("2026-10-10T20:00:00Z");
        var view = AccountQuotaView.From(
            "plus", 12, 300, null, null, null, null, taken, Now);

        Assert.Equal("plus", view.Plan);
        Assert.Equal(taken, view.UpdatedAt);
    }

    [Fact]
    public void TheRemainingFractionMatchesThePercentage()
        => Assert.Equal(
            0.75,
            new QuotaWindowView { Label = "5-hour", RemainingPercent = 75, Health = QuotaHealth.Green }
                .RemainingFraction);
}
