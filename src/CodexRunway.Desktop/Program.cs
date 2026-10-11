using Avalonia;

namespace CodexRunway.Desktop;

/// <summary>
/// Entry point.
/// </summary>
/// <remarks>
/// The whole desktop project is thin: what the window shows and what a click means lives in
/// <c>CodexRunway.Presentation</c>, which is platform-neutral and covered by unit tests. This
/// project only turns that data into controls.
/// </remarks>
internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
        => BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

    /// <summary>Also used by the XAML previewer, which is why it is public and named by convention.</summary>
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
