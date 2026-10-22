#if DEBUG
// The capture lab: the production hotkey, reader, constructor and panel, exercised in the interactive session against a
// real Notepad, with Escape, the tray route, a rebinding and (in its own mode) an elevated window's refusal.
using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using XDict.Client;
using XDict.Models;

namespace XDict.App.Capture;

internal static class CaptureLab
{
    private const byte VkShift = 0x10, VkCtrl = 0x11, VkAlt = 0x12;
    private const byte VkEscape = 0x1B, VkHome = 0x24, VkLeft = 0x25, VkRight = 0x27;
    private const uint KeyUp = 0x0002;


    private static void Key(byte vk)
    {
        Win32.keybd_event(vk, 0, 0, UIntPtr.Zero);
        Win32.keybd_event(vk, 0, KeyUp, UIntPtr.Zero);
        Thread.Sleep(40);
    }

    private static void Chord(params byte[] keys)
    {
        foreach (byte key in keys) Win32.keybd_event(key, 0, 0, UIntPtr.Zero);
        for (int i = keys.Length - 1; i >= 0; i--) Win32.keybd_event(keys[i], 0, KeyUp, UIntPtr.Zero);
    }

    public static async Task RunAsync(string configPath, ServiceClient client)
    {
        try
        {
            await RunCoreAsync(configPath, client);
        }
        catch (Exception error)
        {
            string output = "";
            try
            {
                using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(configPath));
                output = config.RootElement.GetProperty("output").GetString()!;
            }
            catch (Exception) { }
            if (output.Length > 0)
                await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
                {
                    error = error.GetType().Name + ": " + error.Message,
                    stack = error.StackTrace,
                }));
        }
    }

    private static async Task RunCoreAsync(string configPath, ServiceClient client)
    {
        using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(configPath));
        JsonElement root = config.RootElement;
        string output = root.GetProperty("output").GetString()!;
        string mode = root.TryGetProperty("mode", out JsonElement modeElement) ? modeElement.GetString()! : "main";
        string settingsPath = root.GetProperty("settings").GetString()!;
        string libraryPath = root.GetProperty("library").GetString()!;
        string textFile = root.GetProperty("text").GetString()!;
        Environment.SetEnvironmentVariable("XDICT_CAPTURE_SETTINGS", settingsPath);

        var report = new Dictionary<string, object?>();
        string log = output + ".log";
        async Task Mark(string step) => await File.AppendAllTextAsync(log, DateTime.Now.ToString("HH:mm:ss.fff") + " " + step + "\n");
        await Mark("start");
        var store = LibraryStore.Load(libraryPath);
        var session = new SearchSession(client);
        await session.OpenAsync(store.Dictionaries);
        var controller = new CaptureController(client, store, session, (_, _) => { });
        report["hotkeyRegistered"] = controller.Start();
        report["trayVisible"] = controller.TrayVisible;
        report["settingsModifiers"] = controller.Settings.Modifiers;
        report["settingsKey"] = controller.Settings.Key;
        await Mark("controller started");
        report["dictionaries"] = session.Dictionaries.Count;

        Process? target = null;
        IntPtr targetWindow = IntPtr.Zero;
        PdfServer? pdfServer = null;
        try
        {
        await Mark("target mode " + mode);
        if (mode is "main" or "relaunch" or "notepad" or "word" or "pdf" or "suspended" or "elevated")
        {
            bool elevated = mode == "elevated";
            bool notepad = mode is "notepad" or "elevated";
            bool word = mode == "word";
            // A Word the harness opened through COM is used as it is; starting WINWORD.EXE shows the Start screen.
            if (mode == "pdf") pdfServer = new PdfServer(textFile);
            target = notepad ? (elevated ? FindElevatedNotepad() : StartNotepad(textFile))
                : word ? WordHost(textFile) : StartEdge(mode == "pdf" && pdfServer is not null ? pdfServer.Url : textFile);
            report["pdfUrl"] = pdfServer?.Url;
            if (target is null) { report["error"] = "no target window"; await WriteAsync(output, report); return; }
            targetWindow = notepad ? NotepadWindow(15000) : word ? WordWindow(15000) : BrowserWindow(15000);
            if (targetWindow == IntPtr.Zero)
            {
                report["notepads"] = Process.GetProcessesByName("notepad").Select(process => process.Id).ToArray();
                report["error"] = "the target opened no window";
                await WriteAsync(output, report);
                return;
            }
            if (!Focus(targetWindow))
            {
                report["notepads"] = Process.GetProcessesByName("notepad").Select(process => process.Id).ToArray();
                report["startedId"] = target.Id;
                report["startedExited"] = target.HasExited;
                report["startedMainWindow"] = target.MainWindowHandle.ToInt64();
                report["foundWindow"] = Win32.MainWindowOf((uint)target.Id).ToInt64();
                IntPtr foreground = Win32.GetForegroundWindow();
                Win32.GetWindowThreadProcessId(foreground, out uint foregroundPid);
                var name = new char[128];
                int length = Win32.GetClassNameW(foreground, name, name.Length);
                report["foreground"] = foreground.ToInt64();
                report["foregroundPid"] = foregroundPid;
                report["foregroundClass"] = new string(name, 0, length);
                report["error"] = "the target did not come to the foreground";
                await WriteAsync(output, report);
                return;
            }
            await Task.Delay(400);
            if (mode is "notepad" or "word" or "pdf")
            {
                if (mode == "word")
                {
                    // Office's "sign in to set up Office" dialog is modal over the document; close it by its own button.
                    bool dismissed = false;
                    long until = Environment.TickCount64 + 15000;
                    while (!dismissed && Environment.TickCount64 < until)
                    {
                        dismissed = DismissOfficeDialog(targetWindow);
                        if (!dismissed) Thread.Sleep(500);
                    }
                    report["officeDialogDismissed"] = dismissed;
                    Thread.Sleep(800);
                    Focus(targetWindow);
                }
                ClickDocument(targetWindow);
                if (mode == "word") report["wordElements"] = OnSta(() => DescribeTree(targetWindow));
                if (mode == "pdf") report["pdfElements"] = OnSta(() => DescribeTree(targetWindow));
                report["documentFocus"] = OnSta(() => System.Windows.Automation.AutomationElement.FocusedElement?.Current.ControlType.ProgrammaticName ?? "");
                report["selectionAfterSelection"] = OnSta(() => SelectWordByUia(targetWindow, 1));
                report["focusAfterSelection"] = OnSta(() => System.Windows.Automation.AutomationElement.FocusedElement?.Current.ControlType.ProgrammaticName ?? "");
            }
            else if (mode is "main" or "relaunch" or "suspended") ClickCenter(targetWindow);
            await Mark("selection made");
            report["foregroundBefore"] = Win32.GetForegroundWindow().ToInt64();
        }

        if (mode is "main" or "relaunch" or "notepad" or "word" or "pdf" or "suspended" or "elevated")
        {
            uint modifiers = controller.Settings.Modifiers, key = controller.Settings.Key;
            bool paused = false;
            if (mode == "suspended")
            {
                // The panel must reach the screen even when the dictionary service is frozen.
                paused = Win32.Suspend(client.ProcessId, true);
                report["serviceSuspended"] = paused;
            }
            long started = Environment.TickCount64;
            await Mark("sending chord");
            // UIPI drops synthetic keys sent to an elevated window, so that case asks through the tray's own route.
            if (mode == "elevated") _ = controller.AskAsync(CaptureTrigger.Menu);
            else Chord(ModifierVk(modifiers, 0x11), ModifierVk(modifiers, 0x12), ModifierVk(modifiers, 0x10), (byte)key);
            await Mark("chord sent");
            long deadline = Environment.TickCount64 + 3000;
            while (controller.Panel is not { Shown: true } && Environment.TickCount64 < deadline) await Task.Delay(10);
            report["pressedModifiers"] = modifiers;
            report["pressedKey"] = key;
            report["panelShown"] = controller.Panel is { Shown: true };
            report["panelMs"] = controller.Panel is { Shown: true } ? Environment.TickCount64 - started : -1;
            long ackDeadline = Environment.TickCount64 + 8000;
            while (controller.Panel is { Shown: true } && controller.LastAcknowledgement is null &&
                   Environment.TickCount64 < ackDeadline) await Task.Delay(20);
            report["term"] = controller.Panel?.Term;
            report["refusal"] = controller.LastRefusal;
            report["focusInfo"] = controller.LastFocusInfo;
            report["foregroundAfterShowImmediate"] = controller.LastForegroundAfterShow;
            report["panelHandle"] = controller.PanelHandle;
            report["focusUnchanged"] = controller.LastFocusUnchanged;
            report["foregroundAfterShow"] = Win32.GetForegroundWindow().ToInt64();
            report["acknowledgement"] = controller.LastAcknowledgement?.Outcome.ToString();
            if (paused)
            {
                Win32.Suspend(client.ProcessId, false);
                report["serviceResumed"] = true;
            }
            report["acknowledgementGeneration"] = controller.LastAcknowledgement?.Generation;
            report["foregroundAfter"] = Win32.GetForegroundWindow().ToInt64();
            report["targetForeground"] = Win32.GetForegroundWindow() == targetWindow;

            if (mode != "elevated" && controller.Panel is { Shown: true })
            {
                Key(VkEscape);
                await Task.Delay(300);
                report["dismissedByEscape"] = controller.Panel is not { Shown: true };
                report["foregroundAfterEscape"] = Win32.GetForegroundWindow().ToInt64();
                report["targetStillForeground"] = Win32.GetForegroundWindow() == targetWindow;
                // The next key must reach the host app: type into Notepad and read the window title's dirty mark.
                Key(0x58); // 'X'
                await Task.Delay(200);
                report["hostReceivedKey"] = Win32.GetForegroundWindow() == targetWindow;

                // A click outside the panel dismisses it, and the host app keeps the foreground.
                Chord(ModifierVk(modifiers, 0x11), ModifierVk(modifiers, 0x12), ModifierVk(modifiers, 0x10), (byte)key);
                long secondDeadline = Environment.TickCount64 + 3000;
                while (controller.Panel is not { Shown: true } && Environment.TickCount64 < secondDeadline) await Task.Delay(10);
                bool secondShown = controller.Panel is { Shown: true };
                ClickCenter(targetWindow);
                await Task.Delay(400);
                report["panelShownAgain"] = secondShown;
                report["dismissedByClickAway"] = secondShown && controller.Panel is not { Shown: true };
                report["foregroundAfterClickAway"] = Win32.GetForegroundWindow().ToInt64();
                report["targetAfterClickAway"] = Win32.GetForegroundWindow() == targetWindow;
            }
        }

        if (mode == "main")
        {
            // The tray's own route runs the same capture path.
            controller.RunTrayCommand(1);
            long trayDeadline = Environment.TickCount64 + 3000;
            while (controller.Panel is not { Shown: true } && Environment.TickCount64 < trayDeadline) await Task.Delay(10);
            report["trayLookupShown"] = controller.Panel is { Shown: true };
            controller.Panel?.Dismiss();

            // A rebinding is saved; the relaunch pass reads it back and presses the new chord.
            CaptureSettings rebound = controller.Rebind(0x0002 | 0x0001 | 0x0004, 0x4B); // Ctrl+Alt+Shift+K
            report["reboundModifiers"] = rebound.Modifiers;
            report["reboundKey"] = rebound.Key;
            report["reboundRegistered"] = controller.HotkeyRegistered;
            // A clash: another window holds Ctrl+Alt+D; the rebinding is refused and the old one keeps working.
            using (var other = new Hotkey(() => { }))
            {
                bool otherHolds = other.Register(0x0002 | 0x0001, 0x44);
                report["otherHoldsDefault"] = otherHolds;
                try
                {
                    controller.Rebind(0x0002 | 0x0001, 0x44);
                    report["clashReported"] = false;
                }
                catch (CaptureClashException)
                {
                    report["clashReported"] = true;
                }
                report["settingsAfterClash"] = new[] { controller.Settings.Modifiers, controller.Settings.Key };
            }
        }

        await Mark("writing report");
        await WriteAsync(output, report);
        await Mark("report written");
        }
        finally
        {
            // Every early return (no target window, no foreground) still ends its Notepad/Word/Edge and the server.
            try { target?.Kill(); } catch (Exception) { }
            pdfServer?.Dispose();
            controller.Dispose();
        }
    }

    private static byte ModifierVk(uint modifiers, byte key) => (modifiers & KeyMask(key)) != 0 ? key : (byte)0;

    private static uint KeyMask(byte key) => key switch
    {
        0x11 => 0x0002, // Ctrl
        0x12 => 0x0001, // Alt
        0x10 => 0x0004, // Shift
        _ => 0,
    };

    private static Process? FirstProcess(string name) => Process.GetProcessesByName(name).FirstOrDefault();

    /// <summary>A running COM-opened Word is reused; otherwise WINWORD.EXE is started (its Start screen is a risk).</summary>
    private static Process? WordHost(string document) =>
        WordWindow(1500) != IntPtr.Zero ? FirstProcess("WINWORD") : StartWord(document);

    /// <summary>Word's own frame is class OpusApp; a first-run dialog is another window and is not the document.</summary>
    private static IntPtr WordWindow(int milliseconds)
    {
        long deadline = Environment.TickCount64 + milliseconds;
        while (Environment.TickCount64 < deadline)
        {
            foreach (Process process in Process.GetProcessesByName("WINWORD"))
            {
                IntPtr window = Win32.WindowOfClass((uint)process.Id, "OpusApp");
                process.Dispose();
                if (window != IntPtr.Zero) return window;
            }
            Thread.Sleep(100);
        }
        return IntPtr.Zero;
    }

    private static Process StartWord(string document)
    {
        string[] candidates =
        [
            @"C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
            @"C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE",
            "winword.exe",
        ];
        string? executable = candidates.FirstOrDefault(candidate => candidate == "winword.exe" || File.Exists(candidate));
        if (executable is null) throw new InvalidOperationException("Word is not installed");
        return Process.Start(new ProcessStartInfo(executable, "\"" + document + "\"") { UseShellExecute = true })!;
    }

    /// <summary>The visible window of any process with this name, waiting while it starts.</summary>
    private static IntPtr ProcessWindow(string name, int milliseconds)
    {
        long deadline = Environment.TickCount64 + milliseconds;
        while (Environment.TickCount64 < deadline)
        {
            foreach (Process process in Process.GetProcessesByName(name))
            {
                IntPtr window = Win32.MainWindowOf((uint)process.Id);
                process.Dispose();
                if (window != IntPtr.Zero) return window;
            }
            Thread.Sleep(100);
        }
        return IntPtr.Zero;
    }

    private static Process StartEdge(string htmlFile)
    {
        string[] candidates =
        [
            @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            @"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
            @"C:\Program Files\Google\Chrome\Application\chrome.exe",
        ];
        string? executable = candidates.FirstOrDefault(File.Exists);
        if (executable is null) throw new InvalidOperationException("no Edge or Chrome found");
        // A bare Windows path is a search term to Chromium; a file URI opens the page or the PDF viewer.
        string target = File.Exists(htmlFile) ? new Uri(htmlFile).AbsoluteUri : htmlFile;
        return Process.Start(new ProcessStartInfo(executable, "\"" + target + "\"") { UseShellExecute = true })!;
    }

    private static IntPtr BrowserWindow(int milliseconds)
    {
        long deadline = Environment.TickCount64 + milliseconds;
        while (Environment.TickCount64 < deadline)
        {
            foreach (string name in new[] { "msedge", "chrome" })
                foreach (Process process in Process.GetProcessesByName(name))
                {
                    IntPtr window = Win32.MainWindowOf((uint)process.Id);
                    process.Dispose();
                    if (window != IntPtr.Zero) return window;
                }
            Thread.Sleep(100);
        }
        return IntPtr.Zero;
    }

    /// <summary>Clicks the middle of the client area, so the page holds focus rather than the address bar.</summary>
    private static void ClickCenter(IntPtr window)
    {
        Win32.GetWindowRect(window, out Win32.RECT rect);
        Win32.SetCursorPos((rect.Left + rect.Right) / 2, (rect.Top + rect.Bottom) / 2);
        Thread.Sleep(150);
        Win32.mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        Win32.mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(300);
    }

    /// <summary>Selects the word at `index` through the document's own TextPattern range and returns the selection's text.</summary>
    private static string SelectWordByUia(IntPtr window, int index)
    {
        var document = TextDocument(window);
        if (document is null) return "<no document>";
        if (!document.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
            return "<no text pattern>";
        var text = (System.Windows.Automation.TextPattern)raw;
        System.Windows.Automation.Text.TextPatternRange word = text.DocumentRange.Clone();
        word.MoveEndpointByRange(System.Windows.Automation.Text.TextPatternRangeEndpoint.End,
            text.DocumentRange, System.Windows.Automation.Text.TextPatternRangeEndpoint.Start);
        word.Move(System.Windows.Automation.Text.TextUnit.Word, index);
        word.ExpandToEnclosingUnit(System.Windows.Automation.Text.TextUnit.Word);
        // RichEdit's word unit takes its trailing space; a reader's drag would not, so take it back off.
        for (int i = 0; i < 4 && word.GetText(-1).EndsWith(' '); i++)
            word.MoveEndpointByUnit(System.Windows.Automation.Text.TextPatternRangeEndpoint.End,
                System.Windows.Automation.Text.TextUnit.Character, -1);
        word.Select();
        var selection = text.GetSelection();
        string detail = "words=" + word.GetText(-1) + " sel=" + selection.Length;
        if (selection.Length == 0)
        {
            // PDFium's TextPattern does not take a programmatic selection; drag the pointer across the word's box,
            // which is how a reader selects in a PDF.
            System.Windows.Rect box = word.GetBoundingRectangles().FirstOrDefault();
            detail += " rect=" + (box.IsEmpty ? "empty" : box.ToString());
            if (!box.IsEmpty) DragAcross(box);
            Thread.Sleep(400);
            selection = text.GetSelection();
            detail += " afterDrag=" + selection.Length;
        }
        return (selection.Length == 0 ? "<none>" : "<" + selection[0].GetText(-1) + ">") + " [" + detail + "]";
    }

    /// <summary>The first elements of a window's tree, names and control types: what a dialog is made of.</summary>
    private static string DescribeTree(IntPtr window)
    {
        var element = System.Windows.Automation.AutomationElement.FromHandle(window);
        if (element is null) return "<no element>";
        var parts = new List<string>();
        foreach (System.Windows.Automation.AutomationElement child in
                 element.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition))
        {
            parts.Add(child.Current.ControlType.ProgrammaticName + " class=" + child.Current.ClassName + " name=" + child.Current.Name);
            if (parts.Count >= 40) break;
        }
        return string.Join(" | ", parts);
    }

    /// <summary>Closes Office's sign-in dialog through the dialog's own close button; false where none was found.</summary>
    private static bool DismissOfficeDialog(IntPtr window) => OnSta(() =>
    {
        // The dialog may be inside Word's frame or a top-level window of its own; both are searched.
        var roots = new List<IntPtr> { window };
        foreach (Process word in Process.GetProcessesByName("WINWORD"))
        {
            roots.AddRange(Win32.TopLevelWindowsOf((uint)word.Id));
            word.Dispose();
        }
        foreach (IntPtr handle in roots.Distinct())
        {
            var root = System.Windows.Automation.AutomationElement.FromHandle(handle);
            if (root is null) continue;
            var dialogs = new List<System.Windows.Automation.AutomationElement>();
            if (root.Current.Name.Contains("Office", StringComparison.Ordinal)) dialogs.Add(root);
            foreach (System.Windows.Automation.AutomationElement child in root.FindAll(
                System.Windows.Automation.TreeScope.Descendants,
                new System.Windows.Automation.PropertyCondition(
                    System.Windows.Automation.AutomationElement.ControlTypeProperty,
                    System.Windows.Automation.ControlType.Window)))
                if (child.Current.Name.Contains("Office", StringComparison.Ordinal)) dialogs.Add(child);
            foreach (System.Windows.Automation.AutomationElement dialog in dialogs)
            {
                var button = dialog.FindFirst(System.Windows.Automation.TreeScope.Descendants, CloseButton());
                if (button?.TryGetCurrentPattern(System.Windows.Automation.InvokePattern.Pattern, out object raw) == true)
                {
                    ((System.Windows.Automation.InvokePattern)raw).Invoke();
                    return true;
                }
            }
        }
        return false;
    });

    private static System.Windows.Automation.Condition CloseButton()
    {
        System.Windows.Automation.Condition named(string name) => new System.Windows.Automation.AndCondition(
            new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.ControlTypeProperty,
                System.Windows.Automation.ControlType.Button),
            new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.NameProperty, name));
        return new System.Windows.Automation.OrCondition(named("关闭"), named("Close"));
    }

    /// <summary>The window's text-bearing Document, not the address bar's Edit; the first text element as fallback.</summary>
    private static System.Windows.Automation.AutomationElement? TextDocument(IntPtr window)
    {
        var root = System.Windows.Automation.AutomationElement.FromHandle(window);
        if (root is null) return null;
        var documents = root.FindAll(System.Windows.Automation.TreeScope.Descendants,
            new System.Windows.Automation.AndCondition(
                new System.Windows.Automation.PropertyCondition(
                    System.Windows.Automation.AutomationElement.IsTextPatternAvailableProperty, true),
                new System.Windows.Automation.PropertyCondition(
                    System.Windows.Automation.AutomationElement.ControlTypeProperty,
                    System.Windows.Automation.ControlType.Document)));
        // Edge's PDF viewer exposes a hidden empty Document beside the page's; the page's is the one with text.
        foreach (System.Windows.Automation.AutomationElement candidate in documents)
            if (candidate.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
                try
                {
                    if (((System.Windows.Automation.TextPattern)raw).DocumentRange.GetText(64).Trim().Length > 0)
                        return candidate;
                }
                catch (Exception) { }
        if (documents.Count > 0) return documents[0];
        return root.FindFirst(System.Windows.Automation.TreeScope.Descendants,
            new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.IsTextPatternAvailableProperty, true));
    }

    /// <summary>Presses at the box's left edge, moves across it, releases — a reader's drag over one word.</summary>
    private static void DragAcross(System.Windows.Rect box)
    {
        int left = (int)box.X + 1, right = (int)(box.X + box.Width) - 2;
        int y = (int)(box.Y + box.Height / 2);
        Win32.SetCursorPos(left, y);
        Thread.Sleep(100);
        Win32.mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); // left down
        for (int x = left + 1; x <= right; x += Math.Max(1, (right - left) / 8))
        {
            Win32.SetCursorPos(x, y);
            Thread.Sleep(20);
        }
        Win32.SetCursorPos(right, y);
        Thread.Sleep(60);
        Win32.mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); // left up
    }

    /// <summary>
    /// Focuses Notepad's document: UIA `SetFocus` on its own STA thread, then a click at its centre, retried until the
    /// focused element is the document (the WinUI menu bar holds focus first).
    /// </summary>
    private static void ClickDocument(IntPtr window)
    {
        for (int attempt = 0; attempt < 6; attempt++)
        {
            (bool found, bool focused, double x, double y) = OnSta(() =>
            {
                var document = TextDocument(window);
                if (document is null) return (false, false, 0.0, 0.0);
                System.Windows.Rect rect = document.Current.BoundingRectangle;
                try { document.SetFocus(); } catch (Exception) { }
                bool onDocument = System.Windows.Automation.AutomationElement.FocusedElement?.Current.ControlType ==
                    System.Windows.Automation.ControlType.Document;
                return (!rect.IsEmpty, onDocument, rect.X + rect.Width / 2, rect.Y + Math.Min(rect.Height / 2, 200));
            });
            if (found && x > 0 && y > 0)
            {
                Win32.SetCursorPos((int)x, (int)y);
                Thread.Sleep(80);
                Win32.mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
                Win32.mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
                Thread.Sleep(250);
            }
            bool nowFocused = OnSta(() =>
                System.Windows.Automation.AutomationElement.FocusedElement?.Current.ControlType ==
                System.Windows.Automation.ControlType.Document);
            if (nowFocused) return;
            Thread.Sleep(200);
        }
    }

    private static T OnSta<T>(Func<T> work)
    {
        T result = default!;
        var thread = new Thread(() => result = work());
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join(2500);
        return result;
    }

    private static Process StartNotepad(string textFile)
    {
        // Windows 11's Notepad may hand the document to another of its processes; the window is found by name below.
        Process process = Process.Start(new ProcessStartInfo("notepad.exe", "\"" + textFile + "\"") { UseShellExecute = true })!;
        return process;
    }

    private static Process? FindElevatedNotepad()
    {
        foreach (Process process in Process.GetProcessesByName("notepad"))
        {
            if (Win32.IsElevated((uint)process.Id)) return process;
            process.Dispose();
        }
        return null;
    }

    /// <summary>The visible window of any Notepad process, waiting while the app starts its tab host.</summary>
    private static IntPtr ProcessWindow(string name) => ProcessWindow(name, 15000);

    private static IntPtr NotepadWindow(int milliseconds)
    {
        long deadline = Environment.TickCount64 + milliseconds;
        while (Environment.TickCount64 < deadline)
        {
            foreach (Process process in Process.GetProcessesByName("notepad"))
            {
                IntPtr window = Win32.MainWindowOf((uint)process.Id);
                process.Dispose();
                if (window != IntPtr.Zero) return window;
            }
            Thread.Sleep(100);
        }
        return IntPtr.Zero;
    }

    private static bool Focus(IntPtr window)
    {
        for (int i = 0; i < 50; i++)
        {
            if (window != IntPtr.Zero && Win32.Raise(window)) return true;
            Thread.Sleep(100);
        }
        return false;
    }

    private static async Task WriteAsync(string path, Dictionary<string, object?> report) =>
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));

    /// <summary>A one-file HTTP source on loopback: Edge opens a PDF from a URL where a file path becomes a download.</summary>
    private sealed class PdfServer : IDisposable
    {
        private readonly System.Net.Sockets.TcpListener listener;
        private readonly byte[] body;
        private readonly CancellationTokenSource stop = new();

        public string Url { get; }

        public PdfServer(string path)
        {
            body = File.ReadAllBytes(path);
            listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
            listener.Start();
            int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
            Url = "http://127.0.0.1:" + port + "/selection.pdf";
            _ = Task.Run(ServeAsync);
        }

        private async Task ServeAsync()
        {
            while (!stop.IsCancellationRequested)
            {
                System.Net.Sockets.TcpClient client;
                try { client = await listener.AcceptTcpClientAsync(); }
                catch (Exception) { return; }
                using (client)
                {
                    try
                    {
                        System.Net.Sockets.NetworkStream stream = client.GetStream();
                        var buffer = new byte[2048];
                        _ = await stream.ReadAsync(buffer.AsMemory(0, buffer.Length), stop.Token);
                        string header = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Disposition: inline\r\n" +
                            "Content-Length: " + body.Length + "\r\nConnection: close\r\n\r\n";
                        byte[] head = System.Text.Encoding.ASCII.GetBytes(header);
                        await stream.WriteAsync(head, stop.Token);
                        await stream.WriteAsync(body, stop.Token);
                        await stream.FlushAsync(stop.Token);
                    }
                    catch (Exception) { }
                }
            }
        }

        public void Dispose()
        {
            stop.Cancel();
            listener.Stop();
        }
    }
}
#endif
