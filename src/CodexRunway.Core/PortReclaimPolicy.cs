namespace CodexRunway.Core;

/// <summary>What to do when the OAuth callback port is already taken.</summary>
public enum PortReclaimAction
{
    /// <summary>Report the conflict and let the user decide.</summary>
    ReportConflict,

    /// <summary>Terminate the process holding the port.</summary>
    TerminateHolder,
}

/// <summary>
/// Decides how to handle a port that is already in use.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this is a policy rather than a port.</b> The macOS build reclaims port 1455 by
/// finding whatever process is listening and killing it — first with a graceful signal, then
/// with a forced one. The only check is that the pid is greater than one and is not its own, so
/// any program that happens to hold that port is terminated, and a forced kill also discards
/// whatever that program had unsaved.
/// </para>
/// <para>
/// The port itself cannot be changed: it is part of the redirect URI the OAuth provider has
/// registered, so a different port produces a callback the provider refuses. That leaves two
/// options, and they are not equally safe.
/// </para>
/// <para>
/// On Windows the risk is materially higher. Pids are recycled aggressively, and the
/// enumeration that finds a listener and the kill that follows it are separate operations, so
/// the pid can belong to an unrelated process by the time it is terminated. The listening
/// process may also be a shared component — a proxy, a development server — whose loss is not
/// the user's to accept.
/// </para>
/// <para>
/// So the Windows behaviour is to report the conflict and name the holder, and let the user
/// close it. That is less convenient than the macOS build and strictly safer, and the
/// alternative is this app killing a stranger's process.
/// </para>
/// </remarks>
public static class PortReclaimPolicy
{
    /// <summary>The port the OAuth redirect URI is registered with.</summary>
    public const int CallbackPort = 1455;

    /// <summary>The action to take for the platform this build is running on.</summary>
    public static PortReclaimAction ActionForCurrentPlatform
        => OperatingSystem.IsWindows() ? PortReclaimAction.ReportConflict : PortReclaimAction.TerminateHolder;

    /// <summary>
    /// Whether this build may terminate whatever holds the callback port.
    /// </summary>
    /// <remarks>
    /// Always false on Windows, by the reasoning above. Kept as a named property so a caller
    /// cannot accidentally reach the terminating path by testing the platform itself and
    /// getting the sense of the test wrong.
    /// </remarks>
    public static bool MayTerminateHolder => ActionForCurrentPlatform == PortReclaimAction.TerminateHolder;

    /// <summary>
    /// The message to show when the port is held.
    /// </summary>
    /// <remarks>
    /// A code rather than a sentence, so the wording is resolved by whoever owns the language —
    /// and so this stays testable without a culture.
    /// </remarks>
    public static string ConflictMessageCode => "oauth_port_in_use";
}
