// The conformance fixtures through the production client, pipe and service (plan-windows-v1 WI-4), in the order and
// with the comparisons of the Rust suites (`conformance/README.md`, `core/xdict-conformance/tests/{tiny,matrix}.rs`):
// every step the contract's operations can express, each case counted under its suite. The steps no operation reaches
// are named in NotRun with the reason, never skipped in silence. The expectations are
// `conformance/fixtures/*/expected.json`, compared by subset.
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using XDict.Client;
using XDict.Contract;

internal sealed class Fixtures(string executable, string generated, string expectedRoot)
{
    private readonly List<string> failures = [];

    /// <summary>Cases compared, by suite (`tiny.lookups`, `matrix.entries`, …).</summary>
    public SortedDictionary<string, int> Counts { get; } = new(StringComparer.Ordinal);
    public IReadOnlyList<string> Failures => failures;

    /// <summary>The scenario's steps the other bindings run and the service cannot, each with why.</summary>
    public static readonly (string Step, string Why)[] NotRun =
    [
        ("tiny.newWrongProtocol", "the service has no protocol argument; the contract's analogue, contractMismatch, is checked above"),
        ("tiny.byteSource", "the service reads only handles the app duplicates; no operation takes a byte source"),
        ("tiny.errors.notFound", "an absent file has no handle to send: the app's observation fails before any request"),
        ("tiny.errors.cancelled", "the progress answer is the client's cancellation, not a callback the suite can make answer false"),
        ("tiny.explore", "the contract has no explore operation"),
        ("tiny.lifecycle.panic", "the contract has no self-test-panic operation"),
        ("phrase", "the contract has no phrase operation"),
        ("ledger", "the contract has no ledger operation"),
    ];

    public void Tiny(ServiceClient client)
    {
        string dir = Path.Combine(generated, "tiny");
        JsonNode x = Node(Path.Combine(expectedRoot, "tiny", "expected.json"));
        uint baseMax = x["view"]!["maxBodyBytes"]!.GetValue<uint>();
        object View(uint? max = null, bool originalStyle = false) =>
            new { baseUrl = x["view"]!["baseUrl"]!.GetValue<string>(), maxBodyBytes = max ?? baseMax, originalStyle };

        Check("tiny.versions", "versions", x["versions"], Outcome(client.Call("versions", null)));
        Check("tiny.openBeforeImport", "openBeforeImport", x["openBeforeImport"],
            Outcome(client.Call("open", TinyPackage(), Observations(client, dir))));
        JsonNode imported = Ok(client.Call("import", new { package = TinySpec(), progress = false }, Observations(client, dir)));
        Check("tiny.import", "import", x["import"], imported);
        JsonNode opened = Ok(client.Call("open", TinyPackage(), Observations(client, dir)));
        Check("tiny.open", "open", x["open"], opened);
        string dict = opened["dict"]!.GetValue<string>();
        string edition = imported["edition"]!.GetValue<string>();
        string tinyLineage = imported["lineage"]!.GetValue<string>();

        // The generation each lookup returned, by case index, for the cases that continue it (`{ "of": n }`).
        var generations = new List<uint?>();
        JsonArray lookups = x["lookups"]!.AsArray();
        for (int i = 0; i < lookups.Count; i++)
        {
            JsonNode wanted = lookups[i]!;
            uint? generation = wanted["generation"] is JsonObject of
                ? generations[of["of"]!.GetValue<int>()] ?? throw new InvalidOperationException($"lookups[{i}]: no generation to continue")
                : null;
            JsonNode? got = Outcome(client.Call("lookup", new
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
            }));
            generations.Add(got?["generation"]?.GetValue<uint>());
            Check("tiny.lookups", $"lookups[{i}]", Want(wanted, "page"), got);
        }

        JsonArray suggestions = x["suggestions"]!.AsArray();
        for (int i = 0; i < suggestions.Count; i++)
        {
            JsonNode wanted = suggestions[i]!;
            Check("tiny.suggestions", $"suggestions[{i}]", Want(wanted, "keys"), Outcome(client.Call("suggest", new
            {
                prefix = wanted["prefix"]!.GetValue<string>(),
                dicts = new[] { dict },
                limit = wanted["limit"]!.GetValue<uint>(),
            })));
        }

