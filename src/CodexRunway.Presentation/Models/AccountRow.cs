using CodexRunway.Core;

namespace CodexRunway.Presentation;

/// <summary>How an account row should be presented.</summary>
public enum RowTone
{
    /// <summary>Usable, nothing to draw attention to.</summary>
    Normal,

    /// <summary>Usable but notable — an approaching limit, an expiring credential.</summary>
    Caution,

    /// <summary>Not usable until the user acts.</summary>
    Problem,

    /// <summary>Currently the account Codex is using.</summary>
    Active,
}

/// <summary>
/// One account as the window shows it.
/// </summary>
/// <remarks>
/// Built from a <see cref="CodexAuth"/> and the account's stored metadata. It holds no
/// secret: the key is reduced to a masked label at construction, so a row can be logged,
/// serialised in a crash report, or shown in a tooltip without leaking anything. That is a
/// deliberate departure from passing the credential around — the macOS app redacts by
/// discipline, which is easy to forget at a call site.
/// </remarks>
public sealed record AccountRow
{
    public required string Id { get; init; }

    /// <summary>What the user called this account, falling back to a derived name.</summary>
    public required string Title { get; init; }

    /// <summary>Secondary line: plan, workspace, or the masked key.</summary>
    public string? Subtitle { get; init; }

    public required bool IsApiKey { get; init; }

    public required LoginUsability Usability { get; init; }

    /// <summary>The stored plan name, when the index carried one.</summary>
    public string? PlanType { get; init; }

    /// <summary>The ChatGPT user id, shown so a user can tell two similar logins apart.</summary>
    public string? UserId { get; init; }

    /// <summary>The workspace the credential is scoped to.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>The workspace's human name, when known.</summary>
    public string? WorkspaceName { get; init; }

    /// <summary>When the subscription lapses, when the token claimed a date.</summary>
    public DateTimeOffset? SubscriptionExpiresAt { get; init; }

    /// <summary>
    /// A short "expires in …" line, shown only when it is close enough to matter.
    /// </summary>
    /// <remarks>
    /// Suppressed beyond a fortnight: a date a month away is information, not a warning, and
    /// showing it on every card is how a real warning stops being noticed.
    /// </remarks>
    public string? ExpiryNotice { get; init; }

    /// <summary>Whether the expiry notice is close enough to be worth drawing attention to.</summary>
    public bool ExpiryIsUrgent { get; init; }

    /// <summary>Whether to draw the expiry line at all.</summary>
    public bool HasExpiryNotice => !string.IsNullOrWhiteSpace(ExpiryNotice);

    /// <summary>Whether a workspace line should be drawn.</summary>
    public bool HasWorkspace => !string.IsNullOrWhiteSpace(WorkspaceId) || !string.IsNullOrWhiteSpace(WorkspaceName);

    /// <summary>The workspace text: name when known, otherwise the id.</summary>
    public string? WorkspaceLine => WorkspaceName is { Length: > 0 } name
        ? WorkspaceId is { Length: > 0 } id ? $"{name} · {id}" : name
        : WorkspaceId;

    /// <summary>Whether a user-id line should be drawn.</summary>
    public bool HasUserId => !string.IsNullOrWhiteSpace(UserId);

    public bool IsActive { get; init; }

    /// <summary>True when the credential needs the user to sign in again.</summary>
    public bool NeedsReauth { get; init; }

    /// <summary>Quota as a percentage of the window used, when known.</summary>
    public double? UsedPercent { get; init; }

    /// <summary>A short quota summary, e.g. "62% · resets in 3h".</summary>
    public string? QuotaSummary { get; init; }

    /// <summary>The quota windows to draw, when a reading is available.</summary>
    public AccountQuotaView? Quota { get; init; }

    /// <summary>Whether there is a quota block to draw at all.</summary>
    public bool HasQuota => Quota?.HasAny == true;

    /// <summary>The plan badge text, when known.</summary>
    public string? PlanBadge => Quota?.Plan ?? PlanType;

    public RowTone Tone => ResolveTone();

    /// <summary>
    /// Booleans for binding.
    /// </summary>
    /// <remarks>
    /// A view binds to a bool far more easily than to an enum — Avalonia's class selector takes
    /// one directly — and stating the three cases here keeps the mapping in one place instead of
    /// asking each view to compare enum values for itself.
    /// </remarks>
    public bool IsProblem => Tone == RowTone.Problem;

    /// <inheritdoc cref="IsProblem"/>
    public bool IsCaution => Tone == RowTone.Caution;

    /// <summary>Whether there is a quota line to show, so the view can hide an empty one.</summary>
    public bool HasQuotaSummary => !string.IsNullOrWhiteSpace(QuotaSummary);

    /// <summary>
    /// Whether to offer a switch action on this row.
    /// </summary>
    /// <remarks>
    /// Hidden for the account already in use, and for one that cannot be activated. A button
    /// that is present but refuses looks broken, and one on the current account implies a change
    /// that would not happen.
    /// </remarks>
    public bool ShowSwitchAction => CanActivate && !IsActive;

    /// <summary>
    /// Whether to explain the absence of quota rather than leaving a blank gap.
    /// </summary>
    /// <remarks>
    /// Only for a subscription account: a relay account has a balance rather than a quota, so
    /// saying "no quota data" there would be misleading rather than informative.
    /// </remarks>
    public bool NeedsQuotaNotice => !HasQuota && !IsApiKey && !NeedsReauth;

