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


    // ---------------------------------------------------------------- concurrent writes

    /// <summary>
    /// The index is read-modify-written. Without a guard, two writers each read, each modify,
    /// and the second write discards the first — silently losing an account, a note, or which
    /// account is active. The macOS build guards this only with an in-process lock, so a second
    /// process is unprotected; that is what these tests close.
    /// </summary>
    [Fact]
    public void AGuardedWriteSucceedsWhenNothingChanged()
    {
        var (index, snapshot) = AccountIndexCodec.LoadWithSnapshot(_paths);

        AccountIndexCodec.Save(index, _paths, expected: snapshot);

        Assert.True(File.Exists(_paths.IndexPath));
    }

    [Fact]
    public void AGuardedWriteIsRefusedWhenTheFileChangedUnderneath()
    {
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[] { new ManagedAccount { Id = "a" } },
        }, _paths);
        var (index, snapshot) = AccountIndexCodec.LoadWithSnapshot(_paths);

        // Somebody else writes in between.
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[]
            {
                new ManagedAccount { Id = "a" },
                new ManagedAccount { Id = "b" },
            },
        }, _paths);

        Assert.Throws<AccountIndexConflictException>(
            () => AccountIndexCodec.Save(index, _paths, expected: snapshot));
    }

    /// <summary>The refused write must not have touched the file.</summary>
    [Fact]
    public void ARefusedWriteLeavesTheOtherWritersChangeIntact()
    {
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[] { new ManagedAccount { Id = "a" } },
        }, _paths);
        var (index, snapshot) = AccountIndexCodec.LoadWithSnapshot(_paths);
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[]
            {
                new ManagedAccount { Id = "a" },
                new ManagedAccount { Id = "b" },
            },
        }, _paths);

        try
        {
            AccountIndexCodec.Save(index, _paths, expected: snapshot);
        }
        catch (AccountIndexConflictException)
        {
            // Expected.
        }

        Assert.Equal(2, AccountIndexCodec.Load(_paths).Accounts.Count);
    }

    [Fact]
    public void AnUnguardedWriteStillWorks()
    {
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[] { new ManagedAccount { Id = "a" } },
        }, _paths);

        Assert.Single(AccountIndexCodec.Load(_paths).Accounts);
    }

    [Fact]
    public void TheSnapshotIsNullWhenTheFileIsAbsent()
    {
        var (index, snapshot) = AccountIndexCodec.LoadWithSnapshot(_paths);

        Assert.Null(snapshot);
        Assert.Empty(index.Accounts);
    }

    /// <summary>Retrying against a fresh snapshot is the documented response to a conflict.</summary>
    [Fact]
    public void RetryingAfterAConflictSucceeds()
    {
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[] { new ManagedAccount { Id = "a" } },
        }, _paths);
        var (_, stale) = AccountIndexCodec.LoadWithSnapshot(_paths);
        AccountIndexCodec.Save(new AccountIndex
        {
            Accounts = new[] { new ManagedAccount { Id = "a" }, new ManagedAccount { Id = "b" } },
        }, _paths);

        // Re-read, apply this writer's change on top, write again.
        var (fresh, snapshot) = AccountIndexCodec.LoadWithSnapshot(_paths);
        var merged = fresh with
        {
            Accounts = fresh.Accounts.Concat(new[] { new ManagedAccount { Id = "c" } }).ToArray(),
        };
        AccountIndexCodec.Save(merged, _paths, expected: snapshot);

        Assert.Equal(3, AccountIndexCodec.Load(_paths).Accounts.Count);
        Assert.NotEqual(stale, snapshot);
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
            { "id" : "a", "email" : "x@y.z", "someLaterField" : { "deep" : 42 } }
          ]
        }
        """;

        var index = AccountIndexCodec.Decode(withExtra);
        Assert.NotNull(index.Accounts[0].ExtraFields);
        Assert.Contains("someLaterField", index.Accounts[0].ExtraFields!.Select(p => p.Key));

        var encoded = AccountIndexCodec.Encode(index).ToJsonString();
        Assert.Contains("someLaterField", encoded, StringComparison.Ordinal);
        Assert.Contains("42", encoded, StringComparison.Ordinal);
    }

    /// <summary>
    /// The quota cache is modelled now, so it must be read and written as a field rather than
    /// preserved as an unknown blob — losing it would lose the numbers the panel then shows
    /// without a network call.
    /// </summary>
    [Fact]
    public void TheCachedQuotaRoundTrips()
    {
        var index = AccountIndexCodec.Decode("""
        {
          "version" : 1,
          "accounts" : [
            {
              "id" : "a",
              "cachedQuota" : {
                "plan" : "plus",
                "primaryUsedPercent" : 12,
                "primaryWindowMinutes" : 300,
                "primaryResetsAt" : "2026-10-11T11:42:30.000Z",
                "secondaryUsedPercent" : 34,
                "secondaryWindowMinutes" : 10080,
                "updatedAt" : "2026-10-11T06:42:30.166Z"
              }
            }
          ]
        }
        """);

        var quota = index.Accounts[0].CachedQuota;
        Assert.NotNull(quota);
        Assert.Equal("plus", quota!.Plan);
        Assert.Equal(12, quota.PrimaryUsedPercent);
        Assert.Equal(300, quota.PrimaryWindowMinutes);
        Assert.Equal(34, quota.SecondaryUsedPercent);

        var encoded = AccountIndexCodec.Encode(index).ToJsonString();
        Assert.Contains("\"cachedQuota\"", encoded, StringComparison.Ordinal);
        Assert.Contains("primaryUsedPercent", encoded, StringComparison.Ordinal);

        var reloaded = AccountIndexCodec.Decode(encoded);
        Assert.Equal(12, reloaded.Accounts[0].CachedQuota!.PrimaryUsedPercent);
    }

    /// <summary>An account with no quota has no quota, rather than one full of zeros.</summary>
    [Fact]
    public void AnAccountWithoutACachedQuotaReadsAsNull()
    {
        var index = AccountIndexCodec.Decode("""{"version":1,"accounts":[{"id":"a"}]}""");

        Assert.Null(index.Accounts[0].CachedQuota);
    }

    /// <summary>
    /// A meter inside <c>cachedQuota</c> that this build does not model must survive a write.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The quota object was the one place the "preserve what you do not understand" contract was
    /// broken inside an account: <see cref="ManagedAccount.ExtraFields"/> carried only the
    /// account's <em>own</em> unknown keys, and <c>EncodeQuota</c> rebuilt <c>cachedQuota</c> from
    /// scratch, writing only the eight fields it models. Its <c>node</c> parameter accepted the
    /// preserved object and never read it.
    /// </para>
    /// <para>
    /// The consequence was data loss on a shared file: the macOS build adds a meter (a per-model
    /// breakdown, a third window, a reset-credit countdown), this build reads the index and writes
    /// it back, and the meter is gone. The account's own unknown fields survived, so the failure
    /// was specific to the nested object.
    /// </para>
    /// <para>
    /// Fixed by giving <see cref="CachedQuota"/> its own preserved-members field and encoding from
    /// it. This test was written first, marked skipped while the bug was open because it belonged
    /// to code the audit was not permitted to change, and the skip is removed now that the fix is
    /// in — it fails again if the preservation is dropped.
    /// </para>
    /// </remarks>
    [Fact]
    public void AnUnknownMeterInsideTheCachedQuotaSurvivesARoundTrip()
    {
        var index = AccountIndexCodec.Decode("""
        {
          "version" : 1,
          "accounts" : [
            {
              "id" : "a",
              "cachedQuota" : {
                "plan" : "plus",
                "primaryUsedPercent" : 12,
                "someFutureMeter" : 77
              }
            }
          ]
        }
        """);

        // The known field is read, and the unknown one recognized as part of the same object.
        Assert.Equal(12, index.Accounts[0].CachedQuota!.PrimaryUsedPercent);

        var encoded = AccountIndexCodec.Encode(index).ToJsonString();
        Assert.Contains("someFutureMeter", encoded, StringComparison.Ordinal);
    }

    [Fact]
    public void AKnownFieldIsNotDuplicatedIntoTheExtraFields()
    {
        var index = AccountIndexCodec.Decode(Minimal);

        Assert.Null(index.Accounts[0].ExtraFields);
    }

    /// <summary>
    /// An unrecognised top-level key does not stop the index being read.
    /// </summary>
    /// <remarks>
    /// Named for what it establishes. It previously claimed the key <em>survives</em> a round
    /// trip, but top-level extras are not modelled and <see cref="AccountIndexCodec.Encode"/>
    /// emits only <c>version</c>, <c>activeAccountId</c> and <c>accounts</c> — so a write from
    /// this build drops any top-level key it does not know. That is a real divergence from the
    /// per-account contract, and it is recorded as such by
    /// <see cref="AnUnknownTopLevelFieldIsDroppedByAWriteDoNotRelyOnItSurviving"/> rather than
    /// left implied by a name the assertions did not support.
    /// </remarks>
    [Fact]
    public void AnUnknownTopLevelFieldDoesNotBreakARead()
    {
        var index = AccountIndexCodec.Decode("""
        {"version":1,"someFutureKey":true,"accounts":[]}
        """);

        Assert.Empty(index.Accounts);
        Assert.Equal(1, index.Version);
    }

    /// <summary>
    /// Pins the observed behaviour of an unknown <em>top-level</em> key across a write, so a
    /// future change to it is a deliberate decision rather than an accident.
    /// </summary>
    /// <remarks>
    /// The per-account contract is preservation (see
    /// <see cref="AnUnknownFieldSurvivesARoundTrip"/>); the top level does the opposite. That
    /// matters for the shared file: a key the macOS build put at the root and this build does
    /// not model is lost the first time this build writes the index. Asserted as the current
    /// behaviour, with the comment stating that it is a lossy round trip.
    /// </remarks>
    [Fact]
    public void AnUnknownTopLevelFieldIsDroppedByAWriteDoNotRelyOnItSurviving()
    {
        var encoded = AccountIndexCodec
            .Encode(AccountIndexCodec.Decode("""
            {"version":1,"someFutureKey":true,"accounts":[]}
            """))
            .ToJsonString();

        Assert.DoesNotContain("someFutureKey", encoded, StringComparison.Ordinal);
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

    // ---------------------------------------------------------------- reordering

    /// <summary>
    /// The stored order is a dense sortIndex sequence, so a move renumbers rather than swapping.
    /// Swapping leaves gaps and duplicates after a few moves, and the list slowly stops matching
    /// what the user dragged.
    /// </summary>
    [Fact]
    public void MovingAnAccountRenumbersDensely()
    {
        var index = ThreeAccounts();
        var moved = index.MoveAccount("b", +1);

        // Displayed order becomes a, c, b.
        Assert.Equal(new[] { "a", "c", "b" }, moved.OrderedForDisplay().Select(x => x.Id));
        Assert.Equal(new[] { 0, 1, 2 }, moved.OrderedForDisplay().Select(x => x.SortIndex));
    }

    [Fact]
    public void MovingUpSwapsWithThePreviousAccount()
    {
        var moved = ThreeAccounts().MoveAccount("c", -1);

        Assert.Equal(new[] { "a", "c", "b" }, moved.OrderedForDisplay().Select(x => x.Id));
    }

    [Fact]
    public void MovingPastTheEndChangesNothing()
    {
        var index = ThreeAccounts();

        Assert.Equal(
            index.OrderedForDisplay().Select(x => x.Id),
            index.MoveAccount("a", -1).OrderedForDisplay().Select(x => x.Id));
        Assert.Equal(
            index.OrderedForDisplay().Select(x => x.Id),
            index.MoveAccount("c", +1).OrderedForDisplay().Select(x => x.Id));
    }

    [Fact]
    public void MovingAnUnknownAccountChangesNothing()
    {
        var index = ThreeAccounts();

        Assert.Equal(
            index.OrderedForDisplay().Select(x => x.Id),
            index.MoveAccount("nope", +1).OrderedForDisplay().Select(x => x.Id));
    }

    /// <summary>
    /// A move that would displace the pinned active account is refused outright.
    /// </summary>
    /// <remarks>
    /// Asserted on the returned instance, not on the displayed order. <see cref="AccountIndex.OrderedForDisplay"/>
    /// already sorts the active account first, so a displayed order would look correct even if
    /// the move had gone through — an earlier version of this test passed with the guard removed,
    /// which is exactly the kind of test that is worse than none. What the guard actually prevents
    /// is a pointless rewrite of the stored indices.
    /// </remarks>
    [Fact]
    public void AMoveThatWouldDisplaceThePinnedAccountIsRefused()
    {
        var index = ThreeAccounts() with { ActiveAccountId = "b" };

        // Same instance means "nothing happened", which is what the caller reports to the user.
        // The active account is at display index 0 and cannot move down; c is at index 2, and
        // moving it up would land it above the pinned slot.
        Assert.Same(index, index.MoveAccount("b", +1));
        Assert.Same(index, index.MoveAccount("a", -1));
    }

    /// <summary>A move that does not touch the pinned slot still rewrites the order.</summary>
    [Fact]
    public void AMoveAwayFromThePinnedSlotIsApplied()
    {
        var index = new AccountIndex
        {
            ActiveAccountId = "b",
            Accounts = new[]
            {
                new ManagedAccount { Id = "a", SortIndex = 0 },
                new ManagedAccount { Id = "b", SortIndex = 1 },
                new ManagedAccount { Id = "c", SortIndex = 2 },
            },
        };

        // Displayed order is b, a, c; moving c up swaps it with a.
        var moved = index.MoveAccount("c", -1);

        Assert.NotSame(index, moved);
        Assert.Equal(new[] { "b", "c", "a" }, moved.OrderedForDisplay().Select(x => x.Id));
    }

    // ---------------------------------------------------------------- removal

    [Fact]
    public void RemovingAnAccountDropsItAndRenumbers()
    {
        var trimmed = ThreeAccounts().WithoutAccount("b");

        Assert.Equal(new[] { "a", "c" }, trimmed.OrderedForDisplay().Select(x => x.Id));
        Assert.Equal(new[] { 0, 1 }, trimmed.OrderedForDisplay().Select(x => x.SortIndex));
    }

    [Fact]
    public void RemovingAnUnknownAccountChangesNothing()
    {
        var index = ThreeAccounts();

        Assert.Equal(index.Accounts.Count, index.WithoutAccount("nope").Accounts.Count);
    }

    /// <summary>Removing the active account must clear the pointer, not leave it dangling.</summary>
    [Fact]
    public void RemovingTheActiveAccountClearsTheActivePointer()
    {
        var index = ThreeAccounts() with { ActiveAccountId = "b" };

        Assert.Null(index.WithoutAccount("b").ActiveAccountId);
    }

    [Fact]
    public void RemovingAnotherAccountLeavesTheActivePointerAlone()
    {
        var index = ThreeAccounts() with { ActiveAccountId = "b" };

        Assert.Equal("b", index.WithoutAccount("a").ActiveAccountId);
    }

    /// <summary>A double removal must be harmless, since the second click can follow a reload.</summary>
    [Fact]
    public void RemovingTwiceIsHarmless()
    {
        var once = ThreeAccounts().WithoutAccount("b");
        var twice = once.WithoutAccount("b");

        Assert.Equal(2, twice.Accounts.Count);
    }

    private static AccountIndex ThreeAccounts() => new()
    {
        Accounts = new[]
        {
            new ManagedAccount { Id = "a", SortIndex = 0 },
            new ManagedAccount { Id = "b", SortIndex = 1 },
            new ManagedAccount { Id = "c", SortIndex = 2 },
        },
    };

    /// <summary>
    /// A relay account's balance lives one level down, under <c>newAPI</c>.
    /// </summary>
    /// <remarks>
    /// Reading only the top level of <c>cachedQuota</c> left every relay row showing no balance,
    /// which no amount of compiling or unit testing would have revealed — it took a real index
    /// to notice. The nested object also has to survive a write, since it is not modelled
    /// field-by-field.
    /// </remarks>
    [Fact]
    public void ARelayBalanceIsReadFromTheNestedNewApiObject()
    {
        var index = AccountIndexCodec.Decode("""
        {
          "version" : 1,
          "accounts" : [
            {
              "id" : "api-1",
              "authMode" : "apiKey",
              "cachedQuota" : {
                "plan" : "api",
                "newAPI" : {
                  "remainingUSD" : 1.726218,
                  "keyUsedUSD" : 140.426154,
                  "requestCount" : 5392
                }
              }
            }
          ]
        }
        """);

        var quota = index.Accounts[0].CachedQuota;
        Assert.NotNull(quota);
        // A tolerance rather than exact equality: the value round-trips through JSON as a
        // double, and comparing doubles exactly is a check that fails for reasons unrelated to
        // the behaviour under test.
        Assert.NotNull(quota!.RemainingUsd);
        Assert.Equal(1.726218, quota.RemainingUsd!.Value, 6);
        Assert.NotNull(quota.UsedUsd);
        Assert.Equal(140.426154, quota.UsedUsd!.Value, 6);
        Assert.Equal(5392, quota.RequestCount);
    }

    /// <summary>A quoted number is read too, rather than losing the balance to its quotes.</summary>
    [Fact]
    public void ARelayBalanceWrittenAsAStringIsStillRead()
    {
        var index = AccountIndexCodec.Decode("""
        {"version":1,"accounts":[{"id":"a","authMode":"apiKey",
         "cachedQuota":{"newAPI":{"remainingUSD":"2.5"}}}]}
        """);

        Assert.Equal(2.5, index.Accounts[0].CachedQuota!.RemainingUsd);
    }

    [Fact]
    public void AQuotaWithoutNewApiReportsNoBalance()
    {
        var index = AccountIndexCodec.Decode("""
        {"version":1,"accounts":[{"id":"a","cachedQuota":{"plan":"plus"}}]}
        """);

        Assert.Null(index.Accounts[0].CachedQuota!.RemainingUsd);
    }

    /// <summary>The nested object must survive a write, since it is not modelled field by field.</summary>
    [Fact]
    public void TheNestedNewApiObjectSurvivesARoundTrip()
    {
        const string original = """
        {"version":1,"accounts":[{"id":"a","authMode":"apiKey",
         "cachedQuota":{"newAPI":{"remainingUSD":1.5,"someLaterField":"keep"}}}]}
        """;

        var encoded = AccountIndexCodec.Encode(AccountIndexCodec.Decode(original)).ToJsonString();

        Assert.Contains("someLaterField", encoded, StringComparison.Ordinal);
        Assert.Contains("1.5", encoded, StringComparison.Ordinal);
    }
}
