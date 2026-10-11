using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Summing token use from the session logs.
/// </summary>
/// <remarks>
/// Three rules here were each established by disagreeing with a working implementation, so they
/// are pinned rather than left to look like arbitrary choices.
/// </remarks>
public class SessionUsageTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(), "cr-sessions-" + Guid.NewGuid().ToString("N"));

    public SessionUsageTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (IOException)
        {
            // A leftover temp directory is not worth failing a test over.
        }
    }

    private RunwayPaths Paths => new(_root, Path.Combine(_root, "codex-runway"));

    private string Write(string name, params string[] lines)
    {
        var path = Path.Combine(_root, "sessions", "2026", "10", "11", name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllLines(path, lines);
        return path;
    }

    /// <summary>
    /// One token_count record.
    /// </summary>
    /// <remarks>
    /// Built by concatenation rather than as an interpolated raw string: the JSON is dense with
    /// braces, and the raw-string form needs enough dollar signs to disambiguate them, which reads
    /// worse than this does.
    /// </remarks>
    private static string Turn(long input, long output, long total, long reasoning = 0,
        string timestamp = "2026-10-11T12:00:00Z")
        => "{\"timestamp\":\"" + timestamp
            + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{"
            + "\"last_token_usage\":{\"input_tokens\":" + input
            + ",\"cached_input_tokens\":0,\"output_tokens\":" + output
            + ",\"reasoning_output_tokens\":" + reasoning
            + ",\"total_tokens\":" + total + "},"
            + "\"total_token_usage\":{\"total_tokens\":" + total + "}}}}";
    

    // ---------------------------------------------------------------- counting

    [Fact]
    public void TurnsAreSummed()
    {
        Write("a.jsonl", Turn(100, 20, 120), Turn(200, 30, 350));

        var (tokens, turns, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(350, tokens);
        Assert.Equal(2, turns);
    }

    /// <summary>
    /// The count is <c>input + output</c>, not the record's own <c>total_tokens</c>.
    /// </summary>
    /// <remarks>
    /// About 1,500 records in a real log carry a non-zero total with input and output both zero.
    /// Summing the field instead over-counted by roughly 108M tokens against the reference
    /// implementation, which is how this rule was found.
    /// </remarks>
    [Fact]
    public void TheRecordTotalIsNotUsed()
    {
        Write("a.jsonl", Turn(100, 20, 999_999));

        var (tokens, _, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(120, tokens);
    }

    /// <summary>A record with input, output and reasoning all zero is noise, not a turn.</summary>
    [Fact]
    public void AnEmptyReadingIsSkipped()
    {
        Write("a.jsonl", Turn(0, 0, 16532), Turn(100, 20, 120));

        var (tokens, turns, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(120, tokens);
        Assert.Equal(1, turns);
    }

    /// <summary>
    /// Reasoning is a breakdown of output, not an addition to it.
    /// </summary>
    /// <remarks>
    /// Adding it would inflate every figure by the reasoning share — measured at roughly 18.5M
    /// tokens when the mistake was made in the Python implementation.
    /// </remarks>
    [Fact]
    public void ReasoningIsNotAddedToTheCount()
    {
        Write("a.jsonl", Turn(100, 500, 600, reasoning: 400));

        var (tokens, _, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(600, tokens);
    }

    // ---------------------------------------------------------------- duplication

    /// <summary>
    /// An adjacent identical reading with an unchanged running total is a re-emitted turn.
    /// </summary>
    [Fact]
    public void AnAdjacentRepeatedReadingIsCountedOnce()
    {
        var line = Turn(100, 20, 120);
        Write("a.jsonl", line, line);

        var (tokens, turns, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(120, tokens);
        Assert.Equal(1, turns);
    }

    /// <summary>
    /// The same numbers with a <i>changed</i> running total are two real turns.
    /// </summary>
    /// <remarks>
    /// Recognising duplicates by running total alone over-removes: two different turns can land
    /// on the same reading, and a resumed session re-emits its turns adjacently.
    /// </remarks>
    [Fact]
    public void TheSameNumbersWithADifferentRunningTotalBothCount()
    {
        Write("a.jsonl", Turn(100, 20, 120), Turn(100, 20, 121));

        var (tokens, turns, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(240, tokens);
        Assert.Equal(2, turns);
    }

    /// <summary>A repeat that is not adjacent is a separate turn.</summary>
    [Fact]
    public void ARepeatWithAnotherTurnBetweenThemBothCount()
    {
        Write("a.jsonl", Turn(100, 20, 120), Turn(5, 1, 126), Turn(100, 20, 120));

        var (_, turns, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(3, turns);
    }

    // ---------------------------------------------------------------- robustness

    [Fact]
    public void ATruncatedFinalLineIsSkippedRatherThanLosingTheFile()
    {
        Write("a.jsonl", Turn(100, 20, 120), """{"timestamp":"2026-10-11T12:00:00Z","payl""");

        var (tokens, turns, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(120, tokens);
        Assert.Equal(1, turns);
    }

    [Fact]
    public void LinesWithoutUsageAreIgnored()
    {
        Write("a.jsonl", """{"timestamp":"2026-10-11T12:00:00Z","type":"session_meta"}""",
            Turn(100, 20, 120));

        var (tokens, _, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(120, tokens);
    }

    /// <summary>A record with no usable timestamp is dropped, since the day is what is counted.</summary>
    [Fact]
    public void ARecordWithoutATimestampIsDropped()
    {
        Write("a.jsonl", """
        {"type":"event_msg","payload":{"info":{"last_token_usage":
         {"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}
        """);

        var (tokens, turns, _) = SessionUsage.ReadFile(
            Path.Combine(_root, "sessions", "2026", "10", "11", "a.jsonl"));

        Assert.Equal(0, tokens);
        Assert.Equal(0, turns);
    }

    [Fact]
    public void AMissingSessionsRootYieldsNoFiles()
        => Assert.Empty(SessionUsage.EnumerateSessionFiles(
            new RunwayPaths(_root, Path.Combine(_root, "codex-runway"))));

    // ---------------------------------------------------------------- aggregation

    [Fact]
    public void FilesAreAggregatedAcrossSessions()
    {
        Write("a.jsonl", Turn(100, 20, 120));
        Write("b.jsonl", Turn(200, 30, 350));

        var summary = SessionUsage.Summarise(Paths, DateTimeOffset.Parse("2026-10-11T18:00:00Z"));

        Assert.Equal(350, summary.TotalTokens);
        Assert.Equal(2, summary.SessionCount);
    }

    /// <summary>Each turn lands on its own local day, so a day's figure can be charted.</summary>
    [Fact]
    public void TurnsAreGroupedByDay()
    {
        Write("a.jsonl",
            Turn(100, 20, 120, timestamp: "2026-10-11T12:00:00Z"),
            Turn(50, 10, 180, timestamp: "2026-10-10T12:00:00Z"));

        var summary = SessionUsage.Summarise(Paths, DateTimeOffset.Parse("2026-10-11T18:00:00Z"));

        Assert.Equal(2, summary.Daily.Count);
        Assert.Equal(120, summary.Daily[new DateOnly(2026, 10, 11)]);
        Assert.Equal(60, summary.Daily[new DateOnly(2026, 10, 10)]);
    }

    [Theory]
    [InlineData(999, "999")]
    [InlineData(1500, "1.5K")]
    [InlineData(1_500_000, "1.5M")]
    [InlineData(12_048_891_408, "12.05B")]
    public void CountsAreFormattedCompactly(long tokens, string expected)
        => Assert.Equal(expected, SessionUsage.Format(tokens));
}
