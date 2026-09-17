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
    /// <summary>结构化演出条目（见 <see cref="IPresentationEvent"/>）：Seq 单调、永不重编号；超过 <see cref="PresentationCap"/> 丢最旧、抬 <see cref="PresentationDroppedBefore"/>。
    /// 条目本身不进 Checkpoint（表现层不进快照，同 GD cw_state_codec.gd:1-4）。</summary>
    public ImmutableList<StagedEvent> Presentation { get; init; } = ImmutableList<StagedEvent>.Empty;
    public long NextPresentationSeq { get; init; } = 1;
    /// <summary>水位线：Seq 小于它的条目已被丢弃。客户端拿到的 since_seq 比它小就知道自己漏了一段。</summary>
    public long PresentationDroppedBefore { get; init; }
    public const int PresentationCap = 256;
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

    /// <summary>排一条演出条目。推演静音在 <c>Runtime</c> 那一层挡（它不是状态：进状态会让 Fork 多一次提交、Revision 对不上）。</summary>
    public SimulationState Emit(IPresentationEvent ev)
    {
        var list = Presentation.Add(new StagedEvent(NextPresentationSeq, ev));
        var dropped = PresentationDroppedBefore;
        if (list.Count > PresentationCap)
        {
            dropped = list[0].Seq + 1;
            list = list.RemoveAt(0);
        }
        return this with { Presentation = list, NextPresentationSeq = checked(NextPresentationSeq + 1), PresentationDroppedBefore = dropped };
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
