using System.Windows;

namespace CodexRunway.App;

/// <summary>
/// Application entry point.
/// </summary>
/// <remarks>
/// CodexRunway is a tray application, so it owns no main window. <c>ShutdownMode</c> is
/// <c>OnExplicitShutdown</c> in the XAML, which is what stops the process exiting the moment
/// the flyout is closed.
/// </remarks>
public partial class App : System.Windows.Application
{
    private TrayHost? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _tray = new TrayHost();
        _tray.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }
}
