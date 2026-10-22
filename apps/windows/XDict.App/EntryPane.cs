// The native Windows entry surface. The dictionary binding is immutable; each document gets a private generation.
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using XDict.Models;

namespace XDict.App;

public sealed record EntryResponse(byte[] Bytes, string Mime, string Csp, int Status = 200, EntryDisplayOptions? Display = null);
public interface IEntrySource
{
    string Dictionary { get; }
    Task<EntryResponse> ResourceAsync(string path, bool sound, CancellationToken cancellation);
}

public sealed class EntryPane : IDisposable
{
    private readonly WebView2 view;
    private readonly IEntrySource source;
    private CoreWebView2Environment? environment;
    private string document = "", nonce = "", csp = "default-src 'none'";
    private byte[] html = [];
    private ulong generation;
    private CancellationTokenSource lifetime = new();
    private string? bridgeId;
    private EntryDisplayOptions displayOptions = new(1, [], "");
    private ReadingPreferences preferences = new();
    private readonly string? edition;
    private readonly ReadingPreferenceStore? preferenceStore;
    private readonly SemaphoreSlim display = new(1, 1);
    private bool ready, verified, disposed, probing;
    private string probePath = "";
    private TaskCompletionSource? navigationProbe;
    private const string ProbeTarget = "xdict://d/entry/__xdict_guard_navigation";
#if DEBUG
    internal string TestFault { get; init; } = "";
    internal Action<string>? TestTrace { get; init; }
    internal string TestIsolation { get; init; } = "";
    internal string? TestNetLog { get; init; }
    internal (string Nonce, ulong Generation) TestBridge => (nonce, generation);
#endif
    internal void Trace(string phase)
    {
#if DEBUG
        TestTrace?.Invoke(phase);
#endif
    }
    private bool Fault(string fault)
    {
#if DEBUG
        return TestFault == fault;
#else
        return false;
#endif
    }
    public string Runtime { get; private set; } = "";
    public string Document => document;
    public event Action<EntryBridgeMessage>? Message;
    public event Action<string>? Refused;
    public event Action<string>? Failure;
    public event Action<string, int, string>? ResourceServed;
    public WebView2 View => view;

    public EntryPane(WebView2 view, IEntrySource source, string? edition = null, ReadingPreferenceStore? preferences = null)
    {
        this.view = view; this.source = source; this.edition = edition; preferenceStore = preferences;
        if (edition is not null && preferences is not null) this.preferences = preferences.Read(edition);
        if (source is DictionaryEntrySource dictionary) dictionary.OriginalStyle = this.preferences.OriginalStyle;
    }

