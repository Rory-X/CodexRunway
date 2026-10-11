using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Atomic replacement of Codex's own files.
/// </summary>
/// <remarks>
/// Codex and its desktop app read <c>config.toml</c> and <c>auth.json</c> while this app
/// rewrites them, so a half-written file is a real failure mode. The Windows-specific
/// fallbacks cannot be exercised from macOS — the kernel makes every approach succeed there —
/// so these tests pin the guarantees that hold everywhere, and the Windows order of attempts
/// is documented rather than asserted.
/// </remarks>
public class AtomicWriteTests : IDisposable
{
    private readonly string _dir;

    public AtomicWriteTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), $"atomic-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private string Target => Path.Combine(_dir, "config.toml");

    [Fact]
    public void WritesANewFile()
    {
        CodexConfigProviderEditor.AtomicWrite("hello", Target);

        Assert.Equal("hello", File.ReadAllText(Target));
    }

    [Fact]
    public void ReplacesAnExistingFile()
    {
        File.WriteAllText(Target, "old");

        CodexConfigProviderEditor.AtomicWrite("new", Target);

        Assert.Equal("new", File.ReadAllText(Target));
    }

    /// <summary>Repeated replacement is the normal case: every switch rewrites the config.</summary>
    [Fact]
    public void CanBeCalledRepeatedly()
    {
        for (var i = 0; i < 50; i++)
        {
            CodexConfigProviderEditor.AtomicWrite($"value-{i}", Target);
        }

        Assert.Equal("value-49", File.ReadAllText(Target));
    }

    /// <summary>
    /// The temporary file is what makes the write atomic. If one is left behind the directory
    /// accumulates them, and a leftover may hold the old credential.
    /// </summary>
    [Fact]
    public void NoTemporaryFileIsLeftBehind()
    {
        CodexConfigProviderEditor.AtomicWrite("hello", Target);

        var files = Directory.GetFiles(_dir);

        // One file, and it is the target. Hidden temporaries are named with a leading dot, so
        // a glob would miss them — the directory listing is the honest check.
        Assert.Single(files);
        Assert.EndsWith("config.toml", files[0], StringComparison.Ordinal);
    }

    [Fact]
    public void NoTemporaryFileSurvivesAFailure()
    {
        // A directory in place of the target makes the replace fail.
        Directory.CreateDirectory(Target);

        Assert.ThrowsAny<Exception>(() => CodexConfigProviderEditor.AtomicWrite("hello", Target));

        var leftovers = Directory.GetFiles(_dir, ".*", SearchOption.TopDirectoryOnly);
        Assert.Empty(leftovers);
    }

    [Fact]
    public void WritingCreatesTheDirectory()
    {
        var nested = Path.Combine(_dir, "a", "b", "config.toml");

        CodexConfigProviderEditor.AtomicWrite("hello", nested);

        Assert.Equal("hello", File.ReadAllText(nested));
    }

    /// <summary>
    /// A reader must never see a partial file: with one writer and one reader running together,
    /// every observed value is either the old or the new one.
    /// </summary>
    [Fact]
    public async Task AConcurrentReaderNeverSeesAPartialFile()
    {
        const string oldValue = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        const string newValue = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        File.WriteAllText(Target, oldValue);

        var stop = new CancellationTokenSource();
        var bad = 0;
        var reader = Task.Run(() =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    var text = File.ReadAllText(Target);
                    if (text != oldValue && text != newValue)
                    {
                        Interlocked.Increment(ref bad);
                    }
                }
                catch (IOException)
                {
                    // A reader racing the replace may be refused; that is not a torn read.
                }
            }
        });

        for (var i = 0; i < 200; i++)
        {
            CodexConfigProviderEditor.AtomicWrite(i % 2 == 0 ? newValue : oldValue, Target);
        }

        stop.Cancel();
        await reader.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(0, bad);
    }

    /// <summary>Bytes, not text: credentials are written this way too.</summary>
    [Fact]
    public void WritesArbitraryBytes()
    {
        var bytes = new byte[] { 0x00, 0x01, 0xFF, 0x7F };

        CodexConfigProviderEditor.AtomicWrite(bytes, Target);

        Assert.Equal(bytes, File.ReadAllBytes(Target));
    }
}
