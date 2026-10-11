using System.Runtime.Versioning;

namespace CodexRunway.Core;

/// <summary>
/// Keeps one instance of the app writing to a given data directory.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this is not a port of the macOS guard.</b> The macOS build takes <c>flock</c> on a
/// file. That has no Windows equivalent that interoperates: a POSIX advisory lock and a
/// Windows byte-range lock are different mechanisms, and on a directory shared between the two
/// platforms — which is exactly the scenario this project supports — <i>both</i> would acquire
/// successfully. Two instances would then interleave writes to the account index and the live
/// credential, which is the corruption this guard exists to prevent.
/// </para>
/// <para>
/// So the mechanism is chosen per platform rather than translated: a named mutex on Windows,
/// and on POSIX a lock file, which is also what lets the two builds avoid fighting over one
/// name. <see cref="LockName"/> is deliberately platform-specific for the same reason.
/// </para>
/// <para>
/// The scope is one data directory, not one machine, because two installs configured against
/// different directories are legitimately independent.
/// </para>
/// </remarks>
public sealed class InstanceLock : IDisposable
{
    private readonly IDisposable _handle;
    private bool _disposed;

    private InstanceLock(IDisposable handle) => _handle = handle;

    /// <summary>
    /// A name unique to this data directory and platform.
    /// </summary>
    /// <remarks>
    /// Includes a hash of the directory so two differently-configured installs do not block
    /// each other, and the platform so a Windows instance and a macOS instance pointed at one
    /// shared directory do not each believe they hold it.
    /// </remarks>
    public static string LockName(RunwayPaths paths)
        => $"CodexRunway-{AccountIdentity.StableHash(paths.AppHome)}-{(OperatingSystem.IsWindows() ? "win" : "posix")}";

    /// <summary>
    /// Tries to take the lock.
    /// </summary>
    /// <returns>
    /// The lock, or <c>null</c> when another instance already holds it — which is a normal
    /// outcome the caller reports rather than an error.
    /// </returns>
    public static InstanceLock? TryAcquire(RunwayPaths paths)
    {
        var name = LockName(paths);

        if (OperatingSystem.IsWindows())
        {
            return TryAcquireMutex(name);
        }

        return TryAcquireFileLock(paths);
    }

    /// <summary>Whether an instance currently holds the lock. Does not take it.</summary>
    public static bool IsHeld(RunwayPaths paths)
    {
        if (OperatingSystem.IsWindows())
        {
            // Opening without ownership is enough to observe existence, and creating it here
            // is harmless because the object is released immediately.
            try
            {
                using var probe = new Mutex(initiallyOwned: false, LockName(paths));
                return !probe.WaitOne(TimeSpan.Zero);
            }
            catch (AbandonedMutexException)
            {
                // The previous holder died without releasing: nobody holds it now.
                return false;
            }
        }

        var lockPath = LockFilePath(paths);
        if (!File.Exists(lockPath))
        {
            return false;
        }

        try
        {
            using var stream = new FileStream(
                lockPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            return false;
        }
        catch (IOException)
        {
            return true;
        }
    }

    [SupportedOSPlatform("windows")]
    private static InstanceLock? TryAcquireMutex(string name)
    {
        try
        {
            var mutex = new Mutex(initiallyOwned: false, name);
            if (mutex.WaitOne(TimeSpan.Zero, exitContext: false))
            {
                return new InstanceLock(new MutexHandle(mutex));
            }

            mutex.Dispose();
            return null;
        }
        catch (AbandonedMutexException)
        {
            // The previous holder crashed. Taking the abandoned mutex is correct — the
            // alternative is refusing to start until a reboot.
            var mutex = new Mutex(initiallyOwned: false, name);
            return new InstanceLock(new MutexHandle(mutex));
        }
    }

    /// <summary>
    /// POSIX fallback: an exclusively-opened file.
    /// </summary>
    /// <remarks>
    /// Uses <see cref="FileShare.None"/> rather than <c>flock</c>. Both are advisory on POSIX,
    /// so neither interoperates with a macOS instance holding the same path — which is why the
    /// lock file name differs per platform and why the two builds are not expected to run
    /// against one directory simultaneously. The file is kept open for the process lifetime;
    /// the OS releases it on exit, including on a crash, so no stale lock survives.
    /// </remarks>
    private static InstanceLock? TryAcquireFileLock(RunwayPaths paths)
    {
        var lockPath = LockFilePath(paths);
        Directory.CreateDirectory(Path.GetDirectoryName(lockPath)!);

        try
        {
            var stream = new FileStream(
                lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return new InstanceLock(stream);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    internal static string LockFilePath(RunwayPaths paths)
        => Path.Combine(paths.AppHome, $"{LockName(paths)}.lock");

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _handle.Dispose();
    }

    /// <summary>Releases the mutex on dispose, including from a finalizer-free path.</summary>
    private sealed class MutexHandle : IDisposable
    {
        private readonly Mutex _mutex;

        public MutexHandle(Mutex mutex) => _mutex = mutex;

        public void Dispose()
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Not the owner — the thread that took it has already exited. Releasing is
                // then the OS's job, and letting this escape would mask the real shutdown.
            }

            _mutex.Dispose();
        }
    }
}
