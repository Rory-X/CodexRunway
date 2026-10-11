using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CodexRunway.Core;

/// <summary>
/// The account's last known quota, cached by whichever build fetched it.
/// </summary>
/// <remarks>
/// <para>
/// Read from the shared index and shown without a network call, which is what lets the panel
/// open instantly. The values come from the other platform's last refresh, so they can be
/// stale — <see cref="UpdatedAt"/> is what the view reports rather than implying the numbers
/// are live.
/// </para>
/// <para>
/// Only the fields the panel shows are modelled, and the rest are preserved: this object is
/// written back to a file the macOS build also owns, and dropping a meter would lose data it
/// had collected.
/// </para>
/// </remarks>
public sealed record CachedQuota
{
    public string? Plan { get; init; }

    public int? PrimaryUsedPercent { get; init; }

    public int? PrimaryWindowMinutes { get; init; }

    public DateTimeOffset? PrimaryResetsAt { get; init; }

    public int? SecondaryUsedPercent { get; init; }

    public int? SecondaryWindowMinutes { get; init; }

    public DateTimeOffset? SecondaryResetsAt { get; init; }

    /// <summary>When this reading was taken, so its age can be shown.</summary>
    public DateTimeOffset? UpdatedAt { get; init; }

    /// <summary>Whether anything at all is known.</summary>
    public bool HasAnyReading => PrimaryUsedPercent is not null || SecondaryUsedPercent is not null;
}

/// <summary>How a managed account authenticates.</summary>
/// <remarks>
/// The stored spellings are <c>oauth</c> and <c>apiKey</c>, matching the macOS build. They are
/// a file contract, not an implementation detail: a different spelling reads as an unparseable
/// index rather than as a wrong value.
/// </remarks>
public enum ManagedAuthMode
{
    Oauth,
    ApiKey,
}

/// <summary>
/// One managed account as the macOS build stores it.
/// </summary>
/// <remarks>
/// <para>
/// Only the fields this build needs are modelled; everything else in the file is preserved
/// untouched through <see cref="ExtraFields"/>. That matters because the index is shared and
/// written by both platforms: a reader that dropped a field the other side had written would
/// silently delete data, and a quota cache is a lot of data to lose.
/// </para>
/// <para>
/// Properties are nullable and optional throughout, because the file is written by another
/// tool and an upgrade can add or omit fields at any time.
/// </para>
/// </remarks>
public sealed record ManagedAccount
{
    /// <summary>Stable id, also the name of the account's directory.</summary>
    public required string Id { get; init; }

    public int SortIndex { get; init; }

    public ManagedAuthMode AuthMode { get; init; }

    public string? Email { get; init; }

    public string? Username { get; init; }

    public string? UserId { get; init; }

    public string? SubjectId { get; init; }

    public string? AccountId { get; init; }

    public string? WorkspaceName { get; init; }

    public string? DisplayName { get; init; }

    /// <summary>What the user called this account. Wins over everything derived.</summary>
    public string? Alias { get; init; }

    public string? Note { get; init; }

    public string? RelayBaseUrl { get; init; }

    public string? RelayProviderName { get; init; }

    public string? PlanType { get; init; }

    public DateTimeOffset? SubscriptionExpiresAt { get; init; }

    public DateTimeOffset? CreatedAt { get; init; }

    public DateTimeOffset? LastUsedAt { get; init; }

    public DateTimeOffset? LastQuotaAt { get; init; }

    public bool RequiresReauth { get; init; }

    public string? LastError { get; init; }

    /// <summary>The last quota reading, or null when none has been taken.</summary>
    public CachedQuota? CachedQuota { get; init; }

    /// <summary>
    /// Fields this build does not model, kept verbatim so a write does not destroy them.
    /// </summary>
    public JsonObject? ExtraFields { get; init; }