        JsonArray entries = x["entries"]!.AsArray();
        for (int i = 0; i < entries.Count; i++)
        {
            JsonNode wanted = entries[i]!;
            JsonNode? got = Entry(client.Call("entry", new
            {
                dict,
                entry = new
                {
                    edition = wanted["edition"]?.GetValue<string>() ?? edition,
                    key = wanted["entry"]!["key"]!.GetValue<string>(),
                    occurrence = wanted["entry"]!["occurrence"]!.GetValue<uint>(),
                },
                view = View(wanted["maxBodyBytes"]?.GetValue<uint>()),
            }));
            if (wanted["cspContains"] is JsonNode needle && got?["csp"] is JsonNode csp)
                Check("tiny.entries", $"entries[{i}].csp contains {needle}", JsonValue.Create(true),
                    JsonValue.Create(csp.GetValue<string>().Contains(needle.GetValue<string>())));
            Check("tiny.entries", $"entries[{i}]", Want(wanted, "result"), got);
        }

        var origin = new { type = "entry", entry = new { edition, key = "run", occurrence = 0u } };
        JsonArray links = x["links"]!.AsArray();
        for (int i = 0; i < links.Count; i++)
        {
            JsonNode wanted = links[i]!;
            Check("tiny.links", $"links[{i}]", wanted["link"], Outcome(client.Call("link", new
            {
                dict, url = wanted["url"]!.GetValue<string>(), origin, view = View(),
            })));
        }

        JsonArray resources = x["resources"]!.AsArray();
        for (int i = 0; i < resources.Count; i++)
        {
            JsonNode wanted = resources[i]!;
            Check("tiny.resources", $"resources[{i}]", wanted["resource"], Resource(client.Call("resource", new
            {
                dict,
                path = wanted["path"]!.GetValue<string>(),
                view = View(originalStyle: wanted["originalStyle"]?.GetValue<bool>() ?? false),
            })));
        }

        Check("tiny.health", "health", x["health"], Outcome(client.Call("health", new { dict })));

        JsonNode display = x["displayOptions"]!;
        Check("tiny.displayOptions", "displayOptions.tiny", display["tiny"], Outcome(client.Call("displayOptions", new { dict })));
        JsonArray cases = display["cases"]!.AsArray();
        for (int i = 0; i < cases.Count; i++)
        {
            JsonNode wanted = cases[i]!;
            string mdx = wanted["mdx"]!.GetValue<string>();
            string[] sidecars = wanted["sidecars"]!.AsArray().Select(s => s!.GetValue<string>()).ToArray();
            List<object> Files() =>
                [client.Observe(mdx, mdx, Path.Combine(dir, mdx)), .. sidecars.Select(s => client.Observe(s, s, Path.Combine(dir, s)))];
            var package = new
            {
                mdx = new { file = mdx },
                mdd = Array.Empty<object>(),
                sidecars = sidecars.Select(s => new { file = s }).ToArray(),
            };
            Ok(client.Call("import", new { package, progress = false }, Files()));
            string caseDict = Ok(client.Call("open", new { package }, Files()))["dict"]!.GetValue<string>();
            Check("tiny.displayOptions", $"displayOptions.cases[{i}]", wanted["result"],
                Outcome(client.Call("displayOptions", new { dict = caseDict })));
            client.Call("close", new { dict = caseDict });
        }

        JsonNode errors = x["errors"]!;
        foreach (string name in new[] { "unsupported", "malformed" })
        {
            string file = errors[name]!["file"]!.GetValue<string>();
            Check("tiny.errors", "errors." + name, new JsonObject { ["error"] = errors[name]!["error"]!.DeepClone() },
                Outcome(client.Call("import", new
                {
                    package = new { mdx = new { file }, mdd = Array.Empty<object>(), sidecars = Array.Empty<object>() },
                    progress = false,
                }, [client.Observe(file, file, Path.Combine(dir, file))])));
        }
        Check("tiny.errors", "errors.sourceChanged", new JsonObject { ["error"] = errors["sourceChanged"]!["error"]!.DeepClone() },
            SourceChanged(client, dir, View()));

