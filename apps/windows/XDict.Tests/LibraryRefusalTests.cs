// The three refusals the library must word: a 3.0 resource library, the registration-code bit, and a damaged file.
// Each is a typed error from the core, and each sentence is distinct in both languages.
using XDict.Client;
using XDict.Models;
using Xunit;

public class LibraryRefusalTests
{
    [Fact]
    public async Task TheThreeRefusalsAreTypedAndWordedDistinctly()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_LIBRARY_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_LIBRARY_FIXTURES must name the generated library fixtures");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        var sentences = new List<(string English, string Chinese)>();
        var cases = new (string Name, string Type, string? Feature)[]
        {
            ("v3", "unsupported", "resourceLibraryV3"),
            ("regcode", "unsupported", "registrationCode"),
            ("damaged", "malformed", null),
        };
        foreach ((string name, string type, string? feature) in cases)
        {
            string directory = Path.Combine(fixtures, "refused", name);
            string mdx = Directory.GetFiles(directory, "*.mdx").Single();
            using var client = new ServiceClient(service);
            client.Handshake();
            Exception? thrown = await Record.ExceptionAsync(
                () => LibraryImporter.ImportAsync(client, PackageFinder.Discover(mdx)));
            Assert.True(thrown is ServiceFailureException,
                $"{name}: expected a typed refusal, got {thrown?.GetType().Name ?? "success"} {thrown?.Message}");
            var failure = (ServiceFailureException)thrown!;
            Assert.Equal(type, failure.ErrorType);
            Assert.NotNull(failure.Error);
            if (feature is not null)
                Assert.Equal(feature, failure.Error!.Value.GetProperty("feature").GetProperty("type").GetString());
            string english = ServiceMessages.For(failure.Error!.Value, "en");
            string chinese = ServiceMessages.For(failure.Error.Value, "zh-Hans");
            Assert.False(string.IsNullOrWhiteSpace(english));
            Assert.False(string.IsNullOrWhiteSpace(chinese));
            Assert.NotEqual(english, chinese);
            sentences.Add((english, chinese));
        }
        Assert.Equal(3, sentences.Select(item => item.English).Distinct().Count());
        Assert.Equal(3, sentences.Select(item => item.Chinese).Distinct().Count());
    }
}
