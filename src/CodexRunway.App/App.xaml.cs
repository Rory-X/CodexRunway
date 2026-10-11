// WinForms supplies NotifyIcon; WPF supplies the window. Names that exist in both are aliased
// explicitly so neither namespace silently wins.
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using CodexRunway.Core;
using CodexRunway.Presentation;
using Application = System.Windows.Application;
using Color = System.Drawing.Color;
using ExitEventArgs = System.Windows.ExitEventArgs;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;
using NotifyIcon = System.Windows.Forms.NotifyIcon;
using StartupEventArgs = System.Windows.StartupEventArgs;

namespace CodexRunway.App;

/// <summary>
/// Application entry point.
/// </summary>
/// <remarks>
/// CodexRunway lives in the notification area, which is the Windows counterpart of a macOS
/// menu-bar item — WPF has no tray control of its own, so <see cref="NotifyIcon"/> supplies it.
/// The panel window is created lazily on first open, so a user who never opens it never pays
/// for the window.
/// </remarks>
public partial class App : System.Windows.Application
{
    private NotifyIcon? _tray;
    private MainWindow? _panel;
    private InstanceLock? _instanceLock;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var paths = RunwayPaths.FromEnvironment();
        paths.EnsureAppDirectories();

        // One instance per data directory, or two processes interleave writes to the index and
        // the live credential. Released when the process exits.
        _instanceLock = InstanceLock.TryAcquire(paths);
        if (_instanceLock is null)
        {
            System.Windows.MessageBox.Show(
                "CodexRunway 已在运行。",
                "CodexRunway",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown();
            return;
        }

        var store = new CredentialStore(paths);
        var service = new PanelService(paths, store, new AccountDiscovery(paths));

        _tray = new NotifyIcon
        {
            Icon = TrayIcon.Create(AccentColor()),
            Text = "CodexRunway",
            Visible = true,
        };
        _tray.MouseUp += (_, args) =>
        {
            // Left click opens the panel; right click is the menu. Both are conventions on
            // Windows, and neither should require the other to be discovered first.
            if (args.Button == MouseButtons.Left)
            {
                TogglePanel(service);
            }
        };

        _tray.ContextMenuStrip = BuildTrayMenu(service);

        ShowPanel(service);
    }

    /// <summary>
    /// The tray menu.
    /// </summary>
    /// <remarks>
    /// Short on purpose. The panel is where account work happens; the menu exists so the
    /// frequent actions are reachable without opening it, and so there is a discoverable way to
    /// quit a windowless application.
    /// </remarks>
    private ContextMenuStrip BuildTrayMenu(PanelService service)
    {
        var menu = new ContextMenuStrip();

        var open = new ToolStripMenuItem("打开面板");
        open.Click += (_, _) => ShowPanel(service);
        menu.Items.Add(open);

        var refresh = new ToolStripMenuItem("刷新");
        refresh.Click += (_, _) => _panel?.Refresh();
        menu.Items.Add(refresh);

        menu.Items.Add(new ToolStripSeparator());

        var openFolder = new ToolStripMenuItem("打开数据目录");
        openFolder.Click += (_, _) => OpenFolder(service.Paths.AppHome);
        menu.Items.Add(openFolder);

        menu.Items.Add(new ToolStripSeparator());

        var quit = new ToolStripMenuItem("退出");
        quit.Click += (_, _) => Shutdown();
        menu.Items.Add(quit);

        return menu;
    }

    /// <summary>
    /// Opens a directory in the shell.
    /// </summary>
    /// <remarks>
    /// Wrapped because the data directory is created on startup but can be removed while the app
    /// runs, and a failing menu item is worse than one that explains itself.
    /// </remarks>
    private static void OpenFolder(string path)
    {
        try
        {
            if (!Directory.Exists(path))
            {
                Directory.CreateDirectory(path);
            }

            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = path,
                UseShellExecute = true,
            });
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException
            or System.ComponentModel.Win32Exception)
        {
            System.Windows.MessageBox.Show(
                $"无法打开目录：{path}",
                "CodexRunway",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void TogglePanel(PanelService service)
    {
        if (_panel is { IsVisible: true })
        {
            _panel.Hide();
            return;
        }

        ShowPanel(service);
    }

    private void ShowPanel(PanelService service)
    {
        _panel ??= CreatePanel(service);
        _panel.Refresh();
        _panel.Show();
        _panel.Activate();
    }

    private MainWindow CreatePanel(PanelService service)
    {
        var window = new MainWindow(service);
        window.Closed += (_, _) =>
        {
            // Closing hides: a tray application that quits when its panel closes looks broken.
            // Only an explicit tray exit shuts the process down.
            _panel = null;
        };
        return window;
    }

    /// <summary>The accent colour, read from the theme so the icon cannot drift from the UI.</summary>
    private static Color AccentColor()
        => Current?.TryFindResource("AccentBrush") is System.Windows.Media.SolidColorBrush brush
            ? Color.FromArgb(brush.Color.A, brush.Color.R, brush.Color.G, brush.Color.B)
            : Color.FromArgb(255, 10, 132, 255);

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _instanceLock?.Dispose();
        base.OnExit(e);
    }
}
