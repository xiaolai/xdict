using Microsoft.UI.Xaml;

namespace XDict.App;

public partial class App : Application
{
    private Window? window;
    private readonly Mutex? instance;
    private readonly bool alreadyRunning;

    /// <summary>The main window's root, so a theme change reaches it as well as the Settings window.</summary>
    public static Microsoft.UI.Xaml.FrameworkElement? CurrentRoot { get; set; }

    public App()
    {
        InitializeComponent();
        // One XDict per desktop: a second instance would share library.json and the service's data folder file by
        // file. The mutex lives as long as the process.
        instance = new Mutex(initiallyOwned: true, "Local\\XDict.SingleInstance", out bool created);
        alreadyRunning = !created;
        // A windowed application has no console for an exception to land in: keep the last one where it can be read.
        UnhandledException += (_, args) => WriteCrash(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => WriteCrash(args.ExceptionObject as Exception);
    }

    private static void WriteCrash(Exception? error)
    {
        try
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "crash.txt"),
                DateTime.Now.ToString("o") + " " + (error?.ToString() ?? "unknown"));
        }
        catch (Exception)
        {
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (alreadyRunning) { Exit(); return; }
        // A pane folder a stopping WebView2 would not release is collected here, a day later.
        PaneFactory.SweepStale(TimeSpan.FromDays(1));
        window = new MainWindow();
        window.Activate();
    }
}
