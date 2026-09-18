using System.Collections.Immutable;

namespace CellWar.Core.Tests;

/// <summary>
/// 口径二 · 批 0 步 1：结构化演出通道的底座（docs/口径二_批0_底座规格.md A-4）。
/// 钉的是通道本身的不变量：Seq 单调、溢出丢最旧但**不重编号**、事务失败不留条目、推演静音、条目不进 Checkpoint、
/// 规则事件分流（演出走 Emit、其余照旧进日志）。
/// </summary>
public class PresentationTests
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

    private static NoticeAnnounced Notice(string text) => new(1, Phase.PlayerAction, text);

    [Fact]
    public void 序号单调_溢出丢最旧但不重编号_水位线跟着抬()
    {
        using var runtime = Create(new Handler("emit", c => c.Emit(Notice((string)c.CurrentEvent.Payload!))));
        for (var i = 1; i <= 300; i++) runtime.Schedule(i, "emit", $"n{i}");
        while (runtime.Run() > 0) { }   // Run 有步数预算，跑到队列空
        using var lease = runtime.Read();
        var sim = lease.Snapshot.Simulation;
        Assert.Equal(SimulationState.PresentationCap, sim.Presentation.Count);
        Assert.Equal(300 - SimulationState.PresentationCap + 1, sim.Presentation[0].Seq);   // 最旧的那些被丢了
        Assert.Equal(300, sim.Presentation[^1].Seq);                                         // 最新一条仍是第 300 号
        Assert.Equal(301, sim.NextPresentationSeq);
        Assert.Equal(sim.Presentation[0].Seq, sim.PresentationDroppedBefore);                 // 比它小的都不在了
        Assert.True(sim.Presentation.Zip(sim.Presentation.Skip(1)).All(pair => pair.Second.Seq == pair.First.Seq + 1));
        Assert.Equal("n300", ((NoticeAnnounced)sim.Presentation[^1].Event).Text);
    }

    [Fact]
    public void 事务失败_演出条目一起回滚()
    {
        using var runtime = Create(new Handler("fail", c => { c.Emit(Notice("must not escape")); throw new InvalidOperationException("injected"); }));
        runtime.Schedule(1, "fail");
        Assert.Throws<InvalidOperationException>(() => runtime.Step());
        using var lease = runtime.Read();
        Assert.Empty(lease.Snapshot.Simulation.Presentation);
        Assert.Equal(1, lease.Snapshot.Simulation.NextPresentationSeq);
    }

    [Fact]
    public void 分叉出来的推演静音_主线不受影响()
    {
        using var runtime = Create(new Handler("emit", c => c.Emit(Notice("x"))));
        using var branch = (Runtime)runtime.Fork();
        branch.Schedule(1, "emit");
        branch.Run();
        runtime.Schedule(1, "emit");
        runtime.Run();
        using var branchLease = branch.Read();
        using var mainLease = runtime.Read();
        Assert.True(branch.PresentationMuted);
        Assert.Empty(branchLease.Snapshot.Simulation.Presentation);
        Assert.Equal(mainLease.Snapshot.Simulation.NextPresentationSeq, branchLease.Snapshot.Simulation.NextPresentationSeq);   // 序号照走：分支的存档要和主线对得上
        Assert.False(runtime.PresentationMuted);
        Assert.Single(mainLease.Snapshot.Simulation.Presentation);
    }

    [Fact]
    public void 演出条目不进Checkpoint_日志照旧进()
    {
        using var runtime = Create(new Handler("emit", c => { c.Emit(Notice("stage-only-text")); c.Log("log-only-text"); }));
        runtime.Schedule(1, "emit");
        runtime.Run();
        var json = runtime.Checkpoint().Json;
        Assert.DoesNotContain("stage-only-text", json);   // JSON 会把中文转义，用 ASCII 才比得出
        Assert.Contains("log-only-text", json);
    }

    [Fact]
    public void 存档只持久化两个计数器_续档后序号续得上_条目不带()
    {
        using var runtime = Create(new Handler("emit", c => c.Emit(Notice((string)c.CurrentEvent.Payload!))));
        for (var i = 1; i <= 300; i++) runtime.Schedule(i, "emit", $"n{i}");
        while (runtime.Run() > 0) { }
        var json = runtime.Checkpoint().Json;
        Assert.Contains("\"Schema\":2", json);
        Assert.Contains("\"NextPresentationSeq\":301", json);
        Assert.DoesNotContain("PresentationDroppedBefore", json);   // 水位线是派生的，不存
        var (image, _) = CheckpointCodec.Decode(new(json));
        Assert.Empty(image.Simulation.Presentation);
        Assert.Equal(301, image.Simulation.NextPresentationSeq);
        Assert.Equal(301, image.Simulation.PresentationDroppedBefore);   // 续档前的条目全没了：水位线 = 下一个序号
        var next = image.Simulation.Emit(Notice("after"));
        Assert.Equal(301, next.Presentation[^1].Seq);   // 续得上，不重编号
        Assert.Throws<System.Text.Json.JsonException>(() => CheckpointCodec.Decode(new(json.Replace("\"Schema\":2", "\"Schema\":1"))));
    }

    [Fact]
    public void 规则事件分流_演出走通道_其余照旧进日志()
    {
        using var runtime = Create(new Handler("fake", c =>
        {
            var ev = new IGameEvent[]
            {
                new DiceRolled(1, Phase.PlayerAction, "攻击", 6, 6, 0, new HexPosition(0, 0, 0)),
                new EnergyChangedEvent(1, Phase.PlayerAction, new EntityId(2), 60, 50, "test"),
            };
            RuleFlowProbe.Publish(c, ev);
        }));
        runtime.Schedule(1, "fake");
        runtime.Run();
        using var lease = runtime.Read();
        var sim = lease.Snapshot.Simulation;
        var staged = Assert.Single(sim.Presentation);
        Assert.IsType<DiceRolled>(staged.Event);
        Assert.Contains(sim.Outbox, line => line.Contains("能量"));
        Assert.DoesNotContain(sim.Outbox, line => line.Contains("roll"));
    }

    [Fact]
    public void 方向下标照GD的DIRS表()
    {
        var origin = new HexPosition(0, 0, 0);
        Assert.Equal(0, SemanticKey.DirIndex(origin, new HexPosition(1, 0, -1)));
        Assert.Equal(3, SemanticKey.DirIndex(origin, new HexPosition(-1, 0, 1)));
        Assert.Equal(5, SemanticKey.DirIndex(origin, new HexPosition(0, 1, -1)));
        Assert.Equal(-1, SemanticKey.DirIndex(origin, new HexPosition(2, 0, -2)));   // 不是六邻
    }

    /// <summary>RuleFlow 是 internal；测试程序集有 InternalsVisibleTo。</summary>
    private static class RuleFlowProbe
    {
        public static void Publish(IEventContext c, IEnumerable<IGameEvent> events) => RuleFlow.Publish(c, events);
    }
}
