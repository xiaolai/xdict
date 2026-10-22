// The capture contract's lifecycle (conformance/capture/CONTRACT.md §5-§6, lifecycle.md): one numbering for every
// trigger, one terminal acknowledgement per request, a stale answer that changes nothing, and the ephemeral session the
// sentence lives in — metadata-only in every description.
using System.Text.Json.Nodes;

namespace XDict.Models;

public enum CaptureTrigger { Selection, Service, Menu, PointerGesture }

public enum CaptureOutcome { Shown, NotShown, Cancelled }

public enum CaptureDeliveryAnswer { Accepted, Refused }

public readonly record struct CaptureRequest(int Number, CaptureTrigger Trigger);

public sealed record CaptureDelivery(CapturedTerm Term, CaptureRequest Request, int Generation);

public sealed record CaptureAcknowledgement(int Request, int Generation, CaptureOutcome Outcome);

/// <summary>Where a captured term ends up: search, the service, the trail, observation hooks. The answer is immediate;
/// whether it was then shown comes back through the book's acknowledge, for that request and generation only.</summary>
public interface ICaptureSink
{
    CaptureDeliveryAnswer Deliver(CaptureDelivery delivery);
}

/// <summary>The context outcome (§4), parsed from the value's own node.</summary>
public abstract record CaptureContext
{
    public sealed record Available(string Sentence, int Start, int Length) : CaptureContext
    {
        /// <summary>Metadata only: the sentence is held by the session, never by a log line.</summary>
        public override string ToString() => $"available({Length} units at {Start})";
    }
    public sealed record Pending(string Handle) : CaptureContext;
    public sealed record Unavailable(string Reason) : CaptureContext;
}

/// <summary>What capture hands over. Only the term goes to a consumer; the sentence stays in the session.</summary>
public sealed class CapturedTerm
{
    public string Term { get; }
    public CaptureContext Context { get; }
    internal JsonNode Value { get; }

    private CapturedTerm(string term, CaptureContext context, JsonNode value)
    {
        Term = term;
        Context = context;
        Value = value;
    }

    /// <summary>From a validated value: the one production path. Null for a refused one.</summary>
    public static CapturedTerm? From(CaptureValue.Result result)
    {
        if (!result.Valid || result.Value is null) return null;
        JsonNode value = result.Value;
        string term = value["term"]!.GetValue<string>();
        JsonNode? context = value["context"];
        CaptureContext parsed = context?["kind"]?.GetValue<string>() switch
        {
            "available" => new CaptureContext.Available(context["sentence"]!.GetValue<string>(),
                Index(context["term"]!["start"]), Index(context["term"]!["length"])),
            "pending" => new CaptureContext.Pending(context["handle"]!.GetValue<string>()),
            _ => new CaptureContext.Unavailable(context?["reason"]?.GetValue<string>() ?? "notCaptured"),
        };
        return new CapturedTerm(term, parsed, value);
    }

    private static int Index(JsonNode? node) =>
        node is JsonValue scalar && scalar.TryGetValue(out int number) ? number
        : int.Parse(node!.GetValue<string>(), System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>Metadata only: a log line or a dump here never names the sentence.</summary>
    public override string ToString() => $"CapturedTerm({Term.Length} units, {Context.GetType().Name})";
}

/// <summary>**The numbering, and the rule that every request ends exactly once.** Begun at the gesture, before any
/// asynchronous work; claiming presentation is a second act on the same number.</summary>
public sealed class CaptureRequests
{
    private const int EndedMemory = 64;
    private readonly object gate = new();
    private int issued, floor, generations, forgottenThrough;
    private int? current;
    private readonly Dictionary<int, int> open = [];
    private readonly Dictionary<int, CaptureAcknowledgement> ended = [];
    private readonly Queue<int> endedOrder = [];
    private Action<CaptureAcknowledgement>? listener;

    /// <summary>For the bound's test: how much the book holds.</summary>
    public (int Open, int Ended) Retained
    {
        get { lock (gate) return (open.Count, ended.Count); }
    }

    public void OnEnd(Action<CaptureAcknowledgement> handler)
    {
        lock (gate) listener = handler;
    }

    private void Tell(List<CaptureAcknowledgement> endings)
    {
        Action<CaptureAcknowledgement>? handler;
        lock (gate) handler = listener;
        if (handler is null) return;
        foreach (CaptureAcknowledgement ending in endings) handler(ending);
    }

    private int Next()
    {
        issued += 1;
        return issued;
    }

    private bool Known(CaptureRequest request) => request.Number > 0 && request.Number <= issued;

    private bool IsEnded(int number) => ended.ContainsKey(number) || (number <= forgottenThrough && !open.ContainsKey(number));