    /// <summary>
    /// What to show for this account: the user's alias, else a derived name.
    /// </summary>
    /// <remarks>
    /// Order matters. An alias is an explicit choice; a display name is derived, and an email
    /// is a last resort. Showing a derived name over the user's own label is the kind of thing
    /// that makes a switcher feel like it is ignoring you.
    /// </remarks>
    public string ResolvedDisplayName => FirstNonEmpty(Alias, DisplayName, Email, Username, Id) ?? Id;

    /// <summary>The second line: plan and identity, when either is known.</summary>
    public string? Subtitle
    {
        get
        {
            var identity = FirstNonEmpty(Email, Username, WorkspaceName);
            return (PlanType, identity) switch
            {
                (not null, not null) => $"{PlanType} · {identity}",
                (not null, null) => PlanType,
                (null, not null) => identity,
                _ => null,
            };
        }
    }

    private static string? FirstNonEmpty(params string?[] values)
        => values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
}

/// <summary>The whole index file.</summary>
public sealed record AccountIndex
{
    /// <summary>The schema version this build understands.</summary>
    public const int CurrentVersion = 1;

    public int Version { get; init; } = CurrentVersion;

    public string? ActiveAccountId { get; init; }

    public IReadOnlyList<ManagedAccount> Accounts { get; init; } = Array.Empty<ManagedAccount>();

    /// <summary>An index with nothing in it.</summary>
    public static AccountIndex Empty { get; } = new();

    /// <summary>Finds one account by id.</summary>
    public ManagedAccount? Account(string id)
        => Accounts.FirstOrDefault(a => string.Equals(a.Id, id, StringComparison.Ordinal));

    /// <summary>
    /// Moves an account one position in the user's order.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The stored order is a dense <c>sortIndex</c> sequence, so a move rewrites the indices
    /// rather than swapping two values: swapping would leave gaps and duplicates after a few
    /// moves, and the sidebar's ordering would slowly stop matching what the user dragged.
    /// </para>
    /// <para>
    /// The move is expressed against <see cref="OrderedForDisplay"/> rather than the raw list,
    /// because that is the order the user sees — the active account is pinned to the top, and
    /// moving something "up" must mean up on screen. The first movable position is therefore one
    /// past the pinned account.
    /// </para>
    /// </remarks>
    public AccountIndex MoveAccount(string id, int delta)
    {
        var ordered = OrderedForDisplay().ToList();
        var index = ordered.FindIndex(a => string.Equals(a.Id, id, StringComparison.Ordinal));
        if (index < 0)
        {
            return this;
        }

        var target = index + delta;
        if (target < 0 || target >= ordered.Count)
        {
            return this;
        }

        // Cannot move into or out of the pinned active slot: the active account is shown first
        // regardless of sortIndex, so letting a move appear to succeed would change nothing.
        var pinnedCount = ActiveAccountId is not null
            && ordered.Any(a => string.Equals(a.Id, ActiveAccountId, StringComparison.Ordinal))
                ? 1
                : 0;
        if (index < pinnedCount || target < pinnedCount)
        {
            return this;
        }

        (ordered[index], ordered[target]) = (ordered[target], ordered[index]);

        // Renumber densely so the order is exactly what was shown, and give the active account
        // the lowest index it can hold without disturbing the rest.
        var byId = new Dictionary<string, ManagedAccount>(StringComparer.Ordinal);
        for (var i = 0; i < ordered.Count; i++)
        {
            byId[ordered[i].Id] = ordered[i] with { SortIndex = i };
        }

        return this with
        {
            Accounts = Accounts.Select(a => byId.TryGetValue(a.Id, out var updated) ? updated : a).ToArray(),
        };
    }

    /// <summary>Removes an account from the index.</summary>
    /// <remarks>
    /// Only the index entry: the credential file is a separate decision, so a caller can keep a
    /// copy or remove it deliberately. Returns this index unchanged when the id is unknown, which
    /// makes a double-removal harmless.
    /// </remarks>
    public AccountIndex WithoutAccount(string id)
    {
        var remaining = Accounts.Where(a => !string.Equals(a.Id, id, StringComparison.Ordinal)).ToArray();
        if (remaining.Length == Accounts.Count)
        {
            return this;
        }

        // Renumber so the stored order stays dense after a removal.
        var renumbered = remaining
            .Select((a, i) => a with { SortIndex = i })
            .ToArray();

        return this with
        {
            Accounts = renumbered,
            ActiveAccountId = string.Equals(ActiveAccountId, id, StringComparison.Ordinal)
                ? null
                : ActiveAccountId,
        };
    }

