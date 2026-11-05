using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace XDict.App;

public partial class App : Application
{
    private Window? window;
    private readonly Mutex? instance;
    private readonly bool alreadyRunning;
    private EventWaitHandle? activation;
    private Thread? activationThread;
    private volatile DispatcherQueue? dispatcher;

    /// <summary>The first instance's activation event: a second launch asks it to show the window instead of doing nothing.</summary>
    private const string ActivationName = "Local\\XDict.Activate";

    /// <summary>The main window's root, so a theme change reaches it as well as the Settings window.</summary>
    public static Microsoft.UI.Xaml.FrameworkElement? CurrentRoot { get; set; }

    public App()
    {
        InitializeComponent();
        // One XDict per desktop: a second instance would share library.json and the service's data folder file by
        // file. The mutex lives as long as the process.
        instance = new Mutex(initiallyOwned: true, "Local\\XDict.SingleInstance", out bool created);
        alreadyRunning = !created;
        if (created) StartActivation();
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
        if (alreadyRunning)
        {
            // The running instance owns the tray and the service; ask it to come forward, then leave.
            SignalExisting();
            Exit();
            return;
        }
        // A pane folder a stopping WebView2 would not release is collected here, a day later.
        PaneFactory.SweepStale(TimeSpan.FromDays(1));
        // An upgrade from the x86 install path leaves the Run value naming the removed copy; the reader's own launch
        // is the one moment it can be repointed without writing another user's registry.
        StartupRegistration.Repair();
        window = new MainWindow();
        dispatcher = window.DispatcherQueue;
        window.Activate();
    }

    /// <summary>One event, one waiter: the first instance holds it; a second launch sets it and exits.</summary>
    private void StartActivation()
    {
        try
        {
            activation = new EventWaitHandle(false, EventResetMode.AutoReset, ActivationName);
        }
        catch (Exception)
        {
            // A denied or malformed event costs duplicate-launch activation; the mutex still keeps one XDict.
            return;
        }
        activationThread = new Thread(() =>
        {
            try
            {
                while (activation.WaitOne())
                    dispatcher?.TryEnqueue(() => (window as MainWindow)?.ShowMainWindow());
            }
            catch (Exception)
            {
            }
        })
        {
            IsBackground = true,
            Name = "XDict activation",
        };
        activationThread.Start();
    }

    private static void SignalExisting()
    {
        try
        {
            using EventWaitHandle? handle = EventWaitHandle.OpenExisting(ActivationName);
            handle.Set();
        }
        catch (Exception)
        {
            // The first instance has not created the event yet, or is ending; nothing to activate.
        }
    }
}