    private CaptureAcknowledgement? End(int number, int generation, CaptureOutcome outcome)
    {
        if (IsEnded(number)) return null;
        open.Remove(number);
        var ack = new CaptureAcknowledgement(number, generation, outcome);
        ended[number] = ack;
        endedOrder.Enqueue(number);
        if (endedOrder.Count > EndedMemory)
        {
            int gone = endedOrder.Dequeue();
            ended.Remove(gone);
            forgottenThrough = Math.Max(forgottenThrough, gone);
        }
        return ack;
    }

    private List<CaptureAcknowledgement> EndBelow(int number)
    {
        var endings = new List<CaptureAcknowledgement>();
        foreach (int key in open.Keys.Where(key => key < number).OrderBy(key => key))
            if (End(key, open[key], CaptureOutcome.Cancelled) is { } ack) endings.Add(ack);
        return endings;
    }

    /// <summary>A number, now, which claims nothing until <see cref="Present"/>.</summary>
    public CaptureRequest Begin(CaptureTrigger trigger)
    {
        lock (gate)
        {
            int number = Next();
            open[number] = 0;
            return new CaptureRequest(number, trigger);
        }
    }

    /// <summary>A number that claims presentation at once, ending every open request before it.</summary>
    public CaptureRequest BeginPresenting(CaptureTrigger trigger)
    {
        CaptureRequest request;
        List<CaptureAcknowledgement> endings;
        lock (gate)
        {
            int number = Next();
            open[number] = 0;
            floor = number;
            current = number;
            request = new CaptureRequest(number, trigger);
            endings = EndBelow(number);
        }
        Tell(endings);
        return request;
    }

    /// <summary>Claims presentation for a request numbered earlier and delivers; a refused claim never reaches the sink.</summary>
    public CaptureDeliveryAnswer Present(CapturedTerm term, CaptureRequest request, ICaptureSink? sink)
    {
        bool claimed = false;
        var endings = new List<CaptureAcknowledgement>();
        lock (gate)
        {
            if (!Known(request) || IsEnded(request.Number)) return CaptureDeliveryAnswer.Refused;
            if (current == request.Number) claimed = true;
            else if (request.Number > floor && request.Number <= issued)
            {
                floor = request.Number;
                current = request.Number;
                claimed = true;
            }
            else if (End(request.Number, open.GetValueOrDefault(request.Number), CaptureOutcome.Cancelled) is { } endedNow)
            {
                endings.Add(endedNow);
            }
            if (claimed) endings.AddRange(EndBelow(request.Number));
        }
        Tell(endings);
        return claimed ? Deliver(term, request, sink) : CaptureDeliveryAnswer.Refused;
    }

    /// <summary>The reader dismissed what was presented: every open request ends cancelled.</summary>
    public IReadOnlyList<CaptureAcknowledgement> Close()
    {
        List<CaptureAcknowledgement> endings;
        lock (gate)
        {
            floor = issued;
            current = null;
            endings = EndBelow(int.MaxValue);
        }
        Tell(endings);
        return endings;
    }

    public bool IsCurrent(CaptureRequest request)
    {
        lock (gate) return Known(request) && current == request.Number;
    }

    /// <summary>Hands the term over with a fresh generation; the sink is called outside the lock.</summary>
    public CaptureDeliveryAnswer Deliver(CapturedTerm term, CaptureRequest request, ICaptureSink? sink)
    {
        int generation;
        lock (gate)
        {
            if (!Known(request) || IsEnded(request.Number)) return CaptureDeliveryAnswer.Refused;
            generations += 1;
            open[request.Number] = generations;
            generation = generations;
        }
        if (sink is null)
        {
            Tell(EndNow(request.Number, generation));
            return CaptureDeliveryAnswer.Refused;
        }
        CaptureDeliveryAnswer answer = sink.Deliver(new CaptureDelivery(term, request, generation));
        if (answer == CaptureDeliveryAnswer.Refused) Tell(EndNow(request.Number, generation));
        return answer;
    }

    private List<CaptureAcknowledgement> EndNow(int number, int generation)
    {
        lock (gate)
        {
            var ack = End(number, generation, CaptureOutcome.Cancelled);
            return ack is null ? [] : [ack];
        }
    }

    /// <summary>True where this answer became the request's terminal acknowledgement.</summary>
    public bool Acknowledge(CaptureRequest request, int generation, CaptureOutcome outcome)
    {
        CaptureAcknowledgement? endedNow;
        lock (gate)
        {
            if (!Known(request) || generation <= 0 || open.GetValueOrDefault(request.Number, -1) != generation) return false;
            endedNow = End(request.Number, generation, outcome);
        }
        Tell(endedNow is null ? [] : [endedNow]);
        return endedNow is not null;
    }

