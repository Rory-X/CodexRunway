using CodexRunway.Presentation;
using Xunit;

namespace CodexRunway.Presentation.Tests;

/// <summary>
/// Deciding whether a newer release exists.
/// </summary>
/// <remarks>
/// The check reads a feed published by someone else, so the parsing has to tolerate what a tag
/// actually looks like in the wild and fail in the direction that does not nag. A comparison
/// that reported an update for an unreadable tag would prompt a user who is already current; one
/// that reported "current" merely misses a notification.
/// </remarks>
public class UpdateCheckTests
{
    // ---------------------------------------------------------------- feed parsing

    private const string FeedWithOneRelease = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Release notes from CodexRunway</title>
      <entry>
        <id>tag:github.com,2008:Repository/1/v1.4.0</id>
        <link type="text/html" rel="alternate" href="https://github.com/Rory-X/CodexRunway/releases/tag/v1.4.0"/>
        <title>v1.4.0</title>
        <updated>2026-10-11T08:11:34Z</updated>
      </entry>
    </feed>
    """;

    [Fact]
    public void AReleaseIsReadFromTheFeed()
    {
        var (version, url, name, published) = UpdateCheck.ParseFeed(FeedWithOneRelease);

        Assert.Equal("1.4.0", version);
        Assert.Equal("https://github.com/Rory-X/CodexRunway/releases/tag/v1.4.0", url);
        Assert.Equal("v1.4.0", name);
        Assert.Equal(DateTimeOffset.Parse("2026-10-11T08:11:34Z"), published);
    }

    /// <summary>
    /// The feed lists newest first, so reading the last entry would report an old release as the
    /// latest and tell a current user they are behind.
    /// </summary>
    [Fact]
    public void TheNewestEntryIsTheOneRead()
    {
        const string twoEntries = """
        <feed><entry>
          <id>tag:.../v2.0.0</id><title>v2.0.0</title><updated>2026-10-11T00:00:00Z</updated>
        </entry><entry>
          <id>tag:.../v1.0.0</id><title>v1.0.0</title><updated>2026-01-01T00:00:00Z</updated>
        </entry></feed>
        """;

        Assert.Equal("2.0.0", UpdateCheck.ParseFeed(twoEntries).Version);
    }

    [Theory]
    [InlineData("v1.2.3", "1.2.3")]
    [InlineData("1.2.3", "1.2.3")]
    [InlineData("release-1.2.3", "1.2.3")]
    [InlineData("codexrunway-v1.2.3", "1.2.3")]
    [InlineData("1.2.3-beta.1", "1.2.3-beta.1")]
    [InlineData("v2.0", "2.0")]
    public void ATagIsReducedToItsVersion(string tag, string expected)
        => Assert.Equal(expected, UpdateCheck.NormalizeTag(tag));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("nightly")]
    public void ATagWithNoVersionYieldsNothing(string tag)
        => Assert.Null(UpdateCheck.NormalizeTag(tag));

    // ---------------------------------------------------------------- comparison

    [Theory]
    [InlineData("1.1.0", "1.0.0", true)]
    [InlineData("1.0.0", "1.0.0", false)]
    [InlineData("1.0.0", "1.1.0", false)]
    [InlineData("2.0.0", "1.99.99", true)]
    [InlineData("1.0.1", "1.0.0", true)]
    public void VersionsCompareNumerically(string candidate, string current, bool expected)
        => Assert.Equal(expected, UpdateCheck.IsNewer(candidate, current));

    /// <summary>
    /// Compared as numbers, not text: as strings "1.10.0" sorts below "1.9.0", so a user on 1.9
    /// would never be told about 1.10.
    /// </summary>
    [Fact]
    public void AVersionWithATwoDigitPartIsNotComparedAsText()
    {
        Assert.True(UpdateCheck.IsNewer("1.10.0", "1.9.0"));
        Assert.False(UpdateCheck.IsNewer("1.9.0", "1.10.0"));
    }

    /// <summary>A pre-release is older than its own release, which is the usual convention.</summary>
    [Fact]
    public void APreReleaseIsOlderThanItsRelease()
    {
        Assert.False(UpdateCheck.IsNewer("1.0.0-beta", "1.0.0"));
        Assert.True(UpdateCheck.IsNewer("1.0.0", "1.0.0-beta"));
    }

    [Fact]
    public void ABuildSuffixIsIgnored()
    {
        Assert.False(UpdateCheck.IsNewer("1.0.0+build7", "1.0.0"));
        Assert.True(UpdateCheck.IsNewer("1.0.1+build7", "1.0.0"));
    }

    /// <summary>
    /// An unparsable tag must not be reported as an update: prompting someone who is already
    /// current is the failure a user notices and resents.
    /// </summary>
    [Theory]
    [InlineData("garbage")]
    [InlineData("")]
    [InlineData(null)]
    public void AnUnreadableVersionIsNotTreatedAsNewer(string? candidate)
        => Assert.False(UpdateCheck.IsNewer(candidate, "1.0.0"));

    [Fact]
    public void AnUnreadableCurrentVersionIsNotTreatedAsBehind()
        => Assert.False(UpdateCheck.IsNewer("9.9.9", null));

    // ---------------------------------------------------------------- outcomes

    [Fact]
    public void ANewerReleaseIsReportedAsAvailable()
    {
        var result = UpdateCheck.Evaluate(FeedWithOneRelease, "1.0.0");

        Assert.Equal(UpdateStatus.Available, result.Status);
        Assert.True(result.HasUpdate);
        Assert.Equal("1.4.0", result.LatestVersion);
    }

    [Fact]
    public void TheRunningVersionIsReportedAsUpToDate()
    {
        var result = UpdateCheck.Evaluate(FeedWithOneRelease, "1.4.0");

        Assert.Equal(UpdateStatus.UpToDate, result.Status);
        Assert.False(result.HasUpdate);
        // The latest version is still reported, so the panel can say what it compared against.
        Assert.Equal("1.4.0", result.LatestVersion);
    }

    /// <summary>
    /// An empty feed means nothing has been published, which is a normal state for a young
    /// repository rather than a failure to check.
    /// </summary>
    [Fact]
    public void AnEmptyFeedIsNoReleasesRatherThanAFailure()
    {
        const string emptyFeed = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Release notes from CodexRunway</title>
          <updated>2026-10-11T08:11:34Z</updated>
        </feed>
        """;

