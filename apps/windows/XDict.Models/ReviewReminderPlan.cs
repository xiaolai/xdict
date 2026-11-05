// The review reminder's non-window plan: when the next toast falls due, whether to register it, and whether the
// reader must be asked for the OS permission first. The toast itself, its registration and its cold/warm activation
// are the shell's; the summary, due date and permission decision are here.
namespace XDict.Models;

public enum ReminderPermission
{
    Unspecified,
    Granted,
    Denied,
    Unsupported,
}

public enum ReminderKind
{
    None,
    Due,
    NextDue,
    Overdue,
}

/// <summary>One decision for the shell: what to show, when, whether to register and whether to ask.</summary>
public sealed record ReviewReminderPlan(
    ReminderKind Kind,
    double? At,
    bool Register,
    bool AskPermission,
    ReminderPermission Permission)
{
    public bool CanDeliver => Permission == ReminderPermission.Granted && Kind != ReminderKind.None;

    /// <summary>The permission Windows reports, as the model's states; an unknown value is never a yes.</summary>
    public static ReminderPermission PermissionOf(string setting) => setting switch
    {
        "Enabled" => ReminderPermission.Granted,
        "DisabledForApplication" or "DisabledForUser" or "DisabledByGroupPolicy" => ReminderPermission.Denied,
        "Unsupported" => ReminderPermission.Unsupported,
        _ => ReminderPermission.Unspecified,
    };

    /// <summary>Due cards remind now; otherwise the next due date, or an overdue one already passed.</summary>
    public static ReviewReminderPlan Plan(double now, ReviewSummary summary, ReminderPermission permission, bool enabled)
    {
        if (!enabled) return new(ReminderKind.None, null, false, false, permission);
        bool ask = permission == ReminderPermission.Unspecified;
        bool granted = permission == ReminderPermission.Granted;
        if (summary.Due > 0) return new(ReminderKind.Due, now, granted, ask, permission);
        if (summary.NextDue is { } next)
            return next <= now
                ? new(ReminderKind.Overdue, now, granted, ask, permission)
                : new(ReminderKind.NextDue, next, granted, ask, permission);
        return new(ReminderKind.None, null, false, false, permission);
    }
}