    /// <summary>Ends a request not yet ended, delivered or not. True where it did.</summary>
    public bool Cancel(CaptureRequest request)
    {
        CaptureAcknowledgement? endedNow;
        lock (gate)
        {
            if (!Known(request)) return false;
            endedNow = End(request.Number, open.GetValueOrDefault(request.Number), CaptureOutcome.Cancelled);
        }
        Tell(endedNow is null ? [] : [endedNow]);
        return endedNow is not null;
    }

    /// <summary>The consumer is gone: every delivered request still open ends cancelled, in order.</summary>
    public IReadOnlyList<CaptureAcknowledgement> ConsumerGone()
    {
        List<CaptureAcknowledgement> endings;
        lock (gate)
        {
            endings = open.Where(pair => pair.Value > 0).OrderBy(pair => pair.Key)
                .Select(pair => End(pair.Key, pair.Value, CaptureOutcome.Cancelled)).OfType<CaptureAcknowledgement>().ToList();
        }
        Tell(endings);
        return endings;
    }

    public CaptureAcknowledgement? Terminal(CaptureRequest request)
    {
        lock (gate) return Known(request) ? ended.GetValueOrDefault(request.Number) : null;
    }
}

/// <summary>The presented document's identity: a finished document acknowledges only where it belongs to the lookup the
/// presentation was asked to show **now** (rule 3, scenarios B and C).</summary>
public sealed class PresentedEntry
{
    private (CaptureRequest Request, int Generation)? shown;

    public void Show(CaptureRequest request, int generation) => shown = (request, generation);

    /// <summary>True only where the finishing document is the one shown now; a stale finish changes nothing.</summary>
    public bool Finish(CaptureRequest request, int generation) =>
        shown is { } current && current.Request == request && current.Generation == generation;

    public void Clear() => shown = null;
}

/// <summary>**The one ephemeral session a sentence lives in**: in memory only, one context at a time, metadata in every
/// description. Only the term goes to search, the service, the trail and the observation hooks.</summary>
public sealed class CaptureContextSession
{
    private readonly object gate = new();
    private (int Request, int Generation, string Term, CaptureContext Context)? held;

    public PendingContexts Pending { get; }

    public CaptureContextSession(PendingContexts? pending = null) => Pending = pending ?? new PendingContexts();

    /// <summary>Holds a term's context for a delivery, dropping (and cancelling) whatever was held before. A context that
    /// fails the constructor's boundary, or a pending handle the book does not hold, is held as unavailable — fail-closed.</summary>
    public void Hold(CapturedTerm term, int request, int generation)
    {
        CaptureContext context = term.Context;
        PendingContext? waiting = null;
        if (context is CaptureContext.Available available)
        {
            if (CaptureValue.CheckContext(available.Sentence, available.Start, available.Length, term.Term) is not null)
                context = new CaptureContext.Unavailable("notCaptured");
        }
        else if (context is CaptureContext.Pending pending)
        {
            waiting = Pending.Context(pending.Handle);
            if (waiting is null) context = new CaptureContext.Unavailable("notCaptured");
        }
        CaptureContext heldContext = context;
        string? dropped = null;
        lock (gate)
        {
            if (this.held?.Context is CaptureContext.Pending previous) dropped = previous.Handle;
            this.held = (request, generation, term.Term, heldContext);
        }
        if (dropped is not null && dropped != (heldContext as CaptureContext.Pending)?.Handle) Pending.Cancel(dropped);
        waiting?.OnEnd(end => Settle(request, generation, term.Term, end));
    }

    private void Settle(int request, int generation, string term, PendingContextEnd end)
    {
        CaptureContext? settled = !end.Cancelled && end.Context is not null
            ? end.Context
            : new CaptureContext.Unavailable("notCaptured");
        if (settled is CaptureContext.Pending) settled = new CaptureContext.Unavailable("notCaptured");
        if (settled is CaptureContext.Available available &&
            CaptureValue.CheckContext(available.Sentence, available.Start, available.Length, term) is not null)
            settled = new CaptureContext.Unavailable("notCaptured");
        string? taken = null;
        lock (gate)
        {
            if (held is not { } current || current.Request != request || current.Generation != generation ||
                current.Context is not CaptureContext.Pending pending) return;
            held = (request, generation, term, settled);
            taken = pending.Handle;
        }
        if (taken is not null) Pending.Forget(taken);
    }

