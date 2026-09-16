namespace CellWar.Core.Tests;

public class RuntimeTests
{
    private sealed class Handler(string type, Action<IEventContext> action) : IRuleHandler
    {
        public string EventType => type;
        public void Handle(IEventContext context) => action(context);
    }
    private static Runtime Create(params IRuleHandler[] handlers)
    {
        var store = new InMemoryStateStore();
        return new(store, store.Allocate(new(DemoScenario.Create())), handlers, new Xoshiro256StarStar(123));
    }
    [Fact]
    public void FutureOrderAndImmediateNestingAreStable()
    {
        var seen = new List<string>();
        using var runtime = Create(new Handler("event", c =>
        {
            var value = (string)c.CurrentEvent.Payload!;
            seen.Add(value);
            if (value == "first") { c.Schedule(c.CurrentTick, "event", "a"); c.Schedule(c.CurrentTick, "event", "b"); }
        }));
        runtime.Schedule(5, "event", "first");
        runtime.Schedule(5, "event", "second");
        runtime.Schedule(4, "event", "earlier");
        runtime.Run();
        Assert.Equal(new[] { "earlier", "first", "b", "a", "second" }, seen);
    }
    [Fact]
    public void FailureRollsBackStateQueueCancellationRngAndOutput()
    {
        using var runtime = Create(new Handler("fail", c =>
        {
            c.SetWorldState(c.GetWorldState().WithTurn(c.GetWorldState().Turn.WithWorldRound(99)));
            c.Rng.NextDouble();
            c.Schedule(10, "later");
            c.CancelEvents(e => e.EventType == "keep");
            c.Log("must not escape");
            throw new InvalidOperationException("injected");
        }), new Handler("keep", _ => { }));
        runtime.Schedule(1, "fail"); runtime.Schedule(2, "keep");
        var before = runtime.Checkpoint().Json;
        Assert.Throws<InvalidOperationException>(() => runtime.Step());
        Assert.Equal(before, runtime.Checkpoint().Json);
        Assert.Equal(before, runtime.FailureCheckpoint!.Json);
        Assert.False(runtime.IsActive);
    }
    [Fact]
    public void RngConsumptionIsContinuousAcrossEventsAndRestorable()
    {
        var seen = new List<int>();
        using var runtime = Create(new Handler("rng", c => { seen.Add(c.Rng.NextInt(100000)); seen.Add(c.Rng.NextInt(100000)); }));
        runtime.Schedule(1, "rng"); runtime.Schedule(2, "rng"); runtime.Run();
        var oracle = new Xoshiro256StarStar(123);
        Assert.Equal(Enumerable.Range(0, 4).Select(_ => oracle.NextInt(100000)), seen);
        var state = oracle.GetState();
        var expected = oracle.NextDouble();
        oracle.SetState(state);
        Assert.Equal(expected, oracle.NextDouble());
    }
    [Fact]
    public void ForkSharesRootsAndCancellationDoesNotChangeParent()
    {
        using var runtime = Create(new Handler("event", _ => { }));
        runtime.Schedule(1, "event", "keep"); runtime.Schedule(2, "event", "remove");
        using var branch = (Runtime)runtime.Fork();
        using var parentLease = runtime.Read(); using var branchLease = branch.Read();
        Assert.Same(parentLease.Snapshot.State, branchLease.Snapshot.State);
        Assert.Same(parentLease.Snapshot.Simulation.Future, branchLease.Snapshot.Simulation.Future);
        Assert.Equal(1, branch.CancelEvents(e => Equals(e.Payload, "remove")));
        Assert.Equal(2, runtime.Run()); Assert.Equal(1, branch.Run());
    }
    [Fact]
    public void PauseBudgetAndEmptyQueueNeverAdvanceWallClock()
    {
        using var runtime = Create(new Handler("event", _ => { }));
        runtime.Schedule(3, "event"); runtime.Schedule(5, "event");
        runtime.Pause(); Assert.Equal(0, runtime.StepUntil(100)); Assert.Equal(0, runtime.CurrentTick);
        runtime.Resume(); Assert.Equal(1, runtime.Run(1)); Assert.Equal(3, runtime.CurrentTick);
        Assert.Equal(1, runtime.StepUntil(100)); Assert.Equal(5, runtime.CurrentTick);
    }
    [Fact]
    public void InputBarrierPreservesFutureWorkAndRejectsStaleAnswers()
    {
        using var runtime = Create(new Handler("ask", c => c.AwaitInput(0, new IDecision[] { new PassDecision(0) })),
            new Handler("PlayerDecision", _ => { }), new Handler("future", _ => { }));
        runtime.Schedule(1, "ask"); runtime.Schedule(9, "future");
        Assert.Equal(1, runtime.Run());
        using var lease = runtime.Read();
        var request = lease.Snapshot.Simulation.Input!;
        Assert.Equal(0, runtime.StepUntil(100)); Assert.Equal(1, runtime.CurrentTick);
        Assert.False(runtime.Answer(new(request.RequestId, new Revision(-1), 0)).IsValid);
        Assert.True(runtime.Answer(new(request.RequestId, lease.Revision, 0)).IsValid);
        Assert.False(runtime.Answer(new(request.RequestId, lease.Revision, 0)).IsValid);
        Assert.Equal(2, runtime.Run()); Assert.Equal(9, runtime.CurrentTick);
    }
    [Fact]
    public void DisposedRuntimeAndLeaseCannotBeUsed()
    {
        var runtime = Create(); var lease = runtime.Read();
        lease.Dispose(); Assert.Throws<ObjectDisposedException>(() => lease.Snapshot);
        runtime.Dispose(); runtime.Dispose(); Assert.Throws<ObjectDisposedException>(() => runtime.Read());
    }
    [Fact]
    public void UnknownHandlersFaultWithoutLosingEvents()
    {
        using var runtime = Create(); runtime.Schedule(1, "unknown");
        var before = runtime.Checkpoint().Json;
        Assert.Throws<InvalidOperationException>(() => runtime.Step());
        Assert.Equal(before, runtime.Checkpoint().Json);
    }
    [Fact]
    public void MutableEventPayloadIsRejected()
    {
        using var runtime = Create();
        Assert.Throws<ArgumentException>(() => runtime.Schedule(1, "event", new List<int>()));
    }
}
