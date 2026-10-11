using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexRunway.Core;

/// <summary>What the status service says about today's reset.</summary>
public enum ResetTodayVerdict
{
    /// <summary>A completed reset was recorded today.</summary>
    Yes,

    /// <summary>No completed reset was recorded today.</summary>
    No,

    /// <summary>The question could not be answered; <see cref="ResetTodayReport.Problem"/> says why.</summary>
    Unknown,
}

/// <summary>One reset the community observed.</summary>
public sealed record ResetEvent
{
    public required string Kind { get; init; }

    public string? ResetType { get; init; }

    public DateTimeOffset? AnnouncedAt { get; init; }

    public DateTimeOffset? EffectiveAt { get; init; }

    public double Confidence { get; init; }

    public string? Text { get; init; }

    public string? Url { get; init; }

    /// <summary>
    /// When the reset took effect.
    /// </summary>
    /// <remarks>
    /// <c>effectiveAt</c> is the precise moment but is frequently absent — a reset is often
    /// announced before a time is known — so the announcement time is the fallback. Using only
    /// <c>effectiveAt</c> would report "no reset today" on a day when one plainly happened.
    /// </remarks>
    public DateTimeOffset? When => EffectiveAt ?? AnnouncedAt;

    public bool IsGlobal => string.Equals(ResetType, "global", StringComparison.OrdinalIgnoreCase);
}

/// <summary>The verdict plus what it was based on.</summary>
public sealed record ResetTodayReport
{
    public ResetTodayVerdict Verdict { get; init; } = ResetTodayVerdict.Unknown;

    public double? Confidence { get; init; }

    public ResetEvent? Event { get; init; }

    public DateTimeOffset? GeneratedAt { get; init; }

    public DateTimeOffset? LastCheckAt { get; init; }

    public string? MonitorStatus { get; init; }

    /// <summary>A stable code describing why the verdict is unknown, or null.</summary>
    public string? Problem { get; init; }

    public int? ConfidencePercent
        => Confidence is { } value ? (int)Math.Round(value * 100) : null;

    public static ResetTodayReport Unknown(string problem)
        => new() { Verdict = ResetTodayVerdict.Unknown, Problem = problem };
}

/// <summary>
/// Answers "did the quota reset today?" from the public status service.
/// </summary>
/// <remarks>
/// <para>
/// Three states rather than two. "Unknown" must not look like "no": a user deciding whether to
/// keep working needs to tell "no reset happened" from "this could not be checked", and
/// collapsing them answers a question the data did not.
/// </para>
/// <para>
/// Failing to reach the service is reported as a reason, never as an exception, because this
/// feeds a panel — a panel that cannot render because a network call failed is worse than one
/// that says it does not know.
/// </para>
/// </remarks>
public static class ResetTodayStatus
{
    /// <summary>
    /// The status endpoint.
    /// </summary>
    /// <remarks>
    /// The canonical host redirects here, so the redirect is followed rather than hard-coding the
    /// current host — it has already moved once.
    /// </remarks>
    public const string StatusUrl = "https://www.codexrunway.com/api/status.json";

    /// <summary>The schema this build understands.</summary>
    /// <remarks>
    /// A newer schema is reported as unknown rather than guessed at: a renamed field would
    /// otherwise read as "no reset happened".
    /// </remarks>
    public const int SupportedSchemaVersion = 1;

    /// <summary>Parses the service's payload into the pieces the panel needs.</summary>
    public static (
        int? SchemaVersion,
        DateTimeOffset? GeneratedAt,
        DateTimeOffset? LastCheckAt,
        string? MonitorStatus,
        IReadOnlyList<ResetEvent> Events) Parse(string json)
    {
        JsonObject root;
        try
        {
            var node = JsonNode.Parse(json);
            if (node is not JsonObject obj)
            {
                return (null, null, null, null, Array.Empty<ResetEvent>());
            }

            root = obj;
            _ = root.Count;
        }
        catch (Exception error) when (error is JsonException or ArgumentException)
        {
            return (null, null, null, null, Array.Empty<ResetEvent>());
        }

        var monitor = root["monitor"] as JsonObject;
        var events = new List<ResetEvent>();

        if (root["events"] is JsonArray array)
        {
            foreach (var item in array)
            {
                if (item is not JsonObject entry || Str(entry, "kind") is not { } kind)
                {
                    continue;
                }

                var source = entry["source"] as JsonObject;
                events.Add(new ResetEvent
                {
                    Kind = kind,
                    ResetType = Str(entry, "resetType"),
                    AnnouncedAt = Time(entry["announcedAt"]),
                    EffectiveAt = Time(entry["effectiveAt"]),
                    Confidence = Number(entry["confidence"]) ?? 0,
                    Text = Str(entry, "text"),
                    Url = source is null ? null : Str(source, "url"),
                });
            }
        }

        return (
            Integer(root["schemaVersion"]),
            Time(root["generatedAt"]),
            Time(root["lastSuccessfulCheckAt"]),
            monitor is null ? null : Str(monitor, "status"),
            events);
    }

