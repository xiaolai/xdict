// The reader's trail: every entry shown, in order, and a cursor that Back, Forward and Return move. A new visit made
// after going back discards the forward visits, as a browser's history does.
using System.Text.Json;

namespace XDict.Models;

public sealed record Visit(string Edition, JsonElement Entry, string Query);

public sealed class Trail
{
    private readonly List<Visit> visits = [];
    private int index = -1;

    public int Count => visits.Count;

    public int Index => index;

    public Visit? Current => index >= 0 && index < visits.Count ? visits[index] : null;

    public bool CanBack => index > 0;

    public bool CanForward => index >= 0 && index < visits.Count - 1;

    public bool CanReturn => index > 0;

    public void Push(Visit visit)
    {
        if (index + 1 < visits.Count) visits.RemoveRange(index + 1, visits.Count - index - 1);
        visits.Add(visit);
        index = visits.Count - 1;
    }

    public Visit? Back() => CanBack ? visits[--index] : null;

    public Visit? Forward() => CanForward ? visits[++index] : null;

    public Visit? Return() => CanReturn ? visits[index = 0] : null;
}
