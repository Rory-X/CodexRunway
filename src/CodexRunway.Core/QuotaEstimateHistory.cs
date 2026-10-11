using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexRunway.Core;

/// <summary>One recorded allowance estimate for one billing cycle.</summary>
public sealed record EstimateSample
{
    public DateOnly? CycleStart { get; init; }

    public double? EstimatedCredits { get; init; }

    public double? UsedCredits { get; init; }

    public int? UsedPercent { get; init; }

    public DateTimeOffset? RecordedAt { get; init; }

    /// <summary>
    /// Whether the figure was derived from enough of the cycle to be worth showing.
    /// </summary>
    /// <remarks>
    /// The figure is an extrapolation — credits used divided by the fraction of the cycle they
    /// represent — and at a low fraction that division amplifies the rounding in the percentage.
    /// Measured on this machine: one account's completed cycle gave 70M credits where its
    /// 2%-sampled cycle gave 9.8 billion, a factor of 140 from the same arithmetic on a smaller
    /// sample.
    /// <para>
    /// The threshold is 25%. Below it, the divisor is dominated by the rounding of a
    /// whole-number percentage — a reading of 2% means anywhere from roughly 1.5% to 2.5%, a
    /// swing of a third.
    /// </para>
    /// </remarks>
    public bool IsReliable => UsedPercent is >= 25;

    /// <summary>Whether the cycle ran to completion, which is when the figure is firmest.</summary>
    public bool IsComplete => UsedPercent is >= 100;
}

/// <summary>Every estimate recorded for one account.</summary>
public sealed record AccountEstimate
{
    public required string AccountId { get; init; }

    public IReadOnlyList<EstimateSample> Samples { get; init; } = Array.Empty<EstimateSample>();

    /// <summary>Samples derived from enough of a cycle to trust.</summary>
    public IReadOnlyList<EstimateSample> Reliable
        => Samples.Where(s => s.IsReliable).ToArray();

    /// <summary>
    /// The sample to headline: a completed cycle, else a reliable one, else the newest.
    /// </summary>
    /// <remarks>
    /// Preferring a completed cycle over a newer partial one is deliberate. A cycle that ran to
    /// 100% yields a figure from the whole allowance, while a fresh cycle sampled early can be
    /// off by an order of magnitude — and recency alone would surface that one.
    /// <para>
    /// Falling back to unreliable samples rather than hiding the account keeps a row from looking
    /// as though it has no data when it merely has none worth trusting; the caller reports which
    /// of the three it got.
    /// </para>
    /// </remarks>
    public EstimateSample? Best
    {
        get
        {
            if (Samples.Count == 0)
            {
                return null;
            }

            foreach (var pool in new[]
            {
                Samples.Where(s => s.IsComplete).ToArray(),
                Reliable.ToArray(),
                Samples.ToArray(),
            })
            {
                if (pool.Length > 0)
                {
                    return pool.OrderByDescending(
                        s => s.RecordedAt ?? DateTimeOffset.MinValue).First();
                }
            }

            return null;
        }
    }

    /// <summary>Whether the headlined figure came from most of a cycle.</summary>
    public bool BestIsTrustworthy => Best?.IsReliable == true;

    /// <summary>Whether the headlined figure came from a completed cycle.</summary>
    public bool BestIsComplete => Best?.IsComplete == true;
}

/// <summary>
/// Reads the allowance history the app records per billing cycle.
/// </summary>
/// <remarks>
/// <para>
/// The file is shared with the macOS build and is only read here. Its keys are not account ids:
/// an API-key account is filed as <c>id:&lt;accountId&gt;</c> while a subscription account is
/// filed as <c>oauth:user:&lt;userId&gt;|account:&lt;accountId&gt;</c>. Both spellings have to be
/// rebuilt when looking an account up, or half the accounts silently report no estimate.
/// </para>
/// <para>
/// Reading is lenient throughout. A malformed sample is skipped rather than failing the file,
/// and a missing history returns empty rather than throwing, because this feeds a panel that is
/// still useful without it.
/// </para>
/// </remarks>
public static class QuotaEstimateHistory
{
    /// <summary>
    /// The history file for a layout.
    /// </summary>
    /// <remarks>
    /// It sits directly under the app home rather than under <c>accounts/</c>, which is why this
    /// does not come from <see cref="RunwayPaths"/>'s account helpers.
    /// </remarks>
    public static string PathFor(RunwayPaths paths)
        => Path.Combine(paths.AppHome, "quota-estimate-history.json");

    /// <summary>
    /// The key an account's history is filed under.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Mirrors the macOS build exactly, and that includes a detail that is easy to get wrong: the
    /// <c>account:</c> segment is the <i>workspace</i> id, not the managed account's own id. On
    /// this machine every subscription account has a different value for the two — the row id is
    /// a hash such as <c>oauth-ecec8a367a2d5897</c> while the workspace id is a UUID — so passing
    /// the wrong one silently matched one account out of eight.
    /// </para>
    /// <para>
    /// Guessing wrong here does not throw. It reports no estimate, which is the quiet kind of
    /// wrong answer a user is least able to diagnose.
    /// </para>
    /// </remarks>
    internal static string HistoryKey(string accountId, bool isApiKey, string? userId, string? workspaceId)
    {
        if (isApiKey || string.IsNullOrEmpty(userId))
        {
            return $"id:{accountId}";
        }

        // Fall back to the row id only when the index carries no workspace id; a subscription
        // account always has one in practice.
        return $"oauth:user:{userId}|account:{workspaceId ?? accountId}";
    }

