#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using XDict.Client;
using XDict.Contract;
using XDict.Models;

namespace XDict.App;

internal static class EntryDisplayLab
{
    internal static async Task<object> RunAsync(WebView2 browser, JsonElement config, ServiceClient client)
    {
        string folder = Path.GetDirectoryName(config.GetProperty("output").GetString()!)!;
        string tiny = Path.Combine(config.GetProperty("fixtures").GetString()!, "tiny");
        var files = new[] { client.Observe("display-mdx", "prn.mdx", Path.Combine(tiny, "prn.mdx")), client.Observe("display-css", "prn-noad.css", Path.Combine(tiny, "prn-noad.css")) };
        var package = new { mdx = new { file = "display-mdx" }, sidecars = new[] { new { file = "display-css" } } };
        Reply imported = await client.CallAsync("import", new { package }, files);
        if (imported.Error is not null) throw new InvalidOperationException("display import: " + imported.Error);
        Reply opened = await client.CallAsync("open", new { package }, files);
        if (opened.Error is not null) throw new InvalidOperationException("display open: " + opened.Error);
        string dict = opened.Ok!.Value.GetProperty("dict").GetString()!;
        var source = new DictionaryEntrySource(client, dict);
        using var pane = new EntryPane(browser, source) { TestFault = config.GetProperty("mode").GetString() == "display-red" ? "display" : "" };
        await pane.InitializeAsync(Path.Combine(folder, "browser"));
        Reply lookup = await client.CallAsync("lookup", new { query = "zabo", dicts = new[] { dict }, options = new { limit = 10, offset = 0, mode = "link" } });
        if (lookup.Error is not null) throw new InvalidOperationException("display lookup: " + lookup.Error);
        JsonElement reference = lookup.Ok!.Value.GetProperty("hits")[0].GetProperty("entry");
        var outcomes = new List<object>();
        foreach (bool original in new[] { false, true })
        {
            await pane.SetReadingAsync(new(1, "light", original));
            await EntryNativeChecks.LoadAsync(pane, await source.EntryAsync(reference));
            foreach (string choice in new[] { "ipa", "respell", "both" })
            {
                await pane.SetDisplayOptionsAsync(new Dictionary<string, string> { ["pronunciation"] = choice });
                JsonElement measured = default;
                for (int n = 0; n < 100; n++)
                {
                    try
                    {
                        measured = await EntryNativeChecks.EvaluateAsync(browser, "({value:document.documentElement.getAttribute('data-xdict-opt-pronunciation'),ipa:document.querySelector('.t_IPA').checkVisibility({visibilityProperty:true}),respell:document.querySelector('.t_respell').checkVisibility({visibilityProperty:true})})");
                        if (measured.GetProperty("value").GetString() == choice || config.GetProperty("mode").GetString() == "display-red") break;
                    }
                    catch (InvalidOperationException) { }
                    await Task.Delay(50);
                }
                if (measured.GetProperty("value").GetString() != choice || measured.GetProperty("ipa").GetBoolean() != (choice != "respell") || measured.GetProperty("respell").GetBoolean() != (choice != "ipa"))
                    throw new InvalidOperationException("display option was not applied: " + measured);
                outcomes.Add(new { original, choice, measured });
            }
        }
        return new { pass = true, cases = outcomes };
    }
}
#endif