    /// <summary>
    /// Decides the verdict for the local day containing <paramref name="now"/>.
    /// </summary>
    /// <remarks>
    /// "Today" is the user's own day. A reset at 23:40 local time is a reset today even though it
    /// is already tomorrow in UTC, and computing the day in UTC would tell that user the opposite.
    /// </remarks>
    public static ResetTodayReport Evaluate(string json, DateTimeOffset now)
    {
        var (schema, generatedAt, lastCheckAt, monitorStatus, events) = Parse(json);

        var report = new ResetTodayReport
        {
            GeneratedAt = generatedAt,
            LastCheckAt = lastCheckAt,
            MonitorStatus = monitorStatus,
        };

        if (schema != SupportedSchemaVersion)
        {
            return report with { Problem = "unsupported_schema" };
        }

        if (!string.Equals(monitorStatus, "ok", StringComparison.OrdinalIgnoreCase))
        {
            // The upstream monitor is itself unsure. Answering "no" here would invent an answer it
            // explicitly declined to give.
            return report with { Problem = "monitor_not_ok" };
        }

        var localToday = now.ToLocalTime().Date;
        var completedToday = events
            .Where(e => string.Equals(e.Kind, "reset_completed", StringComparison.Ordinal))
            .Where(e => e.When is { } when && when.ToLocalTime().Date == localToday)
            .ToArray();

        if (completedToday.Length == 0)
        {
            return report with { Verdict = ResetTodayVerdict.No };
        }

        // The highest-confidence announcement is the one the community treated as authoritative
        // when several are recorded for the same day.
        var best = completedToday.OrderByDescending(e => e.Confidence).First();
        return report with
        {
            Verdict = ResetTodayVerdict.Yes,
            Confidence = best.Confidence,
            Event = best,
        };
    }

    /// <summary>Fetches and evaluates.</summary>
    public static async Task<ResetTodayReport> CheckAsync(
        DateTimeOffset? now = null,
        HttpClient? client = null,
        CancellationToken cancellationToken = default)
    {
        var reference = now ?? DateTimeOffset.Now;
        var ownsClient = client is null;
        var http = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

        try
        {
            if (!http.DefaultRequestHeaders.UserAgent.Any())
            {
                // Some hosts reject the default agent.
                http.DefaultRequestHeaders.UserAgent.ParseAdd("CodexRunway/1.0");
            }

            var json = await http.GetStringAsync(StatusUrl, cancellationToken).ConfigureAwait(false);
            return Evaluate(json, reference);
        }
        catch (HttpRequestException error)
        {
            // A refused request and an unreachable host are different situations: the first is not
            // fixed by checking a network connection.
            return ResetTodayReport.Unknown(
                error.StatusCode is { } status ? $"http_{(int)status}" : "network_unreachable");
        }
        catch (TaskCanceledException)
        {
            return ResetTodayReport.Unknown("timeout");
        }
        catch (Exception error) when (error is UriFormatException or InvalidOperationException)
        {
            return ResetTodayReport.Unknown("invalid_response");
        }
        finally
        {
            if (ownsClient)
            {
                http.Dispose();
            }
        }
    }

    /// <summary>The message code for an unknown verdict, so the view resolves the wording.</summary>
    public static string ProblemCode(ResetTodayReport report) => report.Problem switch
    {
        "http_403" => "reset_http_403",
        "timeout" => "reset_timeout",
        "network_unreachable" => "reset_unreachable",
        "unsupported_schema" => "reset_unsupported_schema",
        "monitor_not_ok" => "reset_monitor_not_ok",
        _ => "reset_unknown",
    };

    private static string? Str(JsonObject node, string key)
        => node[key] is { } value && value.GetValueKind() == JsonValueKind.String
            ? value.GetValue<string>()
            : null;

    private static double? Number(JsonNode? node)
    {
        if (node is null)
        {
            return null;
        }

        return node.GetValueKind() switch
        {
            JsonValueKind.Number => node.GetValue<double>(),
            JsonValueKind.String => double.TryParse(
                node.GetValue<string>(),
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture,
                out var parsed) ? parsed : null,
            _ => null,
        };
    }

    private static int? Integer(JsonNode? node)
    {
        var value = Number(node);
        return value is null ? null : (int)Math.Round(value.Value);
    }

    private static DateTimeOffset? Time(JsonNode? node)
        => node is { } value && value.GetValueKind() == JsonValueKind.String
            ? RunwayDates.Parse(value.GetValue<string>())
            : null;
}