    public CaptureContext? Context(int request, int generation)
    {
        lock (gate)
        {
            if (held is not { } current || current.Request != request || current.Generation != generation) return null;
            return current.Context;
        }
    }

    public void End(int request)
    {
        string? dropped = null;
        lock (gate)
        {
            if (held is not { } current || current.Request != request) return;
            if (current.Context is CaptureContext.Pending pending) dropped = pending.Handle;
            held = null;
        }
        if (dropped is not null) Pending.Cancel(dropped);
    }

    public void Clear()
    {
        string? dropped = null;
        lock (gate)
        {
            if (held?.Context is CaptureContext.Pending pending) dropped = pending.Handle;
            held = null;
        }
        if (dropped is not null) Pending.Cancel(dropped);
    }

    public bool IsEmpty
    {
        get { lock (gate) return held is null; }
    }

    public override string ToString()
    {
        lock (gate)
        {
            return held is { } current
                ? $"CaptureContextSession(request {current.Request}, generation {current.Generation}, {current.Context.GetType().Name})"
                : "CaptureContextSession(empty)";
        }
    }
}

/// <summary>How a reading ended, once: the context it settled to (or the first reading, on overdue), or cancelled.</summary>
public sealed record PendingContextEnd(bool Cancelled, CaptureContext? Context)
{
    public static PendingContextEnd Settled(CaptureContext context) => new(false, context);
    public static PendingContextEnd Overdue(CaptureContext fallback) => new(false, fallback);
    public static PendingContextEnd CancelledEnd { get; } = new(true, null);
}

/// <summary>A reading still in flight: exactly one ending, its work waited for apart from the ending, metadata only.</summary>
public sealed class PendingContext
{
    public string Handle { get; }
    private readonly object gate = new();
    private PendingContextEnd? end;
    private Action<PendingContextEnd>? listeners;
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task work;

    internal PendingContext(string handle, CaptureContext fallback, TimeSpan bound, Func<Task<CaptureContext?>> body)
    {
        Handle = handle;
        work = Task.Run(async () =>
        {
            Task<CaptureContext?> answer;
            try
            {
                answer = body();
            }
            catch (Exception)
            {
                // A synchronous throw would fault the task before Finish: the reading must still end exactly once.
                Finish(PendingContextEnd.Settled(fallback));
                return;
            }
            Task overdue = Task.Delay(bound, cancellation.Token).ContinueWith(_ => { }, TaskScheduler.Default);
            Task first = await Task.WhenAny(answer, overdue);
            if (cancellation.IsCancellationRequested) return;
            if (first == answer && answer.IsCompletedSuccessfully)
                Finish(PendingContextEnd.Settled(answer.Result ?? fallback));
            else
                Finish(PendingContextEnd.Overdue(fallback));
        });
    }

    public bool Ended { get { lock (gate) return end is not null; } }

    public void OnEnd(Action<PendingContextEnd> handler)
    {
        PendingContextEnd? endedNow;
        lock (gate)
        {
            endedNow = end;
            if (endedNow is null) listeners += handler;
        }
        if (endedNow is not null) handler(endedNow);
    }

    public void Cancel()
    {
        Finish(PendingContextEnd.CancelledEnd);
        cancellation.Cancel();
    }

    public Task Finished => work;

    public override string ToString() => $"PendingContext({Handle}, {(Ended ? "ended" : "reading")})";

    private void Finish(PendingContextEnd ending)
    {
        Action<PendingContextEnd>? told;
        lock (gate)
        {
            if (end is not null) return;
            end = ending;
            told = listeners;
            listeners = null;
        }
        told?.Invoke(ending);
    }
}

/// <summary>The readings still in flight, by handle: started by the reader, found by the session, forgotten when it
/// settles or is cancelled, so a context let go keeps no sentence for later.</summary>
public sealed class PendingContexts
{
    private readonly object gate = new();
    private readonly Dictionary<string, PendingContext> readings = [];
    private ulong next;

    public PendingContext Start(CaptureContext fallback, TimeSpan bound, Func<Task<CaptureContext?>> body)
    {
        string handle;
        lock (gate)
        {
            next += 1;
            handle = next.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        var reading = new PendingContext(handle, fallback, bound, body);
        lock (gate) readings[handle] = reading;
        return reading;
    }

    public PendingContext? Context(string handle)
    {
        lock (gate) return readings.GetValueOrDefault(handle);
    }

    internal void Cancel(string handle)
    {
        PendingContext? reading;
        lock (gate)
        {
            reading = readings.GetValueOrDefault(handle);
            readings.Remove(handle);
        }
        reading?.Cancel();
    }

    internal void Forget(string handle)
    {
        lock (gate) readings.Remove(handle);
    }
}
