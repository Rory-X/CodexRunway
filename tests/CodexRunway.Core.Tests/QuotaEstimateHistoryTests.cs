using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Reading the allowance history.
/// </summary>
/// <remarks>
/// The file is shared with the macOS build and its keys are not account ids, so the mapping back
/// to an account is the part most likely to be quietly wrong: a wrong key does not throw, it
/// reports no estimate, and the panel simply shows one fewer number.
/// </remarks>
public class QuotaEstimateHistoryTests
{
    private const string TwoAccounts = """
    {
      "accounts": {
        "id:api-1": [
          { "cycleStartDate": "2026-09-14", "estimatedCredits": 74186869, "usedCredits": 74186869,
            "usedPercent": 100, "recordedAt": "2026-09-19T04:59:35Z" }
        ],
        "oauth:user:user-abc|account:ws-xyz": [
          { "cycleStartDate": "2026-09-30", "estimatedCredits": 69821714,
            "usedPercent": 100, "recordedAt": "2026-10-03T16:59:00Z" }
        ]
      }
    }
    """;

    // ---------------------------------------------------------------- parsing

    [Fact]
    public void SamplesAreReadFromTheHistory()
    {
        var parsed = QuotaEstimateHistory.Parse(TwoAccounts);

        Assert.Equal(2, parsed.Count);
        var api = parsed["id:api-1"].Samples[0];
        Assert.Equal(74186869, api.EstimatedCredits);
        Assert.Equal(100, api.UsedPercent);
        Assert.Equal(new DateOnly(2026, 9, 14), api.CycleStart);
    }

    [Fact]
    public void AMalformedSampleIsSkippedRatherThanFailingTheFile()
    {
        var parsed = QuotaEstimateHistory.Parse("""
        {"accounts":{"id:a":[
          {"estimatedCredits":"not a number"},
          {"estimatedCredits":5,"usedPercent":100}
        ]}}
        """);

        Assert.Single(parsed["id:a"].Samples);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("""{"accounts":"nope"}""")]
    public void AMalformedDocumentReadsAsEmpty(string json)
        => Assert.Empty(QuotaEstimateHistory.Parse(json));

    /// <summary>A duplicate key arrives as ArgumentException, which is not a JsonException.</summary>
    [Fact]
    public void ADuplicateKeyIsReportedAsEmptyRatherThanThrowing()
        => Assert.Empty(QuotaEstimateHistory.Parse("""{"accounts":{},"accounts":{}}"""));

    // ---------------------------------------------------------------- key mapping

    /// <summary>
    /// The <c>account:</c> segment is the workspace id, not the row's own id.
    /// </summary>
    /// <remarks>
    /// On this machine every subscription account has different values for the two — the row id
    /// is a hash, the workspace id a UUID — and using the row id matched one account out of eight.
    /// </remarks>
    [Fact]
    public void ASubscriptionKeyUsesTheWorkspaceId()
    {
        var key = QuotaEstimateHistory.HistoryKey("oauth-abc", isApiKey: false, "user-1", "ws-9");

        Assert.Equal("oauth:user:user-1|account:ws-9", key);
    }

    [Fact]
    public void AnApiKeyAccountUsesItsOwnId()
    {
        var key = QuotaEstimateHistory.HistoryKey("api-abc", isApiKey: true, null, null);

        Assert.Equal("id:api-abc", key);
    }

    /// <summary>
    /// With no workspace id the row id is used, so an account from an older index still maps.
    /// </summary>
    [Fact]
    public void ASubscriptionWithoutAWorkspaceIdFallsBackToTheRowId()
    {
        var key = QuotaEstimateHistory.HistoryKey("oauth-abc", isApiKey: false, "user-1", null);

        Assert.Equal("oauth:user:user-1|account:oauth-abc", key);
    }

    [Fact]
    public void BothKeyShapesMapBackToAccountIds()
    {
        var parsed = QuotaEstimateHistory.Parse(TwoAccounts);

        var mapped = QuotaEstimateHistory.ByAccountId(parsed, new[]
        {
            ("api-1", true, (string?)null, (string?)null),
            ("oauth-abc", false, "user-abc", "ws-xyz"),
        });

        Assert.Equal(2, mapped.Count);
        Assert.True(mapped.ContainsKey("api-1"));
        Assert.True(mapped.ContainsKey("oauth-abc"));
    }

