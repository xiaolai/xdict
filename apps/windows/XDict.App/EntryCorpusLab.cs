#if DEBUG
// Corpus files stay outside the repository and are parsed only by the production dictionary service.
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using XDict.Client;
using XDict.Contract;
using XDict.Models;

namespace XDict.App;

internal static class EntryCorpusLab
{
    internal static async Task<object> RunAsync(WebView2 first, JsonElement config, ServiceClient client)
    {
        string[] names = ["ahd", "cald", "ced", "cepd", "chambers", "cobuild", "cobuild-ec", "etym", "ldoce", "ldoce-ec", "lpd", "med", "mwaled", "mwc", "mwu", "noad", "oald", "oalecd", "ocd", "ode", "odecn", "oed", "peu", "yhdcd"];
        string mode = config.GetProperty("mode").GetString()!;
        if (mode.StartsWith("corpus-", StringComparison.Ordinal)) names = names.Where(name => name == mode[7..]).ToArray();
        if (names.Length == 0) throw new InvalidOperationException("unknown corpus sample");
        string root = config.GetProperty("corpus").GetString()!;
        string folder = Path.GetDirectoryName(config.GetProperty("output").GetString()!)!;
        var parent = (Panel)first.Parent;
        WebView2 browser = first;
        var rows = new List<object>();
        foreach (string name in names)
        {
            if (rows.Count > 0) { parent.Children.Remove(browser); browser = new(); parent.Children.Add(browser); }
            string directory = Path.Combine(root, name);
            string mdx = Directory.GetFiles(directory, "*.mdx").Single();
            string[] volumes = Directory.GetFiles(directory, "*.mdd").OrderBy(path => VolumeOrder(path)).ToArray();
            string[] sidecars = Directory.GetFiles(directory, "*", SearchOption.AllDirectories)
                .Where(path => !path.EndsWith(".mdx", StringComparison.OrdinalIgnoreCase) && !path.EndsWith(".mdd", StringComparison.OrdinalIgnoreCase) && Path.GetFileName(path) != ".DS_Store").ToArray();
            var files = new List<object>();
            object Observe(string path)
            {
                string id = "entry-corpus-" + name + "-" + files.Count;
                files.Add(client.Observe(id, Path.GetRelativePath(directory, path).Replace('\\', '/'), path));
                return new { file = id };
            }
            object mdxRef = Observe(mdx);
            var package = new { mdx = mdxRef, mdd = volumes.Select(Observe).ToArray(), sidecars = sidecars.Select(Observe).ToArray() };
            Reply imported = await client.CallAsync("import", new { package }, files);
            if (imported.Error is not null) throw new InvalidOperationException(name + " import: " + imported.Error);
            Reply opened = await client.CallAsync("open", new { package }, files);
            if (opened.Error is not null) throw new InvalidOperationException(name + " open: " + opened.Error);
            string dict = opened.Ok!.Value.GetProperty("dict").GetString()!;
            string edition = opened.Ok.Value.GetProperty("edition").GetString()!;
            var source = new DictionaryEntrySource(client, dict);
            Reply lookup = await client.CallAsync("lookup", new { query = name == "ldoce" ? "@collocations_1" : name == "oald" ? "run" : "concept", dicts = new[] { dict }, options = new { limit = 10, offset = 0, mode = "link" } });
            if (lookup.Error is not null) throw new InvalidOperationException(name + " lookup: " + lookup.Error);
            JsonElement[] hits = lookup.Ok!.Value.GetProperty("hits").EnumerateArray().ToArray();
            if (hits.Length == 0)
            {
                // A grammar dictionary need not have the reference headword. Pick its first public key via core.
                Reply suggestions = await client.CallAsync("suggest", new { prefix = "", dicts = new[] { dict }, limit = 1 });
                if (suggestions.Error is not null || suggestions.Ok!.Value.GetArrayLength() == 0) throw new InvalidOperationException(name + ": no public corpus sample");
                string sample = suggestions.Ok.Value[0].GetString()!;
                lookup = await client.CallAsync("lookup", new { query = sample, dicts = new[] { dict }, options = new { limit = 10, offset = 0, mode = "reader" } });
                if (lookup.Error is not null) throw new InvalidOperationException(name + " sample: " + lookup.Error);
                hits = lookup.Ok!.Value.GetProperty("hits").EnumerateArray().ToArray();
                if (hits.Length == 0) throw new InvalidOperationException(name + ": the public sample did not resolve");
            }
            var outcomes = new List<object>();
            var outside = new List<string>();
            using var pane = new EntryPane(browser, source, edition);
            pane.ResourceServed += (uri, status, mime) => outcomes.Add(new { uri, status, mime });
            // The pane's own guard probe is refused on purpose; anything else refused is an outside reach.
            pane.Refused += uri => { if (!uri.Contains("__xdict_guard_navigation", StringComparison.Ordinal)) outside.Add(uri); };
            await pane.InitializeAsync(Path.Combine(folder, "browser-" + name));
            await browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync("window.__corpusErrors=[];addEventListener('error',e=>window.__corpusErrors.push(e.message));addEventListener('securitypolicyviolation',e=>window.__corpusErrors.push(e.effectiveDirective+':'+e.blockedURI));");
            outcomes.Clear();
            await EntryNativeChecks.LoadAsync(pane, await source.EntryAsync(hits[0].GetProperty("entry")));
            await Task.Delay(1200);
            JsonElement media = await EntryNativeChecks.EvaluateAsync(browser, "({images:Array.from(document.images).map(i=>({uri:i.currentSrc||i.src,loaded:i.complete&&i.naturalWidth>0})),sheets:Array.from(document.querySelectorAll('link[rel~=stylesheet]')).map(l=>({uri:l.href,loaded:!!l.sheet})),framed:window.__xdictFrame.measure().proseFaceShare})");
            foreach (var resource in media.GetProperty("images").EnumerateArray().Concat(media.GetProperty("sheets").EnumerateArray()))
            {
                string uri = resource.GetProperty("uri").GetString()!;
                if (!uri.StartsWith("xdict://d/r/", StringComparison.Ordinal)) continue;
                var parsed = new Uri(uri);
                EntryResponse resolved = await source.ResourceAsync(parsed.AbsolutePath[3..] + parsed.Query, false, default);
                if (resolved.Status == 200 && !resource.GetProperty("loaded").GetBoolean())
                    throw new InvalidOperationException(name + " resolved resource did not load: " + uri);
            }
            if (media.GetProperty("framed").GetDouble() < 0.99) throw new InvalidOperationException(name + " did not use the Windows frame");
            JsonElement? folding = null;
            if (name is "oald" or "ldoce")
            {
                folding = await EntryNativeChecks.EvaluateAsync(browser, "(async()=>{for(const h of Array.from(document.querySelectorAll('[onclick]')).filter(h=>/toggle|showAtLink/.test(h.getAttribute('onclick'))).slice(0,20)){const before=document.body.innerText.length;h.click();await new Promise(r=>setTimeout(r,100));const after=document.body.innerText.length;if(Math.abs(before-after)>1){h.click();await new Promise(r=>setTimeout(r,100));return {changed:true,restored:document.body.innerText.length===before,before,after}}}return {changed:false}})()");
                if (!folding.Value.GetProperty("changed").GetBoolean() || !folding.Value.GetProperty("restored").GetBoolean()) {
                    var diagnostic = await EntryNativeChecks.EvaluateAsync(browser, "({errors:window.__corpusErrors,toggle:typeof window.toggle,fn:window.toggle?.toString().slice(0,1200),fold:null,body:{display:getComputedStyle(document.body).display,visibility:getComputedStyle(document.body).visibility,text:document.body.innerText.length},targets:Array.from(document.querySelectorAll('[onclick]')).slice(0,3).map(h=>({content:!!h.parentNode.querySelector('.content'),arrow:!!h.parentNode.querySelector('span.arrow'),handler:typeof h.onclick,chain:(()=>{let a=[],e=h;for(let i=0;e&&i<5;i++,e=e.parentNode)if(e.nodeType===1)a.push(e.tagName+'.'+e.className+':'+getComputedStyle(e).display);return a})(),display:h.parentNode.querySelector('.content')?.style.display,computed:h.parentNode.querySelector('.content')?getComputedStyle(h.parentNode.querySelector('.content')).display:null})),heads:Array.from(document.querySelectorAll('[data-xdict-control=disclosure]')).slice(0,10).map(h=>({tag:h.tagName,id:h.id,cls:h.className,controls:h.getAttribute('aria-controls'),onclick:h.getAttribute('onclick')})),scripts:Array.from(document.scripts).map(s=>s.src)})");
                    throw new InvalidOperationException(name + " folding script did not toggle and restore: " + folding + "; " + diagnostic + "; resources: " + JsonSerializer.Serialize(outcomes));
                }
            }
            rows.Add(new { dictionary = name, edition, media, folding, resources = outcomes.ToArray(), refused = outside.ToArray() });
            await File.WriteAllTextAsync(Path.Combine(folder, "progress.json"), JsonSerializer.Serialize(new { completed = rows.Count, total = names.Length, last = name }));
            await File.WriteAllTextAsync(Path.Combine(folder, "corpus.json"), JsonSerializer.Serialize(rows));
            Reply close = await client.CallAsync("close", new { dict });
            if (close.Error is not null) throw new InvalidOperationException("close: " + close.Error);
        }
        return new { pass = true, dictionaries = rows.Count, cases = rows };
    }
    private static int VolumeOrder(string path)
    {
        string suffix = Path.GetFileNameWithoutExtension(path).Split('.').Last();
        return int.TryParse(suffix, out int number) ? number : 0;
    }
}
#endif