        // The reader's joins and splits; each lineage answered is compared as a label, since ids are minted at random.
        JsonNode n = x["lineages"]!;
        string rebuiltFile = n["file"]!.GetValue<string>();
        JsonNode rebuilt = Ok(client.Call("import", new
        {
            package = new { mdx = new { file = rebuiltFile }, mdd = Array.Empty<object>(), sidecars = Array.Empty<object>() },
            progress = false,
        }, [client.Observe(rebuiltFile, rebuiltFile, Path.Combine(dir, rebuiltFile))]));
        string rebuiltEdition = rebuilt["edition"]!.GetValue<string>();
        string rebuiltLineage = rebuilt["lineage"]!.GetValue<string>();
        JsonNode? Label(JsonNode? value) => value is JsonValue v && v.TryGetValue(out string? id)
            ? id == tinyLineage ? JsonValue.Create("tiny") : id == rebuiltLineage ? JsonValue.Create("rebuilt") : value
            : value;
        JsonNode labelled = rebuilt.DeepClone();
        labelled["lineage"] = Label(labelled["lineage"]!.DeepClone());
        Check("tiny.lineages", "lineages.import", n["import"], labelled);
        JsonNode? LineageOf(string e) => Label(Outcome(client.Call("lineageOf", new { edition = e })));
        JsonNode? Join(string e, string l) => Label(Outcome(client.Call("joinLineage", new { edition = e, lineage = l })));
        JsonNode? Split(string e, string l) => Label(Outcome(client.Call("splitLineage", new { edition = e, newLineage = l })));
        string newLineage = n["newLineage"]!.GetValue<string>();
        string unknown = n["unknownEdition"]!.GetValue<string>();
        Check("tiny.lineages", "lineages.before", n["before"], LineageOf(rebuiltEdition));
        Check("tiny.lineages", "lineages.join", n["join"], Join(rebuiltEdition, tinyLineage));
        Check("tiny.lineages", "lineages.afterJoin", n["afterJoin"], LineageOf(rebuiltEdition));
        Check("tiny.lineages", "lineages.joinAgain", n["joinAgain"], Join(rebuiltEdition, tinyLineage));
        Check("tiny.lineages", "lineages.split", n["split"], Split(rebuiltEdition, rebuiltLineage));
        Check("tiny.lineages", "lineages.afterSplit", n["afterSplit"], LineageOf(rebuiltEdition));
        Check("tiny.lineages", "lineages.splitToNew", n["splitToNew"], Split(rebuiltEdition, newLineage));
        Check("tiny.lineages", "lineages.splitToNewAgain", n["splitToNewAgain"], Split(rebuiltEdition, newLineage));
        Check("tiny.lineages", "lineages.joinUnknownEdition", n["joinUnknownEdition"], Join(unknown, tinyLineage));
        Check("tiny.lineages", "lineages.lineageOfUnknownEdition", n["lineageOfUnknownEdition"], LineageOf(unknown));
        Check("tiny.lineages", "lineages.joinUnknownLineage", n["joinUnknownLineage"],
            Join(rebuiltEdition, n["unknownLineage"]!.GetValue<string>()));
        Check("tiny.lineages", "lineages.splitNotALineage", n["splitNotALineage"],
            Split(rebuiltEdition, n["notALineage"]!.GetValue<string>()));
        Check("tiny.lineages", "lineages.splitIntoAnother", n["splitIntoAnother"], Split(edition, rebuiltLineage));

