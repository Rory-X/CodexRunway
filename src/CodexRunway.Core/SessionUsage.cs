using System.Globalization;
using System.Text.Json;

namespace CodexRunway.Core;

/// <summary>Token use for one day.</summary>
public sealed record DailyUsage
{
    public required DateOnly Day { get; init; }

    public long Tokens { get; init; }

    public int Turns { get; init; }
}

/// <summary>What the session logs add up to.</summary>
public sealed record UsageSummary
{
    public long TotalTokens { get; init; }

    public long TodayTokens { get; init; }

    public long WeekTokens { get; init; }

    public int TurnCount { get; init; }

    public int SessionCount { get; init; }

    /// <summary>Tokens per local day, keyed by date.</summary>
    public IReadOnlyDictionary<DateOnly, long> Daily { get; init; }
        = new Dictionary<DateOnly, long>();

    public static UsageSummary Empty { get; } = new();
}

/// <summary>
/// Sums the token use recorded in Codex's session logs.
/// </summary>
/// <remarks>
/// <para>
/// The logs are NDJSON under <c>&lt;codex home&gt;/sessions/YYYY/MM/DD/</c>, and only
/// <c>event_msg</c> records of type <c>token_count</c> carry usage. Each carries
/// <c>last_token_usage</c> for the turn and <c>total_token_usage</c> for the session so far.
/// </para>
/// <para>
/// <b>Only <c>last_token_usage</c> is summed.</b> The two run in parallel and adding both
/// double-counts; the running total is read solely to detect a turn that was re-emitted, which
/// happens when a session is resumed. Summing turns directly rather than differencing the
/// running total is also what the macOS build does, and the two must agree because they read the
/// same files.
/// </para>
/// <para>
/// <c>reasoning_output_tokens</c> is a <i>subset</i> of <c>output_tokens</c>, not an addition to
/// it — verified against the logs, where <c>total == input + output</c> holds exactly. Adding
/// reasoning would inflate every figure by the reasoning share.
/// </para>
/// </remarks>
public static class SessionUsage
{
    /// <summary>The directory the logs live under.</summary>
    public static string SessionsRoot(RunwayPaths paths)
        => Path.Combine(paths.CodexHome, "sessions");

    /// <summary>Every <c>*.jsonl</c> file under the sessions root.</summary>
    /// <remarks>
    /// A directory named <c>*.jsonl</c> is skipped rather than enumerated as a file: passing one
    /// to a reader throws, and one bad entry would otherwise lose the whole scan.
    /// </remarks>
    public static IReadOnlyList<string> EnumerateSessionFiles(RunwayPaths paths)
    {
        var root = SessionsRoot(paths);
        if (!Directory.Exists(root))
        {
            return Array.Empty<string>();
        }

        var files = new List<string>();
        try
        {
            foreach (var file in Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories))
            {
                files.Add(file);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A partial scan is more useful than none: the figures are for a chart, not a ledger.
        }

        return files;
    }

