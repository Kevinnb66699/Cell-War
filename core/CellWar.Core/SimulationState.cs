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
    /// <summary>水位线：Seq 小于它的条目已不可得（溢出丢掉的、续档前的、推演里没留的）。客户端拿到的 since_seq 比它小就知道自己漏了一段。
    /// **派生**而不是存：队列非空 = 最旧那条的 Seq；队列空 = 下一个序号（之前的全没了）。这样续档 / Fork 静音都不用另存一份、不会和主线的 Checkpoint 对不上。</summary>
    public long PresentationDroppedBefore => Presentation.Count == 0 ? NextPresentationSeq : Presentation[0].Seq;
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

    /// <summary>排一条演出条目。<paramref name="keep"/> = false 是推演静音（<c>Runtime.PresentationMuted</c>）：**序号照走、条目不留** ——
    /// 序号进 Checkpoint，分支与主线做同样的结算就得有同样的序号，否则 Fork 出来的存档和主线对不上。</summary>
    public SimulationState Emit(IPresentationEvent ev, bool keep = true)
    {
        var list = keep ? Presentation.Add(new StagedEvent(NextPresentationSeq, ev)) : Presentation;
        if (list.Count > PresentationCap) list = list.RemoveAt(0);
        return this with { Presentation = list, NextPresentationSeq = checked(NextPresentationSeq + 1) };
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