    /// <summary>Loads every account's estimate, keyed by account id.</summary>
    public static IReadOnlyDictionary<string, AccountEstimate> Load(RunwayPaths paths)
    {
        var path = PathFor(paths);
        if (!File.Exists(path))
        {
            return new Dictionary<string, AccountEstimate>(StringComparer.Ordinal);
        }

        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new Dictionary<string, AccountEstimate>(StringComparer.Ordinal);
        }

        return Parse(text);
    }

    /// <summary>Parses the history document.</summary>
    public static IReadOnlyDictionary<string, AccountEstimate> Parse(string json)
    {
        var result = new Dictionary<string, AccountEstimate>(StringComparer.Ordinal);

        JsonObject root;
        try
        {
            var node = JsonNode.Parse(json);
            if (node is not JsonObject obj)
            {
                return result;
            }

            root = obj;
            _ = root.Count;
        }
        catch (Exception error) when (error is JsonException or ArgumentException)
        {
            // ArgumentException is what JsonObject throws for a duplicate key, and it is not a
            // JsonException — the same trap that bit the credential parser.
            return result;
        }

        if (root["accounts"] is not JsonObject accounts)
        {
            return result;
        }

        foreach (var pair in accounts)
        {
            if (pair.Value is not JsonArray array)
            {
                continue;
            }

            var samples = new List<EstimateSample>();
            foreach (var item in array)
            {
                if (item is JsonObject sample && TryParseSample(sample, out var parsed))
                {
                    samples.Add(parsed);
                }
            }

            if (samples.Count > 0)
            {
                // Stored under the history key; the caller maps it back to an account id.
                result[pair.Key] = new AccountEstimate { AccountId = pair.Key, Samples = samples };
            }
        }

        return result;
    }

    /// <summary>
    /// Re-keys a parsed history by account id.
    /// </summary>
    /// <remarks>
    /// Separate from <see cref="Parse"/> because the mapping needs the account index, which is a
    /// different file. A key whose account no longer exists is dropped rather than surfaced under
    /// its raw storage form, which would show a user an unfamiliar string instead of nothing.
    /// </remarks>
    public static IReadOnlyDictionary<string, AccountEstimate> ByAccountId(
        IReadOnlyDictionary<string, AccountEstimate> byHistoryKey,
        IEnumerable<(string AccountId, bool IsApiKey, string? UserId, string? WorkspaceId)> accounts)
    {
        var lookup = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (accountId, isApiKey, userId, workspaceId) in accounts)
        {
            lookup[HistoryKey(accountId, isApiKey, userId, workspaceId)] = accountId;
        }

        var result = new Dictionary<string, AccountEstimate>(StringComparer.Ordinal);
        foreach (var (key, estimate) in byHistoryKey)
        {
            if (lookup.TryGetValue(key, out var accountId))
            {
                result[accountId] = estimate with { AccountId = accountId };
            }
        }

        return result;
    }

    /// <summary>A compact credit figure; credits are not currency, so no symbol.</summary>
    public static string FormatCredits(double? value) => value switch
    {
        null => "—",
        >= 1_000_000 => $"{value.Value / 1_000_000:0.0}M",
        >= 1_000 => $"{value.Value / 1_000:0.0}K",
        _ => $"{value.Value:0}",
    };

    private static bool TryParseSample(JsonObject node, out EstimateSample sample)
    {
        sample = new EstimateSample
        {
            CycleStart = ParseDate(node["cycleStartDate"]),
            EstimatedCredits = Number(node["estimatedCredits"]),
            UsedCredits = Number(node["usedCredits"]),
            UsedPercent = Integer(node["usedPercent"]),
            RecordedAt = ParseTime(node["recordedAt"]),
        };

        // A sample with no figure at all carries nothing; a percent alone is still useful for
        // deciding whether a cycle completed.
        return sample.EstimatedCredits is not null || sample.UsedPercent is not null;
    }

    private static DateOnly? ParseDate(JsonNode? node)
        => node is { } value && value.GetValueKind() == JsonValueKind.String
            && DateOnly.TryParse(value.GetValue<string>(), out var parsed)
                ? parsed
                : null;

    private static DateTimeOffset? ParseTime(JsonNode? node)
        => node is { } value && value.GetValueKind() == JsonValueKind.String
            ? RunwayDates.Parse(value.GetValue<string>())
            : null;

    /// <summary>
    /// A floating-point field, tolerating a number written as a string.
    /// </summary>
    /// <remarks>
    /// Tolerating the quoted form costs nothing and avoids losing a whole sample to a formatting
    /// choice made by whatever wrote the file.
    /// </remarks>
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
}
