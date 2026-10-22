using XDict.Client;
using XDict.Contract;
using XDict.Models;
using System.Text.Json;

namespace XDict.App;

public sealed class DictionaryEntrySource(ServiceClient client, string dictionary, bool originalStyle = false) : IEntrySource
{
    public string Dictionary => dictionary;
    public bool OriginalStyle { get; set; } = originalStyle;
    public JsonElement? LastEntry { get; private set; }
    private EntryDisplayOptions? displayOptions;
    private readonly JsonSerializerOptions json = new() { PropertyNameCaseInsensitive = true };
    private object View => new { baseUrl = EntryPolicy.Base, maxBodyBytes = 16 << 20, originalStyle = OriginalStyle };
    public async Task<EntryResponse> EntryAsync(JsonElement reference, CancellationToken cancellation = default)
    {
        LastEntry = reference.Clone();
        Reply reply = await client.CallAsync("entry", new { dict = dictionary, entry = reference, view = View }, cancellation: cancellation);
        if (reply.Error is { } error) throw new ServiceFailureException(error.GetProperty("type").GetString()!);
        if (displayOptions is null)
        {
            Reply catalogue = await client.CallAsync("displayOptions", new { dict = dictionary }, cancellation: cancellation);
            if (catalogue.Error is not null) throw new InvalidDataException("display options did not answer");
            displayOptions = catalogue.Ok!.Value.Deserialize<EntryDisplayOptions>(json) ?? throw new InvalidDataException("missing display options");
            _ = displayOptions.Resolve(null);
        }
        return new(reply.Payload ?? [], "text/html; charset=utf-8", reply.Ok!.Value.GetProperty("csp").GetString()!, Display: displayOptions);
    }
    public async Task<EntryResponse> ResourceAsync(string path, CancellationToken cancellation)
    {
        Reply reply = await client.CallAsync("resource", new { dict = dictionary, path, view = View }, cancellation: cancellation);
        if (reply.Error is { } error) throw new ServiceFailureException(error.GetProperty("type").GetString()!);
        if (reply.Ok!.Value.GetProperty("type").GetString() != "found") return new([], "text/plain", "", 404);
        return new(reply.Payload ?? [], reply.Ok.Value.GetProperty("mime").GetString()!, "");
    }
}
