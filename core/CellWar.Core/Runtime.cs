using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>Single writer for a world. Every simulation mutation publishes one complete root.</summary>
public sealed class Runtime : IRuntime, IDisposable
{
    private readonly IStateStore store;
    private readonly StoreKey key;
    private readonly IReadOnlyDictionary<string, IRuleHandler> handlers;
    private readonly object gate = new();
    private bool paused;
    private bool disposed;
    private bool executing;
    public Exception? Fault { get; private set; }
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
                var rng = new Xoshiro256StarStar(1);
                rng.SetState(before.Rng!.Value);
                var context = new EventContext(item, rng, tx);
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
            return new Runtime(store, store.Fork(lease), handlers.Values, new Xoshiro256StarStar(1)) { paused = paused };
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
    public long CurrentTick => transaction.MutableImage.Simulation.Tick;
    public ScheduledEvent CurrentEvent { get; }
    public IDeterministicRng Rng { get; }
    public EventContext(ScheduledEvent item, IDeterministicRng rng, WorldTransaction transaction)
        => (CurrentEvent, Rng, this.transaction) = (item, rng, transaction);
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
}
