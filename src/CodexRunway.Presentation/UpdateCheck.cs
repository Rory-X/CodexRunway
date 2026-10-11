using System.Globalization;
using System.Text.RegularExpressions;

namespace CodexRunway.Presentation;

/// <summary>How a version check ended.</summary>
public enum UpdateStatus
{
    /// <summary>A newer release exists.</summary>
    Available,

    /// <summary>The running build is the newest published one.</summary>
    UpToDate,

    /// <summary>Nothing has been published yet.</summary>
    NoReleases,

    /// <summary>The check could not complete; <see cref="UpdateCheckResult.Reason"/> says why.</summary>
    Failed,
}

/// <summary>The outcome of checking for a newer release.</summary>
public sealed record UpdateCheckResult(
    UpdateStatus Status,
    string? LatestVersion = null,
    string? ReleaseUrl = null,
    string? ReleaseName = null,
    DateTimeOffset? PublishedAt = null,
    string? Reason = null)
{
    public bool HasUpdate => Status == UpdateStatus.Available;
}

/// <summary>
/// Compares the running version against the newest published release.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why the Atom feed rather than the REST API.</b> An unauthenticated API request is limited
/// to 60 per hour per address, and that budget is shared by every process on the machine —
/// measured here, it dropped by five within a few minutes of ordinary use. A "check for updates"
/// button that answers "rate limited" is worse than one that answers slowly. The Atom feed has
/// no such limit and carries everything needed: the tag, the link and the timestamp.
/// </para>
/// <para>
/// Version parsing is deliberately tolerant. Tags in the wild carry a leading <c>v</c>, a
/// pre-release suffix, or a build number, and a comparison that throws on those would report
/// "up to date" for a malformed tag — the wrong direction to fail in. Anything unparseable is
/// reported as such instead.
/// </para>
/// </remarks>
public static partial class UpdateCheck
{
    /// <summary>The repository whose releases are checked.</summary>
    public const string RepositoryUrl = "https://github.com/Rory-X/CodexRunway";

    /// <summary>
    /// The Atom feed for the repository's releases.
    /// </summary>
    /// <remarks>
    /// Not the API endpoint. See the class remarks for why.
    /// </remarks>
    public const string ReleasesFeedUrl = RepositoryUrl + "/releases.atom";

    /// <summary>The version of the running build.</summary>
    public static string CurrentVersion => typeof(UpdateCheck).Assembly
        .GetName().Version is { } version
            ? $"{version.Major}.{version.Minor}.{version.Build}"
            : "1.0.0";

    /// <summary>Reads the newest entry out of a releases Atom feed.</summary>
    /// <remarks>
    /// Entries are in reverse-chronological order, so the first is the newest. Only the fields
    /// needed are read, by pattern rather than by a full XML parse: the feed is simple and a
    /// parser would add a dependency for three values.
    /// </remarks>
    public static (string? Version, string? Url, string? Name, DateTimeOffset? PublishedAt) ParseFeed(string xml)
    {
        // The first <entry> block is the newest release.
        var entry = FirstEntry().Match(xml);
        if (!entry.Success)
        {
            return (null, null, null, null);
        }

        var block = entry.Value;

        var title = Extract(block, "title");

        // The version is read from the title, not from the id. A feed id is a URI —
        // "tag:github.com,2008:Repository/1/v1.4.0" — and taking the first number out of it
        // yields the year "2008", which then compares as an enormous version. The title is the
        // tag as published.
        var tag = title;

        // The link's own text is the tag path; used only when the title carries no version.
        if (NormalizeTag(tag) is null && Extract(block, "id") is { } id)
        {
            tag = id;
        }

        var url = LinkHref().Match(block) is { Success: true } link ? link.Groups[1].Value : null;
        var updated = Extract(block, "updated");

        DateTimeOffset? published = null;
        if (updated is not null
            && DateTimeOffset.TryParse(updated, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            published = parsed;
        }

        return (NormalizeTag(tag), url, title, published);
    }

    /// <summary>Strips the decorations a release tag usually carries.</summary>
    /// <remarks>
    /// A tag is a label, not a version: <c>v1.2.0</c>, <c>release-1.2.0</c> and <c>1.2.0</c> can
    /// all name the same build. Anything with a pre-release suffix keeps it, because
    /// <c>1.2.0-beta</c> is genuinely older than <c>1.2.0</c>.
    /// </remarks>
    internal static string? NormalizeTag(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag))
        {
            return null;
        }

        // A URI id ends with the tag, so the last path segment is the candidate. Taking the
        // first number from the whole string is what produced "2008" from a github feed id.
        var candidate = tag.Contains(':') && tag.Contains('/')
            ? tag[(tag.LastIndexOf('/') + 1)..]
            : tag;

