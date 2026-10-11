using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Deciding whether the quota reset today.
/// </summary>
/// <remarks>
/// The answer drives a user's decision about whether to keep working, so the three states have
/// to stay distinct: "unknown" collapsing into "no" would answer a question the data explicitly
/// declined to. Most of these tests are about keeping them apart.
/// </remarks>
public class ResetTodayStatusTests
{
    private static string Payload(
        string monitorStatus = "ok",
        int schema = 1,
        string? events = null,
        string? generatedAt = "\"2026-10-11T12:05:00Z\"")
        => $$"""
        {
          "schemaVersion": {{schema}},
          "generatedAt": {{generatedAt ?? "null"}},
          "lastSuccessfulCheckAt": "2026-10-11T12:04:00Z",
          "monitor": { "status": "{{monitorStatus}}" },
          "events": [{{events ?? ""}}]
        }
        """;

    private const string CompletedToday = """
    {
      "kind": "reset_completed",
      "resetType": "global",
      "announcedAt": "2026-10-11T11:59:00Z",
      "effectiveAt": "2026-10-11T12:01:00Z",
      "confidence": 0.88,
      "text": "Put the reset in the bag.",
      "source": { "url": "https://example.invalid/post" }
    }
    """;

    // ---------------------------------------------------------------- parsing

    [Fact]
    public void ACompletedResetIsRead()
    {
        var (_, _, _, monitor, events) = ResetTodayStatus.Parse(Payload(events: CompletedToday));

        Assert.Equal("ok", monitor);
        var only = Assert.Single(events);
        Assert.Equal("reset_completed", only.Kind);
        Assert.True(only.IsGlobal);
        Assert.Equal(0.88, only.Confidence, 6);
        Assert.Equal(DateTimeOffset.Parse("2026-10-11T12:01:00Z"), only.When);
        Assert.Equal("https://example.invalid/post", only.Url);
    }

    /// <summary>
    /// A reset is often announced before its time is known, so the announcement stands in.
    /// </summary>
    /// <remarks>
    /// Using only <c>effectiveAt</c> would report "no reset today" on a day when one plainly
    /// happened and was posted about.
    /// </remarks>
    [Fact]
    public void WithoutAnEffectiveTimeTheAnnouncementIsUsed()
    {
        var (_, _, _, _, events) = ResetTodayStatus.Parse(Payload(events: """
        {"kind":"reset_completed","announcedAt":"2026-10-11T09:00:00Z","confidence":0.5}
        """));

        Assert.Equal(DateTimeOffset.Parse("2026-10-11T09:00:00Z"), Assert.Single(events).When);
    }

    [Fact]
    public void AnEventWithoutAKindIsSkipped()
    {
        var (_, _, _, _, events) = ResetTodayStatus.Parse(Payload(events: """
        {"resetType":"global","confidence":0.9}
        """));

        Assert.Empty(events);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("""{"events":"nope"}""")]
    public void AMalformedPayloadParsesAsEmpty(string json)
    {
        var (schema, _, _, _, events) = ResetTodayStatus.Parse(json);

        Assert.Null(schema);
        Assert.Empty(events);
    }

    // ---------------------------------------------------------------- verdicts

    [Fact]
    public void AResetTodayReadsYes()
    {
        var now = DateTimeOffset.Parse("2026-10-11T18:00:00+08:00");
        var report = ResetTodayStatus.Evaluate(Payload(events: CompletedToday), now);

        Assert.Equal(ResetTodayVerdict.Yes, report.Verdict);
        Assert.Equal(88, report.ConfidencePercent);
        Assert.True(report.Event!.IsGlobal);
    }

    /// <summary>A reset on an earlier day is not today's news, however confident it was.</summary>
    [Fact]
    public void AResetOnAnotherDayReadsNo()
    {
        var now = DateTimeOffset.Parse("2026-10-11T18:00:00+08:00");
        var report = ResetTodayStatus.Evaluate(Payload(events: """
        {"kind":"reset_completed","effectiveAt":"2026-10-09T12:01:00Z","confidence":0.9}
        """), now);

        Assert.Equal(ResetTodayVerdict.No, report.Verdict);
        Assert.Null(report.Problem);
    }

