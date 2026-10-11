using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using CodexRunway.Core;
using CodexRunway.Desktop.Views;
using CodexRunway.Presentation;

namespace CodexRunway.Desktop;

public partial class App : Application
{
    private PanelService? _service;

    /// <summary>
    /// Loads the XAML. Kept as an override because Avalonia's generator produces the
    /// <c>x:Name</c> fields but not this entry point for an <c>Application</c>.
    /// </summary>
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // ShutdownMode is explicit: this is a tray application, so closing the panel must
            // not end the process.
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;

            var paths = RunwayPaths.FromEnvironment();
            paths.EnsureAppDirectories();
            _service = new PanelService(paths, new CredentialStore(paths), new AccountDiscovery(paths));

            // A single instance, or two processes interleave writes to the index and the live
            // credential. The lock is released when the process exits.
            var instanceLock = InstanceLock.TryAcquire(paths);
            if (instanceLock is null)
            {
                desktop.Shutdown();
                return;
            }

            desktop.Exit += (_, _) => instanceLock.Dispose();

            var window = new MainWindow(_service);
            desktop.MainWindow = window;
            window.Show();
        }

        base.OnFrameworkInitializationCompleted();
    }
}
