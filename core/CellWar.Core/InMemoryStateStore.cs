namespace CellWar.Core;

/// <summary>Persistent world roots with bounded revision retention. Leases own their root reference.</summary>
public sealed class InMemoryStateStore : IStateStore
{
    private sealed class History
    {
        public readonly SortedDictionary<long, WorldImage> Versions = new();
        public Revision Latest;
    }
    private readonly Dictionary<StoreKey, History> worlds = new();
    private readonly HashSet<StoreKey> writers = new();
    private readonly object gate = new();
    private readonly int retainedRevisions;
    public InMemoryStateStore(int retainedRevisions = 32)
    {
        if (retainedRevisions < 1) throw new ArgumentOutOfRangeException(nameof(retainedRevisions));
        this.retainedRevisions = retainedRevisions;
    }
    public StoreKey Allocate(WorldImage initial)
    {
        lock (gate) return Add(initial.CopyForTransaction().Freeze(), Revision.Initial);
    }
    private StoreKey Add(WorldImage image, Revision revision)
    {
        var key = new StoreKey(Guid.NewGuid());
        var history = new History { Latest = revision };
        history.Versions.Add(revision.Value, image);
        worlds.Add(key, history);
        return key;
    }
    private History Resolve(StoreKey key) => worlds.TryGetValue(key, out var history)
        ? history : throw new InvalidOperationException("World has been released or does not belong to this store.");
    public ReadLease Read(StoreKey key, RevisionQuery query)
    {
        lock (gate)
        {
            var history = Resolve(key);
            var revision = query is RevisionQuery.Exact exact ? exact.Revision : history.Latest;
            if (!history.Versions.TryGetValue(revision.Value, out var image))
                throw new InvalidOperationException("Revision is outside the retained window.");
            return new ReadLease(key, revision, image);
        }
    }
    public Result<WorldTransaction, ConflictError> Begin(StoreKey key, Revision expected)
    {
        lock (gate)
        {
            var history = Resolve(key);
            if (expected != history.Latest)
                return new Result<WorldTransaction, ConflictError>.Err(new(expected, history.Latest));
            return new Result<WorldTransaction, ConflictError>.Ok(new(key, expected,
                history.Versions[expected.Value].CopyForTransaction()) { Owner = this });
        }
    }
    public Result<CommitReceipt, StoreError> Commit(WorldTransaction tx)
    {
        lock (gate)
        {
            if (tx.Completed || tx.Owner != this || !worlds.TryGetValue(tx.Key, out var history))
                return new Result<CommitReceipt, StoreError>.Err(new("Invalid or completed transaction."));
            if (history.Latest != tx.BaseRevision)
            {
                tx.Dispose();
                return new Result<CommitReceipt, StoreError>.Err(new("Revision conflict."));
            }
            var revision = tx.BaseRevision.Next();
            history.Versions.Add(revision.Value, tx.MutableImage.Freeze());
            history.Latest = revision;
            tx.Dispose();
            while (history.Versions.Count > retainedRevisions) history.Versions.Remove(history.Versions.First().Key);
            return new Result<CommitReceipt, StoreError>.Ok(new(revision));
        }
    }
    public ChangeSet Diff(ReadLease before, ReadLease after)
    {
        if (before.Key != after.Key) throw new ArgumentException("Diff requires the same world.");
        var a = before.Snapshot;
        var b = after.Snapshot;
        return new ChangeSet
        {
            Cells = Changed(a.State.Cells, b.State.Cells),
            Tissues = Changed(a.State.Board.Tissues, b.State.Board.Tissues),
            Players = Changed(a.State.Players, b.State.Players),
            TurnChanged = !ReferenceEquals(a.State.Turn, b.State.Turn),
            SimulationChanged = a.Simulation != b.Simulation
        };
    }
    private static IReadOnlyList<T> Changed<T, V>(PagedMap<T, V> a, PagedMap<T, V> b) where T : notnull
        => Array.AsReadOnly(a.Keys.Concat(b.Keys).Distinct().Where(key =>
            !a.TryGetValue(key, out var x) || !b.TryGetValue(key, out var y) || !Equals(x, y)).ToArray());
    public StoreKey Fork(ReadLease source)
    {
        lock (gate) { Resolve(source.Key); return Add(source.Snapshot, source.Revision); }
    }
    public Checkpoint Export(StoreKey key)
    {
        using var lease = Read(key, new RevisionQuery.Latest());
        return CheckpointCodec.Encode(lease.Snapshot, lease.Revision);
    }
    public Result<StoreKey, SnapshotError> Import(Checkpoint checkpoint)
    {
        try
        {
            var (image, revision) = CheckpointCodec.Decode(checkpoint);
            lock (gate) return new Result<StoreKey, SnapshotError>.Ok(Add(image.Freeze(), revision));
        }
        catch (Exception error) when (error is System.Text.Json.JsonException or ArgumentException or InvalidOperationException or OverflowException or KeyNotFoundException)
        {
            return new Result<StoreKey, SnapshotError>.Err(new(error.Message));
        }
    }
    internal void ClaimWriter(StoreKey key)
    {
        lock (gate)
        {
            Resolve(key);
            if (!writers.Add(key)) throw new InvalidOperationException("World already has a runtime writer.");
        }
    }
    public void Drop(StoreKey key) { lock (gate) { worlds.Remove(key); writers.Remove(key); } }
}
