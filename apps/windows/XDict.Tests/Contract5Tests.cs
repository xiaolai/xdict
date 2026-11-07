// Contract 5 through the production client, pipe and service: Explore and its stores, the word pack's staging and
// the long builds. A failure in a pack or a store keeps what was already held and answers a typed error.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using Xunit;

public class Contract5Tests
{
    private static ServiceClient Start() => new(
        Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable"),
        new ServiceClientOptions { Storage = "contract5-" + Guid.NewGuid().ToString("N") });

    private static JsonElement Ok(Reply reply)
    {
        if (reply.Error is { } error) throw new InvalidOperationException("the service refused: " + error);
        return reply.Ok ?? throw new InvalidOperationException("the reply has no answer");
    }

    private static string Error(Reply reply) =>
        reply.Error is { } error ? error.GetProperty("type").GetString()! : "";

    private static (ServiceClient Client, string Dict, string Edition, object[] Files) OpenTiny()
    {
        ServiceClient client = Start();
        try
        {
            string dir = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")
                ?? throw new InvalidOperationException("XDICT_FIXTURES names the generated conformance fixtures"), "tiny");
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
            JsonElement ok = Ok(opened);
            return (client, ok.GetProperty("dict").GetString()!, ok.GetProperty("edition").GetString()!, files);
        }
        catch
        {
            // Ownership has not been transferred yet: a failed setup must not leave a service process per test run.
            client.Dispose();
            throw;
        }
    }

    [Fact]
    public void TheExploreStoresAnswerThroughTheProductionPipe()
    {
        var (client, dict, _, files) = OpenTiny();
        using (client)
        {
            Reply explored = client.Call("explore", new
            {
                dicts = new[] { dict },
                mode = new { type = "endsWith" },
                text = "un",
                offset = 0,
                limit = 20,
            }, files);
            Assert.Null(explored.Error);
            JsonElement answer = Ok(explored);
            Assert.Equal("answered", answer.GetProperty("state").GetProperty("type").GetString());
            Assert.True(answer.GetProperty("rows").GetArrayLength() > 0);
            JsonElement row = answer.GetProperty("rows")[0];
            Assert.False(string.IsNullOrEmpty(row.GetProperty("word").GetString()));
            Assert.Equal(dict, row.GetProperty("dict").GetString());
            Assert.True(row.GetProperty("entry").TryGetProperty("key", out _));

            Reply collocations = client.Call("collocates", new { query = "run", dicts = new[] { dict }, limit = 20 },
                files);
            Assert.Null(collocations.Error);
            Assert.Equal(JsonValueKind.Array, Ok(collocations).ValueKind);

            Reply examples = client.Call("examples", new { query = "跑", dicts = new[] { dict }, limit = 20 }, files);
            Assert.Null(examples.Error);
            JsonElement exampleAnswer = Ok(examples);
            Assert.Equal(JsonValueKind.Array, exampleAnswer.GetProperty("hits").ValueKind);
            Assert.Contains(dict, exampleAnswer.GetProperty("notReady").EnumerateArray().Select(e => e.GetString()));

            Reply phrases = client.Call("phrases", new
            {
                sentence = "The run began.",
                term = new { location = 4, length = 3 },
                dicts = new[] { dict },
            }, files);
            Assert.Null(phrases.Error);
            JsonElement phraseAnswer = Ok(phrases);
            Assert.Equal(JsonValueKind.Array, phraseAnswer.GetProperty("matches").ValueKind);
            Assert.True(phraseAnswer.GetProperty("state").ValueKind == JsonValueKind.String);
        }
    }

    /// <summary>A pack the core accepts: a version 2 header and no entries. Its source id is the marker a refusal must
    /// leave in place.</summary>
    private const string EmptyPack = """
        {"type":"header","schema":"xdict-word-pack","version":2,"language":"en","sources":[{"id":"test","name":"Test","url":"https://example.invalid/x","version":"1","sha256":"0000000000000000000000000000000000000000000000000000000000000000","licence":"CC0-1.0","attribution":"The contract test"}]}
        """;

    private static string InstallEmptyPack(ServiceClient client)
    {
        string path = Path.Combine(Path.GetTempPath(), "xdict-held-" + Guid.NewGuid().ToString("N") + ".jsonl");
        File.WriteAllText(path, EmptyPack + "\n");
        object[] files = [client.Observe("held", "pack.jsonl", path)];
        Reply installed = client.Call("setWordPack", new { file = new { file = "held" } }, files);
        Assert.Null(installed.Error);
        return path;
    }

    [Fact]
    public void TheWordPackRefusesWhatItCannotReadAndKeepsThePackItHeld()
    {
        var (client, dict, _, files) = OpenTiny();
        using (client)
        {
            Assert.Equal(JsonValueKind.Null, Ok(client.Call("wordPack", null)).GetProperty("pack").ValueKind);
            // A distinguishable pack comes first: a refusal that deleted what was held would leave the same null the
            // test started with, so starting empty proved nothing.
            string heldPath = InstallEmptyPack(client);
            try
            {
                JsonElement heldPack = Ok(client.Call("wordPack", null)).GetProperty("pack");
                Assert.Equal(2u, heldPack.GetProperty("version").GetUInt32());
                Assert.Equal("test", heldPack.GetProperty("sources")[0].GetString());
                string before = Ok(client.Call("explore", new
                {
                    dicts = new[] { dict },
                    mode = new { type = "endsWith" },
                    text = "un",
                    offset = 0,
                    limit = 20,
                }, files)).GetProperty("rows").GetRawText();

                string dir = Environment.GetEnvironmentVariable("XDICT_FIXTURES")!;
                object[] pack =
                [
                    client.Observe("pack", "xdict-word-pack.jsonl", Path.Combine(dir, "tiny", "tiny.mdx")),
                ];
                Reply refused = client.Call("setWordPack", new { file = new { file = "pack" } }, pack);
                Assert.NotEqual("", Error(refused));
                Assert.Contains(Error(refused), Validate.CoreErrorTypes);

                // What was held is still held, by its own facts and by its answers.
                JsonElement after = Ok(client.Call("wordPack", null)).GetProperty("pack");
                Assert.Equal(2u, after.GetProperty("version").GetUInt32());
                Assert.Equal("test", after.GetProperty("sources")[0].GetString());
                Assert.Equal(before, Ok(client.Call("explore", new
                {
                    dicts = new[] { dict },
                    mode = new { type = "endsWith" },
                    text = "un",
                    offset = 0,
                    limit = 20,
                }, files)).GetProperty("rows").GetRawText());
            }
            finally { File.Delete(heldPath); }
            Assert.Equal(JsonValueKind.Null, Ok(client.Call("clearWordPack", null)).GetProperty("pack").ValueKind);
        }
    }

    [Fact]
    public void ABuildThatCannotReadItsManifestKeepsWhatWasHeld()
    {
        var (client, _, _, _) = OpenTiny();
        using (client)
        {
            string heldPath = InstallEmptyPack(client);
            try
            {
                // A valid source and a manifest that is not JSON: only the manifest is wrong, so the refusal is the
                // manifest's, not any core error at all.
                string manifestPath = Path.Combine(Path.GetTempPath(),
                    "xdict-manifest-" + Guid.NewGuid().ToString("N") + ".json");
                File.WriteAllText(manifestPath, "{not a manifest");
                try
                {
                    string dir = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")!, "tiny");
                    object[] files =
                    [
                        client.Observe("source", "kaikki.jsonl", Path.Combine(dir, "tiny.mdx")),
                        client.Observe("manifest", "manifest.json", manifestPath),
                    ];
                    Reply refused = client.Call("buildWordPack", new
                    {
                        sources = new[] { new { file = "source" } },
                        manifest = new { file = "manifest" },
                    }, files);
                    Assert.Equal("malformed", Error(refused));
                    string detail = refused.Error!.Value.GetProperty("detail").GetString()!;
                    Assert.Contains("manifest", detail);
                    JsonElement after = Ok(client.Call("wordPack", null)).GetProperty("pack");
                    Assert.Equal(2u, after.GetProperty("version").GetUInt32());
                    Assert.Equal("test", after.GetProperty("sources")[0].GetString());
                }
                finally { File.Delete(manifestPath); }
            }
            finally { File.Delete(heldPath); }
        }
    }

    [Fact]
    public void TheInstalledPackSurvivesAServiceRestart()
    {
        string storage = "pack-restart-" + Guid.NewGuid().ToString("N");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")!;
        string packPath = Path.Combine(Path.GetTempPath(), "xdict-pack-" + Guid.NewGuid().ToString("N") + ".jsonl");
        string header = """
            {"type":"header","schema":"xdict-word-pack","version":2,"language":"en","sources":[{"id":"test","name":"Test","url":"https://example.invalid/x","version":"1","sha256":"0000000000000000000000000000000000000000000000000000000000000000","licence":"CC0-1.0","attribution":"The contract test"}]}
            """;
        File.WriteAllText(packPath, header + "\n");
        try
        {
            using (var first = new ServiceClient(service, new ServiceClientOptions { Storage = storage }))
            {
                first.Handshake();
                object[] files = [first.Observe("pack", "pack.jsonl", packPath)];
                Reply installed = first.Call("setWordPack", new { file = new { file = "pack" } }, files);
                Assert.Null(installed.Error);
                Assert.Equal(2u, Ok(installed).GetProperty("pack").GetProperty("version").GetUInt32());
            }
            // A disposed client closes the pipe; the next service starts from the same data folder and has to load
            // the pack the first one persisted.
            using var second = new ServiceClient(service, new ServiceClientOptions { Storage = storage });
            second.Handshake();
            Reply restored = second.Call("wordPack", null);
            Assert.Null(restored.Error);
            Assert.Equal(JsonValueKind.Object, Ok(restored).GetProperty("pack").ValueKind);
            Assert.Equal(2u, Ok(restored).GetProperty("pack").GetProperty("version").GetUInt32());
            Reply cleared = second.Call("clearWordPack", null);
            Assert.Null(cleared.Error);
            Assert.Equal(JsonValueKind.Null, Ok(second.Call("wordPack", null)).GetProperty("pack").ValueKind);
        }
        finally { File.Delete(packPath); }
    }

    [Fact]
    public void TheStoreBuildsAnswerAndCanBeAskedAgain()
    {
        var (client, dict, edition, files) = OpenTiny();
        using (client)
        {
            Reply examples = client.Call("examplesBuild", new { dict }, files);
            Assert.Null(examples.Error);
            JsonElement built = Ok(examples);
            Assert.Equal(edition, built.GetProperty("edition").GetString());
            Assert.True(built.TryGetProperty("cached", out _));
            // What the store holds, not only that a build answered: the fixture has no Chinese, so the store is
            // empty for that stated reason and no pair can be answered from it.
            Assert.True(built.GetProperty("noChinese").GetBoolean());
            Assert.Equal(0u, built.GetProperty("pairs").GetUInt32());
            JsonElement exampleQuery = Ok(client.Call("examples", new
            {
                query = "run",
                dicts = new[] { dict },
                limit = 20,
            }, files));
            Assert.Empty(exampleQuery.GetProperty("hits").EnumerateArray());

            Reply phrases = client.Call("phrasesBuild", new { dict }, files);
            Assert.Null(phrases.Error);
            JsonElement phrasesBuilt = Ok(phrases);
            Assert.Equal(edition, phrasesBuilt.GetProperty("edition").GetString());
            ulong stored = phrasesBuilt.GetProperty("phrases").GetUInt64();
            JsonElement phraseQuery = Ok(client.Call("phrases", new
            {
                sentence = "The run began.",
                term = new { location = 4, length = 3 },
                dicts = new[] { dict },
            }, files));
            // The store answers about this dictionary: its own pair count, and no invented match.
            Assert.Equal(stored, (ulong)phraseQuery.GetProperty("matches").GetArrayLength());

            // The build is kept: the reader's next query reads the store instead of building it again, with the same
            // contents the first pass wrote.
            JsonElement again = Ok(client.Call("examplesBuild", new { dict }, files));
            Assert.True(again.GetProperty("cached").GetBoolean());
            Assert.Equal(built.GetProperty("pairs").GetUInt32(), again.GetProperty("pairs").GetUInt32());
            Assert.Equal(built.GetProperty("roles").GetRawText(), again.GetProperty("roles").GetRawText());
        }
    }
}
