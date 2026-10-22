// The conformance fixtures through the production client, pipe and service (plan-windows-v1 WI-4): the tiny
// scenario's open-before-import, import, open, lookups, suggestions, entries, resources and a closed handle, then
// every matrix variant's import, open and first lookup. The expectations are `conformance/fixtures/*/expected.json`,
// compared by subset, as the Rust suites do.
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using XDict.Client;
using XDict.Contract;

internal static class Fixtures
{
    public static void Tiny(ServiceClient client, string generated, string expectedRoot)
    {
        string dir = Path.Combine(generated, "tiny");
        JsonNode expected = Node(Path.Combine(expectedRoot, "tiny", "expected.json"));

        Reply before = client.Call("open", Body(true), Observations(client, dir));
        Expect(expected["openBeforeImport"], Ok(before), "openBeforeImport");

        Reply imported = client.Call("import", new { package = Spec(true, true), progress = false }, Observations(client, dir));
        Expect(expected["import"], Ok(imported), "import");

        Reply opened = client.Call("open", Body(true), Observations(client, dir));
        JsonNode openedOk = Ok(opened);
        Expect(expected["open"], openedOk, "open");
        string dict = openedOk["dict"]!.GetValue<string>();

        var generations = new List<uint>();
        JsonArray lookups = expected["lookups"]!.AsArray();
        for (int i = 0; i < lookups.Count; i++)
        {
            JsonNode wanted = lookups[i]!;
            // The staleHandle cases run after the close, at the end; this loop runs the live ones.
            if (wanted["error"]?["type"]?.GetValue<string>() == "staleHandle")
                continue;
            uint? generation = null;
            if (wanted["generation"] is JsonObject of)
                generation = generations[of["of"]!.GetValue<int>()];
            Reply page = client.Call("lookup", new
            {
                query = wanted["query"]!.GetValue<string>(),
                dicts = new[] { dict },
                options = new
                {
                    limit = wanted["limit"]!.GetValue<uint>(),
                    offset = wanted["offset"]!.GetValue<uint>(),
                    mode = wanted["mode"]?.GetValue<string>() ?? "reader",
                    generation,
                },
            });
            if (wanted["error"] is JsonObject wantedError)
            {
                Require(page.Error is { } actual && actual.GetProperty("type").GetString() == wantedError["type"]!.GetValue<string>(),
                    $"lookups[{i}]: expected {wantedError.ToJsonString()}, got {page.Error}");
                continue;
            }
            JsonNode pageOk = Ok(page);
            Expect(wanted["page"], pageOk, $"lookups[{i}]");
            generations.Add(pageOk["generation"]!.GetValue<uint>());
        }

        foreach (JsonNode? maybeWanted in expected["suggestions"]!.AsArray())
        {
            JsonNode wanted = maybeWanted!;
            Reply reply = client.Call("suggest", new
            {
                prefix = wanted["prefix"]!.GetValue<string>(),
                dicts = new[] { dict },
                limit = wanted["limit"]!.GetValue<uint>(),
            });
            if (wanted["error"] is JsonObject error)
            {
                Require(reply.Error is { } actual && actual.GetProperty("type").GetString() == error["type"]!.GetValue<string>(),
                    $"suggestions: expected {error.ToJsonString()}, got {reply.Error}");
                continue;
            }
            Expect(wanted["keys"], Ok(reply), "suggestions");
        }

        foreach (JsonNode? maybeWanted in expected["entries"]!.AsArray())
        {
            JsonNode wanted = maybeWanted!;
            Reply reply = client.Call("entry", new
            {
                dict,
                entry = new
                {
                    edition = wanted["edition"]?.GetValue<string>() ?? openedOk["edition"]!.GetValue<string>(),
                    key = wanted["entry"]!["key"]!.GetValue<string>(),
                    occurrence = wanted["entry"]!["occurrence"]!.GetValue<uint>(),
                },
                view = new
                {
                    baseUrl = "xdict://d/",
                    maxBodyBytes = wanted["maxBodyBytes"]?.GetValue<uint>() ?? 1u << 20,
                    originalStyle = wanted["originalStyle"]?.GetValue<bool>() ?? false,
                },
            });
            if (wanted["error"] is JsonObject error)
            {
                Require(reply.Error is { } actual && actual.GetProperty("type").GetString() == error["type"]!.GetValue<string>(),
                    $"entry: expected {error.ToJsonString()}, got {reply.Error}");
                continue;
            }
            JsonNode ok = Ok(reply);
            var result = new JsonObject
            {
                ["entry"] = JsonNode.Parse(ok["entry"]!.ToJsonString()),
                ["csp"] = ok["csp"]!.DeepClone(),
                ["lossyBytes"] = ok["lossyBytes"]!.DeepClone(),
                ["html"] = Encoding.UTF8.GetString(reply.Payload
                    ?? throw new InvalidOperationException("an entry answered no HTML")),
            };
            JsonNode expectedResult = wanted["result"]!.DeepClone();
            Expect(expectedResult, result, "entry");
            if (wanted["cspContains"] is JsonNode cspWanted)
            {
                string cspContains = cspWanted.GetValue<string>();
                Require(result["csp"]!.GetValue<string>().Contains(cspContains), "entry: the CSP lacks " + cspContains);
            }
        }

        foreach (JsonNode? maybeWanted in expected["resources"]!.AsArray())
        {
            JsonNode wanted = maybeWanted!;
            Reply reply = client.Call("resource", new
            {
                dict,
                path = wanted["path"]!.GetValue<string>(),
                view = new { baseUrl = "xdict://d/", maxBodyBytes = 1 << 20, originalStyle = wanted["originalStyle"]?.GetValue<bool>() ?? false },
            });
            JsonNode ok = Ok(reply);
            var result = new JsonObject
            {
                ["type"] = ok["type"]!.DeepClone(),
                ["path"] = ok["path"]!.DeepClone(),
            };
            if (ok["type"]!.GetValue<string>() == "found")
            {
                result["mime"] = ok["mime"]!.DeepClone();
                result["text"] = Encoding.UTF8.GetString(reply.Payload ?? []);
            }
            Expect(wanted["resource"], result, "resource");
        }

        Reply closed = client.Call("close", new { dict });
        Require(closed.Error is null && closed.Ok?.GetString() == "closed", "close: " + closed.Error);

        Reply stale = client.Call("lookup", new
        {
            query = "run",
            dicts = new[] { dict },
            options = new { limit = 10u, offset = 0u, mode = "reader", generation = (uint?)null },
        });
        Require(stale.Error is { } staleError && staleError.GetProperty("type").GetString() == "staleHandle",
            "a closed handle: expected staleHandle, got " + stale.Error);
    }

