// The review reminder's shell half: one app-notification registration, the permission Windows reports, the plan
// ReviewReminderPlan decides, and the timer that asks again. The toast's click runs the review; the model never
// touches a notification.
using Microsoft.UI.Dispatching;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

public sealed class ReviewReminders : IDisposable
{
    private const double RepeatAfter = 3600;
    /// <summary>A check after a failure, so one closed service does not disable reminders until an unrelated action.</summary>
    private const double RetryAfter = 300;
    /// <summary>An idle check while nothing is due: a card that becomes due later is still found.</summary>
    private const double IdleAfter = 900;

    private readonly ServiceClient client;
    private readonly Action review;
    private readonly DispatcherQueue dispatcher;
    private AppNotificationManager? manager;
    private DispatcherQueueTimer? timer;
    private double lastShown;
    private bool registered;
    private bool askedPermission;
    private bool disposed;
    private int refreshes;

    public ReviewReminders(ServiceClient client, Action review)
    {
        this.client = client;
        this.review = review;
        dispatcher = DispatcherQueue.GetForCurrentThread();
    }

    public bool Supported { get; private set; }
    public ReminderPermission Permission { get; private set; } = ReminderPermission.Unspecified;
    public string? Failure { get; private set; }

    /// <summary>Registers with Windows once; false means the Learning pane must say why no reminder can arrive.</summary>
    public bool Start()
    {
        try
        {
            if (!AppNotificationManager.IsSupported())
            {
                Permission = ReminderPermission.Unsupported;
                return false;
            }
            manager = AppNotificationManager.Default;
            manager.NotificationInvoked += OnInvoked;
            manager.Register();
            registered = true;
            Supported = true;
            Permission = ReviewReminderPlan.PermissionOf(manager.Setting.ToString());
            _ = RefreshAsync();
            return true;
        }
        catch (Exception error)
        {
            Failure = error.Message;
            Permission = ReminderPermission.Unsupported;
            return false;
        }
    }

    /// <summary>The plan, read again after a setting or a resume; one notification at a time, then a later check.</summary>
    public async Task RefreshAsync()
    {
        if (!Supported || manager is null || disposed) return;
        int mine = ++refreshes;
        try
        {
            Permission = ReviewReminderPlan.PermissionOf(manager.Setting.ToString());
            LearningSettings settings = LearningSettings.Load();
            ReviewSummary summary = await new ReviewSession(client).SummaryAsync();
            // A slower refresh that started earlier must not publish over a newer one, or restart a timer after
            // Dispose.
            if (disposed || mine != refreshes) return;
            double now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            ReviewReminderPlan plan = ReviewReminderPlan.Plan(now, summary, Permission, settings.RemindersEnabled);
            // Windows has no separate permission call: the first notification is the request, and the OS shows its
            // prompt (or refuses). Ask once, then read the setting again a minute later.
            if (plan.AskPermission && !askedPermission)
            {
                askedPermission = true;
                Show(Strings.Get("review.reminderAsk"));
                Schedule(60);
                return;
            }
            if (!plan.CanDeliver)
            {
                // Nothing to deliver now is not nothing to deliver ever: keep a slow check alive while the
                // settings still ask for reminders.
                if (settings.RemindersEnabled) Schedule(IdleAfter);
                else timer?.Stop();
                return;
            }
            if (plan.Kind is ReminderKind.Due or ReminderKind.Overdue)
            {
                if (now - lastShown >= RepeatAfter) Show(Strings.Format("review.reminderBody", summary.Due));
                Schedule(RepeatAfter);
                return;
            }
            if (plan.Kind == ReminderKind.NextDue && plan.At is { } at)
            {
                double wait = Math.Clamp(at - now, 1, RepeatAfter);
                Schedule(wait);
            }
        }
        catch (Exception error)
        {
            // The service can be closed or restarting; a reminder must not end the tray. Retry on a bounded timer.
            if (disposed || mine != refreshes) return;
            Failure = error.Message;
            Schedule(RetryAfter);
        }
    }

    private void Schedule(double seconds)
    {
        if (disposed) return;
        timer ??= CreateTimer();
        timer.Stop();
        timer.Interval = TimeSpan.FromSeconds(seconds);
        timer.Start();
    }

    private DispatcherQueueTimer CreateTimer()
    {
        DispatcherQueueTimer created = dispatcher.CreateTimer();
        created.IsRepeating = false;
        created.Tick += (_, _) => _ = RefreshAsync();
        return created;
    }

    private void Show(string body)
    {
        if (manager is null) return;
        AppNotification notification = new AppNotificationBuilder()
            .AddText(Strings.Get("review.reminderTitle"))
            .AddText(body)
            .AddArgument("action", "review")
            .BuildNotification();
        manager.Show(notification);
        lastShown = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    }

    private void OnInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
    {
        if (!args.Argument.Contains("review", StringComparison.Ordinal)) return;
        dispatcher.TryEnqueue(() => review());
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        timer?.Stop();
        if (manager is not null)
        {
            manager.NotificationInvoked -= OnInvoked;
            if (registered)
            {
                try { manager.Unregister(); } catch (Exception) { }
            }
        }
    }
}
