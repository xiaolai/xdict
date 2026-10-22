// Spike 3-5: WebView2 as the entry view. A page under xdict://d/ attempts egress (image, fetch, worker, srcdoc,
// preconnect, dns-prefetch, WebRTC, meta refresh) while a TCP and a UDP canary count what leaves; the layers are
// selected by the mode so each one has an isolated control. In `transfer` a 16 MiB script hashes itself in the page
// and the host compares it with what it served. Throwaway code for plan-windows-v1 WI-1.
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

internal static class Program
{
    private const int CanaryPort = 18080;
    private const int StunPort = 3478;
    private const string Csp =
        "default-src https://xdict.local/; script-src https://xdict.local/ 'unsafe-inline' 'unsafe-eval'; " +
        "style-src https://xdict.local/ 'unsafe-inline'; img-src https://xdict.local/ data:; " +
        "font-src https://xdict.local/ data:; media-src https://xdict.local/; connect-src 'none'; " +
        "form-action 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'";
    private const string Base = "https://xdict.local/";

    private static readonly Dictionary<string, object?> Result = new();
    private static readonly TaskCompletionSource<bool> Finished = new();
    private static Canary? canary;
    private static string mode = "production";
    private static string root = "";
    private static string bigHash = "";
    private static int bigLength;
    private static string? bigText;

    [STAThread]
    private static void Main(string[] args)
    {
        mode = args.Length > 0 ? args[0] : "production";
        root = args.Length > 1 ? args[1] : throw new ArgumentException("the result directory is required");
        Directory.CreateDirectory(root);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var web = new WebView2();
        var window = new Window
        {
            Title = "XDict WebView2 spike - " + mode,
            Width = 1000,
            Height = 800,
            Content = web,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
        };
        canary = new Canary();
        canary.Start();
        window.Loaded += async (_, _) =>
        {
            try { await Run(web); }
            catch (Exception error)
            {
                Result["error"] = error.ToString();
                Finish();
            }
        };
        _ = new Timer(_ => Finish(), null, TimeSpan.FromSeconds(30), Timeout.InfiniteTimeSpan);
        app.Run(window);
    }

    private static async Task Run(WebView2 web)
    {
        var options = new CoreWebView2EnvironmentOptions();
        bool argsOn = mode == "args" || mode.StartsWith("production", StringComparison.Ordinal);
        if (argsOn)
        {
            options.AdditionalBrowserArguments =
                "--disable-background-networking --disable-component-update --disable-domain-reliability --disable-sync " +
                "--disable-features=msSmartScreenProtection,OptimizationHints,MediaRouter,NetworkPrediction,PreconnectToSearch " +
                "--disable-preconnect " +
                "--host-resolver-rules=MAP * ~NOTFOUND --proxy-server=http://127.0.0.1:9 " +
                "--proxy-bypass-list=<-loopback> " +
                "--force-webrtc-ip-handling-policy --webrtc-ip-handling-policy=disable_non_proxied_udp --disable-crash-reporter";
        }
        string udf = Path.Combine(root, "udf-" + mode + "-" + Guid.NewGuid().ToString("N"));
        CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, udf, options);
        await web.EnsureCoreWebView2Async(environment);
        CoreWebView2 core = web.CoreWebView2;
        string hostFolder = Path.Combine(root, "host");
        Directory.CreateDirectory(hostFolder);
        Result["mode"] = mode;
        Result["runtime"] = environment.BrowserVersionString;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsWebMessageEnabled = true;
        core.Settings.AreDefaultScriptDialogsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        try { core.Settings.IsReputationCheckingRequired = false; } catch { }

