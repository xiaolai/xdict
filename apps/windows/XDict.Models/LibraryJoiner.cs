// The reader's word on a changed edition: joining its lineage to the dictionary it continues, and splitting it back.
// The core keeps both idempotent (ADR-0002 decision 3), so a retry is safe.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

public static class LibraryJoiner
{
    public static async Task<string> JoinAsync(ServiceClient client, string edition, string lineage,
        CancellationToken cancellation = default) =>
        Lineage(await client.CallAsync("joinLineage", new { edition, lineage }, cancellation: cancellation));

    public static async Task<string> SplitAsync(ServiceClient client, string edition, string newLineage,
        CancellationToken cancellation = default) =>
        Lineage(await client.CallAsync("splitLineage", new { edition, newLineage }, cancellation: cancellation));

    public static async Task<string?> LineageOfAsync(ServiceClient client, string edition,
        CancellationToken cancellation = default)
    {
        Reply reply = await client.CallAsync("lineageOf", new { edition }, cancellation: cancellation);
        if (reply.Error is { } error)
            throw new ServiceFailureException(error.GetProperty("type").GetString() ?? "internal", error);
        JsonElement answer = reply.Ok ?? throw new InvalidOperationException("lineageOf answered nothing");
        return answer.ValueKind == JsonValueKind.Null ? null : answer.GetString();
    }

    private static string Lineage(Reply reply)
    {
        if (reply.Error is { } error)
            throw new ServiceFailureException(error.GetProperty("type").GetString() ?? "internal", error);
        return reply.Ok?.GetString() ?? throw new InvalidOperationException("the lineage answer is not a string");
    }
}
