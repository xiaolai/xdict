#if DEBUG
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using XDict.Models;

namespace XDict.App;

internal static class EntryNativeChecks
{
    internal const string Csp = "default-src xdict://d/; script-src xdict://d/ 'unsafe-inline'; style-src xdict://d/ 'unsafe-inline'; img-src xdict://d/ data:; connect-src 'none'; object-src 'none'; frame-src xdict://d/; base-uri 'none'; form-action 'none'";
    internal static async Task LoadAsync(EntryPane pane, EntryResponse response)
    {
        var completed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Loaded(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args) => completed.TrySetResult(args.IsSuccess);
        pane.View.CoreWebView2.NavigationCompleted += Loaded;
        try
        {
            await pane.ShowAsync(response);
            if (!await completed.Task.WaitAsync(TimeSpan.FromSeconds(30))) throw new InvalidOperationException("native document did not load");
        }
        finally { pane.View.CoreWebView2.NavigationCompleted -= Loaded; }
    }
    internal static async Task<JsonElement> EvaluateAsync(WebView2 view, string expression)
    {
        string reply = await view.CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
            JsonSerializer.Serialize(new { expression, awaitPromise = true, returnByValue = true })).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        using var json = JsonDocument.Parse(reply);
        if (json.RootElement.TryGetProperty("exceptionDetails", out var error)) throw new InvalidOperationException(error.ToString());
        return json.RootElement.GetProperty("result").GetProperty("value").Clone();
    }
    internal static async Task<object> BridgeAsync(EntryPane pane)
    {
        var messages = new List<EntryBridgeMessage>();
        pane.Message += messages.Add;
        var current = pane.TestBridge;
        foreach (string kind in new[] { "word", "link", "sound" })
        {
            string value = kind == "word" ? "dictionary reader" : "xdict://d/entry/word";
            foreach (var token in new[] { (current.Nonce, current.Generation), ("forged", current.Generation), (current.Nonce, current.Generation - 1) })
            {
                await pane.View.CoreWebView2.ExecuteScriptAsync("chrome.webview.postMessage(" + JsonSerializer.Serialize(new { kind, value, nonce = token.Item1, generation = token.Item2 }) + ")");
                await Task.Delay(100);
            }
        }
        if (messages.Count != 3) throw new InvalidOperationException("forged/stale bridge messages were delivered: " + messages.Count);
        await LoadAsync(pane, new(Encoding.UTF8.GetBytes("<!doctype html><p>new document</p>"), "text/html", Csp));
        await pane.View.CoreWebView2.ExecuteScriptAsync("chrome.webview.postMessage(" + JsonSerializer.Serialize(new { kind = "word", value = "old", nonce = current.Nonce, generation = current.Generation }) + ")");
        await Task.Delay(200);
        if (messages.Count != 3) throw new InvalidOperationException("an old document's bridge survived reload");
        return new { pass = true, accepted = 3, rejected = 7 };
    }
    internal static async Task<object> RtcAsync(EntryPane pane)
    {
        pane.Trace("rtc-start");
        using var probe = new EntryTurnProbe();
        await LoadAsync(pane, new(Encoding.UTF8.GetBytes("<!doctype html><p>TURN byte canary</p>"), "text/html", Csp));
        pane.Trace("rtc-script");
        await pane.View.CoreWebView2.ExecuteScriptAsync(probe.Script).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        pane.Trace("rtc-configured");
        await Task.Delay(2200);
        var state = await EvaluateAsync(pane.View, "({probe:window.__turnProbe,state:window.__turnConnection?.connectionState,ice:window.__turnConnection?.iceConnectionState})");
        await EvaluateAsync(pane.View, "(()=>{window.__turnConnection?.close();return true})()");
        pane.Trace("rtc-complete");
        if (probe.PrivatePackets > 0) throw new InvalidOperationException("private entry bytes reached the TURN observer; packets=" + probe.Packets);
        return new { pass = true, state, packets = probe.Packets, privatePackets = probe.PrivatePackets };
    }

    internal static async Task<object> WordAsync(EntryPane pane)
    {
        await LoadAsync(pane, new(Encoding.UTF8.GetBytes("<!doctype html><p id='word'>dictionary reader</p>"), "text/html", Csp));
        var messages = new List<EntryBridgeMessage>();
        pane.Message += messages.Add;
        JsonElement point = await EvaluateAsync(pane.View, "(()=>{const t=document.getElementById('word').firstChild,r=document.createRange();r.setStart(t,0);r.setEnd(t,10);const b=r.getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}})()");
        foreach (int modifiers in new[] { 0, 2 })
        {
            foreach (string type in new[] { "mousePressed", "mouseReleased" })
                await pane.View.CoreWebView2.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent", JsonSerializer.Serialize(new { type, x = point.GetProperty("x").GetDouble(), y = point.GetProperty("y").GetDouble(), modifiers, button = "left", clickCount = 1 }));
            await Task.Delay(200);
            if (messages.Count != (modifiers == 0 ? 0 : 1)) throw new InvalidOperationException("Windows Ctrl-click was not routed once: " + messages.Count);
        }
        if (messages[0] != new EntryBridgeMessage("word", "dictionary")) throw new InvalidOperationException("Ctrl-click changed the selected word");
        return new { pass = true, plainClicks = 0, controlClicks = 1 };
    }

    internal static async Task<object> IsolatedAsync(WebView2 view, string mode, string folder, IEntrySource source)
    {
        using var observers = new EntryObservers([47090], [47390]);
        await observers.ProveAsync(47090, 47390);
        string layer = mode["control-".Length..];
        using var pane = new EntryPane(view, source) { TestIsolation = layer, TestNetLog = Path.Combine(folder, "netlog.json") };
        await pane.InitializeAsync(Path.Combine(folder, "browser"));
        string target = "http://127.0.0.1:47090/" + observers.Canary;
        string policy = layer == "csp-on" ? Csp : "default-src * data: 'unsafe-inline' 'unsafe-eval'; connect-src *";
        await LoadAsync(pane, new(Encoding.UTF8.GetBytes("<!doctype html><p>isolated guard control</p>"), "text/html", policy));
        int refused = 0;
        pane.Refused += _ => refused++;
        string action = layer.StartsWith("navigation", StringComparison.Ordinal) ? "location.href=" + JsonSerializer.Serialize(target) : "fetch(" + JsonSerializer.Serialize(target) + ").catch(()=>{})";
        await view.CoreWebView2.ExecuteScriptAsync(action);
        await Task.Delay(1800);
        bool escaped = !observers.Requests.IsEmpty && !observers.CanaryPackets.IsEmpty;
        bool expected = layer.EndsWith("-off", StringComparison.Ordinal);
        string location = await view.CoreWebView2.ExecuteScriptAsync("location.href");
        // Navigation cancellation is a document-commit boundary. The filter and CSP own request denial.
        bool navigation = layer.StartsWith("navigation", StringComparison.Ordinal);
        bool left = location != JsonSerializer.Serialize(pane.Document);
        bool actual = navigation ? left : escaped;
        if (actual != expected || (navigation && !expected && refused == 0)) throw new InvalidOperationException("isolated " + layer + ": expected escaped=" + expected + ", requests=" + string.Join(';', observers.Requests));
        // A browser DNS attempt is recorded by this environment's NetLog, not attributed by a machine-wide count.
        string dnsControl = "xdict-dns-control-" + Guid.NewGuid().ToString("N") + ".invalid";
        if (expected) await view.CoreWebView2.ExecuteScriptAsync("fetch('http://" + dnsControl + "/').catch(()=>{})");
        await Task.Delay(500);
        return new { pass = true, layer, escaped, left, refused, location, requests = observers.Requests.ToArray(), bytes = observers.CanaryPackets.ToArray(), dnsControl = expected ? dnsControl : "", byteControl = expected ? observers.Canary : "", netlog = Path.Combine(folder, "netlog.json") };
    }
}
#endif