    /// <summary>
    /// The account is unusable, so it must read as a problem rather than as a preference.
    /// </summary>
    public bool CanActivate => Usability == LoginUsability.Usable && !NeedsReauth;

    /// <summary>
    /// Builds a row, masking any credential material.
    /// </summary>
    /// <remarks>
    /// The masked key keeps its length and its first four characters, matching the macOS
    /// app's rule and the relay panel's own convention. Keeping the length matters because
    /// a user compares it against the panel that issued the key to spot a truncated paste.
    /// </remarks>
    public static AccountRow From(
        string id,
        string? alias,
        string? displayName,
        string? email,
        CodexAuth auth,
        bool isActive,
        bool needsReauth,
        double? usedPercent = null,
        string? quotaSummary = null,
        string? planType = null,
        AccountQuotaView? quota = null,
        string? userId = null,
        string? workspaceId = null,
        string? workspaceName = null,
        DateTimeOffset? subscriptionExpiresAt = null,
        DateTimeOffset? now = null)
    {
        const string FallbackTitle = "(unnamed account)";

        var title = FirstNonEmpty(alias, displayName, email) ?? MaskedKey(auth) ?? FallbackTitle;
        // The stored plan is preferred over the credential's, because the index is what the
        // settings window writes and therefore what the user last saw.
        var subtitle = SubtitleFor(alias, displayName, email, auth, planType);

        return new AccountRow
        {
            Id = id,
            Title = title,
            Subtitle = subtitle,
            IsApiKey = auth.IsApiKeyAuth,
            Usability = auth.GetLoginUsability(),
            IsActive = isActive,
            NeedsReauth = needsReauth,
            UsedPercent = usedPercent,
            QuotaSummary = quotaSummary,
            PlanType = planType,
            Quota = quota,
            UserId = userId,
            WorkspaceId = workspaceId,
            WorkspaceName = workspaceName,
            SubscriptionExpiresAt = subscriptionExpiresAt,
            ExpiryNotice = ExpiryTextFor(subscriptionExpiresAt, now ?? DateTimeOffset.Now),
            ExpiryIsUrgent = IsExpiryUrgent(subscriptionExpiresAt, now ?? DateTimeOffset.Now),
        };
    }

    /// <summary>How soon an expiry is worth flagging.</summary>
    private static readonly TimeSpan ExpiryWarningWindow = TimeSpan.FromDays(14);

    /// <summary>
    /// A short expiry line, or null when the date is absent or comfortably far off.
    /// </summary>
    /// <remarks>
    /// Days are the unit that matters here — a subscription does not lapse in minutes — and an
    /// already-expired date says so rather than reporting a negative duration.
    /// </remarks>
    private static string? ExpiryTextFor(DateTimeOffset? expiresAt, DateTimeOffset now)
    {
        if (expiresAt is not { } expiry)
        {
            return null;
        }

        var remaining = expiry - now;
        if (remaining <= TimeSpan.Zero)
        {
            return "订阅已到期";
        }

        if (remaining > ExpiryWarningWindow)
        {
            return null;
        }

        var days = (int)Math.Floor(remaining.TotalDays);
        var hours = remaining.Hours;

        return days > 0
            ? $"订阅 {days} 天 {hours} 小时后到期"
            : $"订阅 {Math.Max(1, hours)} 小时后到期";
    }

    private static bool IsExpiryUrgent(DateTimeOffset? expiresAt, DateTimeOffset now)
        => expiresAt is { } expiry && expiry - now <= TimeSpan.FromDays(3);

    private RowTone ResolveTone()
    {
        if (NeedsReauth || Usability != LoginUsability.Usable)
        {
            return RowTone.Problem;
        }

        if (IsActive)
        {
            return RowTone.Active;
        }

        // An account close to its limit is worth noticing before it runs out.
        return UsedPercent is >= 80 ? RowTone.Caution : RowTone.Normal;
    }

    private static string? SubtitleFor(
        string? alias,
        string? displayName,
        string? email,
        CodexAuth auth,
        string? storedPlan)
    {
        if (auth.IsApiKeyAuth)
        {
            var masked = MaskedKey(auth);
            return masked is null ? null : masked;
        }

        // For a subscription account the plan is the useful second line.
        var plan = storedPlan ?? auth.PlanType ?? auth.AuthFilePlanType;
        var identity = FirstNonEmpty(email, displayName);

        return (plan, identity) switch
        {
            (not null, not null) => $"{plan} · {identity}",
            (not null, null) => plan,
            (null, not null) => identity,
            _ => alias is null ? null : displayName,
        };
    }

    /// <summary>
    /// A key reduced to something safe to display. Never returns more than four characters
    /// of the original.
    /// </summary>
    private static string? MaskedKey(CodexAuth auth)
    {
        var key = auth.OpenAiApiKey;
        if (string.IsNullOrEmpty(key))
        {
            return null;
        }

        // Short values are masked whole: four characters out of five is not a mask.
        if (key.Length <= 8)
        {
            return new string('•', 8);
        }

        return key[..4] + new string('•', Math.Min(8, key.Length - 4));
    }

    private static string? FirstNonEmpty(params string?[] values)
        => values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
}
