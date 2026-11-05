// The AI settings and the two ways the shell keeps a secret: the DeepSeek defaults macOS uses, a settings file with
// no key in it, Credential Manager for the key, and the factory's typed refusal when a CLI is absent.
using System.Runtime.Versioning;
using XDict.AI;
using Xunit;

[SupportedOSPlatform("windows")]
public class AISettingsTests
{
    [Fact]
    public void TheDefaultsAreTheMacOsDeepSeekConfiguration()
    {
        var settings = new AISettings();
        Assert.Equal(AISourceKind.Off, settings.Source);
        Assert.Equal("deepseek", settings.HttpProfile);
        Assert.Equal("https://api.deepseek.com", settings.Endpoint);
        Assert.Equal("deepseek-flash", settings.Model);
        Assert.False(settings.SendEntryText);
        Assert.True(settings.PreviewBeforeSending);

        AIHttpConfig config = settings.HttpConfig("secret");
        Assert.Equal(new Uri("https://api.deepseek.com"), config.Endpoint);
        Assert.Equal("deepseek-flash", config.Model);
        Assert.True(config.SendKey);
        Assert.Equal(AITokenField.MaxTokens, config.TokenField);
        Assert.Equal(8_192, config.TokenBudget);
    }

    [Fact]
    public void TheSettingsFileRoundTripsWithoutTheKey()
    {
        string path = Path.Combine(Path.GetTempPath(), "xdict-ai-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var settings = new AISettings
            {
                Source = AISourceKind.Http, Model = "deepseek-v4-pro", SendEntryText = true,
                Language = "zh-Hans", PreviewBeforeSending = false, CodexModel = "gpt-5.4",
            };
            settings.Save(path);
            string text = File.ReadAllText(path);
            Assert.DoesNotContain("secret", text);
            Assert.DoesNotContain("apiKey", text);
            AISettings read = AISettings.Load(path);
            Assert.Equal(AISourceKind.Http, read.Source);
            Assert.Equal("deepseek-v4-pro", read.Model);
            Assert.True(read.SendEntryText);
            Assert.Equal("zh-Hans", read.Language);
            Assert.False(read.PreviewBeforeSending);
            Assert.Equal("gpt-5.4", read.CodexModel);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void AMissingCliIsNotConfigured()
    {
        var settings = new AISettings
        {
            Source = AISourceKind.CodexCli,
            CodexExecutable = Path.Combine(Path.GetTempPath(), "no-such-codex-" + Guid.NewGuid().ToString("N") + ".exe"),
        };
        var error = Assert.Throws<AIProviderException>(() =>
            AISourceFactory.Create(settings, null));
        Assert.Equal(AIProviderError.NotConfigured, error.Error);
    }

    [Fact]
    public void TheKeyLivesInCredentialManagerAndCanBeRemoved()
    {
        string target = "XDict.AI.test." + Guid.NewGuid().ToString("N");
        var store = new WindowsCredentialStore(target);
        try
        {
            Assert.Null(store.Read());
            store.Write("secret-key");
            Assert.Equal("secret-key", store.Read());
            store.Write("rotated");
            Assert.Equal("rotated", store.Read());
            store.Write(null);
            Assert.Null(store.Read());
        }
        finally
        {
            store.Write(null);
        }
    }
}
