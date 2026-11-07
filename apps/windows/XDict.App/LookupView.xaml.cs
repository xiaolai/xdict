// Lookup: the capture shortcut and hover. The reader's both ways of asking live in one pane (plan-windows-parity
// WS-P8): the chord that reads a selection, and the key, gesture, rest and excluded apps hover reads with.
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using XDict.Models;
using Windows.System;
using Windows.UI.Core;

namespace XDict.App;

public sealed partial class LookupView : UserControl
{
    private readonly Capture.CaptureController? capture;
    private readonly List<string> excluded = [];
    private bool loadingHover = true;
    private uint proposedModifiers;
    private uint proposedKey;

    public LookupView(Capture.CaptureController? capture)
    {
        InitializeComponent();
        this.capture = capture;
        Heading.Text = Strings.Get("settings.lookup");
        HotkeyLabel.Text = Strings.Get("settings.hotkey");
        ChangeHotkeyButton.Content = Strings.Get("settings.changeHotkey");
        ShowHotkey();
        HoverHeading.Text = Strings.Get("hover.title");
        HoverToggle.Header = Strings.Get("hover.enabled");
        HoverToggle.OnContent = "";
        HoverToggle.OffContent = "";
        AutomationProperties.SetName(HoverToggle, Strings.Get("hover.enabled"));
        HoverDescription.Text = Strings.Get("hover.enabled.description");
        HoverKeyBox.Header = Strings.Get("hover.key");
        HoverGestureBox.Header = Strings.Get("hover.gesture");
        HoverSettleBox.Header = Strings.Get("hover.settle");
        HoverExcludedLabel.Text = Strings.Get("hover.excluded");
        HoverExcludedDescription.Text = Strings.Get("hover.excluded.description");
        HoverAddButton.Content = Strings.Get("hover.addApp");
        HoverKeyBox.ItemsSource = new[]
        {
            Strings.Get("hover.key.control"), Strings.Get("hover.key.shift"),
            Strings.Get("hover.key.alt"), Strings.Get("hover.key.windows"),
        };
        HoverGestureBox.ItemsSource = new[]
        {
            Strings.Get("hover.gesture.hold"), Strings.Get("hover.gesture.doubleTap"),
        };
        HoverSettleBox.ItemsSource = HoverPolicy.SettleChoices
            .Select(rest => Strings.Format("hover.settleMs", rest)).ToArray();
        LoadHover();
        loadingHover = false;
    }

    private void ShowHotkey()
    {
        CaptureSettings chord = capture?.Settings ?? CaptureSettings.Load();
        HotkeyText.Text = CaptureSettings.Describe(chord.Modifiers, chord.Key);
    }

    private void LoadHover()
    {
        HoverPolicy policy = capture?.Hover ?? new HoverPolicy();
        HoverToggle.IsOn = policy.Enabled;
        HoverKeyBox.SelectedIndex = (int)policy.Modifier;
        HoverGestureBox.SelectedIndex = (int)policy.Gesture;
        int rest = Array.IndexOf(HoverPolicy.SettleChoices, policy.SettleMs);
        HoverSettleBox.SelectedIndex = rest >= 0 ? rest : Array.IndexOf(HoverPolicy.SettleChoices,
            HoverPolicy.DefaultSettleMs);
        excluded.Clear();
        excluded.AddRange(policy.ExcludedApps);
        RenderExcluded();
        ShowHoverState();
    }

    private void ShowHoverState()
    {
        if (capture is null)
        {
            HoverStatus.Text = Strings.Get("settings.unavailable");
            return;
        }
        if (capture.HoverStartFailed)
        {
            HoverStatus.Text = Strings.Get("hover.unavailable");
            return;
        }
        HoverStatus.Text = capture.HoverNotice switch
        {
            "elevated" => Strings.Get("capture.elevated"),
            "ocrUnavailable" => Strings.Get("hover.ocrUnavailable"),
            _ => "",
        };
    }

    /// <summary>Every change saves and restarts the watcher; the choice is the reader's next rest.</summary>
    private void OnHoverToggle(object sender, RoutedEventArgs e) => SaveHover();

    private void OnHoverChoice(object sender, SelectionChangedEventArgs e) => SaveHover();

