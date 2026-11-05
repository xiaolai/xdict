// Contract 4's entryText through the production client and service: the plain text carries its spans and
// completeness, and a budget or body ceiling outside the contract is admission, not a truncated answer.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using Xunit;

public class EntryTextTests
{
    private static (ServiceClient Client, string Dict, string Edition, object[] Files) OpenTiny()
    {
        var client = new ServiceClient(Environment.GetEnvironmentVariable("XDICT_SERVICE")!,
            new ServiceClientOptions { Storage = "entry-text-" + Guid.NewGuid().ToString("N") });
        string dir = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")!, "tiny");
        object[] files =
        [
            client.Observe("tiny.mdx", "tiny.mdx", Path.Combine(dir, "tiny.mdx")),
            client.Observe("tiny.mdd", "tiny.mdd", Path.Combine(dir, "tiny.mdd")),
            client.Observe("tiny.css", "tiny.css", Path.Combine(dir, "tiny.css")),
        ];
        var package = new
        {
            mdx = new { file = "tiny.mdx" },
            mdd = new[] { new { file = "tiny.mdd" } },
            sidecars = new[] { new { file = "tiny.css" } },
        };
        Assert.Null(client.Call("import", new { package, progress = false }, files).Error);
        Reply opened = client.Call("open", new { package }, files);
        Assert.Null(opened.Error);
        return (client, opened.Ok!.Value.GetProperty("dict").GetString()!,
            opened.Ok.Value.GetProperty("edition").GetString()!, files);
    }

    private static object View(ulong body = 16 << 20, ulong text = 1 << 20) => new
    {
        baseUrl = "https://example.invalid/",
        maxBodyBytes = body,
        maxTextBytes = text,
        originalStyle = false,
    };

    [Fact]
    public void TheEntryTextCarriesItsSpansAndCut()
    {
        var (client, dict, edition, files) = OpenTiny();
        using (client)
        {
            Reply reply = client.Call("entryText", new
            {
                dict,
                entry = new { edition, key = "run", occurrence = 0u },
                view = View(),
            }, files);
            Assert.Null(reply.Error);
            JsonElement ok = reply.Ok!.Value;
            Assert.Contains("run", ok.GetProperty("text").GetString()!);
            Assert.True(ok.GetProperty("complete").GetBoolean());
            Assert.Equal(JsonValueKind.Array, ok.GetProperty("spans").ValueKind);
            Assert.True(ok.GetProperty("spans").GetArrayLength() > 0);
            Assert.Equal(0ul, ok.GetProperty("omittedBytes").GetUInt64());
        }
    }

    [Fact]
    public void ABudgetOutsideTheContractIsAdmission()
    {
        var (client, dict, edition, files) = OpenTiny();
        using (client)
        {
            foreach (object view in new object[] { View(text: 0), View(text: (1 << 20) + 1), View(body: 0) })
            {
                Reply reply = client.Call("entryText", new
                {
                    dict,
                    entry = new { edition, key = "run", occurrence = 0u },
                    view,
                }, files);
                Assert.NotNull(reply.Error);
                Assert.Equal("admission", reply.Error!.Value.GetProperty("type").GetString());
            }
        }
    }
}
