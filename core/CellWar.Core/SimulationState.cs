using System.Collections.Immutable;

namespace CellWar.Core;

public sealed record PendingInput(long RequestId, int PlayerSeat, ImmutableArray<IDecision> Options);
public readonly record struct InputAnswer(long RequestId, Revision ExpectedRevision, int OptionIndex);

public sealed record SimulationState
{
    public long Tick { get; init; }
    public int NextSequence { get; init; }
    public long NextRequest { get; init; } = 1;
    public RngState? Rng { get; init; }
    public ImmutableSortedDictionary<EventOrder, ScheduledEvent> Future { get; init; } =
        ImmutableSortedDictionary<EventOrder, ScheduledEvent>.Empty;
    public ImmutableStack<ScheduledEvent> Immediate { get; init; } = ImmutableStack<ScheduledEvent>.Empty;
    public PendingInput? Input { get; init; }
    public ImmutableList<string> Outbox { get; init; } = ImmutableList<string>.Empty;
    public bool Terminated { get; init; }
    public bool QueueEmpty => Future.Count == 0 && Immediate.IsEmpty;

    public SimulationState Schedule(long tick, string type, object? payload, int order = 0)
    {
        if (tick < Tick) throw new ArgumentOutOfRangeException(nameof(tick));
        PayloadCodec.Validate(payload);
        var sequence = NextSequence;
        var item = new ScheduledEvent(tick, type, payload, sequence);
        var next = this with { NextSequence = checked(sequence + 1) };
        return tick == Tick
            ? next with { Immediate = Immediate.Push(item) }
            : next with { Future = Future.Add(new(tick, order, sequence), item) };
    }

    public ScheduledEvent Peek() => Immediate.IsEmpty ? Future.First().Value : Immediate.Peek();
    public SimulationState Take(out ScheduledEvent item)
    {
        if (!Immediate.IsEmpty)
        {
            item = Immediate.Peek();
            return this with { Immediate = Immediate.Pop(), Tick = item.Tick };
        }
        var first = Future.First();
        item = first.Value;
        return this with { Future = Future.Remove(first.Key), Tick = item.Tick };
    }

    public SimulationState Cancel(Func<ScheduledEvent, bool> predicate, out int count)
    {
        count = 0;
        var future = Future;
        foreach (var pair in Future)
            if (predicate(pair.Value)) { future = future.Remove(pair.Key); count++; }
        var immediate = Immediate;
        // Cancellation is uncommon; unchanged stack tails remain shared.
        var prefix = new List<ScheduledEvent>();
        var cursor = Immediate;
        while (!cursor.IsEmpty)
        {
            var item = cursor.Peek();
            cursor = cursor.Pop();
            if (predicate(item))
            {
                count++;
                immediate = cursor;
                for (var i = prefix.Count - 1; i >= 0; i--) immediate = immediate.Push(prefix[i]);
            }
            else prefix.Add(item);
        }
        return this with { Future = future, Immediate = immediate };
    }
}

public readonly record struct EventOrder(long Tick, int Order, int Sequence) : IComparable<EventOrder>
{
    public int CompareTo(EventOrder other)
    {
        var result = Tick.CompareTo(other.Tick);
        if (result == 0) result = Order.CompareTo(other.Order);
        return result == 0 ? Sequence.CompareTo(other.Sequence) : result;
    }
}
