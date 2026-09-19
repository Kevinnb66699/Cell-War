using System.Text.Json;
using CellWar.Core.Observation;

namespace CellWar.Core.Tests;

/// <summary>
/// 口径二 · 批 0 步 4：观测协议 v1 的 C# 生产者（docs/观测协议_v1.md）。
/// 钉的是协议本身的硬规矩：零浮点、零 rng、cells 稠密、tiles 有序、枚举是 GD 值、store / cards 分离、
/// 未知键硬错、tier B 缺席合法、ask 的 kind / stop_index / options 形状、出牌流水进档且分支静音也照记。
/// </summary>
public class ObservationV1Tests
{
    private static MatchSession Demo() => new(DemoScenario.Create());

    [Fact]
    public void 全量envelope_零浮点零rng_cells稠密_tiles有序_枚举是GD值()
    {
        using var session = Demo();
        var env = session.ObserveV1(ObservationV1Codec.ViewerOmniscient);
        var json = ObservationV1Codec.Serialize(env);

        Assert.Equal(3, env.P);   // p=3（2026-09-19 删七个世界事件残留字段）
        Assert.Equal(["A"], env.ProducedTiers);
        Assert.True(env.Full); Assert.Null(env.Base);
        Assert.DoesNotContain("\"rng\"", json);
        using var doc = JsonDocument.Parse(json);
        AssertNoFraction(doc.RootElement, "$");

        Assert.Equal(127, env.State.Board.Tiles.Length);
        Assert.True(env.State.Board.Tiles.Zip(env.State.Board.Tiles.Skip(1))
            .All(p => p.First.At.Q < p.Second.At.Q || (p.First.At.Q == p.Second.At.Q && p.First.At.R < p.Second.At.R)), "tiles 要按 q→r 排");
        Assert.Equal(Enumerable.Range(0, env.State.Cells.Length), env.State.Cells.Select(c => c.Id));
        foreach (var c in env.State.Cells)
        {
            if (c.Faction == 0) { Assert.InRange(c.Itype, 0, 4); Assert.Equal(-1, c.Ctype); }
            else { Assert.InRange(c.Ctype, 0, 3); Assert.Equal(-1, c.Itype); }
            Assert.Equal(-1, c.NeutralUntil);   // 从没被中和：C# 存 0、协议给 -1
            Assert.Null(c.CampPos);             // 没在蹲：null 而不是 (0,0)
            Assert.Equal(c.Id, env.State.Board.Tiles.Single(t => t.At == c.Pos).Cell);   // tile.cell 是 cell id
        }
        foreach (var p in env.State.G.Players)
            Assert.Equal(p.Id, env.State.Cells.Single(c => c.Pid == p.Id).Id);   // DemoScenario 每席一只，id = 席位
        Assert.Equal("turn", env.State.G.Phase);
        Assert.Equal("玩家回合", env.State.G.D.PhaseText);
        Assert.Equal([30, 20, 20], env.State.G.Tune.SolidifyThreshold);
        Assert.Equal(63, env.State.G.Tune.LimitCancerous);
        Assert.Equal("", env.State.G.WinKind); Assert.Equal(-1, env.State.G.Winner); Assert.False(env.State.G.IsOver);
        Assert.Equal(-1, env.State.G.EffectorRound);   // 从没发动过：C# 存 0、协议给 -1
    }

    [Fact]
    public void 骨髓格只填cards_其余只填store()
    {
        var world = DemoScenario.Create();
        var marrow = world.Board.Tissues.Values.First(t => t.OccupyingCell == null);
        var core = world.Board.Tissues.Values.First(t => t.OccupyingCell == null && t.Position != marrow.Position);
        world = world.WithBoard(world.Board.UpdateTissue(marrow.Position, marrow.WithType(TissueType.BoneMarrow).WithCharge(1))
            .UpdateTissue(core.Position, core.WithType(TissueType.MetabolicCore).WithCharge(15)));
        using var session = new MatchSession(world);
        var tiles = session.ObserveV1(-2).State.Board.Tiles;
        var m = tiles.Single(t => t.At == ObservationV1Codec.Pos(marrow.Position));
        var k = tiles.Single(t => t.At == ObservationV1Codec.Pos(core.Position));
        Assert.Equal((2, 0, 1), (m.Special, m.Store, m.Cards));
        Assert.Equal((1, 15, 0), (k.Special, k.Store, k.Cards));
        Assert.Equal(750, k.D.StoreFraction);   // 15 / 20 → 千分点
    }

    [Fact]
    public void 序列化往返字节相同_未知键硬错_tierB缺席合法()
    {
        using var session = Demo();
        var json = ObservationV1Codec.Serialize(session.ObserveV1(-2));
        var back = ObservationV1Codec.Deserialize(json);
        Assert.Equal(json, ObservationV1Codec.Serialize(back));
        Assert.DoesNotContain("count_healthy", json);   // tier B：C# 批 0 不产出，键不出现
        Assert.Null(back.State.G.D.CountHealthy);
        Assert.Throws<JsonException>(() => ObservationV1Codec.Deserialize(json.Replace("\"round_no\":", "\"zzz\":1,\"round_no\":")));
        Assert.Throws<JsonException>(() => ObservationV1Codec.Deserialize(json.Replace("\"chain_left\":", "\"chain_lft\":")));
    }

