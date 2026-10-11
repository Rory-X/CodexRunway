using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// The port-reclaim decision, which is deliberately different on Windows.
/// </summary>
/// <remarks>
/// The macOS build terminates whatever holds the callback port. That is not carried over,
/// because pids are recycled and the kill follows a separate enumeration on Windows, so the
/// process terminated can be an unrelated one. These tests pin the choice so it cannot be
/// undone by accident.
/// </remarks>
public class PortReclaimPolicyTests
{
    /// <summary>The port is fixed by the registered redirect URI, so it is not a tunable.</summary>
    [Fact]
    public void TheCallbackPortMatchesTheMacOsBuild()
        => Assert.Equal(1455, PortReclaimPolicy.CallbackPort);

    /// <summary>
    /// The platform-appropriate action. Recorded per platform rather than asserted globally,
    /// because this test runs on macOS while the behaviour under test is Windows'.
    /// </summary>
    [Fact]
    public void TheActionDependsOnThePlatform()
    {
        var expected = OperatingSystem.IsWindows()
            ? PortReclaimAction.ReportConflict
            : PortReclaimAction.TerminateHolder;

        Assert.Equal(expected, PortReclaimPolicy.ActionForCurrentPlatform);
    }

    /// <summary>
    /// The guard that matters: a call on Windows reports the conflict instead of terminating
    /// the holder.
    /// </summary>
    /// <remarks>
    /// Asserted against the literal value for the host, not by comparing two enum members to
    /// each other — an earlier version asserted <c>ReportConflict != TerminateHolder</c>, which
    /// the compiler guarantees and which no change to this policy could ever break.
    /// <para>
    /// The Windows row of this table cannot be exercised from a non-Windows host, because
    /// <see cref="PortReclaimPolicy.ActionForCurrentPlatform"/> reads the real OS rather than an
    /// injected one. The macOS row is fully falsifiable here; the Windows row needs a Windows
    /// run, and is recorded above in <see cref="PortReclaimPolicy"/> rather than pretended to
    /// be covered.
    /// </para>
    /// </remarks>
    [Fact]
    public void ThePolicyReportsTheConflictOnWindowsInsteadOfTerminating()
    {
        var action = PortReclaimPolicy.ActionForCurrentPlatform;

        if (OperatingSystem.IsWindows())
        {
            Assert.Equal(PortReclaimAction.ReportConflict, action);
            Assert.False(PortReclaimPolicy.MayTerminateHolder);
            return;
        }

        Assert.Equal(PortReclaimAction.TerminateHolder, action);
        // A macOS build must keep working the way it always has.
        Assert.True(PortReclaimPolicy.MayTerminateHolder);
    }

    /// <summary>
    /// <see cref="PortReclaimPolicy.MayTerminateHolder"/> is the single predicate callers use,
    /// so it must carry the platform's answer rather than a value of its own.
    /// </summary>
    /// <remarks>
    /// Pinned against the literal for the host. The previous form compared
    /// <c>ActionForCurrentPlatform == TerminateHolder</c> with <c>MayTerminateHolder</c>, which
    /// is literally how the property is defined — a tautology that no implementation change
    /// could break.
    /// </remarks>
    [Fact]
    public void MayTerminateHolderCarriesThePlatformAnswer()
        => Assert.Equal(
            !OperatingSystem.IsWindows(),
            PortReclaimPolicy.MayTerminateHolder);

    [Fact]
    public void TheConflictMessageIsACode()
        => Assert.Equal("oauth_port_in_use", PortReclaimPolicy.ConflictMessageCode);
}