    public async Task InitializeAsync(string userDataFolder)
    {
        var registration = new CoreWebView2CustomSchemeRegistration("xdict") { HasAuthorityComponent = true, TreatAsSecure = 1 };
        var options = new CoreWebView2EnvironmentOptions
        {
            IsCustomCrashReportingEnabled = !Fault("crash"),
            ExclusiveUserDataFolderAccess = true,
            CustomSchemeRegistrations = Fault("scheme") ? [] : new List<CoreWebView2CustomSchemeRegistration> { registration },
        };
        #if DEBUG
        if (TestNetLog is not null) options.AdditionalBrowserArguments = "--log-net-log=\"" + TestNetLog + "\" --net-log-capture-mode=Everything";
#endif
        Trace("environment");
        environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, userDataFolder, options);
        Trace("controller");
        // A control added in an event handler may not be loaded yet; Ensure waits forever for a Loaded it missed.
        if (!view.IsLoaded)
        {
            var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            RoutedEventHandler? handler = null;
            handler = (_, _) => { view.Loaded -= handler; loaded.TrySetResult(); };
            view.Loaded += handler;
            await loaded.Task;
        }
        await view.EnsureCoreWebView2Async(environment);
        Trace("delegates");
        var core = view.CoreWebView2;
        Runtime = environment.BrowserVersionString;
        var settings = core.Settings;
        settings.AreHostObjectsAllowed = false;
        settings.AreDevToolsEnabled = false;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDefaultScriptDialogsEnabled = false;
        settings.IsPasswordAutosaveEnabled = false;
        settings.IsGeneralAutofillEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsWebMessageEnabled = true;
        settings.IsReputationCheckingRequired = false;
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
        if (!Fault("filter")) core.WebResourceRequested += Requested;
        if (!Fault("navigation")
#if DEBUG
            && (TestIsolation.Length == 0 || TestIsolation == "navigation-on")
#endif
            )
        core.NavigationStarting += (_, e) =>
        {
            if (!EntryPolicy.Navigation(e.Uri, document, true))
            {
                e.Cancel = true;
                if (e.Uri == ProbeTarget) navigationProbe?.TrySetResult();
                Refused?.Invoke(e.Uri);
                // Own links are resolved by the shell, never navigated as another document.
                if (e.IsUserInitiated && EntryPolicy.Route(e.Uri) is not EntryRoute.Refused)
                    Message?.Invoke(new("link", e.Uri));
            }
        };
        core.FrameNavigationStarting += (_, e) =>
        {
            if (!EntryPolicy.Navigation(e.Uri, document, false)) { e.Cancel = true; Refused?.Invoke(e.Uri); }
        };
        core.NewWindowRequested += (_, e) => { e.Handled = true; Refused?.Invoke(e.Uri); };
        core.DownloadStarting += (_, e) => e.Cancel = true;
        core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        core.ScriptDialogOpening += (_, _) => { };
        core.LaunchingExternalUriScheme += (_, e) => e.Cancel = true;
        core.ClientCertificateRequested += (_, e) => { e.Cancel = true; e.Handled = true; };
        core.ServerCertificateErrorDetected += (_, e) => e.Action = CoreWebView2ServerCertificateErrorAction.Cancel;
        core.WebMessageReceived += (_, e) =>
        {
            var message = EntryPolicy.Message(e.WebMessageAsJson, e.Source, document, nonce, generation);
#if DEBUG
            if (Fault("bridge"))
            {
                using var forged = JsonDocument.Parse(e.WebMessageAsJson);
                message = new(forged.RootElement.GetProperty("kind").GetString()!, forged.RootElement.GetProperty("value").GetString()!);
            }
#endif
            if (message is not null) Message?.Invoke(message);
        };
        core.ProcessFailed += (_, e) =>
        {
            ready = false;
            lifetime.Cancel();
            Failure?.Invoke(e.ProcessFailedKind.ToString());
        };
        // Reportable settings are read back; delegates and scheme/CSP are exercised by the launch self-test.
        var readback = new Dictionary<string, bool>
        {
            ["crashReporting"] = options.IsCustomCrashReportingEnabled,
            ["scheme"] = options.CustomSchemeRegistrations.Count == 1,
            ["hostObjects"] = !settings.AreHostObjectsAllowed, ["devTools"] = !settings.AreDevToolsEnabled,
            ["menus"] = !settings.AreDefaultContextMenusEnabled, ["dialogs"] = !settings.AreDefaultScriptDialogsEnabled,
            ["passwords"] = !settings.IsPasswordAutosaveEnabled, ["autofill"] = !settings.IsGeneralAutofillEnabled,
            ["reputation"] = !settings.IsReputationCheckingRequired, ["messages"] = settings.IsWebMessageEnabled,
        };
        ready = readback.Values.All(value => value);
        if (!ready) throw new InvalidOperationException(Strings.Get("entry.guardFailed"), new InvalidOperationException(JsonSerializer.Serialize(readback)));
        #if DEBUG
        if (TestIsolation.Length > 0) { verified = true; return; }
#endif
        try { Trace("probe"); await ProbeAsync(); verified = true; Trace("ready"); }
        catch (Exception e)
        {
            ready = false;
            core.Stop();
            throw new InvalidOperationException(Strings.Get("entry.guardFailed"), e);
        }
    }

    public async Task ShowAsync(EntryResponse response)
    {
        if (!verified) throw new InvalidOperationException(Strings.Get("entry.guardFailed"));
        await display.WaitAsync();
        ulong navigation = 0;
        var completed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Starting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
        {
            if (args.Uri == document) navigation = args.NavigationId;
        }
        void Completed(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            if (navigation != 0 && args.NavigationId == navigation) completed.TrySetResult(args.IsSuccess);
        }
        view.CoreWebView2.NavigationStarting += Starting;
        view.CoreWebView2.NavigationCompleted += Completed;
        try
        {
            await DisplayAsync(response);
            // The display lock is held until this navigation finishes: releasing it earlier let the next ShowAsync
            // reset the lifetime under this one, turning its wait into OperationCanceledException in an async-void
            // handler. Serialized instead: the second display starts after this one has landed.
            CancellationToken cancellation = lifetime.Token;
            if (!await completed.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellation))
                throw new InvalidOperationException(Strings.Get("entry.guardFailed"));
        }
        finally
        {
            view.CoreWebView2.NavigationStarting -= Starting;
            view.CoreWebView2.NavigationCompleted -= Completed;
            display.Release();
        }
    }

    public async Task SetReadingAsync(ReadingPreferences value)
    {
        bool changedStyle = preferences.OriginalStyle != value.OriginalStyle;
        preferences = value.Validated();
        if (edition is not null) preferenceStore?.Write(edition, preferences);
        if (source is DictionaryEntrySource dictionary)
        {
            dictionary.OriginalStyle = preferences.OriginalStyle;
            if (changedStyle && verified && dictionary.LastEntry is not null)
            {
                await ShowAsync(await dictionary.EntryAsync(dictionary.LastEntry.Value));
                return;
            }
        }
        if (verified && html.Length > 0) await ShowAsync(new(html, "text/html", csp));
    }
    public Task SetDisplayOptionsAsync(IReadOnlyDictionary<string, string> chosen) => SetReadingAsync(preferences with { DisplayOptions = new Dictionary<string, string>(chosen) });

    private async Task DisplayAsync(EntryResponse response)
    {
        if (!ready || disposed || string.IsNullOrWhiteSpace(response.Csp) || response.Bytes.Length > 16 << 20)
            throw new InvalidOperationException(Strings.Get("entry.guardFailed"));
        lifetime.Cancel();
        lifetime.Dispose();
        lifetime = new CancellationTokenSource();
        generation++;
        nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        document = EntryPolicy.Base + "entry/" + Guid.NewGuid().ToString("N");
        html = response.Bytes;
        if (response.Display is not null) displayOptions = response.Display;
        csp = response.Csp;
        if (bridgeId is not null) view.CoreWebView2.RemoveScriptToExecuteOnDocumentCreated(bridgeId);
        Trace("document-script");
        bridgeId = await view.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(Bridge(nonce, generation) + (probing ? "" : ReadingFrame.Script(preferences) + (Fault("display") ? "" : ReadingFrame.DisplayScript(displayOptions, preferences.DisplayOptions))));
        Trace("document-navigate");
        view.CoreWebView2.Navigate(document);
    }

    private async Task ProbeAsync()
    {
        probing = true;
        probePath = "__xdict_guard_" + Guid.NewGuid().ToString("N") + ".css";
        var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Completed(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs e) => loaded.TrySetResult(e.IsSuccess);
        view.CoreWebView2.NavigationCompleted += Completed;
        try
        {
            const string policy = "default-src xdict://d/; script-src 'unsafe-inline'; style-src xdict://d/; connect-src 'none'; object-src 'none'; base-uri 'none'";
            string test = "<!doctype html><link rel=stylesheet href=xdict://d/r/" + probePath + "><body>Guard self-test<script>fetch('xdict://d/r/" + probePath +
                "').then(()=>document.documentElement.dataset.guard='leaked',()=>document.documentElement.dataset.guard='blocked')</script>";
            await DisplayAsync(new(Encoding.UTF8.GetBytes(test), "text/html", policy));
            Trace("probe-await-load");
            if (!await loaded.Task.WaitAsync(TimeSpan.FromSeconds(10))) throw new InvalidOperationException("scheme/filter probe failed");
            Trace("probe-csp");
            string status = "";
            for (int attempt = 0; attempt < 20; attempt++)
            {
                status = await view.CoreWebView2.ExecuteScriptAsync("document.documentElement.dataset.guard||''").AsTask().WaitAsync(TimeSpan.FromSeconds(10));
                if (status != "\"\"") break;
                await Task.Delay(50);
            }
            string colour = await view.CoreWebView2.ExecuteScriptAsync("getComputedStyle(document.body).color").AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            if (status != "\"blocked\"" || colour != "\"rgb(1, 2, 3)\"") throw new InvalidOperationException("CSP/resource probe failed");
            navigationProbe = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            try
            {
                Trace("probe-navigate");
                view.CoreWebView2.Navigate(ProbeTarget);
                Trace("probe-await-navigation");
                await navigationProbe.Task.WaitAsync(TimeSpan.FromSeconds(3));
                Trace("probe-location");
                if (await view.CoreWebView2.ExecuteScriptAsync("location.href").AsTask().WaitAsync(TimeSpan.FromSeconds(10)) != JsonSerializer.Serialize(document))
                    throw new InvalidOperationException("navigation probe left the document");
            }
            finally { navigationProbe = null; }
        }
        finally { probing = false; view.CoreWebView2.NavigationCompleted -= Completed; }
    }

    private async void Requested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        var deferral = e.GetDeferral();
        ulong requestedGeneration = generation;
        CancellationToken cancellation = lifetime.Token;
        try
        {
            EntryResponse response;
            EntryRoute route = EntryPolicy.Route(e.Request.Uri, e.Request.Method);
#if DEBUG
            // Isolated controls keep only the named layer. Production never takes this branch.
            if (route == EntryRoute.Refused && TestIsolation.Length > 0 && TestIsolation != "filter-on") return;
#endif
            if (!ready || disposed || route == EntryRoute.Refused)
            {
                Refused?.Invoke(e.Request.Uri);
                response = new([], "text/plain", csp, 403);
            }
            else if (route == EntryRoute.Document && e.Request.Uri.Split('#')[0] == document)
                response = new(html, "text/html; charset=utf-8", csp);
            else if (route == EntryRoute.Blocked)
            {
                string remote = Uri.UnescapeDataString(new Uri(e.Request.Uri).AbsolutePath[9..]);
                string label = Uri.TryCreate(remote, UriKind.Absolute, out Uri? target) && target.Host.Length > 0 ? target.Host : remote;
                label = label[..Math.Min(label.Length, 256)];
                string text = System.Security.SecurityElement.Escape(Strings.Format("entry.remoteImage", label))!;
                string svg = "<svg xmlns='http://www.w3.org/2000/svg' width='320' height='64' viewBox='0 0 320 64'><rect width='320' height='64' rx='4' fill='#f3f3f3'/><text x='12' y='36' font-family='Segoe UI,Microsoft YaHei UI,sans-serif' font-size='13' fill='#333333'>" + text + "</text></svg>";
                response = new(Encoding.UTF8.GetBytes(svg), "image/svg+xml", csp);
            }
            else if (route == EntryRoute.Font)
            {
                byte[] font = ReadingFrame.Font(new Uri(e.Request.Uri).AbsolutePath[6..]);
                response = new(font, "font/ttf", csp, font.Length > 0 ? 200 : 404);
            }
            else if (route is EntryRoute.Resource or EntryRoute.Sound)
            {
                var uri = new Uri(e.Request.Uri);
                int prefix = route == EntryRoute.Resource ? 3 : 7;
                if (probing && uri.AbsolutePath == "/r/" + probePath)
                    response = new(Encoding.UTF8.GetBytes("body{color:rgb(1,2,3)}"), "text/css", csp);
                else response = await source.ResourceAsync(uri.AbsolutePath[prefix..] + uri.Query, route == EntryRoute.Sound, cancellation);
            }
            // Blocked is answered above; a route that reaches here is not this entry's (404).
            else response = new([], "text/plain", csp, 404);
            if (cancellation.IsCancellationRequested || requestedGeneration != generation)
                response = new([], "text/plain", "default-src 'none'", 410);
            // The entry's core policy reaches every response, including resources and refusals. Never redirect.
            string headers = "Content-Type: " + response.Mime.Replace("\r", "").Replace("\n", "") + "\r\n" +
                (Fault("csp") ? "" : "Content-Security-Policy: " + csp.Replace("\r", "").Replace("\n", "") + "\r\n") +
                (Fault("connections")
#if DEBUG
                    || TestIsolation.Length > 0
#endif
                    ? "" : "Connection-Allowlist: (response-origin);webrtc=block;report-to=xdict-guard\r\n") +
                "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\n";
            ResourceServed?.Invoke(e.Request.Uri, response.Status, response.Mime);
            var stream = new MemoryStream(response.Bytes);
            e.Response = environment!.CreateWebResourceResponse(stream.AsRandomAccessStream(), response.Status,
                response.Status == 200 ? "OK" : "Refused", headers);
        }
        catch (Exception error)
        {
            e.Response = environment!.CreateWebResourceResponse(null, 403, "Refused", "Content-Security-Policy: default-src 'none'\r\n");
            Failure?.Invoke(error.GetType().Name);
        }
        finally { deferral.Complete(); }
    }

    private static string Bridge(string nonce, ulong generation) => $$"""
        (()=>{'use strict';const send=chrome.webview.postMessage.bind(chrome.webview);
        const nonce={{JsonSerializer.Serialize(nonce)}},generation={{generation}};
        addEventListener('click',e=>{if(!e.isTrusted)return;const a=e.target.closest&&e.target.closest('a[href]');
        if(!a)return;const value=a.href;if(!value.startsWith('xdict://d/'))return;
        e.preventDefault();send({nonce,generation,kind:value.startsWith('xdict://d/sound/')?'sound':'link',value});},true);
        {{ReadingFrame.WordBridge()}}
        })();
        """;

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        lifetime.Cancel();
        view.Close();
        lifetime.Dispose();
    }
}
