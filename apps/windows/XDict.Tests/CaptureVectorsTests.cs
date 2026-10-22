// Every capture-contract vector through the production constructor: a valid value's exact UTF-16 output, or the
// refusal code the contract names. No vector may be skipped.
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using XDict.Models;
using Xunit;

public class CaptureVectorsTests
{
    [Fact]
    public void AllFiftyEightVectorsAgree()
    {
        string path = VectorsPath();
        int count = 0;
        foreach (string line in File.ReadAllLines(path))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonNode vector = JsonNode.Parse(line)!;
            string id = vector["id"]!.GetValue<string>();
            JsonNode input = vector["input"]!;
            JsonNode expect = vector["expect"]!;
            CaptureValue.Result result = CaptureValue.Make(input);
            if (expect["status"]!.GetValue<string>() == "valid")
            {
                Assert.True(result.Valid, $"{id}: refused as {result.Code}");
                Assert.True(JsonNode.DeepEquals(expect["value"], result.Value), $"{id}: the value differs");
            }
            else
            {
                Assert.False(result.Valid, $"{id}: accepted, expected {expect["code"]}");
                Assert.Equal(expect["code"]!.GetValue<string>(), result.Code);
            }
            count++;
        }
        Assert.Equal(58, count);
    }

    /// <summary>The suite revision the contract's runner must report: a digest of vectors.jsonl. A change to the suite
    /// reaches conformance only after this pin moves with it, deliberately.</summary>
    [Fact]
    public void SuiteRevisionIsRecorded()
    {
        byte[] digest = SHA256.HashData(File.ReadAllBytes(VectorsPath()));
        Assert.Equal("9843b8de3d881d58fae9e6d2fade6e07d0b16a264b47bd541fcc1f4906ceb0ff",
            Convert.ToHexString(digest).ToLowerInvariant());
    }

    private static string VectorsPath()
    {
        string? named = Environment.GetEnvironmentVariable("XDICT_CAPTURE");
        if (!string.IsNullOrWhiteSpace(named)) return Path.Combine(named, "vectors.jsonl");
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "conformance", "capture")))
            directory = directory.Parent;
        Assert.NotNull(directory);
        return Path.Combine(directory!.FullName, "conformance", "capture", "vectors.jsonl");
    }
}