    /// <summary>Reads one session file and adds its turns.</summary>
    /// <remarks>
    /// A line that fails to parse is skipped rather than abandoning the file. The logs are
    /// append-only and can be truncated mid-write by a crash, which would otherwise discard
    /// everything the file did contain.
    /// </remarks>
    public static (long Tokens, int Turns, Dictionary<DateOnly, long> Daily)
        ReadFile(string path)
    {
        long tokens = 0;
        var turns = 0;
        var daily = new Dictionary<DateOnly, long>();

        // The previous reading, to spot a turn the log recorded twice. A resumed session re-emits
        // its turns adjacently, so only an immediately-preceding match counts.
        string? previousReading = null;
        long? previousTotal = null;

        IEnumerable<string> lines;
        try
        {
            lines = File.ReadLines(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return (0, 0, daily);
        }

        foreach (var line in lines)
        {
            // A cheap pre-filter before parsing: most lines in these files are not token counts,
            // and the files total gigabytes.
            if (line.IndexOf("last_token_usage", StringComparison.Ordinal) < 0
                || line.IndexOf("\"info\"", StringComparison.Ordinal) < 0)
            {
                continue;
            }

            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;

                if (!root.TryGetProperty("payload", out var payload)
                    || !payload.TryGetProperty("info", out var info)
                    || !info.TryGetProperty("last_token_usage", out var last))
                {
                    continue;
                }

                // A record with no readable timestamp is dropped rather than guessed at: the day
                // it belongs to is the one thing being counted.
                if (ReadTimestamp(root) is not { } timestamp)
                {
                    continue;
                }

                // The turn's own numbers, which identify a repeated reading and give the count.
                // Reason is read because two turns can share input and output while differing in
                // reasoning.
                var input = ReadLong(last, "input_tokens");
                var output = ReadLong(last, "output_tokens");
                var reasoning = ReadLong(last, "reasoning_output_tokens");
                var cached = ReadLong(last, "cached_input_tokens");

                // A reading of nothing at all is noise, not a turn.
                if (input == 0 && output == 0 && reasoning == 0)
                {
                    continue;
                }

                var reading = $"{input}/{output}/{reasoning}/{cached}";
                long? runningTotal = info.TryGetProperty("total_token_usage", out var total)
                    && total.TryGetProperty("total_tokens", out var totalValue)
                    && totalValue.ValueKind == JsonValueKind.Number
                    && totalValue.TryGetInt64(out var parsedTotal)
                        ? parsedTotal
                        : null;

                // Only an adjacent match with an unchanged running total is a re-emitted turn.
                if (reading == previousReading
                    && runningTotal is not null
                    && runningTotal == previousTotal)
                {
                    continue;
                }

                previousReading = reading;
                previousTotal = runningTotal;

                // Counted as input + output, not from the record's own total_tokens. The two
                // differ on about 1,500 records in this log — every one of them a record with
                // input and output at zero but a non-zero total — and summing the field instead
                // over-counted by roughly 108M tokens against the reference implementation.
                // reasoning_output_tokens is deliberately absent: it breaks output down rather
                // than adding to it.
                var turnTokens = input + output;
                if (turnTokens <= 0)
                {
                    continue;
                }

                var day = DateOnly.FromDateTime(timestamp.ToLocalTime().DateTime);
                tokens += turnTokens;
                turns++;
                daily[day] = daily.TryGetValue(day, out var existing) ? existing + turnTokens : turnTokens;
            }
            catch (JsonException)
            {
                // A truncated final line is expected after an unclean shutdown.
            }
        }

        return (tokens, turns, daily);
    }

    /// <summary>Scans every session and totals it.</summary>
    public static UsageSummary Summarise(RunwayPaths paths, DateTimeOffset now)
    {
        var files = EnumerateSessionFiles(paths);
        var daily = new Dictionary<DateOnly, long>();
        long total = 0;
        var turns = 0;

        foreach (var file in files)
        {
            var (fileTokens, fileTurns, fileDaily) = ReadFile(file);
            total += fileTokens;
            turns += fileTurns;

            foreach (var (day, value) in fileDaily)
            {
                daily[day] = daily.TryGetValue(day, out var existing) ? existing + value : value;
            }
        }

        var localNow = now.ToLocalTime();
        var today = DateOnly.FromDateTime(localNow.DateTime);
        var weekStart = today.AddDays(-6);

        return new UsageSummary
        {
            TotalTokens = total,
            TurnCount = turns,
            SessionCount = files.Count,
            Daily = daily,
            TodayTokens = daily.TryGetValue(today, out var todayTokens) ? todayTokens : 0,
            WeekTokens = daily.Where(p => p.Key >= weekStart && p.Key <= today).Sum(p => p.Value),
        };
    }

    /// <summary>A compact token count: 1.2M rather than 1234567.</summary>
    public static string Format(long tokens)
    {
        if (tokens >= 1_000_000_000)
        {
            return $"{tokens / 1_000_000_000.0:0.00}B";
        }

        if (tokens >= 1_000_000)
        {
            return $"{tokens / 1_000_000.0:0.0}M";
        }

        return tokens >= 1_000 ? $"{tokens / 1_000.0:0.0}K" : tokens.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// The moment a record was written.
    /// </summary>
    /// <remarks>
    /// Taken from the record's own timestamp, not the file path: the path says when the session
    /// started, and a session running past midnight would otherwise have its later turns
    /// attributed to the previous day.
    /// </remarks>
    private static DateTimeOffset? ReadTimestamp(JsonElement root)
        => root.TryGetProperty("timestamp", out var stamp)
            && stamp.ValueKind == JsonValueKind.String
            && RunwayDates.Parse(stamp.GetString()) is { } parsed
                ? parsed
                : null;

    private static long ReadLong(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt64(out var parsed)
                ? parsed
                : 0;
}