    [Fact]
    public void ask_行动回合_kind与stop_index_options带键与GD形状的data()
    {
        using var session = Demo();
        var env = session.ObserveV1(-2);
        var ask = env.Ask!;
        Assert.Equal("action", ask.Kind); Assert.Null(ask.Tag);
        Assert.Equal(0, ask.Seat); Assert.Equal(-1, ask.StopIndex);
        Assert.Equal(ask.Options.Length, ask.Options.Select(o => o.Key).Distinct().Count());
        Assert.Contains(ask.Options, o => o.Key == SemanticKey.PassKey);   // C# 固定多出的一条，协议原样带出
        Assert.Contains(ask.Options, o => o.Key == "k=action|act=end");
        Assert.All(ask.Options, o => { Assert.NotEmpty(o.Label); Assert.True(o.Data.ContainsKey("act"), o.Key); });
        var move = ask.Options.First(o => o.Key.StartsWith("k=action|act=move|to=", StringComparison.Ordinal));
        Assert.NotNull(move.Cost);
        Assert.Equal(move.Cost, move.Data["cost"].GetInt32());   // GD 迁移选项自带 cost
        Assert.Equal(JsonValueKind.Object, move.Data["to"].ValueKind);   // 坐标是 {q, r}
        Assert.Equal(move.Data["to"].GetProperty("q").GetInt32() + "," + move.Data["to"].GetProperty("r").GetInt32(), move.Key["k=action|act=move|to=".Length..]);
        Assert.False(move.IsStop);
        Assert.Equal(0, ask.Options.Count(o => o.IsStop));
        Assert.Equal(Enumerable.Range(0, ask.Options.Length), ask.Options.Select(o => o.Index));
    }

    [Fact]
    public void ask_中途询问_stop项在下标0_组键取前半截()
    {
        // 【连续吞噬】：GD 把 {stop:true} append 在末尾（cw_actions.gd:1693），C# 的选项序另算 —— 所以 stop_index 是显式字段
        var world = DemoScenario.Create();
        var walker = world.Cells.Values.First(c => c.Faction == Faction.Immune);
        world = world.WithTurn(world.Turn.Copy(pendingChain: walker.Id, pendingChainWalkDepth: 1, setPendingChain: true));
        var s = world;
        var options = new IDecision[] { new StopChainDecision(walker.OwnerSeat, walker.Id), new ChainMoveDecision(walker.OwnerSeat, walker.Id, walker.Position) };
        var image = new WorldImage(s) { Simulation = new SimulationState { Input = new PendingInput(7, walker.OwnerSeat, [.. options]) } };
        var ask = ObservationV1Codec.Encode(image, new Revision(3)).Ask!;
        Assert.Equal(("free_move", "连续吞噬", 0), (ask.Kind, ask.Tag, ask.StopIndex));
        Assert.True(ask.Options[0].IsStop);
        Assert.Equal(7, ask.AskId); Assert.Equal(3, ask.Rev);
        Assert.True(ask.Options[0].Data["stop"].GetBoolean());
    }

    [Fact]
    public void 出牌流水_进档_分支静音也照记_溢出只留六条()
    {
        using var session = Demo();
        var before = session.ObserveV1(-2).State.G;
        Assert.Empty(before.FeedLog); Assert.Equal(0, before.FeedSeq);

        var store = new InMemoryStateStore();
        using var runtime = new Runtime(store, store.Allocate(new(DemoScenario.Create())),
            [new Handler("play", c => c.Emit(new CardPlayed(1, Phase.PlayerAction, 0, "免疫A 打出【x】", new EntityId(1), default, Faction.Immune, (string)c.CurrentEvent.Payload!)))],
            new Xoshiro256StarStar(5));
        for (var i = 1; i <= 8; i++) runtime.Schedule(i, "play", $"卡{i}");
        while (runtime.Run() > 0) { }
        using (var lease = runtime.Read())
        {
            var sim = lease.Snapshot.Simulation;
            Assert.Equal(8, sim.FeedSeq);
            Assert.Equal([3, 4, 5, 6, 7, 8], sim.FeedLog.Select(f => f.Seq));
            Assert.Equal(("play", 0, 0, "卡8"), (sim.FeedLog[^1].Kind, sim.FeedLog[^1].Pid, sim.FeedLog[^1].Faction, sim.FeedLog[^1].Card));
        }
        var (image, _) = CheckpointCodec.Decode(runtime.Checkpoint());
        Assert.Equal(8, image.Simulation.FeedSeq);
        Assert.Equal(6, image.Simulation.FeedLog.Count);

        var branch = (Runtime)runtime.Fork();
        branch.Schedule(9, "play", "卡9");
        while (branch.Run() > 0) { }
        using var branchLease = branch.Read();
        Assert.True(branch.PresentationMuted);
        Assert.Equal(9, branchLease.Snapshot.Simulation.FeedSeq);   // 静音只挡演出条目，流水是状态
    }

    private sealed class Handler(string type, Action<IEventContext> action) : IRuleHandler
    {
        public string EventType => type;
        public void Handle(IEventContext context) => action(context);
    }

    private static void AssertNoFraction(JsonElement e, string path)
    {
        switch (e.ValueKind)
        {
            case JsonValueKind.Number:
                Assert.True(e.TryGetInt64(out _), $"{path} 是小数：{e.GetRawText()}（协议零浮点）");
                break;
            case JsonValueKind.Object:
                foreach (var p in e.EnumerateObject()) AssertNoFraction(p.Value, $"{path}.{p.Name}");
                break;
            case JsonValueKind.Array:
                var i = 0;
                foreach (var x in e.EnumerateArray()) AssertNoFraction(x, $"{path}[{i++}]");
                break;
        }
    }
}
