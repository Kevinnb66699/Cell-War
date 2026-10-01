using System.Collections.Immutable;

namespace CellWar.Core;

public sealed record PendingInput(long RequestId, int PlayerSeat, ImmutableArray<IDecision> Options);
public readonly record struct InputAnswer(long RequestId, Revision ExpectedRevision, int OptionIndex);

/// <summary>出牌流水的一条（GD `CWGame.note_feed`）：`kind` = play（谁打出）/ event（谁抽到事件卡）。
/// `world` 档随世界事件一起作废（Kevin 2026-09-19）：字段留着、永不产生。</summary>
public sealed record FeedEntry(long Seq, string Kind, int Pid, int Faction, string Card, int Left);

/// <summary>对局日志的一行（GD `logs` / `log_secret` / `log_public` 三列并成一条）。<paramref name="Index"/> 是**绝对下标**：从开局（或续档）起数，
/// 永不因裁剪而漂移 —— 观测的 `logs.from` 与句柄条目的 `index` 都是它。</summary>
public sealed record LogEntry(long Index, string Text, int SecretSeat, string PublicText);

/// <summary>日志游标：下一行的下标 + GD `log_run` 的三个游标（`_run_key` / `_run_at` / `_run_items`）。
/// 与 <see cref="SimulationState.Logs"/> 一样**不进 Checkpoint**（GD `cw_save.gd`「日志不入档」，`restore()` 同时把 `_run_key` 清掉）：续档等于重新开一卷。</summary>
public sealed record LogCursor(long NextIndex, string RunKey, long RunAt, ImmutableList<string> RunItems)
{
    public static readonly LogCursor Start = new(0, "", -1, ImmutableList<string>.Empty);
}

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
    /// <summary>
    /// 玩家看的对局日志（换内核 P2）：每一行都是 GD 那一行的**原文**（同一个格式串、结算那一刻的数值），按结算顺序、全量保留（GD `logs` 也不裁）。
    /// 2026-10-01 之前这里是 `Outbox`：装的是「Accepted … for seat N」这类英文调试串，128 行溢出删头，`logs.from` 游标随之漂移。
    /// **不进 Checkpoint**（同 GD「日志不入档」）；推演（Fork）静音：游标照走、原文不留（同 <see cref="Presentation"/> 的「序号照走、条目不留」）。
    /// </summary>
    public ImmutableList<LogEntry> Logs { get; init; } = ImmutableList<LogEntry>.Empty;
    public LogCursor LogCursor { get; init; } = LogCursor.Start;
    /// <summary>结构化演出条目（见 <see cref="IPresentationEvent"/>）：Seq 单调、永不重编号；超过 <see cref="PresentationCap"/> 丢最旧、抬 <see cref="PresentationDroppedBefore"/>。
    /// 条目本身不进 Checkpoint（表现层不进快照，同 GD cw_state_codec.gd:1-4）。</summary>
    public ImmutableList<StagedEvent> Presentation { get; init; } = ImmutableList<StagedEvent>.Empty;
    public long NextPresentationSeq { get; init; } = 1;
    /// <summary>水位线：Seq 小于它的条目已不可得（溢出丢掉的、续档前的、推演里没留的）。客户端拿到的 since_seq 比它小就知道自己漏了一段。
    /// **派生**而不是存：队列非空 = 最旧那条的 Seq；队列空 = 下一个序号（之前的全没了）。这样续档 / Fork 静音都不用另存一份、不会和主线的 Checkpoint 对不上。</summary>
    public long PresentationDroppedBefore => Presentation.Count == 0 ? NextPresentationSeq : Presentation[0].Seq;
    public const int PresentationCap = 256;
    /// <summary>左侧出牌列的数据源（观测协议 `g.feed_log` / `g.feed_seq`，GD `cw_game.gd:83-90`）。**进 Checkpoint、不进 canon / state_hash**；
    /// 广播是一次性的、断线重连要靠它补，所以是状态不是演出。推演静音时**照记**（分支反正会丢，记了才能和主线的存档对得上）。</summary>
    public ImmutableList<FeedEntry> FeedLog { get; init; } = ImmutableList<FeedEntry>.Empty;
    public long FeedSeq { get; init; }
    public const int FeedKeep = 6;   // GD CWData.FEED_KEEP
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
        if (ev is LogLine or LogRun) return WriteLog(ev, keep);
        var list = keep ? Presentation.Add(new StagedEvent(NextPresentationSeq, ev)) : Presentation;
        if (list.Count > PresentationCap) list = list.RemoveAt(0);
        var next = this with { Presentation = list, NextPresentationSeq = checked(NextPresentationSeq + 1) };
        return ev switch   // GD note_feed 的两个调用点（cw_game.gd:757,768）
        {
            CardPlayed cp => next.Feed("play", cp.Seat, (int)cp.Faction, cp.Card),
            EventCardDrawn ed => next.Feed("event", ed.Seat, (int)ed.Faction, ed.Card),
            _ => next,
        };
    }

    /// <summary>
    /// 一行日志落定：逐句照 GD `CWGame.log_msg` / `log_run`（cw_game.gd:1161-1192）——
    /// `log_msg` 追加一行并**清掉**连续游标（中间插进任何别的行，连续就断了）；`log_run` 在 key 非空、与游标相同、且游标正指着**末条**时
    /// 把 item 并进末条（`prefix + "、".join(items) + suffix`，suffix 用这一次的 —— 【净化】那句尾巴要的是最新的累计记忆数），否则另起一行再记游标。
    /// 落定后排一条 <see cref="LogWritten"/> 进演出队列（合并 = 同一个下标再发一次）。
    /// <paramref name="keep"/> = false（推演静音）：游标与演出序号照走、原文不留 —— 分支与主线做同样的结算就有同样的计数，Fork 出来的存档才和主线对得上。
    /// </summary>
    private SimulationState WriteLog(IPresentationEvent ev, bool keep)
    {
        var c = LogCursor;
        LogWritten written;
        LogCursor next;
        var merge = ev is LogRun m && m.Key != "" && m.Key == c.RunKey && c.RunAt >= 0 && c.RunAt == c.NextIndex - 1;
        if (merge)
        {
            var run = (LogRun)ev;
            var items = c.RunItems.Add(run.Item);
            var text = run.Prefix + string.Join("、", items) + run.Suffix;
            written = new LogWritten(run.WorldRound, run.Phase, c.RunAt, text, -1, text);
            next = c with { RunItems = items };
        }
        else if (ev is LogRun run)
        {
            var text = run.Prefix + run.Item + run.Suffix;
            written = new LogWritten(run.WorldRound, run.Phase, c.NextIndex, text, -1, text);
            next = new LogCursor(c.NextIndex + 1, run.Key, c.NextIndex, [run.Item]);
        }
        else
        {
            var line = (LogLine)ev;
            // GD：`log_public.append(msg if secret_pid < 0 else public_msg)`
            written = new LogWritten(line.WorldRound, line.Phase, c.NextIndex, line.Text, line.SecretSeat,
                line.SecretSeat < 0 ? line.Text : line.PublicText ?? "");
            next = LogCursor.Start with { NextIndex = c.NextIndex + 1 };
        }
        var logs = Logs;
        if (keep)
        {
            var entry = new LogEntry(written.Index, written.Text, written.SecretSeat, written.PublicText);
            if (!merge) logs = logs.Add(entry);
            else if (logs.Count > 0 && logs[^1].Index == written.Index) logs = logs.SetItem(logs.Count - 1, entry);
        }
        return (this with { Logs = logs, LogCursor = next }).Emit(written, keep);
    }

    private SimulationState Feed(string kind, int pid, int faction, string card, int left = 0)
    {
        var seq = checked(FeedSeq + 1);
        var log = FeedLog.Add(new FeedEntry(seq, kind, pid, faction, card, left));
        while (log.Count > FeedKeep) log = log.RemoveAt(0);
        return this with { FeedLog = log, FeedSeq = seq };
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