        bool block = mode == "block" || mode.StartsWith("production", StringComparison.Ordinal);
        bool cspOn = mode == "csp" || mode.StartsWith("production", StringComparison.Ordinal);
        bool navOn = mode == "nav" || mode.StartsWith("production", StringComparison.Ordinal);
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All,
            CoreWebView2WebResourceRequestSourceKinds.All);
        core.WebResourceRequested += (_, e) =>
        {
            string uri = e.Request.Uri;
            if (uri.StartsWith("https://xdict.local/entry/test")) Serve(e, environment, Html(), "text/html", cspOn);
            else if (uri.StartsWith("https://xdict.local/entry/big")) Serve(e, environment, BigHtml(), "text/html", cspOn);
            else if (uri.StartsWith("https://xdict.local/r/big.js")) Serve(e, environment, BigScript(), "text/javascript", cspOn);
            else if (uri.StartsWith("https://xdict.local/")) e.Response = environment.CreateWebResourceResponse(null, 404, "Not Found", "");
            else if (block) e.Response = environment.CreateWebResourceResponse(null, 403, "Forbidden", "");
            // control, csp, args, nav: no response, so the request proceeds and the canary sees it.
        };
        core.NavigationStarting += (_, e) => { if (navOn && !Allowed(e.Uri)) e.Cancel = true; };
        core.FrameNavigationStarting += (_, e) => { if (navOn && !Allowed(e.Uri)) e.Cancel = true; };
        core.NewWindowRequested += (_, e) => { if (navOn) e.Handled = true; };
        core.DownloadStarting += (_, e) => { if (navOn) e.Cancel = true; };
        core.PermissionRequested += (_, e) => { if (navOn) e.State = CoreWebView2PermissionState.Deny; };
        core.WebMessageReceived += (_, e) =>
        {
            try
            {
                using var document = JsonDocument.Parse(e.WebMessageAsJson);
                string kind = document.RootElement.GetProperty("kind").GetString() ?? "";
                if (kind == "done")
                {
                    Result["page"] = JsonSerializer.Deserialize<object>(e.WebMessageAsJson);
                    Finish();
                }
                else if (kind == "big")
                {
                    string hash = document.RootElement.GetProperty("hash").GetString() ?? "";
                    int length = document.RootElement.GetProperty("length").GetInt32();
                    Result["big"] = new
                    {
                        servedLength = bigLength,
                        servedHash = bigHash,
                        pageLength = length,
                        pageHash = hash,
                        equal = hash == bigHash && length == bigLength,
                    };
                    Finish();
                }
            }
            catch (Exception error) { Result["messageError"] = error.Message; }
        };
        core.Navigate(mode is "transfer" or "transfer64" ? "https://xdict.local/entry/big" : "https://xdict.local/entry/test");
    }

    private static bool Allowed(string uri) =>
        uri.StartsWith("https://xdict.local/") || uri == "about:blank" || uri.StartsWith("about:srcdoc");

    private static void Serve(CoreWebView2WebResourceRequestedEventArgs e, CoreWebView2Environment environment,
        string body, string type, bool csp)
    {
        string headers = "Content-Type: " + type + "\r\n" + (csp ? "Content-Security-Policy: " + Csp + "\r\n" : "");
        e.Response = environment.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes(body)), 200, "OK",
            headers);
    }

    private static string Html()
    {
        if (mode is "production-empty" or "production-preconnect")
        {
            string link = mode == "production-preconnect"
                ? "<link rel=preconnect href=http://127.0.0.1:18080/canary>" : "";
            return "<!doctype html><meta charset=utf-8><body><p>quiet probe</p>" + link +
                "<script>setTimeout(()=>chrome.webview.postMessage({kind:'done'}),4000)</script></body>";
        }
        return $$"""
        <!doctype html><meta charset="utf-8"><title>spike</title><body><p>spike</p>
        <script>
        const results = [];
        function note(kind, ok, detail) { results.push({kind, ok, detail: detail || ''}); }
        try { const img = new Image(); img.onload=()=>note('img',true); img.onerror=()=>note('img',false); img.src='http://127.0.0.1:{{CanaryPort}}/img'; } catch (e) { note('img',false,e.message); }
        try { fetch('http://127.0.0.1:{{CanaryPort}}/fetch').then(()=>note('fetch',true)).catch(e=>note('fetch',false,e.message)); } catch (e) { note('fetch',false,e.message); }
        try { const w = new Worker(URL.createObjectURL(new Blob(["fetch('http://127.0.0.1:{{CanaryPort}}/worker')"],{type:'text/javascript'}))); w.onerror=()=>note('worker',false); } catch (e) { note('worker',false,e.message); }
        try { const f=document.createElement('iframe'); f.srcdoc='<img src="http://127.0.0.1:{{CanaryPort}}/srcdoc">'; document.body.appendChild(f); } catch (e) { note('srcdoc',false,e.message); }
        try { const l=document.createElement('link'); l.rel='preconnect'; l.href='http://127.0.0.1:{{CanaryPort}}/preconnect'; document.head.appendChild(l); } catch (e) {}
        try { const d=document.createElement('link'); d.rel='dns-prefetch'; d.href='//canary.invalid'; document.head.appendChild(d); } catch (e) {}
        try { const pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:{{StunPort}}'}]}); pc.createDataChannel('x'); pc.createOffer().then(o=>pc.setLocalDescription(o)).catch(()=>{}); } catch (e) { note('rtc',false,e.message); }
        try { const m=document.createElement('meta'); m.httpEquiv='refresh'; m.content='2;url=https://example.com'; document.head.appendChild(m); } catch (e) {}
        setTimeout(()=>chrome.webview.postMessage({kind:'done', results}), 4000);
        </script></body>
        """;
    }

    private static string BigHtml() =>
        """<!doctype html><meta charset="utf-8"><body><script src="https://xdict.local/r/big.js"></script><p>big</p></body>""";

    private static string BigScript()
    {
        if (bigText is not null) return bigText;
        int size = mode == "transfer64" ? 64 * 1024 * 1024 : 16 * 1024 * 1024;
        const string code =
            "(async()=>{const s=document.currentScript;const r=await fetch(s.src);const t=await r.text();const h=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(t));chrome.webview.postMessage({kind:'big',hash:[...new Uint8Array(h)].map(b=>b.toString(16).padStart(2,'0')).join(''),length:t.length});})();\n";
        var builder = new StringBuilder(size + code.Length);
        builder.Append("/*");
        builder.Append('x', size - 2 - code.Length);
        builder.Append("*/\n");
        builder.Append(code);
        string text = builder.ToString();
        bigLength = text.Length;
        bigHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
        bigText = text;
        return text;
    }

    private static void Finish()
    {
        if (!Finished.TrySetResult(true)) return;
        Result["canaryHttp"] = canary?.HttpCount ?? 0;
        Result["canaryUdp"] = canary?.UdpCount ?? 0;
        Result["proxyConnections"] = canary?.ProxyCount ?? 0;
        string path = Path.Combine(root, "wv2-" + mode + ".json");
        File.WriteAllText(path, JsonSerializer.Serialize(Result, new JsonSerializerOptions { WriteIndented = true }),
            Encoding.UTF8);
        Application.Current?.Dispatcher.BeginInvoke(new Action(() => Application.Current.Shutdown()));
    }
}