        var result = UpdateCheck.Evaluate(emptyFeed, "1.0.0");

        Assert.Equal(UpdateStatus.NoReleases, result.Status);
        Assert.Null(result.Reason);
    }

    [Fact]
    public void AnEmptyResponseIsAFailure()
    {
        var result = UpdateCheck.Evaluate(null, "1.0.0");

        Assert.Equal(UpdateStatus.Failed, result.Status);
        Assert.Equal("empty_response", result.Reason);
    }

    /// <summary>An entry whose tag cannot be read is a failure, not "no releases".</summary>
    [Fact]
    public void AnEntryWithAnUnreadableTagIsReportedAsAFailure()
    {
        const string badFeed = """
        <feed><entry><id>nightly</id><title>nightly</title></entry></feed>
        """;

        var result = UpdateCheck.Evaluate(badFeed, "1.0.0");

        Assert.Equal(UpdateStatus.Failed, result.Status);
        Assert.Equal("unreadable_tag", result.Reason);
    }

    // ---------------------------------------------------------------- endpoint

    /// <summary>
    /// The feed, not the REST API: the unauthenticated API allows 60 requests an hour per
    /// address, shared by every process on the machine, and a check that answers "rate limited"
    /// is worse than useless. The feed carries the same three values without a quota.
    /// </summary>
    [Fact]
    public void TheCheckUsesTheFeedRatherThanTheApi()
    {
        Assert.EndsWith("/releases.atom", UpdateCheck.ReleasesFeedUrl, StringComparison.Ordinal);
        Assert.DoesNotContain("api.github.com", UpdateCheck.ReleasesFeedUrl, StringComparison.Ordinal);
        Assert.StartsWith(UpdateCheck.RepositoryUrl, UpdateCheck.ReleasesFeedUrl, StringComparison.Ordinal);
    }

    [Fact]
    public void TheCurrentVersionLooksLikeAVersion()
    {
        var version = UpdateCheck.CurrentVersion;

        Assert.NotNull(UpdateCheck.ParseVersion(version));
        Assert.Matches(@"^\d+\.\d+\.\d+", version);
    }
}