        var match = VersionNumber().Match(candidate);
        return match.Success ? match.Value : null;
    }

    /// <summary>
    /// Parses a version into comparable parts.
    /// </summary>
    /// <remarks>
    /// Numeric segments are compared as numbers, so 1.10 is newer than 1.9. A pre-release suffix
    /// sorts below its release, which is the convention every package manager uses and the one a
    /// user expects.
    /// </remarks>
    internal static (int[] Numbers, string? PreRelease)? ParseVersion(string? version)
    {
        if (string.IsNullOrWhiteSpace(version))
        {
            return null;
        }

        var text = version.Trim().TrimStart('v', 'V');
        var dash = text.IndexOf('-');
        var preRelease = dash >= 0 ? text[(dash + 1)..] : null;
        var numbersText = dash >= 0 ? text[..dash] : text;

        var parts = numbersText.Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            return null;
        }

        var numbers = new int[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            // A build-metadata suffix such as "0+build7" is not part of the number.
            var piece = parts[i].Split('+')[0];
            if (!int.TryParse(piece, NumberStyles.Integer, CultureInfo.InvariantCulture, out numbers[i]))
            {
                return null;
            }
        }

        return (numbers, preRelease);
    }

    /// <summary>
    /// Whether <paramref name="candidate"/> is newer than <paramref name="current"/>.
    /// </summary>
    /// <remarks>
    /// Returns false when either side cannot be parsed. Reporting an update on an unreadable tag
    /// would nag a user who is already current, and reporting "current" on one is a missed
    /// notification rather than a wrong action — the safer direction for a check nobody can act
    /// on anyway.
    /// </remarks>
    public static bool IsNewer(string? candidate, string? current)
    {
        var left = ParseVersion(candidate);
        var right = ParseVersion(current);
        if (left is null || right is null)
        {
            return false;
        }

        var (leftNumbers, leftPre) = left.Value;
        var (rightNumbers, rightPre) = right.Value;

        var length = Math.Max(leftNumbers.Length, rightNumbers.Length);
        for (var i = 0; i < length; i++)
        {
            var a = i < leftNumbers.Length ? leftNumbers[i] : 0;
            var b = i < rightNumbers.Length ? rightNumbers[i] : 0;
            if (a != b)
            {
                return a > b;
            }
        }

        // Same numbers: a release outranks its own pre-release.
        if (leftPre is null && rightPre is not null)
        {
            return true;
        }

        if (leftPre is not null && rightPre is null)
        {
            return false;
        }

        return false;
    }

    /// <summary>Builds the result from a feed body and the running version.</summary>
    public static UpdateCheckResult Evaluate(string? feedXml, string? currentVersion)
    {
        if (string.IsNullOrWhiteSpace(feedXml))
        {
            return new UpdateCheckResult(UpdateStatus.Failed, Reason: "empty_response");
        }

        var (version, url, name, published) = ParseFeed(feedXml);

        if (version is null)
        {
            // A well-formed feed with no entries means nothing has been released yet, which is a
            // normal state for a young repository rather than a failure.
            return FirstEntry().IsMatch(feedXml)
                ? new UpdateCheckResult(UpdateStatus.Failed, Reason: "unreadable_tag")
                : new UpdateCheckResult(UpdateStatus.NoReleases);
        }

        return IsNewer(version, currentVersion)
            ? new UpdateCheckResult(UpdateStatus.Available, version, url, name, published)
            : new UpdateCheckResult(UpdateStatus.UpToDate, version, url, name, published);
    }

    /// <summary>
    /// Fetches the feed and evaluates it.
    /// </summary>
    /// <remarks>
    /// Kept out of the UI layer so the decision logic stays testable, and bounded in time
    /// because this runs from a button: a check that can hang the window is worse than one that
    /// reports it could not reach the network.
    /// </remarks>
    public static async Task<UpdateCheckResult> CheckAsync(
        string currentVersion,
        HttpClient? client = null,
        CancellationToken cancellationToken = default)
    {
        var ownsClient = client is null;
        var http = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        try
        {
            // GitHub rejects a request with no user agent.
            if (!http.DefaultRequestHeaders.UserAgent.Any())
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("CodexRunway/" + currentVersion);
            }

            var xml = await http.GetStringAsync(ReleasesFeedUrl, cancellationToken)
                .ConfigureAwait(false);
            return Evaluate(xml, currentVersion);
        }
        catch (HttpRequestException)
        {
            return new UpdateCheckResult(UpdateStatus.Failed, Reason: "network_unreachable");
        }
        catch (TaskCanceledException)
        {
            return new UpdateCheckResult(UpdateStatus.Failed, Reason: "timeout");
        }
        catch (Exception error) when (error is UriFormatException or InvalidOperationException)
        {
            return new UpdateCheckResult(UpdateStatus.Failed, Reason: "invalid_response");
        }
        finally
        {
            if (ownsClient)
            {
                http.Dispose();
            }
        }
    }

    /// <summary>The message code for a failed check, so the view resolves the wording.</summary>
    public static string FailureMessageCode(UpdateCheckResult result) => result.Reason switch
    {
        "timeout" => "update_check_timeout",
        "network_unreachable" => "update_check_unreachable",
        "invalid_response" => "update_check_invalid",
        "unreadable_tag" => "update_check_unreadable",
        "empty_response" => "update_check_invalid",
        _ => "update_check_failed",
    };

    private static string? Extract(string xml, string tag)
        => Regex.Match(xml, $"<{tag}[^>]*>(.*?)</{tag}>", RegexOptions.Singleline) is
            { Success: true } match
                ? System.Net.WebUtility.HtmlDecode(match.Groups[1].Value).Trim()
                : null;

    [GeneratedRegex(@"<entry\b.*?</entry>", RegexOptions.Singleline)]
    private static partial Regex FirstEntry();

    [GeneratedRegex(@"<link[^>]*href=""([^""]+)""")]
    private static partial Regex LinkHref();

    [GeneratedRegex(@"\d+(?:\.\d+)*(?:-[0-9A-Za-z.\-]+)?")]
    private static partial Regex VersionNumber();
}
