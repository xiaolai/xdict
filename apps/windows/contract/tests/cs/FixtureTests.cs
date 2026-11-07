// The wire contract's fixtures through C#: every line decodes, the envelope obeys the schema, and the request and
// reply re-encode to themselves. plan-windows-v1 WI-1; the app's client decode test is WI-3's.
using System.Text.Json;
using System.Text.Json.Nodes;
using XDict.Contract;
using Xunit;

public class FixtureTests
{
    [Fact]
    public void EveryFixtureDecodesAndReEncodes()
    {
        string dir = AppContext.BaseDirectory;
        JsonNode schema = JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "contract.json")))!;
        JsonObject operations = schema["operations"]!.AsObject();
        var errors = new HashSet<string>(StringComparer.Ordinal);
        foreach (string side in new[] { "core", "wire" })
            foreach (JsonNode? error in schema["errors"]![side]!.AsArray())
                errors.Add(error!.GetValue<string>());

        // The C# validators and the schema name the same errors.
        string[] coreErrors = schema["errors"]!["core"]!.AsArray().Select(e => e!.GetValue<string>()).ToArray();
        string[] wireErrors = schema["errors"]!["wire"]!.AsArray().Select(e => e!.GetValue<string>()).ToArray();
        Assert.Equal(coreErrors, Validate.CoreErrorTypes);
        Assert.Equal(wireErrors, Validate.WireErrorTypes);

        int count = 0;
        foreach (string line in File.ReadAllLines(Path.Combine(dir, "fixtures.jsonl")))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonNode pair = JsonNode.Parse(line)!;
            string name = pair["name"]!.GetValue<string>();
            JsonNode request = pair["request"]!;
            JsonNode reply = pair["reply"]!;

            using JsonDocument requestDocument = JsonDocument.Parse(request.ToJsonString());
            using JsonDocument replyDocument = JsonDocument.Parse(reply.ToJsonString());
            Validate.Request(requestDocument.RootElement);
            Validate.Reply(replyDocument.RootElement);

            // Through the production records: the file observations as the client builds them, and the handshake's
            // answer as the client reads it. A field renamed on the client's side fails here, not at a live call.
            foreach (JsonElement file in requestDocument.RootElement.GetProperty("files").EnumerateArray())
            {
                FileObservation observation = file.Deserialize<FileObservation>(Wire.Options)
                    ?? throw new InvalidOperationException($"{name}: a file record does not decode");
                Assert.False(string.IsNullOrEmpty(observation.Id), $"{name}: a file record has no id");
                Assert.Equal(file.GetProperty("handle").GetUInt64(), observation.Handle);
            }
            if (request["op"]!.GetValue<string>() == "versions" &&
                replyDocument.RootElement.TryGetProperty("ok", out JsonElement versions))
            {
                Versions typed = versions.Deserialize<Versions>(Wire.Options)
                    ?? throw new InvalidOperationException($"{name}: the versions answer does not decode");
                Assert.Equal(versions.GetProperty("protocol").GetUInt32(), typed.Protocol);
                Assert.Equal(versions.GetProperty("core").GetString(), typed.Core);
                Assert.Equal(versions.GetProperty("indexFormat").GetUInt32(), typed.IndexFormat);
                Assert.Equal(versions.GetProperty("normalization").GetUInt32(), typed.Normalization);
            }

            Assert.Equal(request["id"]!.ToJsonString(), reply["id"]!.ToJsonString());
            string op = request["op"]!.GetValue<string>();
            Assert.True(operations.ContainsKey(op), $"{name}: op {op} is in the schema");
            Assert.Equal(Wire.Version, reply["contract"]!.GetValue<uint>());
            if (request["contract"]!.GetValue<uint>() != Wire.Version)
                Assert.Equal("contractMismatch", reply["error"]!["type"]!.GetValue<string>());
            if (reply["error"] is JsonObject error)
                Assert.Contains(error["type"]!.GetValue<string>(), errors);

            foreach ((string what, JsonNode value) in new[] { ("request", request), ("reply", reply) })
            {
                JsonNode reparsed = JsonNode.Parse(value.ToJsonString())!;
                Assert.True(JsonNode.DeepEquals(value, reparsed), $"{name}: the {what} round-trips");
            }
            count++;
        }
        Assert.True(count >= 26, $"the fixture set is {count}, expected at least 26");
    }
}
