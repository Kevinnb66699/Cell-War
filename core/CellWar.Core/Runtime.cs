using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>Single writer for a world. Every simulation mutation publishes one complete root.</summary>
public sealed class Runtime : IRuntime, IDisposable
{
    private readonly IStateStore store;
    private readonly StoreKey key;
    private readonly IReadOnlyDictionary<string, IRuleHandler> handlers;
    /// <summary>注入的随机源原型：每个事件靠它 Fork 出同一个实现，状态另由 Simulation.Rng 带。</summary>
    private readonly IDeterministicRng rngPrototype;
    private readonly object gate = new();
    private bool paused;
    private bool disposed;
    private bool executing;
    public Exception? Fault { get; private set; }
    /// <summary>演出静音：Fork 出来的推演为 true，<see cref="IEventContext.Emit"/> 在这里被短路。</summary>
    public bool PresentationMuted { get; init; }
    public Checkpoint? FailureCheckpoint { get; private set; }
    public long CurrentTick { get { using var lease = Read(); return lease.Snapshot.Simulation.Tick; } }
    public bool IsActive
    {
        get
        {
            lock (gate)
            {
                if (disposed || paused || Fault != null) return false;
                using var lease = Read();
                return !lease.Snapshot.Simulation.Terminated;
            }
        }
    }
    public Runtime(IStateStore store, StoreKey worldKey, IEnumerable<IRuleHandler> handlers,
        IDeterministicRng rng, long startTick = 0)
    {
        this.store = store;
        key = worldKey;
        this.handlers = handlers.ToDictionary(h => h.EventType);
        // 留住注入的那个实例当**原型**：每个事件靠它 Fork 出同一个实现（见 ExecuteOne）。
        // 不留的话，「注入随机源」就只在构造那一瞬间有效，之后全是写死的 xoshiro。
        rngPrototype = rng;
        using var lease = Read();
        if (lease.Snapshot.Simulation.Rng == null)
        {
            using var tx = Begin(lease.Revision);
            tx.MutableImage.Simulation = tx.MutableImage.Simulation with { Rng = rng.GetState(), Tick = startTick };
            Commit(tx);
        }
        if (store is InMemoryStateStore memory) memory.ClaimWriter(key);
    }
    public ReadLease Read()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        return store.Read(key, new RevisionQuery.Latest());
    }
    private WorldTransaction Begin(Revision revision) => store.Begin(key, revision) switch
    {
        Result<WorldTransaction, ConflictError>.Ok ok => ok.Value,
        _ => throw new InvalidOperationException("Concurrent world writer detected.")
    };
    private void Commit(WorldTransaction tx)
    {
        if (store.Commit(tx) is not Result<CommitReceipt, StoreError>.Ok)
            throw new InvalidOperationException("World commit failed.");
    }
    public StepResult Step()
    {
        lock (gate)
        {
            if (executing) throw new InvalidOperationException("Rules cannot reenter Runtime.");
            using var lease = Read();
            var before = lease.Snapshot.Simulation;
            if (!IsActive || before.Input != null || before.QueueEmpty)
                return new(0, before.Tick, before.QueueEmpty);
            using var tx = Begin(lease.Revision);
            try
            {
                executing = true;
                var next = before.Take(out var item);
                if (!handlers.TryGetValue(item.EventType, out var handler))
                    throw new InvalidOperationException($"No handler for {item.EventType}.");
                tx.MutableImage.Simulation = next;
                // 2026-09-15 修：这里原来是 `new Xoshiro256StarStar(1)` —— **状态流过去了，算法写死了**。
                // 构造函数收下的那个 IDeterministicRng 只在初始化时被 GetState() 用过一次，
                // 之后每个事件都用写死的 xoshiro 跑，于是「注入随机源」这件事在执行层**完全无效**。
                //
                // 改成拿注入的那个实例当**原型**：Fork() 复制出同一个实现，再 SetState 定位。
                // 默认路径逐位不变（Xoshiro.Fork() 仍是 Xoshiro），而注入别的实现时它终于真的生效。
                //
                // 为什么要紧：① 权威内核必须能控制随机源；② 对拍 L1 要塞一个「录/放带子」的 rng；
                // ③ AI 推演不能用真实 rng 状态，否则 AI 提前看到自己要掷的骰子
                //    —— GDScript 侧 2026-09-01 修过同一个 bug（monte_carlo_bridge 的 _playout_seed）。
                var rng = rngPrototype.Fork();
                rng.SetState(before.Rng!.Value);
                var context = new EventContext(item, rng, tx, PresentationMuted);
                handler.Handle(context);
                tx.MutableImage.Simulation = tx.MutableImage.Simulation with { Rng = rng.GetState() };
                Commit(tx);
                return new(1, tx.MutableImage.Simulation.Tick, tx.MutableImage.Simulation.QueueEmpty);
            }
            catch (Exception error)
            {
                Fault = error;
                FailureCheckpoint = CheckpointCodec.Encode(lease.Snapshot, lease.Revision);
                throw;
            }
            finally { executing = false; }
        }
    }
    public int Run(int eventBudget = 256)
    {
        if (eventBudget < 1) throw new ArgumentOutOfRangeException(nameof(eventBudget));
        var count = 0;
        while (count < eventBudget && Step().EventsProcessed > 0) count++;
        return count;
    }
    public int StepUntil(long targetTick)
    {
        lock (gate)
        {
            var count = 0;
            while (count < 10000)
            {
                using var lease = Read();
                var s = lease.Snapshot.Simulation;
                if (!IsActive || s.Input != null || s.QueueEmpty || s.Peek().Tick > targetTick) break;
                count += Step().EventsProcessed;
            }
            return count;
        }
    }
    public void Schedule(long tick, string eventType, object? payload = null)
    {
        lock (gate)
        {
            if (executing) throw new InvalidOperationException("Use the event context inside a handler.");
            using var lease = Read();
            if (lease.Snapshot.Simulation.Input != null)
                throw new InvalidOperationException("Use Answer to resume a pending input.");
            using var tx = Begin(lease.Revision);
            tx.MutableImage.Simulation = tx.MutableImage.Simulation.Schedule(tick, eventType, payload);
            Commit(tx);
        }
    }
    public ValidationResult Answer(InputAnswer answer)
    {
        lock (gate)
        {
            using var lease = Read();
            var input = lease.Snapshot.Simulation.Input;
            if (!IsActive || executing || input == null || input.RequestId != answer.RequestId ||
                lease.Revision != answer.ExpectedRevision || answer.OptionIndex < 0 || answer.OptionIndex >= input.Options.Length)
                return new(false, "Stale or invalid input answer.");
            using var tx = Begin(lease.Revision);
            tx.MutableImage.Simulation = (tx.MutableImage.Simulation with { Input = null })
                .Schedule(CurrentTick, "PlayerDecision", input.Options[answer.OptionIndex]);
            // 行动边界（协议 p=2 附录 B）：答下即开步，这一步的演出都排在它之后
            var turn = tx.MutableImage.State.Turn;
            tx.MutableImage.Simulation = tx.MutableImage.Simulation.Emit(new StepBegin(turn.WorldRound, turn.Phase, input.RequestId, input.PlayerSeat), keep: !PresentationMuted);
            Commit(tx);
            return new(true);
        }
    }
    public int CancelEvents(Func<ScheduledEvent, bool> predicate)
    {
        lock (gate)
        {
            if (executing) throw new InvalidOperationException("Use the event context inside a handler.");
            using var lease = Read();
            using var tx = Begin(lease.Revision);
            tx.MutableImage.Simulation = tx.MutableImage.Simulation.Cancel(predicate, out var count);
            Commit(tx);
            return count;
        }
    }
    public void Pause() { lock (gate) paused = true; }
    public void Resume() { lock (gate) paused = false; }
    public IRuntime Fork()
    {
        lock (gate)
        {
            using var lease = Read();
            // 同上：分支出来的 Runtime 也要带着原型走，否则 Fork 一次就退回写死的 xoshiro。
            // AI 的推演正是从这里分叉出去的 —— 这条不改，注入的随机源在推演里当场失效。
            // 推演不演出（GD `sim_quiet`）：AI 分叉出去的世界不该往演出队列里塞东西。静音是 Runtime 的属性、不进状态 —— 进状态就要多提交一次，分支的 Revision 会和主线对不上
            return new Runtime(store, store.Fork(lease), handlers.Values, rngPrototype.Fork()) { paused = paused, PresentationMuted = true };
        }
    }
    public Checkpoint Checkpoint() { lock (gate) { using var lease = Read(); return CheckpointCodec.Encode(lease.Snapshot, lease.Revision); } }
    public void Terminate()
    {
        lock (gate)
        {
            using var lease = Read();
            using var tx = Begin(lease.Revision);
            tx.MutableImage.Simulation = tx.MutableImage.Simulation with { Terminated = true, Input = null };
            Commit(tx);
        }
    }
    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            store.Drop(key);
            disposed = true;
            FailureCheckpoint = null;
            Fault = null;
        }
    }
}