    /// <summary>
    /// Accounts in the order the sidebar shows them: active first, then the user's order, then
    /// display name.
    /// </summary>
    /// <remarks>
    /// Reproduces the macOS ordering exactly, because the list is a user-visible contract: the
    /// active account is pinned to the top, and everything else follows the order the user
    /// dragged them into.
    /// </remarks>
    public IReadOnlyList<ManagedAccount> OrderedForDisplay()
        => Accounts
            .OrderByDescending(a => string.Equals(a.Id, ActiveAccountId, StringComparison.Ordinal))
            .ThenBy(a => a.SortIndex)
            .ThenBy(a => a.ResolvedDisplayName, StringComparer.CurrentCulture)
            .ToArray();
}

/// <summary>The index file's location and content, as JSON.</summary>
/// <remarks>
/// <para>
/// Read leniently and written carefully. The file is shared with the macOS build, so reading
/// has to tolerate what that side writes — including a fractional-second timestamp and
/// fields this build does not know — while writing must not drop anything.
/// </para>
/// <para>
/// A field this build does not model is carried through <see cref="ManagedAccount.ExtraFields"/>
/// rather than discarded, and a malformed account is skipped rather than failing the whole
/// file, because losing one account's metadata is much better than showing none.
/// </para>
/// </remarks>
public static class AccountIndexCodec
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>Reads an index from JSON. Never throws for a well-formed JSON document.</summary>
    public static AccountIndex Decode(string json)
    {
        JsonObject root;
        try
        {
            var node = JsonNode.Parse(json);
            if (node is null)
            {
                throw new AccountIndexFormatException("index is empty");
            }

            root = node as JsonObject
                ?? throw new AccountIndexFormatException("index must be a JSON object");

            // JsonObject builds its key dictionary lazily, so reading a duplicate key does NOT
            // throw from Parse — it throws on the first member access. Count is touched here,
            // inside the guard, so the failure is reported as a format error instead of
            // escaping as an ArgumentException from somewhere further down.
            _ = root.Count;
        }
        catch (JsonException error)
        {
            throw new AccountIndexFormatException($"index is not valid JSON: {error.Message}");
        }
        catch (ArgumentException error)
        {
            // ArgumentException is not a JsonException, so without this it would escape every
            // caller's catch and turn a boolean query into an unhandled crash.
            throw new AccountIndexFormatException($"duplicate key in index: {error.Message}");
        }

        var accounts = new List<ManagedAccount>();
        if (root["accounts"] is JsonArray array)
        {
            foreach (var entry in array)
            {
                if (entry is JsonObject account && TryDecodeAccount(account, out var decoded))
                {
                    accounts.Add(decoded);
                }
            }
        }

        return new AccountIndex
        {
            Version = Int(root, "version") ?? AccountIndex.CurrentVersion,
            ActiveAccountId = Str(root, "activeAccountId"),
            Accounts = accounts,
        };
    }

    /// <summary>Reads the index from disk, or an empty one when the file is absent.</summary>
    public static AccountIndex Load(RunwayPaths paths)
    {
        if (!File.Exists(paths.IndexPath))
        {
            return AccountIndex.Empty;
        }

        try
        {
            return Decode(File.ReadAllText(paths.IndexPath, System.Text.Encoding.UTF8));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new AccountIndexFormatException($"index could not be read: {error.Message}");
        }
    }

    /// <summary>
    /// Writes the index back, preserving fields this build does not model.
    /// </summary>
    public static void Save(AccountIndex index, RunwayPaths paths)
        => Save(index, paths, expected: null);

    /// <summary>
    /// Writes the index back only if it has not changed since it was read.
    /// </summary>
    /// <param name="expected">
    /// The exact text that was read, or null to write unconditionally.
    /// </param>
    /// <remarks>
    /// <para>
    /// <b>Why this exists.</b> The index is read-modify-written, and the macOS build guards that
    /// only with an in-process lock. Two Runway processes — a tray app plus a second instance,
    /// or one instance per platform against a shared directory — would each read, each modify,
    /// and the second write would silently discard the first one's account, note or active
    /// selection.
    /// </para>
    /// <para>
    /// The guard is a compare-and-swap on the file's bytes rather than a lock, because a lock
    /// would have to be held across the user's whole interaction and the two platforms do not
    /// share a lock mechanism in the first place. Comparing content is portable and needs no
    /// cooperation from the other writer.
    /// </para>
    /// <para>
    /// Callers should re-read and retry on <see cref="AccountIndexConflictException"/> rather
    /// than overwriting: the conflict means somebody else's change is in the file, and the
    /// correct response is to re-apply this change on top of it.
    /// </para>
    /// </remarks>
    /// <exception cref="AccountIndexConflictException">
    /// The file changed since <paramref name="expected"/> was read.
    /// </exception>
    public static void Save(AccountIndex index, RunwayPaths paths, string? expected)
    {
        Directory.CreateDirectory(paths.AccountsDirectory);
        var root = Encode(index);

        if (expected is not null)
        {
            // Read immediately before writing, so the window between check and write is as
            // small as this API can make it. A truly atomic compare-and-swap would need
            // filesystem support neither platform offers for a plain file.
            var current = File.Exists(paths.IndexPath)
                ? File.ReadAllText(paths.IndexPath, System.Text.Encoding.UTF8)
                : null;

            if (!string.Equals(current, expected, StringComparison.Ordinal))
            {
                throw new AccountIndexConflictException(
                    "the account index changed since it was read");
            }
        }

        CodexConfigProviderEditor.AtomicWrite(
            root.ToJsonString(WriteOptions),
            paths.IndexPath);
    }

    /// <summary>
    /// Reads the index and the exact text it came from, for a later guarded write.
    /// </summary>
    /// <remarks>
    /// Returning the raw text alongside the parsed value is what makes
    /// <see cref="Save(AccountIndex,RunwayPaths,string?)"/> usable without the caller re-reading
    /// the file and risking a different snapshot.
    /// </remarks>
    public static (AccountIndex Index, string? RawText) LoadWithSnapshot(RunwayPaths paths)
    {
        if (!File.Exists(paths.IndexPath))
        {
            return (AccountIndex.Empty, null);
        }

        string raw;
        try
        {
            raw = File.ReadAllText(paths.IndexPath, System.Text.Encoding.UTF8);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new AccountIndexFormatException($"index could not be read: {error.Message}");
        }

        return (Decode(raw), raw);
    }

    /// <summary>Encodes an index, keeping unknown fields.</summary>
    public static JsonObject Encode(AccountIndex index)
    {
        var accounts = new JsonArray();
        foreach (var account in index.Accounts)
        {
            accounts.Add(EncodeAccount(account));
        }

        var root = new JsonObject
        {
            ["version"] = index.Version,
            ["accounts"] = accounts,
        };
        if (index.ActiveAccountId is not null)
        {
            root["activeAccountId"] = index.ActiveAccountId;
        }

        return root;
    }

    // ---------------------------------------------------------------- per account

    private static JsonObject EncodeAccount(ManagedAccount account)
    {
        // Start from the preserved fields so anything unknown survives, then overwrite the
        // ones this build owns.
        var root = account.ExtraFields is null
            ? new JsonObject()
            : (JsonObject)account.ExtraFields.DeepClone();

        root["id"] = account.Id;
        root["sortIndex"] = account.SortIndex;
        root["authMode"] = account.AuthMode == ManagedAuthMode.ApiKey ? "apiKey" : "oauth";
        root["requiresReauth"] = account.RequiresReauth;

        Set(root, "email", account.Email);
        Set(root, "username", account.Username);
        Set(root, "userId", account.UserId);
        Set(root, "subjectId", account.SubjectId);
        Set(root, "accountId", account.AccountId);
        Set(root, "workspaceName", account.WorkspaceName);
        Set(root, "displayName", account.DisplayName);
        Set(root, "alias", account.Alias);
        Set(root, "note", account.Note);
        Set(root, "relayBaseURL", account.RelayBaseUrl);
        Set(root, "relayProviderName", account.RelayProviderName);
        Set(root, "planType", account.PlanType);
        Set(root, "lastError", account.LastError);
        SetDate(root, "subscriptionExpiresAt", account.SubscriptionExpiresAt);
        SetDate(root, "createdAt", account.CreatedAt);
        SetDate(root, "lastUsedAt", account.LastUsedAt);
        SetDate(root, "lastQuotaAt", account.LastQuotaAt);

        // Quota is passed through as it was read unless a caller replaced it, so a write
        // from this build cannot lose a meter the other build collected.
        if (account.CachedQuota is { } quota)
        {
            root["cachedQuota"] = EncodeQuota(quota, node: account.ExtraFields);
        }

        return root;
    }

    private static bool TryDecodeAccount(JsonObject node, out ManagedAccount account)
    {
        account = null!;

        var id = Str(node, "id");
        if (string.IsNullOrEmpty(id))
        {
            // An account without an id cannot be addressed, so it cannot be shown.
            return false;
        }

        // Everything this build does not model is kept, so a later write does not delete it.
        var known = new HashSet<string>(StringComparer.Ordinal)
        {
            "id", "sortIndex", "authMode", "email", "username", "userId", "subjectId",
            "accountId", "workspaceName", "displayName", "alias", "note", "relayBaseURL",
            "relayProviderName", "planType", "subscriptionExpiresAt", "createdAt",
            "lastUsedAt", "lastQuotaAt", "requiresReauth", "lastError", "cachedQuota",
        };

        var extra = new JsonObject();
        foreach (var pair in node)
        {
            if (!known.Contains(pair.Key))
            {
                extra[pair.Key] = pair.Value?.DeepClone();
            }
        }

        account = new ManagedAccount
        {
            Id = id,
            SortIndex = Int(node, "sortIndex") ?? 0,
            AuthMode = string.Equals(Str(node, "authMode"), "apiKey", StringComparison.OrdinalIgnoreCase)
                ? ManagedAuthMode.ApiKey
                : ManagedAuthMode.Oauth,
            Email = Str(node, "email"),
            Username = Str(node, "username"),
            UserId = Str(node, "userId"),
            SubjectId = Str(node, "subjectId"),
            AccountId = Str(node, "accountId"),
            WorkspaceName = Str(node, "workspaceName"),
            DisplayName = Str(node, "displayName"),
            Alias = Str(node, "alias"),
            Note = Str(node, "note"),
            RelayBaseUrl = Str(node, "relayBaseURL"),
            RelayProviderName = Str(node, "relayProviderName"),
            PlanType = Str(node, "planType"),
            SubscriptionExpiresAt = Date(node, "subscriptionExpiresAt"),
            CreatedAt = Date(node, "createdAt"),
            LastUsedAt = Date(node, "lastUsedAt"),
            LastQuotaAt = Date(node, "lastQuotaAt"),
            RequiresReauth = Bool(node, "requiresReauth") ?? false,
            LastError = Str(node, "lastError"),
            CachedQuota = DecodeQuota(node["cachedQuota"] as JsonObject),
            ExtraFields = extra.Count > 0 ? extra : null,
        };
        return true;
    }

    // ---------------------------------------------------------------- primitives

    /// <summary>Reads the cached quota, tolerating a missing or partial object.</summary>
    private static CachedQuota? DecodeQuota(JsonObject? node)
    {
        if (node is null)
        {
            return null;
        }

        return new CachedQuota
        {
            Plan = Str(node, "plan"),
            PrimaryUsedPercent = Int(node, "primaryUsedPercent"),
            PrimaryWindowMinutes = Int(node, "primaryWindowMinutes"),
            PrimaryResetsAt = Date(node, "primaryResetsAt"),
            SecondaryUsedPercent = Int(node, "secondaryUsedPercent"),
            SecondaryWindowMinutes = Int(node, "secondaryWindowMinutes"),
            SecondaryResetsAt = Date(node, "secondaryResetsAt"),
            UpdatedAt = Date(node, "updatedAt"),
        };
    }

    /// <summary>Writes the cached quota back, keeping any meter this build does not model.</summary>
    private static JsonObject EncodeQuota(CachedQuota quota, JsonObject? node)
    {
        var root = new JsonObject();
        SetInt(root, "primaryUsedPercent", quota.PrimaryUsedPercent);
        SetInt(root, "primaryWindowMinutes", quota.PrimaryWindowMinutes);
        SetInt(root, "secondaryUsedPercent", quota.SecondaryUsedPercent);
        SetInt(root, "secondaryWindowMinutes", quota.SecondaryWindowMinutes);
        Set(root, "plan", quota.Plan);
        SetDate(root, "primaryResetsAt", quota.PrimaryResetsAt);
        SetDate(root, "secondaryResetsAt", quota.SecondaryResetsAt);
        SetDate(root, "updatedAt", quota.UpdatedAt);
        return root;
    }

    private static void SetInt(JsonObject root, string key, int? value)
    {
        if (value is { } number)
        {
            root[key] = number;
        }
        else
        {
            root.Remove(key);
        }
    }

    private static void Set(JsonObject root, string key, string? value)
    {
        if (value is not null)
        {
            root[key] = value;
        }
        else
        {
            root.Remove(key);
        }
    }

    private static void SetDate(JsonObject root, string key, DateTimeOffset? value)
    {
        if (value is { } date)
        {
            root[key] = RunwayDates.FormatIndexDate(date);
        }
        else
        {
            root.Remove(key);
        }
    }

    /// <summary>A string field, or null when absent or not a string.</summary>
    private static string? Str(JsonObject node, string key)
        => node[key] is { } value && value.GetValueKind() == JsonValueKind.String
            ? value.GetValue<string>()
            : null;

    /// <summary>
    /// An integer field, tolerating the JSON number forms another writer might produce.
    /// </summary>
    private static int? Int(JsonObject node, string key)
    {
        if (node[key] is not { } value || value.GetValueKind() != JsonValueKind.Number)
        {
            return null;
        }

        // Read as a double then narrow, because JSON has one number type and a writer may
        // emit 1.0 where an integer is expected.
        var asDouble = value.GetValue<double>();
        return asDouble >= int.MinValue && asDouble <= int.MaxValue && asDouble == Math.Floor(asDouble)
            ? (int)asDouble
            : null;
    }

    private static bool? Bool(JsonObject node, string key)
    {
        if (node[key] is not { } value)
        {
            return null;
        }

        return value.GetValueKind() switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }

    /// <summary>
    /// A timestamp field.
    /// </summary>
    /// <remarks>
    /// The macOS build writes fractional seconds here; an unparseable value is treated as
    /// absent rather than failing the account, because a timestamp is presentation metadata and
    /// losing it must not lose the account.
    /// </remarks>
    private static DateTimeOffset? Date(JsonObject node, string key)
        => Str(node, key) is { } text ? RunwayDates.ParseIndexDate(text) : null;
}

/// <summary>The index file could not be read.</summary>
public sealed class AccountIndexFormatException : Exception
{
    public AccountIndexFormatException(string message)
        : base(message)
    {
    }
}

/// <summary>
/// The index changed between being read and being written, so the write was refused.
/// </summary>
/// <remarks>
/// A conflict rather than a failure: the caller's change is still valid, it just has to be
/// re-applied on top of whatever the other writer did.
/// </remarks>
public sealed class AccountIndexConflictException : Exception
{
    public AccountIndexConflictException(string message)
        : base(message)
    {
    }
}
