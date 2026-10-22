#if DEBUG
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using XDict.Client;
using XDict.Contract;
using XDict.Models;

namespace XDict.App;

internal static class EntryHostileLab
{
    public static async Task<object> RunAsync(WebView2 browser, JsonElement config, ServiceClient client)
    {
        string generated = Path.Combine(config.GetProperty("fixtures").GetString()!, "hostile");
        using var cases = JsonDocument.Parse(await File.ReadAllTextAsync(config.GetProperty("cases").GetString()!));
        JsonElement[] all = cases.RootElement.GetProperty("cases").EnumerateArray().Select(item => item.Clone()).ToArray();
        if (all.Length != 195) throw new InvalidOperationException("the hostile battery must contain all 195 cases");
        using var observers = new EntryObservers(all.Select(c => c.GetProperty("tcp").GetInt32()).Append(47090),
            all.Select(c => c.GetProperty("udp").GetInt32()).Append(47390));
        await observers.ProveAsync(47090, 47390);
        var files = new List<object>
        {
            client.Observe("hostile-mdx", "hostile.mdx", Path.Combine(generated, "hostile.mdx")),
            client.Observe("hostile-mdd", "hostile.mdd", Path.Combine(generated, "hostile.mdd")),
        };
        var package = new { mdx = new { file = "hostile-mdx" }, mdd = new[] { new { file = "hostile-mdd" } } };
        Reply imported = await client.CallAsync("import", new { package }, files);
        if (imported.Error is not null) throw new InvalidOperationException("hostile import: " + imported.Error);
        Reply opened = await client.CallAsync("open", new { package }, files);
        if (opened.Error is not null) throw new InvalidOperationException("hostile open: " + opened.Error);
        string dict = opened.Ok!.Value.GetProperty("dict").GetString()!;
        var source = new DictionaryEntrySource(client, dict);
        string folder = Path.GetDirectoryName(config.GetProperty("output").GetString()!)!;
        using var pane = new EntryPane(browser, source) { TestNetLog = Path.Combine(folder, "netlog.json") };
        await pane.InitializeAsync(Path.Combine(folder, "browser"));
        var rows = new List<object>();
        int refusals = 0, linkMessages = 0;
        pane.Message += message => { if (message.Kind == "link") linkMessages++; };
        pane.Refused += _ => refusals++;
        string mode = config.GetProperty("mode").GetString()!;
        if (mode == "hostile-red")
        {
            using var direct = new System.Net.Http.HttpClient();
            await direct.GetStringAsync("http://127.0.0.1:47090/" + observers.Canary);
        }
        var selected = mode is "hostile-quick" or "hostile-red" ? all.Where(c => c.GetProperty("context").GetString() == "byte-zero").Take(12) : mode == "hostile-allowed" ? all.Where(c => c.GetProperty("group").GetString() == "allowed") : all.AsEnumerable();
        foreach (var item in selected)
        {
            string key = item.GetProperty("id").GetString()!;
            Reply page = await client.CallAsync("lookup", new { query = key, dicts = new[] { dict }, options = new { limit = 10, offset = 0, mode = "link" } });
            if (page.Error is not null) throw new InvalidOperationException("lookup " + key + ": " + page.Error);
            JsonElement reference = page.Ok!.Value.GetProperty("hits")[0].GetProperty("entry").Clone();
            var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            void Complete(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs e) => loaded.TrySetResult(e.IsSuccess);
            browser.CoreWebView2.NavigationCompleted += Complete;
            bool successful;
            try
            {
                await pane.ShowAsync(await source.EntryAsync(reference));
                successful = await loaded.Task.WaitAsync(TimeSpan.FromSeconds(10));
                await browser.CoreWebView2.ExecuteScriptAsync("document.body.appendChild(document.createTextNode(" + JsonSerializer.Serialize(observers.Canary) + "));fetch('http://127.0.0.1:" + item.GetProperty("tcp").GetInt32() + "/" + observers.Canary + "').catch(()=>{})");
                await Task.Delay(item.GetProperty("wait").GetInt32());
                string probe = item.GetProperty("probe").GetString()!;
                if (key == "ok-link-nav")
                {
                    int before = linkMessages;
                    var rect = await EntryNativeChecks.EvaluateAsync(browser, "(()=>{const b=document.getElementById('go').getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}})()");
                    foreach (string type in new[] { "mousePressed", "mouseReleased" })
                        await browser.CoreWebView2.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent", JsonSerializer.Serialize(new { type, x = rect.GetProperty("x").GetDouble(), y = rect.GetProperty("y").GetDouble(), button = "left", clickCount = 1 }));
                    await Task.Delay(400);
                    if (linkMessages != before + 1) throw new InvalidOperationException("trusted entry link was not routed once");
                }
                else if (probe.Length > 0)
                {
                    JsonElement observations = await EntryNativeChecks.EvaluateAsync(browser, "(()=>{" + probe + "})()");
                    int wanted = key == "ok-xdict" ? 4 : 1;
                    if (observations.GetArrayLength() != wanted) throw new InvalidOperationException("allowed fixture failed: " + key + ": " + observations);
                }
            }
            finally { browser.CoreWebView2.NavigationCompleted -= Complete; }
            rows.Add(new { id = key, loaded = successful, requests = observers.Requests.Count, canaryPackets = observers.CanaryPackets.Count });
            await File.WriteAllTextAsync(Path.Combine(folder, "progress.json"), JsonSerializer.Serialize(new { completed = rows.Count, total = selected.Count(), last = key }));
            if (!successful || !observers.Requests.IsEmpty || !observers.CanaryPackets.IsEmpty)
                throw new InvalidOperationException("hostile case failed: " + key + "; requests: " + string.Join(";", observers.Requests));
        }
        // Crash while a generated private marker is present; custom crash reporting is an API read-back requirement.
        await pane.ShowAsync(new(Encoding.UTF8.GetBytes("<!doctype html><p>" + observers.Canary + "</p>"), "text/html",
            "default-src xdict://d/; connect-src 'none'; object-src 'none'"));
        await Task.Delay(300);
        var crashed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pane.Failure += _ => crashed.TrySetResult();
        try { await browser.CoreWebView2.CallDevToolsProtocolMethodAsync("Page.crash", "{}").AsTask().WaitAsync(TimeSpan.FromSeconds(10)); }
        catch (Exception) { /* The RPC is expected to fail when its renderer dies. */ }
        await crashed.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await Task.Delay(500);
        if (!observers.Requests.IsEmpty || !observers.CanaryPackets.IsEmpty) throw new InvalidOperationException("crash canary escaped");
        return new { pass = true, runtime = pane.Runtime, cases = rows, refusals, crash = true, netlog = Path.Combine(folder, "netlog.json"), canary = observers.Canary,
            requests = observers.Requests.ToArray(), canaryPackets = observers.CanaryPackets.ToArray(),
            residualTcpConnections = observers.Connections, residualUdpPackets = observers.UdpPackets,
            qualification = "Local request/byte canaries; no process-level connection-count criterion" };
    }
}
#endif
