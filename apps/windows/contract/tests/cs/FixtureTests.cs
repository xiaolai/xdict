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

            Assert.Equal(request["id"]!.ToJsonString(), reply["id"]!.ToJsonString());
            string op = request["op"]!.GetValue<string>();
            Assert.True(operations.ContainsKey(op), $"{name}: op {op} is in the schema");
            Assert.Equal(1, reply["contract"]!.GetValue<int>());
            if (request["contract"]!.GetValue<int>() != 1)
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
        Assert.True(count >= 8, $"the fixture set is {count}, expected at least 8");
    }
}