    /// <summary>
    /// "Today" is the user's own day, not UTC's.
    /// </summary>
    /// <remarks>
    /// A reset at 00:30 local time in +08:00 is 16:30 the previous day in UTC. Deciding the day
    /// in UTC would tell that user today's reset happened yesterday — the exact opposite answer,
    /// from the same data.
    /// </remarks>
    [Fact]
    public void TheDayIsComputedInLocalTimeNotUtc()
    {
        var utc = new DateTimeOffset(2026, 10, 10, 16, 30, 0, TimeSpan.Zero);
        var local = utc.ToLocalTime();

        var report = ResetTodayStatus.Evaluate(Payload(events: $$"""
        {"kind":"reset_completed","effectiveAt":"2026-10-10T16:30:00Z","confidence":0.9}
        """), local);

        // The reset falls on the local day containing `local`, so the answer must be yes whatever
        // that day is called in UTC.
        Assert.Equal(ResetTodayVerdict.Yes, report.Verdict);
    }

    /// <summary>An unsure upstream monitor must not be turned into a "no".</summary>
    [Fact]
    public void AnUnsureMonitorReadsUnknownRatherThanNo()
    {
        var now = DateTimeOffset.Parse("2026-10-11T18:00:00+08:00");
        var report = ResetTodayStatus.Evaluate(Payload(monitorStatus: "degraded"), now);

        Assert.Equal(ResetTodayVerdict.Unknown, report.Verdict);
        Assert.Equal("monitor_not_ok", report.Problem);
    }

    /// <summary>
    /// A newer schema is reported as unknown rather than guessed at.
    /// </summary>
    /// <remarks>
    /// A renamed field would otherwise read as an empty event list, which the panel would present
    /// as "no reset happened" — a confident answer derived from a parsing failure.
    /// </remarks>
    [Fact]
    public void ANewerSchemaReadsUnknown()
    {
        var now = DateTimeOffset.Parse("2026-10-11T18:00:00+08:00");
        var report = ResetTodayStatus.Evaluate(Payload(schema: 2, events: CompletedToday), now);

        Assert.Equal(ResetTodayVerdict.Unknown, report.Verdict);
        Assert.Equal("unsupported_schema", report.Problem);
    }

    /// <summary>Several announcements on one day: the most confident one is the answer.</summary>
    [Fact]
    public void TheMostConfidentAnnouncementWins()
    {
        var now = DateTimeOffset.Parse("2026-10-11T18:00:00+08:00");
        var report = ResetTodayStatus.Evaluate(Payload(events: """
        {"kind":"reset_completed","effectiveAt":"2026-10-11T08:00:00Z","confidence":0.4},
        {"kind":"reset_completed","effectiveAt":"2026-10-11T12:00:00Z","confidence":0.9}
        """), now);

        Assert.Equal(ResetTodayVerdict.Yes, report.Verdict);
        Assert.Equal(90, report.ConfidencePercent);
    }

    /// <summary>A countdown is not a completion.</summary>
    [Fact]
    public void AnAnnouncementThatIsNotACompletionDoesNotReadYes()
    {
        var now = DateTimeOffset.Parse("2026-10-11T18:00:00+08:00");
        var report = ResetTodayStatus.Evaluate(Payload(events: """
        {"kind":"reset_announced","effectiveAt":"2026-10-11T12:00:00Z","confidence":0.9}
        """), now);

        Assert.Equal(ResetTodayVerdict.No, report.Verdict);
    }

    [Fact]
    public void AnUnknownVerdictCarriesAReasonCode()
    {
        var report = ResetTodayReport.Unknown("timeout");

        Assert.Equal(ResetTodayVerdict.Unknown, report.Verdict);
        Assert.Equal("reset_timeout", ResetTodayStatus.ProblemCode(report));
        Assert.Null(report.ConfidencePercent);
    }

    [Theory]
    [InlineData("http_403", "reset_http_403")]
    [InlineData("network_unreachable", "reset_unreachable")]
    [InlineData("unsupported_schema", "reset_unsupported_schema")]
    [InlineData("monitor_not_ok", "reset_monitor_not_ok")]
    [InlineData("something_new", "reset_unknown")]
    public void EveryReasonMapsToItsOwnWording(string problem, string expected)
        => Assert.Equal(expected, ResetTodayStatus.ProblemCode(ResetTodayReport.Unknown(problem)));

    [Fact]
    public void TheEndpointIsTheCanonicalHost()
        => Assert.Equal("https://www.codexrunway.com/api/status.json", ResetTodayStatus.StatusUrl);
}
