#if DEBUG
// The system voice on the host: the voices present, a plain and an IPA render measured to a stream, a real WAV played
// to its end through Media Foundation, and a Chinese render. Nothing remote; the dictionary recordings' own playback
// and the entry's sound links are product paths that the entry view exercises.
using System.Text.Json;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;
using XDict.Models;

namespace XDict.App;

internal static class SoundLab
{
    public static async Task RunAsync(string configPath)
    {
        using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(configPath));
        string output = config.RootElement.GetProperty("output").GetString()!;
        string folder = Path.GetDirectoryName(output)!;
        (string Name, string Language)[] voices = SpeechSynthesizer.AllVoices
            .Select(voice => (voice.DisplayName, voice.Language)).ToArray();
        using var synth = new SpeechSynthesizer();
        ulong plain = 0, ipa = 0, chinese = 0;
        string? english = SpeechText.ChooseVoice(voices, "en", "us");
        if (english is not null)
        {
            synth.Voice = SpeechSynthesizer.AllVoices.First(voice => voice.DisplayName == english);
            using (SpeechSynthesisStream stream = await synth.SynthesizeTextToStreamAsync("record")) plain = stream.Size;
            using (SpeechSynthesisStream stream = await synth.SynthesizeSsmlToStreamAsync(
                       SpeechText.Ssml("record", "rɪˈkɔːrd", "en-US"))) ipa = stream.Size;
        }
        string? zh = SpeechText.ChooseVoice(voices, "zh-Hans");
        if (zh is not null)
        {
            synth.Voice = SpeechSynthesizer.AllVoices.First(voice => voice.DisplayName == zh);
            using SpeechSynthesisStream stream = await synth.SynthesizeTextToStreamAsync("词典");
            chinese = stream.Size;
        }
        string wav = Path.Combine(folder, "tone.wav");
        WriteTone(wav, 0.5);
        bool played = await PlayAsync(wav);
        await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
        {
            voices,
            english,
            zh,
            plain,
            ipa,
            chinese,
            played,
        }));
    }

    private static async Task<bool> PlayAsync(string path)
    {
        using var player = new MediaPlayer();
        var ended = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        player.MediaEnded += (_, _) => ended.TrySetResult(true);
        player.MediaFailed += (_, _) => ended.TrySetResult(false);
        player.Source = MediaSource.CreateFromUri(new Uri(path));
        player.Play();
        try
        {
            return await ended.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        catch (TimeoutException)
        {
            return false;
        }
    }

    /// <summary>A 16-bit mono PCM sine wave: a recording the host can actually decode.</summary>
    private static void WriteTone(string path, double seconds)
    {
        const int rate = 8000;
        int samples = (int)(rate * seconds);
        byte[] data = new byte[44 + samples * 2];
        void Put(int at, uint value) { data[at] = (byte)value; data[at + 1] = (byte)(value >> 8); data[at + 2] = (byte)(value >> 16); data[at + 3] = (byte)(value >> 24); }
        void Put16(int at, ushort value) { data[at] = (byte)value; data[at + 1] = (byte)(value >> 8); }
        System.Text.Encoding.ASCII.GetBytes("RIFF").CopyTo(data, 0);
        Put(4, (uint)(36 + samples * 2));
        System.Text.Encoding.ASCII.GetBytes("WAVEfmt ").CopyTo(data, 8);
        Put(16, 16);
        Put16(20, 1);
        Put16(22, 1);
        Put(24, rate);
        Put(28, rate * 2);
        Put16(32, 2);
        Put16(34, 16);
        System.Text.Encoding.ASCII.GetBytes("data").CopyTo(data, 36);
        Put(40, (uint)(samples * 2));
        for (int i = 0; i < samples; i++)
        {
            short value = (short)(Math.Sin(2 * Math.PI * 440 * i / rate) * 12000);
            Put16(44 + i * 2, (ushort)value);
        }
        File.WriteAllBytes(path, data);
    }
}
#endif
