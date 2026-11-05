// The AI contract's 90 vectors through the shell's own marking, composer and validator: every case by id, ordinal
// comparison, no canonicalisation. The vectors are the normative conformance/ai/vectors.jsonl.
using System.Text.Json;
using XDict.AI;
using Xunit;

public class AIContractTests
{
    private static string Vectors()
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory is not null &&
               !File.Exists(Path.Combine(directory.FullName, "conformance", "ai", "vectors.jsonl")))
            directory = directory.Parent;
        if (directory is null) throw new InvalidOperationException("conformance/ai/vectors.jsonl was not found");
        return Path.Combine(directory.FullName, "conformance", "ai", "vectors.jsonl");
    }

    [Fact]
    public void EveryAiContractVectorPasses()
    {
        int count = 0;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (string line in File.ReadLines(Vectors()))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement vector = document.RootElement;
            string id = vector.GetProperty("id").GetString()!;
            Assert.True(ids.Add(id), $"{id}: duplicate id");
            Assert.Equal(6, vector.GetProperty("contract").GetInt32());
            string op = vector.GetProperty("op").GetString()!;
            JsonElement input = vector.GetProperty("input");
            JsonElement expect = vector.GetProperty("expect");
            string expectedStatus = expect.GetProperty("status").GetString()!;
            switch (op)
            {
                case "mark":
                {
                    string sentence = input.GetProperty("sentence").GetString()!;
                    string marked = input.TryGetProperty("range", out JsonElement range)
                        ? AIMarker.Mark(sentence, range)
                        : sentence;
                    Assert.True(expectedStatus == "ok", $"{id}: unexpected status {expectedStatus}");
                    Assert.Equal(expect.GetProperty("text").GetString(), marked);
                    break;
                }
                case "compose":
                {
                    AIComposeResult result = AIComposer.Compose(input);
                    Assert.True(result.Status == expectedStatus,
                        $"{id}: status {result.Status}, expected {expectedStatus} ({result.Code})");
                    if (expectedStatus == "ok")
                        Assert.Equal(expect.GetProperty("text").GetString(), result.Text);
                    else
                        Assert.Equal(expect.GetProperty("code").GetString(), result.Code);
                    break;
                }
                case "validate":
                {
                    AIValidationResult result = AIValidator.Validate(input);
                    Assert.True(result.Status == expectedStatus,
                        $"{id}: status {result.Status}, expected {expectedStatus} ({result.Code})");
                    if (expectedStatus == "ok")
                    {
                        Assert.Equal(expect.GetProperty("outcome").GetString(), result.Outcome);
                        if (expect.TryGetProperty("translation", out JsonElement translation))
                            Assert.Equal(translation.GetString(), result.Translation);
                        if (expect.TryGetProperty("explanation", out JsonElement explanation))
                            Assert.Equal(explanation.GetString(), result.Explanation);
                    }
                    else
                    {
                        Assert.Equal(expect.GetProperty("code").GetString(), result.Code);
                    }
                    break;
                }
                default:
                    throw new InvalidOperationException($"{id}: unknown AI vector op {op}");
            }
            count++;
        }
        Assert.Equal(90, count);
    }
}