internal sealed class Canary
{
    private readonly TcpListener http = new(IPAddress.Loopback, 18080);
    // Observe the supposedly dead endpoint too. A listener here changes no browser flag or interception layer.
    private readonly TcpListener proxy = new(IPAddress.Loopback, 9);
    private readonly UdpClient udp = new(new IPEndPoint(IPAddress.Loopback, 3478));
    private readonly CancellationTokenSource stop = new();
    public int HttpCount;
    public int UdpCount;
    public int ProxyCount;

    public void Start()
    {
        http.Start();
        proxy.Start();
        _ = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    using TcpClient client = await proxy.AcceptTcpClientAsync(stop.Token);
                    Interlocked.Increment(ref ProxyCount);
                }
                catch { break; }
            }
        });
        _ = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    TcpClient client = await http.AcceptTcpClientAsync(stop.Token);
                    Interlocked.Increment(ref HttpCount);
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            NetworkStream stream = client.GetStream();
                            byte[] buffer = new byte[2048];
                            if (await stream.ReadAsync(buffer, stop.Token) == 0) return;
                            byte[] response = Encoding.ASCII.GetBytes(
                                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
                            await stream.WriteAsync(response, stop.Token);
                        }
                        catch { }
                        finally { client.Close(); }
                    });
                }
                catch { break; }
            }
        });
        _ = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                try { await udp.ReceiveAsync(stop.Token); Interlocked.Increment(ref UdpCount); }
                catch { break; }
            }
        });
    }
}