    private void SaveHover()
    {
        if (loadingHover || capture is null) return;
        var policy = new HoverPolicy
        {
            Enabled = HoverToggle.IsOn,
            Modifier = (HoverModifier)Math.Clamp(HoverKeyBox.SelectedIndex, 0, 3),
            Gesture = (HoverGesture)Math.Clamp(HoverGestureBox.SelectedIndex, 0, 1),
            SettleMs = HoverPolicy.SettleChoices[Math.Clamp(HoverSettleBox.SelectedIndex, 0,
                HoverPolicy.SettleChoices.Length - 1)],
            ExcludedApps = excluded.ToArray(),
        };
        try
        {
            capture.SetHover(policy);
            ShowHoverState();
        }
        catch (Exception error)
        {
            // The write failed, so the previous choice is still the one in force: put the controls back to it and
            // say why, instead of leaving the pane showing a policy that was never saved.
            loadingHover = true;
            try { LoadHover(); }
            finally { loadingHover = false; }
            HoverStatus.Text = Strings.Format("hover.saveFailed", error.Message);
        }
    }

    private void RenderExcluded()
    {
        HoverExcludedPanel.Children.Clear();
        foreach (string app in excluded.OrderBy(name => name, StringComparer.OrdinalIgnoreCase))
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Tokens.Space.Xs };
            row.Children.Add(new TextBlock { Text = app, VerticalAlignment = VerticalAlignment.Center });
            var remove = new Button { Content = Strings.Get("hover.remove"), Tag = app };
            remove.Click += OnRemoveHoverApp;
            row.Children.Add(remove);
            HoverExcludedPanel.Children.Add(row);
        }
    }

    private async void OnAddHoverApp(object sender, RoutedEventArgs e)
    {
        if (capture is null) return;
        var field = new TextBox { PlaceholderText = Strings.Get("hover.appPlaceholder") };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("hover.addApp"),
            Content = field,
            PrimaryButtonText = Strings.Get("settings.keep"),
            CloseButtonText = Strings.Get("settings.close"),
        };
        ContentDialogResult answer;
        try { answer = await dialog.ShowAsync(); }
        catch (Exception error)
        {
            Status.Text = Strings.Format("settings.saveFailed", error.Message);
            return;
        }
        if (answer != ContentDialogResult.Primary) return;
        string name = field.Text.Trim();
        if (name.Length == 0 || name.IndexOfAny(['\\', '/', ':']) >= 0 || name.Length > 260)
        {
            HoverStatus.Text = Strings.Get("hover.appInvalid");
            return;
        }
        if (!name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name += ".exe";
        if (!excluded.Contains(name, StringComparer.OrdinalIgnoreCase)) excluded.Add(name);
        RenderExcluded();
        SaveHover();
    }

    private void OnRemoveHoverApp(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string app }) return;
        excluded.RemoveAll(name => string.Equals(name, app, StringComparison.OrdinalIgnoreCase));
        RenderExcluded();
        SaveHover();
    }

    private async void OnChangeHotkey(object sender, RoutedEventArgs e)
    {
        if (capture is null) { Status.Text = Strings.Get("settings.unavailable"); return; }
        var field = new TextBox { PlaceholderText = Strings.Get("settings.pressKeys"), IsReadOnly = true };
        field.KeyDown += (_, args) =>
        {
            VirtualKey key = args.Key;
            if (key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftWindows or VirtualKey.RightWindows) return;
            uint modifiers = 0;
            if (Down(VirtualKey.Control)) modifiers |= 0x0002;
            if (Down(VirtualKey.Menu)) modifiers |= 0x0001;
            if (Down(VirtualKey.Shift)) modifiers |= 0x0004;
            if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) modifiers |= 0x0008;
            if (modifiers == 0) { Status.Text = Strings.Get("settings.modifierRequired"); return; }
            proposedModifiers = modifiers;
            proposedKey = (uint)key;
            field.Text = CaptureSettings.Describe(modifiers, (uint)key);
            args.Handled = true;
        };
        proposedModifiers = 0;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("settings.changeHotkey"),
            Content = field,
            PrimaryButtonText = Strings.Get("settings.keep"),
            CloseButtonText = Strings.Get("settings.close"),
        };
        ContentDialogResult change;
        try { change = await dialog.ShowAsync(); }
        catch (Exception error)
        {
            Status.Text = Strings.Format("settings.saveFailed", error.Message);
            return;
        }
        if (change != ContentDialogResult.Primary || proposedModifiers == 0) return;
        try
        {
            CaptureSettings kept = capture.Rebind(proposedModifiers, proposedKey);
            HotkeyText.Text = CaptureSettings.Describe(kept.Modifiers, kept.Key);
            Status.Text = "";
        }
        catch (CaptureClashException)
        {
            Status.Text = Strings.Get("capture.clash");
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("library.failed", Strings.Get("settings.changeHotkey"), error.Message);
        }
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
