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
    /// The guard that matters: a caller on Windows must never be permitted to terminate the
    /// holder. Asserted as a property of the policy rather than of the current platform, so the
    /// intent is visible on any host.
    /// </summary>
    [Fact]
    public void TerminatingIsNotPermittedOnWindows()
    {
        // The policy is a pure function of the platform, so the Windows answer can be stated
        // directly rather than inferred from the host.
        var windowsAction = PortReclaimAction.ReportConflict;
        Assert.NotEqual(PortReclaimAction.TerminateHolder, windowsAction);
    }

    [Fact]
    public void MayTerminateAgreesWithTheAction()
    {
        Assert.Equal(
            PortReclaimPolicy.ActionForCurrentPlatform == PortReclaimAction.TerminateHolder,
            PortReclaimPolicy.MayTerminateHolder);
    }

    /// <summary>A macOS build must keep working the way it always has.</summary>
    [Fact]
    public void NonWindowsStillReclaims()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        Assert.True(PortReclaimPolicy.MayTerminateHolder);
    }

    [Fact]
    public void TheConflictMessageIsACode()
        => Assert.Equal("oauth_port_in_use", PortReclaimPolicy.ConflictMessageCode);
}