    /// <summary>A key whose account is gone is dropped, not surfaced under its storage form.</summary>
    [Fact]
    public void AnUnmatchedKeyIsDropped()
    {
        var parsed = QuotaEstimateHistory.Parse(TwoAccounts);

        var mapped = QuotaEstimateHistory.ByAccountId(parsed, new[]
        {
            ("some-other-account", true, (string?)null, (string?)null),
        });

        Assert.Empty(mapped);
    }

    // ---------------------------------------------------------------- reliability

    /// <summary>
    /// A figure extrapolated from a sliver of a cycle is not trustworthy.
    /// </summary>
    /// <remarks>
    /// Measured on this machine: one account's completed cycle gave 70M credits where its
    /// 2%-sampled cycle gave 9.8 billion — the same arithmetic on a smaller sample, off by a
    /// factor of 140.
    /// </remarks>
    [Theory]
    [InlineData(2, false)]
    [InlineData(24, false)]
    [InlineData(25, true)]
    [InlineData(85, true)]
    [InlineData(100, true)]
    public void ReliabilityFollowsTheSamplePoint(int usedPercent, bool expected)
    {
        var sample = new EstimateSample { UsedPercent = usedPercent };

        Assert.Equal(expected, sample.IsReliable);
    }

    [Fact]
    public void ASampleWithNoPercentIsNotReliable()
        => Assert.False(new EstimateSample { EstimatedCredits = 5 }.IsReliable);

    /// <summary>
    /// A completed cycle is preferred over a newer partial one, because recency alone would
    /// surface the figure that is off by an order of magnitude.
    /// </summary>
    [Fact]
    public void ACompletedCycleBeatsANewerPartialOne()
    {
        var estimate = new AccountEstimate
        {
            AccountId = "a",
            Samples = new[]
            {
                new EstimateSample
                {
                    EstimatedCredits = 69_821_714, UsedPercent = 100,
                    RecordedAt = DateTimeOffset.Parse("2026-10-03T00:00:00Z"),
                },
                new EstimateSample
                {
                    EstimatedCredits = 9_774_696_600, UsedPercent = 2,
                    RecordedAt = DateTimeOffset.Parse("2026-10-11T00:00:00Z"),
                },
            },
        };

        Assert.Equal(69_821_714, estimate.Best!.EstimatedCredits);
        Assert.True(estimate.BestIsComplete);
        Assert.True(estimate.BestIsTrustworthy);
    }

    /// <summary>
    /// With no completed cycle, the newest reliable sample wins over the newest of all.
    /// </summary>
    [Fact]
    public void WithoutACompletedCycleTheNewestReliableSampleIsUsed()
    {
        var estimate = new AccountEstimate
        {
            AccountId = "a",
            Samples = new[]
            {
                new EstimateSample
                {
                    EstimatedCredits = 100, UsedPercent = 40,
                    RecordedAt = DateTimeOffset.Parse("2026-10-01T00:00:00Z"),
                },
                new EstimateSample
                {
                    EstimatedCredits = 999_999, UsedPercent = 3,
                    RecordedAt = DateTimeOffset.Parse("2026-10-11T00:00:00Z"),
                },
            },
        };

        Assert.Equal(100, estimate.Best!.EstimatedCredits);
        Assert.True(estimate.BestIsTrustworthy);
    }

    /// <summary>With nothing reliable, the figure is still shown — and flagged as weak.</summary>
    [Fact]
    public void WithNothingReliableTheFigureIsShownButNotTrusted()
    {
        var estimate = new AccountEstimate
        {
            AccountId = "a",
            Samples = new[] { new EstimateSample { EstimatedCredits = 9_774_696_600, UsedPercent = 2 } },
        };

        Assert.NotNull(estimate.Best);
        Assert.False(estimate.BestIsTrustworthy);
    }

    [Fact]
    public void AnAccountWithNoSamplesHasNoBest()
        => Assert.Null(new AccountEstimate { AccountId = "a" }.Best);

    // ---------------------------------------------------------------- formatting

    [Theory]
    // Written as doubles: InlineData carries an int literal as int, which xUnit cannot bind to
    // a nullable double parameter.
    [InlineData(74_186_869.0, "74.2M")]
    [InlineData(162_000_000.0, "162.0M")]
    [InlineData(1500.0, "1.5K")]
    [InlineData(42.0, "42")]
    [InlineData(null, "—")]
    public void CreditsAreFormattedCompactly(double? value, string expected)
        => Assert.Equal(expected, QuotaEstimateHistory.FormatCredits(value));
}
