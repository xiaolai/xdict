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
        try
        {
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
        catch
        {
            client.Dispose();
            throw;
        }
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
            string text = ok.GetProperty("text").GetString()!;
            Assert.Contains("run", text);
            Assert.True(ok.GetProperty("complete").GetBoolean());
            Assert.Equal(JsonValueKind.Array, ok.GetProperty("spans").ValueKind);
            Assert.True(ok.GetProperty("spans").GetArrayLength() > 0);
            Assert.Equal(0ul, ok.GetProperty("omittedBytes").GetUInt64());
            // The spans are offsets into this text, in UTF-8 bytes: each one lies inside it, starts and ends on a
            // character boundary, and names its own words. A nonempty array alone said none of that.
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(text);
            ulong previousEnd = 0;
            foreach (JsonElement span in ok.GetProperty("spans").EnumerateArray())
            {
                ulong start = span.GetProperty("start").GetUInt64();
                ulong len = span.GetProperty("len").GetUInt64();
                Assert.True(len > 0, "a span is empty");
                Assert.True(start >= previousEnd, "the spans overlap or are out of order");
                Assert.True(start + len <= (ulong)bytes.Length, "a span reaches past the text");
                Assert.True(start == 0 || (bytes[start] & 0xC0) != 0x80, "a span starts inside a character");
                Assert.True(start + len == (ulong)bytes.Length || (bytes[start + len] & 0xC0) != 0x80,
                    "a span ends inside a character");
                string run = System.Text.Encoding.UTF8.GetString(bytes, (int)start, (int)len);
                Assert.False(string.IsNullOrWhiteSpace(run), "a span holds no text");
                previousEnd = start + len;
            }
            Assert.Contains("run", string.Join("", ok.GetProperty("spans").EnumerateArray().Select(span =>
                System.Text.Encoding.UTF8.GetString(bytes, (int)span.GetProperty("start").GetUInt64(),
                    (int)span.GetProperty("len").GetUInt64()))));

            // A budget that cuts says so as data: incomplete, the bytes it left out, and where the cut fell.
            Reply cut = client.Call("entryText", new
            {
                dict,
                entry = new { edition, key = "run", occurrence = 0u },
                view = View(text: 8),
            }, files);
            Assert.Null(cut.Error);
            JsonElement cutOk = cut.Ok!.Value;
            Assert.False(cutOk.GetProperty("complete").GetBoolean());
            Assert.True(cutOk.GetProperty("omittedBytes").GetUInt64() > 0);
            ulong kept = (ulong)System.Text.Encoding.UTF8.GetByteCount(cutOk.GetProperty("text").GetString()!);
            Assert.Equal(kept, cutOk.GetProperty("cutAt").GetUInt64());
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
