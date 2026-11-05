// The erase whose reply is lost (plan WS-P1/WS-P3, objection 11): the core commits the rewrite, the test service
// exits before replying, the model must not retry, and a fresh export proves the erase and carries the core's receipt.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class LostEraseAcknowledgementTests
{
    [Fact]
    public async Task AnEraseWhoseReplyIsLostIsSettledByAFreshExport()
    {
        string normal = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable");
        string fault = Environment.GetEnvironmentVariable("XDICT_FAULT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_FAULT_SERVICE names the lost-reply service artifact");
        string storage = "lost-ack-" + Guid.NewGuid().ToString("N");
        double at = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var reading = new
        {
            surface = "run",
            lemma = "run",
            sentence = "The run began at dawn.",
            span = (object?)null,
            cut = (byte)0,
            quality = "complete",
            edition = "mdx-sha256-v1:lost-ack",
            entryKey = "run",
            occurrence = 0u,
            dictionaryName = "Tiny",
            language = "en",
            at,
            device = "device-a",
        };

        using (var client = new ServiceClient(normal, new ServiceClientOptions { Storage = storage }))
        {
            Reply recorded = client.Call("ledgerRecord", new
            {
                reading,
                operation = "reading-" + Guid.NewGuid().ToString("N"),
                targetLanguages = new[] { "en" },
            });
            Assert.Null(recorded.Error);
        }

        int erases = 0;
        Environment.SetEnvironmentVariable("XDICT_FAULT_AFTER_ERASE", "1");
        try
        {
            using var faultClient = new ServiceClient(fault, new ServiceClientOptions { Storage = storage });
            faultClient.RequestSent += (_, operation) =>
            {
                if (operation == "eraseData") Interlocked.Increment(ref erases);
            };
            var export = new DataExport(faultClient);
            await Assert.ThrowsAnyAsync<ServiceFailureException>(
                () => export.EraseAsync(() => at, () => "device-a"));
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDICT_FAULT_AFTER_ERASE", null);
        }
        Assert.Equal(1, Volatile.Read(ref erases));

        using (var client = new ServiceClient(normal, new ServiceClientOptions { Storage = storage }))
        {
            Reply history = client.Call("ledgerHistory", new { now = at, utcOffsetSeconds = 0 });
            Assert.Null(history.Error);
            Assert.Empty(history.Ok!.Value.GetProperty("days").EnumerateArray());

            string path = Path.Combine(Path.GetTempPath(), "xdict-erase-" + Guid.NewGuid().ToString("N") + ".json");
            try
            {
                await new DataExport(client).ExportAsync(path);
                using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
                JsonElement? erased = null;
                foreach (JsonElement item in document.RootElement.GetProperty("events").EnumerateArray())
                    if (item.GetProperty("kind").GetString() == "erased") erased = item;
                Assert.NotNull(erased);
                JsonElement receipt = erased!.Value.GetProperty("payload");
                Assert.True(receipt.GetProperty("clearedReadings").GetUInt64() >= 1,
                    "the receipt must name what the lost erase cleared");
            }
            finally
            {
                File.Delete(path);
            }
        }
    }
}
