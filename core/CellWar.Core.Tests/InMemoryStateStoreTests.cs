namespace CellWar.Core.Tests;

public class InMemoryStateStoreTests
{
    private static WorldTransaction Begin(InMemoryStateStore store, StoreKey key, Revision revision)
        => Assert.IsType<Result<WorldTransaction, ConflictError>.Ok>(store.Begin(key, revision)).Value;
    [Fact]
    public void PublishedImageAndRetainedBuilderCannotMutateWorld()
    {
        var store = new InMemoryStateStore();
        var initial = DemoScenario.Create();
        var builder = initial.Cells.ToBuilder();
        var id = new EntityId(1);
        var state = new WorldState { Board = initial.Board, Cells = builder, Players = initial.Players, Turn = initial.Turn };
        var key = store.Allocate(new(state));
        builder[id] = builder[id].WithEnergy(99);
        using var lease = store.Read(key, new RevisionQuery.Latest());
        Assert.Equal(30, lease.Snapshot.State.Cells[id].Energy);
        Assert.Throws<InvalidOperationException>(() => lease.Snapshot.State = initial);
        using var tx = Begin(store, key, lease.Revision);
        tx.MutableImage.State = state.UpdateCell(id, state.Cells[id].WithEnergy(70));
        Assert.True(store.Commit(tx).IsOk);
        Assert.Throws<InvalidOperationException>(() => tx.MutableImage.State = initial);
        Assert.True(store.Commit(tx).IsErr);
        Assert.Equal(30, lease.Snapshot.State.Cells[id].Energy);
    }
    [Fact]
    public void ForkMutationAndDiffCompareActualDomainValues()
    {
        var store = new InMemoryStateStore();
        var key = store.Allocate(new(DemoScenario.Create()));
        using var before = store.Read(key, new RevisionQuery.Latest());
        var branch = store.Fork(before);
        using var tx = Begin(store, branch, before.Revision);
        var id = new EntityId(1);
        tx.MutableImage.State = tx.MutableImage.State.UpdateCell(id, tx.MutableImage.State.Cells[id].WithEnergy(90));
        Assert.True(store.Commit(tx).IsOk);
        using var parent = store.Read(key, new RevisionQuery.Latest());
        using var changed = store.Read(branch, new RevisionQuery.Latest());
        using var baseBranch = store.Read(branch, new RevisionQuery.Exact(before.Revision));
        Assert.Equal(30, parent.Snapshot.State.Cells[id].Energy);
        Assert.Equal(90, changed.Snapshot.State.Cells[id].Energy);
        var diff = store.Diff(baseBranch, changed);
        Assert.Equal(new[] { id }, diff.Cells);
        Assert.Empty(diff.Tissues);
        Assert.Same(parent.Snapshot.State.Board, changed.Snapshot.State.Board);
    }
    [Fact]
    public void LeaseSurvivesHistoryEvictionAndDropUntilDisposed()
    {
        var store = new InMemoryStateStore(2);
        var key = store.Allocate(new(DemoScenario.Create()));
        var lease = store.Read(key, new RevisionQuery.Latest());
        for (var revision = 0; revision < 10; revision++)
        {
            using var tx = Begin(store, key, new(revision));
            tx.MutableImage.State = tx.MutableImage.State.WithTurn(tx.MutableImage.State.Turn.WithWorldRound(revision + 2));
            Assert.True(store.Commit(tx).IsOk);
        }
        Assert.Throws<InvalidOperationException>(() => store.Read(key, new RevisionQuery.Exact(Revision.Initial)));
        Assert.Equal(1, lease.Snapshot.State.Turn.WorldRound);
        store.Drop(key);
        Assert.Throws<InvalidOperationException>(() => store.Read(key, new RevisionQuery.Latest()));
        Assert.Equal(1, lease.Snapshot.State.Turn.WorldRound);
        lease.Dispose();
        Assert.Throws<ObjectDisposedException>(() => lease.Snapshot);
    }
    [Fact]
    public void AbortAndConflictDoNotPublish()
    {
        var store = new InMemoryStateStore();
        var key = store.Allocate(new(DemoScenario.Create()));
        using var one = Begin(store, key, Revision.Initial);
        using var two = Begin(store, key, Revision.Initial);
        Assert.True(store.Commit(one).IsOk);
        Assert.True(store.Commit(two).IsErr);
        using var abandoned = Begin(store, key, new(1));
        abandoned.MutableImage.State = abandoned.MutableImage.State.WithTurn(abandoned.MutableImage.State.Turn.WithWorldRound(99));
        abandoned.Dispose();
        Assert.True(store.Commit(abandoned).IsErr);
        using var current = store.Read(key, new RevisionQuery.Latest());
        Assert.Equal(1, current.Revision.Value);
        Assert.Equal(1, current.Snapshot.State.Turn.WorldRound);
    }
    [Fact]
    public void CheckpointRejectsEmptyUnsupportedAndMalformedImages()
    {
        var store = new InMemoryStateStore();
        Assert.True(store.Import(new()).IsErr);
        Assert.True(store.Import(new("{}" )).IsErr);
        var key = store.Allocate(new(DemoScenario.Create()));
        var valid = store.Export(key);
        Assert.True(store.Import(new(valid.Json.Replace("core-slice-1", "unknown"))).IsErr);
        var restored = Assert.IsType<Result<StoreKey, SnapshotError>.Ok>(store.Import(valid)).Value;
        Assert.Equal(valid.Json, store.Export(restored).Json);
    }
}

