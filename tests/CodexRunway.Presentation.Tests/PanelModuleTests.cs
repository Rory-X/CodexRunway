using CodexRunway.Presentation;
using Xunit;

namespace CodexRunway.Presentation.Tests;

/// <summary>
/// The module order is shared with the macOS build through preferences, so the stored
/// spellings are a contract rather than an implementation detail.
/// </summary>
public class PanelModuleTests
{
    [Fact]
    public void EveryModuleHasAStoredName()
    {
        foreach (var module in Enum.GetValues<PanelModule>())
        {
            var name = module.ToStoredName();

            Assert.False(string.IsNullOrWhiteSpace(name));
            Assert.Equal(module, PanelModuleNames.FromStoredName(name));
        }
    }

    /// <summary>These exact strings are what the macOS build writes.</summary>
    [Theory]
    [InlineData(PanelModule.Quota, "quota")]
    [InlineData(PanelModule.TokenUsage, "tokenUsage")]
    [InlineData(PanelModule.RateLimitResetToday, "rateLimitResetToday")]
    [InlineData(PanelModule.QuotaEstimate, "quotaEstimate")]
    [InlineData(PanelModule.ResetCredits, "resetCredits")]
    [InlineData(PanelModule.ApiCost, "apiCost")]
    [InlineData(PanelModule.SessionRepair, "sessionRepair")]
    [InlineData(PanelModule.RecentSessions, "recentSessions")]
    [InlineData(PanelModule.LocalAllowance, "localAllowance")]
    public void StoredNamesMatchTheMacOsRawValues(PanelModule module, string expected)
        => Assert.Equal(expected, module.ToStoredName());

    [Fact]
    public void AnUnknownStoredNameIsDropped()
        => Assert.Null(PanelModuleNames.FromStoredName("somethingAddedLater"));

    [Fact]
    public void NoStoredOrderFallsBackToTheDefault()
        => Assert.Equal(PanelModuleNames.DefaultOrder, PanelModuleNames.Normalize(null));

    [Fact]
    public void AStoredOrderIsHonoured()
    {
        var normalized = PanelModuleNames.Normalize(new[] { "apiCost", "quota" });

        Assert.Equal(PanelModule.ApiCost, normalized[0]);
        Assert.Equal(PanelModule.Quota, normalized[1]);
    }

    /// <summary>
    /// A module the stored order forgot must still appear, or an upgrade would silently hide
    /// a block from every existing user.
    /// </summary>
    [Fact]
    public void AModuleMissingFromTheStoredOrderIsStillShown()
    {
        var normalized = PanelModuleNames.Normalize(new[] { "quota" });

        Assert.Contains(PanelModule.ApiCost, normalized);
        Assert.Equal(Enum.GetValues<PanelModule>().Length, normalized.Count);
    }

    [Fact]
    public void DuplicatesCollapse()
    {
        var normalized = PanelModuleNames.Normalize(new[] { "quota", "quota", "apiCost" });

        Assert.Single(normalized, m => m == PanelModule.Quota);
        Assert.Equal(Enum.GetValues<PanelModule>().Length, normalized.Count);
    }

    [Fact]
    public void UnknownNamesDoNotBreakTheOrder()
    {
        var normalized = PanelModuleNames.Normalize(new[] { "nonsense", "apiCost", "quota" });

        Assert.Equal(PanelModule.ApiCost, normalized[0]);
        Assert.Equal(PanelModule.Quota, normalized[1]);
        Assert.Equal(Enum.GetValues<PanelModule>().Length, normalized.Count);
    }

    [Fact]
    public void MovingAModuleSwapsItWithItsNeighbour()
    {
        IReadOnlyList<PanelModule> order = new[] { PanelModule.Quota, PanelModule.ApiCost };

        var moved = PanelModuleNames.Move(order, PanelModule.Quota, +1);

        Assert.Equal(PanelModule.ApiCost, moved[0]);
        Assert.Equal(PanelModule.Quota, moved[1]);
    }

    [Fact]
    public void MovingPastEitherEndChangesNothing()
    {
        IReadOnlyList<PanelModule> order = new[] { PanelModule.Quota, PanelModule.ApiCost };

        Assert.Equal(order, PanelModuleNames.Move(order, PanelModule.Quota, -1));
        Assert.Equal(order, PanelModuleNames.Move(order, PanelModule.ApiCost, +1));
    }
}