    public static void Matrix(ServiceClient client, string generated, string expectedRoot)
    {
        string dir = Path.Combine(generated, "matrix");
        JsonNode expected = Node(Path.Combine(expectedRoot, "matrix", "expected.json"));
        JsonArray variants = Node(Path.Combine(dir, "variants.json")).AsArray();
        int count = 0;
        foreach (JsonNode? maybeVariant in variants)
        {
            JsonNode variant = maybeVariant!;
            string name = variant["name"]!.GetValue<string>();
            string word = variant["word"]!.GetValue<string>();
            JsonNode em = Substitute(expected, variant);
            string mdx = Path.Combine(dir, name + ".mdx");
            string location = name + ".mdx";
            var files = new List<object> { client.Observe(location, location, mdx) };
            Reply imported = client.Call("import", new
            {
                package = new { mdx = new { file = location } },
                progress = false,
            }, files);
            JsonNode ok = Ok(imported);
            Expect(em["import"], ok, name + " import");
            string edition = ok["edition"]!.GetValue<string>();

            var files2 = new List<object> { client.Observe(location, location, mdx) };
            Reply opened = client.Call("open", new { package = new { mdx = new { file = location } } }, files2);
            JsonNode openedOk = Ok(opened);
            Expect(em["open"], openedOk, name + " open");
            string dict = openedOk["dict"]!.GetValue<string>();

            JsonNode lookup = em["lookups"]![0]!;
            Reply page = client.Call("lookup", new
            {
                query = lookup["query"]!.GetValue<string>(),
                dicts = new[] { dict },
                options = new { limit = lookup["limit"]!.GetValue<uint>(), offset = 0u, mode = "reader", generation = (uint?)null },
            });
            JsonNode pageOk = Ok(page);
            Require(pageOk["hits"]!.AsArray().Count > 0, $"{name}: the lookup of {word} found nothing");
            Expect(lookup["page"], pageOk, name + " lookup");
            client.Call("close", new { dict });
            count++;
        }
        Require(count >= 32, $"the matrix has {count} variants, expected at least 32");
    }

