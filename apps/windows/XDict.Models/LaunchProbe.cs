// The launch probe: while the E2E host's harness starts the app in its interactive session, the app writes what it
// read from the service and quits when a file tells it to. Testable without a window (XDict.Tests).
using System.Text.Json;
using XDict.Contract;

namespace XDict.Models;

public sealed class LaunchProbe
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public LaunchProbe(string directory, string id)
    {
        Directory = directory;
        Id = id;
        RecordPath = Path.Combine(directory, id + ".json");
        QuitPath = Path.Combine(directory, id + ".quit");
    }

    public string Directory { get; }

    public string Id { get; }

    public string RecordPath { get; }

    public string QuitPath { get; }

    /// <summary>%LOCALAPPDATA%\XDict\launch, unless XDICT_LAUNCH_DIR names another folder.</summary>
    public static string DefaultDirectory =>
        Environment.GetEnvironmentVariable("XDICT_LAUNCH_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "launch");

    /// <summary>The launch id from <c>--launch-id &lt;id&gt;</c>, or null for a hand-run window.</summary>
    public static string? IdFromArgs(IReadOnlyList<string> args)
    {
        for (int i = 0; i + 1 < args.Count; i++)
            if (args[i] == "--launch-id")
                return string.IsNullOrWhiteSpace(args[i + 1]) ? null : args[i + 1];
        return null;
    }

    public static LaunchProbe? FromCommandLine()
    {
        string? id = IdFromArgs(Environment.GetCommandLineArgs());
        return id is null ? null : new LaunchProbe(DefaultDirectory, id);
    }

    public void RecordVersions(Versions versions, int? servicePid = null) => Write(new
    {
        id = Id,
        pid = Environment.ProcessId,
        servicePid,
        versions,
        startedAt = DateTimeOffset.UtcNow,
    });

    public void RecordError(string error) => Write(new
    {
        id = Id,
        pid = Environment.ProcessId,
        error,
        startedAt = DateTimeOffset.UtcNow,
    });

    /// <summary>Completes once the harness writes the quit file; polls, because a file watch races a quick write.</summary>
    public async Task WaitForQuitAsync(CancellationToken cancellationToken = default)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (File.Exists(QuitPath)) return;
            await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken).ConfigureAwait(false);
        }
    }

    private void Write(object record)
    {
        System.IO.Directory.CreateDirectory(Directory);
        string temporary = RecordPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(record, Options));
        File.Move(temporary, RecordPath, overwrite: true);
    }
}
