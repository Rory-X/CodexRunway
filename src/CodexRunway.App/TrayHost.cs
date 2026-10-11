using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Forms;
using CodexRunway.Core;
using CodexRunway.Presentation;

namespace CodexRunway.App;

/// <summary>
/// Owns the tray icon and the flyout window.
/// </summary>
/// <remarks>
/// <para>
/// This is the Windows counterpart of a macOS menu-bar item, and it is the one place in the
/// project that has to talk to a Windows-only API directly: WPF has no tray control, so
/// <see cref="NotifyIcon"/> from WinForms supplies it.
/// </para>
/// <para>
/// Only wiring lives here. Everything about what the window shows — which accounts, in which
/// order, how a value reads — comes from <c>CodexRunway.Presentation</c>, which is
/// platform-neutral and therefore covered by ordinary unit tests.
/// </para>
/// </remarks>
public sealed class TrayHost : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly PanelLoader _loader;
    private readonly AccountDiscovery _discovery;
    private readonly CredentialStore _store;
    private FlyoutWindow? _flyout;
    private bool _disposed;

    public TrayHost()
    {
        var paths = RunwayPaths.FromEnvironment();
        paths.EnsureAppDirectories();
        var store = new CredentialStore(paths);
        _loader = new PanelLoader(store);
        _discovery = new AccountDiscovery(paths);
        _store = store;

        _icon = new NotifyIcon
        {
            Icon = TrayIcon.Create(),
            // The account count is the one thing worth knowing without opening the panel.
            Text = "CodexRunway",
            Visible = true,
        };
        _icon.MouseUp += OnIconMouseUp;
    }

    /// <summary>Shows the tray icon. The icon is visible from construction.</summary>
    public void Start() => Refresh();

    private void OnIconMouseUp(object? sender, MouseEventArgs e)
    {
        // Left click opens the panel; right click is reserved for a context menu later.
        if (e.Button == MouseButtons.Left)
        {
            ToggleFlyout();
        }
    }

    private void ToggleFlyout()
    {
        if (_flyout is { IsVisible: true })
        {
            _flyout.Hide();
            return;
        }

        _flyout ??= BuildFlyout();
        Refresh();
        _flyout.ShowNear(_icon);
    }

    private FlyoutWindow BuildFlyout()
    {
        var window = new FlyoutWindow();
        window.Closing += (_, args) =>
        {
            // Closing hides rather than exits: a tray app that quits when its panel closes
            // looks like it crashed.
            args.Cancel = true;
            window.Hide();
        };
        window.RefreshRequested += (_, _) => Refresh();
        window.SwitchRequested += (_, id) => OnSwitchRequested(id);
        return window;
    }

    /// <summary>Reloads account state into the panel.</summary>
    /// <remarks>
    /// Accounts are discovered from the accounts directory and matched against the live
    /// credential to find the active one, so the panel is useful before the account index is
    /// ported. Any failure here leaves the tray alive and reports the problem in the panel,
    /// rather than taking down a long-running tray process.
    /// </remarks>
    public void Refresh()
    {
        PanelState state;
        try
        {
            state = _loader.Load(
                _discovery.Discover(),
                _discovery.ActiveAccountId(_store),
                PanelModuleNames.DefaultOrder,
                DateTimeOffset.Now);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            state = PanelState.Failed("accounts_unreadable", PanelModuleNames.DefaultOrder);
        }

        _flyout?.Apply(state);

        // The tooltip is the only place the count is visible without opening the panel.
        _icon.Text = state.Status switch
        {
            PanelStatus.Ready => $"CodexRunway — {state.Accounts.Count} accounts",
            PanelStatus.Failed => "CodexRunway — accounts unreadable",
            _ => "CodexRunway",
        };
    }

    private void OnSwitchRequested(string accountId)
    {
        // Wiring the actual switch needs the transaction layer, which is not ported yet.
        // Reporting it plainly beats a button that appears to work and does nothing.
        System.Windows.MessageBox.Show(
            $"Switching is not wired up yet (requested {accountId}).",
            "CodexRunway",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _icon.MouseUp -= OnIconMouseUp;
        _icon.Visible = false;
        _icon.Dispose();
        _flyout?.Close();
    }
}

/// <summary>
/// Draws the tray icon.
/// </summary>
/// <remarks>
/// Generated rather than shipped as a file, so the project has no binary asset to keep in
/// step, and the icon scales from a single definition.
/// </remarks>
internal static class TrayIcon
{
    public static Icon Create()
    {
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            // A rounded square with a runway stripe: legible at 16px, which is what the
            // notification area actually renders.
            using var fill = new SolidBrush(Color.FromArgb(255, 76, 141, 255));
            g.FillEllipse(fill, 2, 2, 28, 28);
            using var pen = new Pen(Color.White, 2.5f) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round };
            g.DrawLine(pen, 10, 20, 16, 11);
            g.DrawLine(pen, 16, 11, 22, 20);
        }

        // Icon.FromHandle does not own the handle, so the copy keeps the icon alive after
        // the bitmap is disposed.
        var handle = bitmap.GetHicon();
        using var fromHandle = Icon.FromHandle(handle);
        return (Icon)fromHandle.Clone();
    }
}