        // The lifecycle on tiny's own handle (the byte source's second handle has no service counterpart).
        JsonNode l = x["lifecycle"]!;
        var page = new { limit = 10u, offset = 0u, mode = "reader", generation = (uint?)null };
        using (var other = new ServiceClient(executable, new ServiceClientOptions { Storage = "conformance-" + Guid.NewGuid().ToString("N") }))
            Check("tiny.lifecycle", "lifecycle.foreignHandle", l["foreignHandle"],
                Outcome(other.Call("lookup", new { query = "run", dicts = new[] { dict }, options = page })));
        Reply closed = client.Call("close", new { dict });
        Check("tiny.lifecycle", "close", JsonValue.Create("closed"), Outcome(closed));
        Check("tiny.lifecycle", "lifecycle.afterClose", l["afterClose"],
            Outcome(client.Call("lookup", new { query = "run", dicts = new[] { dict }, options = page })));
        Reply again = client.Call("close", new { dict });
        Check("tiny.lifecycle", "lifecycle.closeTwice", l["closeTwice"], JsonValue.Create(again.Error is null ? "ok" : "error"));
    }

    // A copy of tiny.mdx and its sidecar, opened; then the sidecar moved aside and a new file written at its path (an
    // open file cannot be replaced on Windows, but it can be renamed). The path's next observation names another file,
    // so the resource is answered sourceChanged (the Rust suite raises the inode).
    private JsonNode? SourceChanged(ServiceClient client, string dir, object view)
    {
        string copy = Path.Combine(generated, "tiny-source-changed");
        Directory.CreateDirectory(copy);
        string mdx = Path.Combine(copy, "tiny.mdx"), css = Path.Combine(copy, "tiny.css");
        File.Copy(Path.Combine(dir, "tiny.mdx"), mdx, overwrite: true);
        File.Copy(Path.Combine(dir, "tiny.css"), css, overwrite: true);
        var package = new
        {
            mdx = new { file = "changed-mdx" },
            mdd = Array.Empty<object>(),
            sidecars = new[] { new { file = "changed-css" } },
        };
        List<object> Files() => [client.Observe("changed-mdx", "changed-mdx", mdx), client.Observe("changed-css", "tiny.css", css)];
        Ok(client.Call("import", new { package, progress = false }, Files()));
        string watched = Ok(client.Call("open", new { package }, Files()))["dict"]!.GetValue<string>();
        File.Move(css, css + ".old", overwrite: true);
        File.Copy(Path.Combine(dir, "tiny.css"), css);
        JsonNode? got = Resource(client.Call("resource", new { dict = watched, path = "tiny.css", view }));
        client.Call("close", new { dict = watched });
        return got;
    }

    public void Matrix(ServiceClient client)
    {
        string dir = Path.Combine(generated, "matrix");
        JsonNode expected = Node(Path.Combine(expectedRoot, "matrix", "expected.json"));
        JsonArray variants = Node(Path.Combine(dir, "variants.json")).AsArray();
        foreach (JsonNode? maybeVariant in variants)
        {
            JsonNode variant = maybeVariant!;
            string name = variant["name"]!.GetValue<string>();
            JsonNode em = Substitute(expected, variant);
            string mdx = Path.Combine(dir, name + ".mdx");
            string location = name + ".mdx";
            var package = new { mdx = new { file = location }, mdd = Array.Empty<object>(), sidecars = Array.Empty<object>() };
            JsonNode imported = Ok(client.Call("import", new { package, progress = false }, [client.Observe(location, location, mdx)]));
            Check("matrix.import", name + " import", em["import"], imported);
            JsonNode opened = Ok(client.Call("open", new { package }, [client.Observe(location, location, mdx)]));
            Check("matrix.open", name + " open", em["open"], opened);
            string dict = opened["dict"]!.GetValue<string>();
            string edition = imported["edition"]!.GetValue<string>();

            JsonArray lookups = em["lookups"]!.AsArray();
            for (int i = 0; i < lookups.Count; i++)
            {
                JsonNode wanted = lookups[i]!;
                Check("matrix.lookups", $"{name} lookups[{i}]", wanted["page"], Outcome(client.Call("lookup", new
                {
                    query = wanted["query"]!.GetValue<string>(),
                    dicts = new[] { dict },
                    options = new
                    {
                        limit = wanted["limit"]!.GetValue<uint>(),
                        offset = wanted["offset"]!.GetValue<uint>(),
                        mode = "reader",
                        generation = (uint?)null,
                    },
                })));
            }
            JsonArray entries = em["entries"]!.AsArray();
            for (int i = 0; i < entries.Count; i++)
            {
                JsonNode wanted = entries[i]!;
                Check("matrix.entries", $"{name} entries[{i}]", wanted["result"], Entry(client.Call("entry", new
                {
                    dict,
                    entry = new
                    {
                        edition,
                        key = wanted["entry"]!["key"]!.GetValue<string>(),
                        occurrence = wanted["entry"]!["occurrence"]!.GetValue<uint>(),
                    },
                    view = new { baseUrl = "xdict://d/", maxBodyBytes = 1u << 20, originalStyle = false },
                })));
            }
            client.Call("close", new { dict });
        }
        Check("matrix.variants", "variants", JsonValue.Create(32), JsonValue.Create(variants.Count));
    }

    private void Check(string suite, string name, JsonNode? expected, JsonNode? actual)
    {
        Counts[suite] = Counts.GetValueOrDefault(suite) + 1;
        try { Expect(expected, actual, name); }
        catch (InvalidOperationException error) { failures.Add(error.Message); }
    }

    /// <summary>A case's expectation: its error as `{"error": …}`, or the named field.</summary>
    private static JsonNode? Want(JsonNode wanted, string field) =>
        wanted["error"] is JsonNode error ? new JsonObject { ["error"] = error.DeepClone() } : wanted[field];

    private static object TinySpec() => new
    {
        mdx = new { file = "tiny-mdx" },
        mdd = new[] { new { file = "tiny-mdd" } },
        sidecars = new[] { new { file = "tiny-css" } },
    };

    private static object TinyPackage() => new { package = TinySpec() };

    private static List<object> Observations(ServiceClient client, string dir) =>
    [
        client.Observe("tiny-mdx", "tiny-mdx", Path.Combine(dir, "tiny.mdx")),
        client.Observe("tiny-mdd", "tiny-mdd", Path.Combine(dir, "tiny.mdd")),
        client.Observe("tiny-css", "tiny.css", Path.Combine(dir, "tiny.css")),
    ];

    private static JsonNode Substitute(JsonNode source, JsonNode variant)
    {
        string text = source.ToJsonString()
            .Replace("$word", variant["word"]!.GetValue<string>())
            .Replace("$gloss", variant["gloss"]!.GetValue<string>())
            .Replace("$version", variant["version"]!.GetValue<string>());
        return JsonNode.Parse(text)!;
    }

    private static JsonNode Node(string path) => JsonNode.Parse(File.ReadAllText(path))!;

    /// <summary>A reply as the suites compare it: the record, or `{"error": …}`.</summary>
    private static JsonNode? Outcome(Reply reply) => reply.Error is { } error
        ? new JsonObject { ["error"] = JsonNode.Parse(error.GetRawText()) }
        : JsonNode.Parse(reply.Ok!.Value.GetRawText());

    /// <summary>An entry as the suites compare it: the record with its body's HTML as text.</summary>
    private static JsonNode? Entry(Reply reply)
    {
        JsonNode? got = Outcome(reply);
        if (reply.Error is not null || got is not JsonObject ok) return got;
        ok["html"] = Encoding.UTF8.GetString(reply.Payload ?? throw new InvalidOperationException("an entry answered no HTML"));
        return ok;
    }

    /// <summary>A resource as the suites compare it: a found one's bytes as UTF-8 text.</summary>
    private static JsonNode? Resource(Reply reply)
    {
        JsonNode? got = Outcome(reply);
        if (reply.Error is not null || got is not JsonObject ok) return got;
        if (ok["type"]?.GetValue<string>() == "found") ok["text"] = Encoding.UTF8.GetString(reply.Payload ?? []);
        return ok;
    }

    private static JsonNode Ok(Reply reply)
    {
        if (reply.Error is { } error) throw new InvalidOperationException("the service refused: " + error);
        return JsonNode.Parse(reply.Ok!.Value.GetRawText())
            ?? throw new InvalidOperationException("the service answered null where a record was due");
    }

    /// <summary>The Rust suites' comparison: every field the expectation writes must be present and equal (a JSON
    /// null included); a `comment` is documentation; lists must have equal lengths.</summary>
    private static void Expect(JsonNode? expected, JsonNode? actual, string path)
    {
        switch (expected)
        {
            case null:
                if (actual is not null) throw new InvalidOperationException($"{path}: expected null, got {actual.ToJsonString()}");
                break;
            case JsonObject wanted:
                if (actual is not JsonObject got)
                    throw new InvalidOperationException($"{path}: expected an object, got {actual?.ToJsonString() ?? "null"}");
                foreach ((string key, JsonNode? value) in wanted)
                {
                    if (key == "comment") continue;
                    if (!got.TryGetPropertyValue(key, out JsonNode? child))
                        throw new InvalidOperationException($"{path}.{key}: missing in {got.ToJsonString()}");
                    Expect(value, child, $"{path}.{key}");
                }
                break;
            case JsonArray wanted:
                if (actual is not JsonArray gotArray)
                    throw new InvalidOperationException($"{path}: expected an array, got {actual?.ToJsonString() ?? "null"}");
                if (gotArray.Count != wanted.Count)
                    throw new InvalidOperationException($"{path}: {gotArray.Count} items, expected {wanted.Count}: {gotArray.ToJsonString()}");
                for (int i = 0; i < wanted.Count; i++)
                    Expect(wanted[i], gotArray[i], $"{path}[{i}]");
                break;
            default:
                if (!JsonNode.DeepEquals(expected, actual))
                    throw new InvalidOperationException($"{path}: {actual?.ToJsonString() ?? "null"}, expected {expected.ToJsonString()}");
                break;
        }
    }
}
