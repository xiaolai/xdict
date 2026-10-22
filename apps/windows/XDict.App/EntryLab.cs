#if DEBUG
// Interactive acceptance harness. The renderer, routes, bridge and provider are the product's own objects.
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

internal static class EntryLab
{
    private sealed class Synthetic : IEntrySource
    {
        public string Dictionary => "synthetic-selftest";
        public Task<EntryResponse> ResourceAsync(string path, bool sound, CancellationToken cancellation) =>
            Task.FromResult(new EntryResponse(Encoding.UTF8.GetBytes("body{color:rgb(0,128,0)}"), "text/css", ""));
    }
    public static async Task RunAsync(WebView2 browser, string configuration, ServiceClient client)
    {
        using var config = JsonDocument.Parse(await File.ReadAllTextAsync(configuration));
        var root = config.RootElement;
        string output = root.GetProperty("output").GetString()!;
        var result = new Dictionary<string, object?>();
        try
        {
            string mode = root.GetProperty("mode").GetString()!;
            if (mode.StartsWith("display", StringComparison.Ordinal))
            {
                object display = await EntryDisplayLab.RunAsync(browser, root, client);
                await File.WriteAllTextAsync(output, JsonSerializer.Serialize(display, new JsonSerializerOptions { WriteIndented = true }));
                return;
            }
            if (mode.StartsWith("corpus", StringComparison.Ordinal))
            {
                object corpus = await EntryCorpusLab.RunAsync(browser, root, client);
                await File.WriteAllTextAsync(output, JsonSerializer.Serialize(corpus, new JsonSerializerOptions { WriteIndented = true }));
                return;
            }
            if (mode.StartsWith("hostile", StringComparison.Ordinal))
            {
                object hostile = await EntryHostileLab.RunAsync(browser, root, client);
                await File.WriteAllTextAsync(output, JsonSerializer.Serialize(hostile, new JsonSerializerOptions { WriteIndented = true }));
                return;
            }
            string folder = Path.GetDirectoryName(output)!;
            if (mode.StartsWith("control-", StringComparison.Ordinal))
            {
                object isolated = await EntryNativeChecks.IsolatedAsync(browser, mode, folder, new Synthetic());
                await File.WriteAllTextAsync(output, JsonSerializer.Serialize(isolated, new JsonSerializerOptions { WriteIndented = true }));
                return;
            }
            var preferences = new ReadingPreferenceStore(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "entry-acceptance-preferences.json"));
            using var pane = new EntryPane(browser, new Synthetic(), "entry-acceptance-edition", preferences)
                { TestTrace = phase => File.AppendAllText(Path.Combine(folder, "startup.txt"), phase + "\n"), TestFault = mode == "rtc-off" ? "connections" : mode == "bridge-red" ? "bridge" : mode.StartsWith("fault-") ? mode[6..] : "" };
            await pane.InitializeAsync(Path.Combine(Path.GetDirectoryName(output)!, "browser-" + Guid.NewGuid().ToString("N")));
            result["runtime"] = pane.Runtime;
            var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            browser.CoreWebView2.NavigationCompleted += (_, e) => loaded.TrySetResult(e.IsSuccess);
            await browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync("window.__frameErrors=[];addEventListener('error',e=>window.__frameErrors.push(e.message));");
            const string csp = "default-src xdict://d/; script-src xdict://d/ 'unsafe-inline'; style-src xdict://d/ 'unsafe-inline'; img-src xdict://d/ data:; connect-src 'none'; object-src 'none'; frame-src xdict://d/; base-uri 'none'; form-action 'none'";
            await pane.ShowAsync(new(Encoding.UTF8.GetBytes("<!doctype html><link rel=stylesheet href=xdict://d/r/test.css><p id=p>custom scheme</p>"), "text/html", csp));
            result["loaded"] = await loaded.Task.WaitAsync(TimeSpan.FromSeconds(15));
            result["scheme"] = await browser.CoreWebView2.ExecuteScriptAsync("location.protocol");
            result["resource"] = await browser.CoreWebView2.ExecuteScriptAsync("getComputedStyle(document.body).color");
            if (mode.StartsWith("frame", StringComparison.Ordinal))
            {
                if (mode.StartsWith("frame-large", StringComparison.Ordinal))
                {
                    browser.Width = mode.EndsWith("-red", StringComparison.Ordinal) ? 1024 : 320;
                    string body = "<!doctype html><p>needle needle needle</p><p>" + string.Concat(Enumerable.Repeat("readable ", 385000)) + "</p><p>needle needle needle needle</p>";
                    if (mode.EndsWith("-red", StringComparison.Ordinal)) body = body.Replace("<p>", "<p style='min-width:2048px'>");
                    await EntryNativeChecks.LoadAsync(pane, new(Encoding.UTF8.GetBytes(body), "text/html", csp));
                    var size = await EntryNativeChecks.EvaluateAsync(browser, "({width:document.documentElement.clientWidth,overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth+1,find:window.__xdictFind.find('needle')})");
                    if (size.GetProperty("width").GetInt32() > 330 || size.GetProperty("overflow").GetBoolean() || size.GetProperty("find").GetProperty("visible").GetInt32() != 7)
                        throw new InvalidOperationException("large/narrow reading failed: " + size);
                    result["large"] = new { bytes = Encoding.UTF8.GetByteCount(body), size };
                    // The common frame check still expects this phrase exactly once.
                    await EntryNativeChecks.LoadAsync(pane, new(Encoding.UTF8.GetBytes("<!doctype html><p>custom scheme</p>"), "text/html", csp));
                }
                if (mode == "frame-write")
                {
                    await EntryNativeChecks.LoadAsync(pane, new(Encoding.UTF8.GetBytes("<!doctype html><p>custom scheme</p>"), "text/html", csp));
                    await pane.SetReadingAsync(new(1.5, "dark"));
                    for (int n = 0; n < 100; n++)
                    {
                        if (await browser.CoreWebView2.ExecuteScriptAsync("document.documentElement.dataset.xdictTheme") == "\"dark\"") break;
                        await Task.Delay(50);
                    }
                }
                if (mode == "frame-relaunch" || mode == "frame-write")
                {
                    var saved = await EntryNativeChecks.EvaluateAsync(browser, "({theme:document.documentElement.dataset.xdictTheme,size:parseFloat(getComputedStyle(document.documentElement).fontSize)})");
                    if (saved.GetProperty("theme").GetString() != "dark" || saved.GetProperty("size").GetDouble() != 25.5)
                        throw new InvalidOperationException("edition zoom/theme was not restored in the view: " + saved);
                    result["preferences"] = saved;
                }
                result["font"] = await EntryNativeChecks.EvaluateAsync(browser, "document.fonts.load('16px \"XDict Phonetic\"').then(f=>f.length)");
                if (((JsonElement)result["font"]!).GetInt32() == 0) throw new InvalidOperationException("shipped phonetic font did not load");
                result["diagnostic"] = await browser.CoreWebView2.ExecuteScriptAsync("JSON.stringify({errors:window.__frameErrors,frame:typeof window.__xdictFrame,find:typeof window.__xdictFind,font:getComputedStyle(document.body).fontFamily})");
                result["frame"] = await browser.CoreWebView2.ExecuteScriptAsync("JSON.stringify({find:window.__xdictFind.find('custom scheme'),framed:window.__xdictFrame.measure().proseFaceShare})");
                string frame = JsonSerializer.Deserialize<string>((string)result["frame"]!)!;
                using var measurement = JsonDocument.Parse(frame);
                if (measurement.RootElement.GetProperty("find").GetProperty("visible").GetInt32() != 1 || measurement.RootElement.GetProperty("framed").GetDouble() < 0.99)
                    throw new InvalidOperationException("Windows prose or find was not framed");
            }
            if (mode.StartsWith("rtc", StringComparison.Ordinal)) result["rtc"] = await EntryNativeChecks.RtcAsync(pane);
            if (mode == "word") result["word"] = await EntryNativeChecks.WordAsync(pane);
            if (mode.StartsWith("bridge", StringComparison.Ordinal))
                result["bridge"] = await EntryNativeChecks.BridgeAsync(pane);
            result["pass"] = (bool)result["loaded"]! && (string)result["scheme"]! == "\"xdict:\"" && (string)result["resource"]! == "\"rgb(0, 128, 0)\"";
        }
        catch (Exception e)
        {
            result["error"] = e.ToString();
            result["pass"] = root.GetProperty("mode").GetString()!.StartsWith("fault-") && e.Message == Strings.Get("entry.guardFailed");
        }
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        await File.WriteAllTextAsync(output, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
    }
}
#endif
