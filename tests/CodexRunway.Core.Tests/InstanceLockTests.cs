using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// One instance per data directory.
/// </summary>
/// <remarks>
/// The guard matters because two instances interleaving writes to the account index and the
/// live credential is how those files get corrupted. The macOS build uses <c>flock</c>, which
/// does not interoperate with any Windows lock, so the lock name is platform-specific — these
/// tests pin that rather than assuming a single shared mechanism.
/// </remarks>
public class InstanceLockTests : IDisposable
{
    private readonly string _root;
    private readonly RunwayPaths _paths;

    public InstanceLockTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"lock-{Guid.NewGuid():N}");
        _paths = new RunwayPaths(Path.Combine(_root, ".codex"), Path.Combine(_root, ".codex-runway"));
        Directory.CreateDirectory(_paths.AppHome);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    [Fact]
    public void TheFirstInstanceTakesTheLock()
    {
        using var first = InstanceLock.TryAcquire(_paths);

        Assert.NotNull(first);
    }

    /// <summary>
    /// The behaviour the guard exists for: a second instance must be told, not allowed to run.
    /// </summary>
    [Fact]
    public void ASecondInstanceCannotTakeIt()
    {
        using var first = InstanceLock.TryAcquire(_paths);
        Assert.NotNull(first);

        using var second = InstanceLock.TryAcquire(_paths);

        Assert.Null(second);
    }

    [Fact]
    public void ReleasingLetsAnotherInstanceIn()
    {
        var first = InstanceLock.TryAcquire(_paths);
        Assert.NotNull(first);
        first.Dispose();

        using var second = InstanceLock.TryAcquire(_paths);

        Assert.NotNull(second);
    }

    [Fact]
    public void AFreshDirectoryIsNotLocked()
        => Assert.False(InstanceLock.IsHeld(_paths));

    [Fact]
    public void AHeldLockIsReported()
    {
        using var held = InstanceLock.TryAcquire(_paths);
        Assert.NotNull(held);

        Assert.True(InstanceLock.IsHeld(_paths));
    }

    [Fact]
    public void TheLockIsReleasedOnDispose()
    {
        var held = InstanceLock.TryAcquire(_paths);
        Assert.NotNull(held);
        held.Dispose();

        Assert.False(InstanceLock.IsHeld(_paths));
    }

    [Fact]
    public void DisposingTwiceIsHarmless()
    {
        var held = InstanceLock.TryAcquire(_paths);
        Assert.NotNull(held);

        held.Dispose();
        held.Dispose();
    }

    /// <summary>
    /// Two installs pointed at different directories are independent, so they must not block
    /// each other.
    /// </summary>
    [Fact]
    public void TwoDifferentDataDirectoriesDoNotConflict()
    {
        var other = new RunwayPaths(
            Path.Combine(_root, "other", ".codex"),
            Path.Combine(_root, "other", ".codex-runway"));
        Directory.CreateDirectory(other.AppHome);

        using var first = InstanceLock.TryAcquire(_paths);
        using var second = InstanceLock.TryAcquire(other);

        Assert.NotNull(first);
        Assert.NotNull(second);
    }

    /// <summary>
    /// A Windows instance and a macOS instance sharing one directory must not both believe they
    /// hold the lock — the failure that made a literal <c>flock</c> port unsafe.
    /// </summary>
    [Fact]
    public void TheLockNameDiffersPerPlatform()
    {
        var name = InstanceLock.LockName(_paths);

        Assert.Contains(OperatingSystem.IsWindows() ? "win" : "posix", name, StringComparison.Ordinal);

        // And the two spellings are distinct strings, not merely different on the current OS.
        var windows = name.Replace("-posix", "-win", StringComparison.Ordinal);
        var posix = name.Replace("-win", "-posix", StringComparison.Ordinal);
        Assert.NotEqual(windows, posix);
    }

    /// <summary>
    /// The lock name is stable for one data directory.
    /// </summary>
    /// <remarks>
    /// Both the positive and the negative direction are asserted, because the scope is one
    /// <em>data</em> directory: two configurations that share the app directory must agree on
    /// the name, and a different app directory must not. Without the second half, a name that
    /// silently folded in <c>CodexHome</c> as well would still look stable — two <c>RunwayPaths</c>
    /// built with the same <c>AppHome</c> would agree by construction either way.
    /// </remarks>
    [Fact]
    public void TheLockNameIsStableForADirectory()
    {
        var again = new RunwayPaths(_paths.CodexHome, _paths.AppHome);

        Assert.Equal(InstanceLock.LockName(_paths), InstanceLock.LockName(again));
    }

    /// <summary>
    /// Only the app directory decides the name: a second configuration pointed at the same app
    /// directory but a different Codex directory holds the same lock, because that is the data
    /// the lock protects.
    /// </summary>
    [Fact]
    public void ASharedAppDirectoryMeansASharedLockNameEvenWithADifferentCodexDirectory()
    {
        var other = new RunwayPaths(Path.Combine(_root, "elsewhere", ".codex"), _paths.AppHome);

        Assert.Equal(InstanceLock.LockName(_paths), InstanceLock.LockName(other));
    }

    [Fact]
    public void TheLockNameDiffersForDifferentDirectories()
    {
        var other = new RunwayPaths(Path.Combine(_root, "x"), Path.Combine(_root, "y"));

        Assert.NotEqual(InstanceLock.LockName(_paths), InstanceLock.LockName(other));
    }

    /// <summary>
    /// The name must be usable as a mutex name: no path separators, and not excessively long.
    /// </summary>
    [Fact]
    public void TheLockNameIsSafeToUseAsAMutexName()
    {
        var name = InstanceLock.LockName(_paths);

        Assert.DoesNotContain("/", name, StringComparison.Ordinal);
        Assert.DoesNotContain("\\", name, StringComparison.Ordinal);
        Assert.DoesNotContain(":", name, StringComparison.Ordinal);
        Assert.True(name.Length <= 200, $"lock name too long: {name.Length}");
    }
}
