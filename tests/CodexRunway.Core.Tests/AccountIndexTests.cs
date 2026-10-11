using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Reading and writing the account index.
/// </summary>
/// <remarks>
/// The file is shared with the macOS build, so the contract that matters is "read whatever
/// that side writes, and never delete what this build does not understand". A reader that
/// dropped an unknown field would quietly destroy data the other platform had stored — and a
/// quota cache is a large amount of data to lose.
/// </remarks>
public class AccountIndexTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;

    public AccountIndexTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"idx-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(Path.Combine(_root, ".codex"), Path.Combine(_root, ".codex-runway"));
        Directory.CreateDirectory(_paths.AccountsDirectory);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private const string Minimal = """
    {
      "version" : 1,
      "activeAccountId" : "oauth-1",
      "accounts" : [
        {
          "id" : "oauth-1",
          "sortIndex" : 3,
          "authMode" : "oauth",
          "email" : "me@example.com",
          "displayName" : "me@example.com",
          "planType" : "plus",
          "requiresReauth" : false,
          "createdAt" : "2026-09-28T13:15:30.674Z"
        }
      ]
    }
    """;

    [Fact]
    public void ReadsTheBasics()
    {
        var index = AccountIndexCodec.Decode(Minimal);

        Assert.Equal(1, index.Version);
        Assert.Equal("oauth-1", index.ActiveAccountId);
        Assert.Single(index.Accounts);
        Assert.Equal("me@example.com", index.Accounts[0].Email);
        Assert.Equal("plus", index.Accounts[0].PlanType);
        Assert.Equal(3, index.Accounts[0].SortIndex);
    }

    /// <summary>The macOS build writes fractional seconds here.</summary>
    [Fact]
    public void ReadsAFractionalSecondTimestamp()
    {
        var index = AccountIndexCodec.Decode(Minimal);

        Assert.Equal(
            DateTimeOffset.Parse("2026-09-28T13:15:30.674Z"),
            index.Accounts[0].CreatedAt);
    }

    /// <summary>A plain-second timestamp round-trips too, for older files and hand edits.</summary>
    [Fact]
    public void ReadsASecondPrecisionTimestamp()
    {
        var index = AccountIndexCodec.Decode("""
        {"version":1,"accounts":[{"id":"a","createdAt":"2026-09-28T13:15:30Z"}]}
        """);

        Assert.Equal(DateTimeOffset.Parse("2026-09-28T13:15:30Z"), index.Accounts[0].CreatedAt);
    }

    [Fact]
    public void AnUnparseableTimestampDoesNotLoseTheAccount()
    {
        var index = AccountIndexCodec.Decode("""
        {"version":1,"accounts":[{"id":"a","createdAt":"not a date","email":"x@y.z"}]}
        """);

        Assert.Single(index.Accounts);
        Assert.Null(index.Accounts[0].CreatedAt);
        Assert.Equal("x@y.z", index.Accounts[0].Email);
    }

    [Fact]
    public void AnAccountWithoutAnIdIsSkipped()
    {
        var index = AccountIndexCodec.Decode("""
        {"version":1,"accounts":[{"email":"no-id@example.com"},{"id":"has-id"}]}
        """);

        Assert.Single(index.Accounts);
        Assert.Equal("has-id", index.Accounts[0].Id);
    }

    [Fact]
    public void AnEmptyIndexReadsAsEmpty()
    {
        var index = AccountIndexCodec.Decode("""{"version":1}""");

        Assert.Empty(index.Accounts);
        Assert.Null(index.ActiveAccountId);
    }

    [Fact]
    public void MalformedJsonIsReported()
        => Assert.Throws<AccountIndexFormatException>(() => AccountIndexCodec.Decode("{ not json"));

    [Fact]
    public void ANonObjectIndexIsReported()
        => Assert.Throws<AccountIndexFormatException>(() => AccountIndexCodec.Decode("[1,2]"));

    /// <summary>
    /// A duplicate key arrives as ArgumentException from JsonObject, which is not a
    /// JsonException — so without an explicit guard it escapes every caller's catch.
    /// </summary>
    [Fact]
    public void ADuplicateKeyIsReportedAsAFormatError()
        => Assert.Throws<AccountIndexFormatException>(
            () => AccountIndexCodec.Decode("{\"version\":1,\"version\":2,\"accounts\":[]}"));

    // ---------------------------------------------------------------- preservation

    /// <summary>
    /// The behaviour that protects the other platform's data: a field this build does not model
    /// must survive a read and write.
    /// </summary>
    [Fact]
    public void AnUnknownFieldSurvivesARoundTrip()
    {
        const string withExtra = """
        {
          "version" : 1,
          "accounts" : [
            { "id" : "a", "email" : "x@y.z", "cachedQuota" : { "plan" : "plus", "used" : 42 } }
          ]
        }
        """;

        var index = AccountIndexCodec.Decode(withExtra);
        Assert.NotNull(index.Accounts[0].ExtraFields);
        Assert.Contains("cachedQuota", index.Accounts[0].ExtraFields!.Select(p => p.Key));

        var encoded = AccountIndexCodec.Encode(index).ToJsonString();
        Assert.Contains("cachedQuota", encoded, StringComparison.Ordinal);
        Assert.Contains("42", encoded, StringComparison.Ordinal);
    }

    [Fact]
    public void AKnownFieldIsNotDuplicatedIntoTheExtraFields()
    {
        var index = AccountIndexCodec.Decode(Minimal);

        Assert.Null(index.Accounts[0].ExtraFields);
    }

    [Fact]
    public void AnUnknownTopLevelFieldSurvivesAPerAccountRoundTrip()
    {
        // Top-level extras are not modelled, so this pins only that they do not break a read.
        var index = AccountIndexCodec.Decode("""
        {"version":1,"someFutureKey":true,"accounts":[]}
        """);

        Assert.Empty(index.Accounts);
    }

    // ---------------------------------------------------------------- writing

    [Fact]
    public void WritesAndReadsBackThroughDisk()
    {
        var original = AccountIndexCodec.Decode(Minimal);

        AccountIndexCodec.Save(original, _paths);
        var reloaded = AccountIndexCodec.Load(_paths);

        Assert.Equal(original.Accounts[0].Id, reloaded.Accounts[0].Id);
        Assert.Equal(original.Accounts[0].Email, reloaded.Accounts[0].Email);
        Assert.Equal(original.Accounts[0].PlanType, reloaded.Accounts[0].PlanType);
        Assert.Equal(original.ActiveAccountId, reloaded.ActiveAccountId);
    }

    [Fact]
    public void AMissingIndexFileReadsAsEmpty()
        => Assert.Empty(AccountIndexCodec.Load(_paths).Accounts);

    [Fact]
    public void WritingCreatesTheDirectory()
    {
        var fresh = new RunwayPaths(
            Path.Combine(_root, "new", ".codex"), Path.Combine(_root, "new", ".codex-runway"));

        AccountIndexCodec.Save(new AccountIndex { Accounts = Array.Empty<ManagedAccount>() }, fresh);

        Assert.True(File.Exists(fresh.IndexPath));
    }

    [Fact]
    public void AuthModeRoundTrips()
    {
        var index = new AccountIndex
        {
            Accounts = new[]
            {
                new ManagedAccount { Id = "api-1", AuthMode = ManagedAuthMode.ApiKey },
                new ManagedAccount { Id = "oauth-1", AuthMode = ManagedAuthMode.Oauth },
            },
        };

        AccountIndexCodec.Save(index, _paths);
        var reloaded = AccountIndexCodec.Load(_paths);

        Assert.Equal(ManagedAuthMode.ApiKey, reloaded.Account("api-1")!.AuthMode);
        Assert.Equal(ManagedAuthMode.Oauth, reloaded.Account("oauth-1")!.AuthMode);
    }

    /// <summary>The stored spelling is a file contract, not a preference.</summary>
    [Fact]
    public void TheStoredAuthModeSpellingsAreExact()
    {
        var encoded = AccountIndexCodec.Encode(new AccountIndex
        {
            Accounts = new[]
            {
                new ManagedAccount { Id = "a", AuthMode = ManagedAuthMode.ApiKey },
                new ManagedAccount { Id = "b", AuthMode = ManagedAuthMode.Oauth },
            },
        }).ToJsonString();

        Assert.Contains("\"apiKey\"", encoded, StringComparison.Ordinal);
        Assert.Contains("\"oauth\"", encoded, StringComparison.Ordinal);
    }

    /// <summary>A cleared field must be removed, not written as null, or the file stops
    /// matching what the other platform produces.</summary>
    [Fact]
    public void AClearedOptionalFieldIsRemovedRatherThanWrittenAsNull()
    {
        var encoded = AccountIndexCodec.Encode(new AccountIndex
        {
            Accounts = new[] { new ManagedAccount { Id = "a" } },
        }).ToJsonString();

        Assert.DoesNotContain("null", encoded, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------- display

    [Fact]
    public void TheAliasWinsOverADerivedName()
    {
        var account = new ManagedAccount
        {
            Id = "a",
            Alias = "工作号",
            DisplayName = "me@example.com",
            Email = "me@example.com",
        };

        Assert.Equal("工作号", account.ResolvedDisplayName);
    }

    [Fact]
    public void WithoutAnAliasTheDisplayNameIsUsed()
        => Assert.Equal("Me", new ManagedAccount { Id = "a", DisplayName = "Me" }.ResolvedDisplayName);

    [Fact]
    public void WithoutEitherTheEmailIsUsed()
        => Assert.Equal("x@y.z", new ManagedAccount { Id = "a", Email = "x@y.z" }.ResolvedDisplayName);

    [Fact]
    public void WithNothingTheIdIsUsed()
        => Assert.Equal("acct-1", new ManagedAccount { Id = "acct-1" }.ResolvedDisplayName);

    [Fact]
    public void TheSubtitleJoinsPlanAndIdentity()
        => Assert.Equal("plus · x@y.z",
            new ManagedAccount { Id = "a", PlanType = "plus", Email = "x@y.z" }.Subtitle);

    [Fact]
    public void TheSubtitleIsNullWhenNothingIsKnown()
        => Assert.Null(new ManagedAccount { Id = "a" }.Subtitle);

    /// <summary>The active account is pinned to the top, then the user's own order applies.</summary>
    [Fact]
    public void OrderingPutsTheActiveAccountFirstThenSortIndex()
    {
        var index = new AccountIndex
        {
            ActiveAccountId = "c",
            Accounts = new[]
            {
                new ManagedAccount { Id = "b", SortIndex = 1 },
                new ManagedAccount { Id = "a", SortIndex = 2 },
                new ManagedAccount { Id = "c", SortIndex = 3 },
            },
        };

        Assert.Equal(new[] { "c", "b", "a" }, index.OrderedForDisplay().Select(a => a.Id));
    }
}