internal sealed class EventContext : IEventContext
{
    private readonly WorldTransaction transaction;
    private readonly bool muted;
    public long CurrentTick => transaction.MutableImage.Simulation.Tick;
    public ScheduledEvent CurrentEvent { get; }
    public IDeterministicRng Rng { get; }
    public EventContext(ScheduledEvent item, IDeterministicRng rng, WorldTransaction transaction, bool presentationMuted = false)
        => (CurrentEvent, Rng, this.transaction, muted) = (item, rng, transaction, presentationMuted);
    public WorldState GetWorldState() => transaction.MutableImage.State;
    public void SetWorldState(WorldState state) => transaction.MutableImage.State = state;
    public void Schedule(long tick, string type, object? payload = null)
        => transaction.MutableImage.Simulation = transaction.MutableImage.Simulation.Schedule(tick, type, payload);
    public int CancelEvents(Func<ScheduledEvent, bool> predicate)
    {
        transaction.MutableImage.Simulation = transaction.MutableImage.Simulation.Cancel(predicate, out var count);
        return count;
    }
    public void AwaitInput(int playerSeat, IReadOnlyList<IDecision> options)
    {
        var s = transaction.MutableImage.Simulation;
        if (s.Input != null || options.Count == 0 || options.Any(o => o.PlayerSeat != playerSeat))
            throw new InvalidOperationException("Invalid input barrier.");
        foreach (var option in options) PayloadCodec.Validate(option);
        // 行动边界：下一问挂起之前收步，rev = 这次提交后的修订号（与紧随其后的 envelope.rev 同一个数）
        var turn = transaction.MutableImage.State.Turn;
        s = s.Emit(new StepEnd(turn.WorldRound, turn.Phase, transaction.BaseRevision.Value + 1), keep: !muted);
        transaction.MutableImage.Simulation = s with
        {
            Input = new(s.NextRequest, playerSeat, options.ToImmutableArray()), NextRequest = checked(s.NextRequest + 1)
        };
    }
    public void Log(string message)
    {
        var s = transaction.MutableImage.Simulation;
        var output = s.Outbox.Add(message);
        if (output.Count > 128) output = output.RemoveAt(0);
        transaction.MutableImage.Simulation = s with { Outbox = output };
    }
    public void Emit(IPresentationEvent ev) => transaction.MutableImage.Simulation = transaction.MutableImage.Simulation.Emit(ev, keep: !muted);
}