    private static object Spec(bool volumes, bool sidecars) => new
    {
        mdx = new { file = "tiny-mdx" },
        mdd = volumes ? new[] { new { file = "tiny-mdd" } } : Array.Empty<object>(),
        sidecars = sidecars ? new[] { new { file = "tiny-css" } } : Array.Empty<object>(),
    };

    private static object Body(bool full) => new { package = Spec(full, full) };

    private static List<object> Observations(ServiceClient client, string dir)
    {
        return
        [
            client.Observe("tiny-mdx", "tiny-mdx", Path.Combine(dir, "tiny.mdx")),
            client.Observe("tiny-mdd", "tiny-mdd", Path.Combine(dir, "tiny.mdd")),
            client.Observe("tiny-css", "tiny.css", Path.Combine(dir, "tiny.css")),
        ];
    }

    private static JsonNode Substitute(JsonNode source, JsonNode variant)
    {
        string text = source.ToJsonString()
            .Replace("$word", variant["word"]!.GetValue<string>())
            .Replace("$gloss", variant["gloss"]!.GetValue<string>())
            .Replace("$version", variant["version"]!.GetValue<string>());
        return JsonNode.Parse(text)!;
    }

    private static JsonNode Node(string path) => JsonNode.Parse(File.ReadAllText(path))!;

    private static JsonNode Ok(Reply reply)
    {
        if (reply.Error is { } error) throw new InvalidOperationException("the service refused: " + error);
        return JsonNode.Parse(reply.Ok!.Value.GetRawText())!;
    }

    /// <summary>The Rust suites' comparison: every field the expectation writes must be present and equal.</summary>
    private static void Expect(JsonNode? expected, JsonNode? actual, string path)
    {
        switch (expected)
        {
            case null:
                return;
            case JsonObject wanted:
                if (actual is not JsonObject got)
                    throw new InvalidOperationException($"{path}: expected an object, got {actual?.ToJsonString() ?? "nothing"}");
                foreach ((string key, JsonNode? value) in wanted)
                {
                    if (!got.TryGetPropertyValue(key, out JsonNode? child))
                        throw new InvalidOperationException($"{path}.{key}: missing");
                    Expect(value, child, $"{path}.{key}");
                }
                break;
            case JsonArray wanted:
                if (actual is not JsonArray gotArray)
                    throw new InvalidOperationException($"{path}: expected an array, got {actual?.ToJsonString() ?? "nothing"}");
                if (gotArray.Count != wanted.Count)
                    throw new InvalidOperationException($"{path}: {gotArray.Count} items, expected {wanted.Count}");
                for (int i = 0; i < wanted.Count; i++)
                    Expect(wanted[i], gotArray[i], $"{path}[{i}]");
                break;
            default:
                if (!JsonNode.DeepEquals(expected, actual))
                    throw new InvalidOperationException($"{path}: {actual?.ToJsonString() ?? "nothing"}, expected {expected.ToJsonString()}");
                break;
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
