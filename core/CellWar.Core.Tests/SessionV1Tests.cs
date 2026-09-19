using System.Text.Json;
using CellWar.Core.Observation;

namespace CellWar.Core.Tests;

/// <summary>
/// 口径二 · 批 0 步 5：MatchSession 上与 GD CWKernel 句柄同形的那几项（docs/观测协议_v1.md §六作答口径 / §七 save 边界 / 附录 B / §5.3）。
/// 钉：语义键为准、下标兜底、两者都不对就拒答；pull 的条目形状与 GD 报文键逐字相同、immune_attack 的 itype/ctype 是 GD 值；
/// query 两条走已有方法；version 三字段分开；save 含 rng 与明文手牌而 ObserveV1 任何档都没有。
/// </summary>
public class SessionV1Tests
{
    private static MatchSession Demo() => new(DemoScenario.Create());

    [Fact]
    public void 作答_键为准_下标兜底_都不对就拒答()
    {
        using var session = Demo();
        var ask = session.ObserveV1(0).Ask!;
        var end = ask.Options.Single(o => o.Key == "k=action|act=end");
        var wrongIndex = (end.Index + 1) % ask.Options.Length;

        Assert.False(session.SubmitByKey(1, ask.AskId, end.Key, end.Index).IsValid);            // 不是这一席的问
        Assert.False(session.SubmitByKey(0, ask.AskId + 99, end.Key, end.Index).IsValid);       // ask_id 对不上
        Assert.False(session.SubmitByKey(0, ask.AskId, "k=action|act=nope", 9999).IsValid);    // 键与下标都不对 → 拒答、不钳位
        Assert.Equal(0, session.Observe(null).ActiveSeat);

        var ok = session.SubmitByKey(0, ask.AskId, end.Key, wrongIndex);   // 键对、下标故意错：键为准
        Assert.True(ok.IsValid, ok.ErrorMessage);
        Assert.Equal(1, session.Observe(null).ActiveSeat);

        var ask2 = session.ObserveV1(1).Ask!;
        var end2 = ask2.Options.Single(o => o.Key == "k=action|act=end");
        Assert.True(session.SubmitByKey(1, ask2.AskId, "k=action|act=nope", end2.Index).IsValid);   // 键找不到 → 下标兜底（回放只有下标）
        Assert.Equal(2, session.Observe(null).ActiveSeat);
    }

    [Fact]
    public void pull_条目形状照GD报文键_immune_attack的种类是GD值()
    {
        var s = DemoScenario.Create();
        var immune = s.Cells.Values.First(c => c.Faction == Faction.Immune);
        var cancer = s.Cells.Values.First(c => c.Faction == Faction.Cancer);
        var staged = new StagedEvent[]
        {
            new(1, new DiceRolled(1, Phase.PlayerAction, "attack", 6, 6, 0, cancer.Position)),
            new(2, Stage.Fx(s, "immune_attack", ("from", immune.Position), ("to", cancer.Position), ("cid", immune.Id), ("target_id", cancer.Id),
                ("itype", GdEnum.Itype(immune.Type)), ("ctype", GdEnum.Ctype(cancer.Type)), ("hit", true))),
            new(3, new AttackResolved(1, Phase.PlayerAction, immune.Id, cancer.Id, 6, false, "attack_success", 20, false, false)),
            new(4, new CardDrawn(1, Phase.PlayerAction, 0, immune.Id, immune.Position, "draw")),
            new(5, new BeamFired(1, Phase.PlayerAction, immune.Position, cancer.Position, [cancer.Position])),
        };
        var entries = staged.Select(PresentationCodec.Encode).ToArray();

        Assert.Equal(["t", "reason", "value", "sides", "pid", "at", "seq", "barrier"], entries[0].Keys);
        Assert.Equal("roll", entries[0]["t"].GetString()); Assert.True(entries[0]["barrier"].GetBoolean()); Assert.Equal(1, entries[0]["seq"].GetInt64());
        Assert.Equal(cancer.Position.Q, entries[0]["at"].GetProperty("q").GetInt32());

        var fx = entries[1];
        Assert.Equal("fx", fx["t"].GetString()); Assert.False(fx["barrier"].GetBoolean());
        Assert.Equal("immune_attack", fx["kind"].GetString());
        var data = fx["data"];
        Assert.Equal((int)immune.Id.Value - 1, data.GetProperty("cid").GetInt32());                 // 细胞引用是 cell id
        Assert.Equal(GdEnum.Ctype(cancer.Type), data.GetProperty("ctype").GetInt32());
        Assert.InRange(data.GetProperty("ctype").GetInt32(), 0, 3);                                   // GD CancerType 0..3，不是 C# 的 5..8
        Assert.Equal(immune.Position.R, data.GetProperty("from").GetProperty("r").GetInt32());

        Assert.Equal("attack", entries[2]["t"].GetString());
        Assert.Equal((int)cancer.Id.Value - 1, entries[2]["defender"].GetInt32());
        Assert.Equal("card_drawn", entries[3]["t"].GetString());
        Assert.DoesNotContain("card", entries[3].Keys);   // 刻意不带牌名
        Assert.Equal(1, entries[4]["splash"].GetArrayLength());
    }

    [Fact]
    public void pull_从会话取_水位线与下一个序号()
    {
        using var session = Demo();
        var page0 = session.PullPresentation(-2, long.MaxValue);
        Assert.Empty(page0.Entries); Assert.Equal(page0.NextSeq, session.PullPresentation(-2, 0).NextSeq);
        // 开局的呼吸 fx 已经在队列里；再结束几个回合攒一点
        for (var i = 0; i < 4; i++)
        {
            var ask = session.ObserveV1(-2).Ask!;
            session.SubmitByKey(ask.Seat, ask.AskId, "k=action|act=end", -1);
        }
        var page = session.PullPresentation(-2, 0, limit: 2);
        Assert.NotEmpty(page.Entries);
        Assert.True(page.Entries.Length <= 2);
        Assert.Equal(page.Entries[0]["seq"].GetInt64(), page.DroppedBefore);
        var since = page.Entries[^1]["seq"].GetInt64();
        Assert.All(session.PullPresentation(-2, since).Entries, e => Assert.True(e["seq"].GetInt64() > since));
        Assert.All(page.Entries, e => Assert.Contains(e["t"].GetString(), new[] { "roll", "attack", "result", "notice", "card_played", "event_drawn", "card_drawn", "erosion", "beam", "fx", "step_begin", "step_end" }));
    }

    /// <summary>批 1 步 4（Kevin 拍演出播放形态 2）：答下之后第一条是 step_begin{ask_id, seat}，下一问挂起之前最后一条是 step_end{rev}，rev 与随后的 envelope.rev 同一个数。</summary>
    [Fact]
    public void pull_行动边界_答下之后step_begin_下一问之前step_end()
    {
        using var session = Demo();
        var ask = session.ObserveV1(-2).Ask!;
        var before = session.PullPresentation(-2, 0).NextSeq;
        Assert.True(session.SubmitByKey(ask.Seat, ask.AskId, "k=action|act=end", -1).IsValid);
        var entries = session.PullPresentation(-2, before - 1).Entries;
        var kinds = entries.Select(e => e["t"].GetString()).ToArray();
        Assert.Equal("step_begin", kinds[0]);
        Assert.Equal(ask.AskId, entries[0]["ask_id"].GetInt64());
        Assert.Equal(ask.Seat, entries[0]["seat"].GetInt32());
        Assert.Equal("step_end", kinds[^1]);
        Assert.Equal(1, kinds.Count(k => k == "step_begin"));
        Assert.Equal(1, kinds.Count(k => k == "step_end"));
        Assert.Equal(session.ObserveV1(-2).Rev, entries[^1]["rev"].GetInt64());
    }

    [Fact]
    public void query_两条走已有方法_其余为null()
    {
        using var session = Demo();
        var me = session.ObserveV1(0).State.Cells.Single(c => c.Pid == 0);
        var args = JsonSerializer.SerializeToElement(new { cid = me.Id, from = me.Pos, path = new[] { me.Pos } }, ObservationV1Codec.Json);
        var dests = session.QueryV1(0, "plan_next_dests", args);
        Assert.NotNull(dests); Assert.Equal(JsonValueKind.Array, dests.Value.ValueKind);
        var quote = session.QueryV1(0, "quote_path", args);
        Assert.NotNull(quote);
        Assert.Equal(JsonValueKind.Array, quote.Value.GetProperty("steps").ValueKind);
        Assert.True(quote.Value.TryGetProperty("total", out _) && quote.Value.TryGetProperty("stop", out _));
        Assert.Null(session.QueryV1(0, "cost_effects_for", args));   // tier B
        Assert.Null(session.QueryV1(0, "nope", args));
    }

    [Fact]
    public void quote_path_借道第一跳_与GD的pass_through_mid同口径()
    {
        // 免疫 A 旁边摆一只友军 B，B 再往外一格空着：A 借道 B 到那一格，mid = B 所在格（第一跳）；相邻格与走不到的格 mid = null
        var s = DemoScenario.Create();
        var immune = s.Cells.Values.Where(c => c.Faction == Faction.Immune).OrderBy(c => c.Id.Value).ToArray();
        var a = immune[0]; var b = immune[1];
        var n = RulePolicies.GdNeighbors(s, a.Position).First(p => s.GetCellAt(p) == null && s.Board.Tissues[p].State == TissueState.Healthy);
        s = s.UpdateTissueOccupant(b.Position, null).UpdateCell(b.Id, b.WithPosition(n)).UpdateTissueOccupant(n, b.Id);
        var t = RulePolicies.GdNeighbors(s, n).First(p => s.GetCellAt(p) == null && p.DistanceTo(a.Position) == 2);
        Assert.Equal(n, RulePolicies.PassThroughMid(s, s.Cells[a.Id], t));
        Assert.Null(RulePolicies.PassThroughMid(s, s.Cells[a.Id], n));   // 相邻格：普通迁移，不算借道
        Assert.Equal(RulePolicies.PassThroughMap(s, s.Cells[a.Id]), RulePolicies.PassThroughRoutes(s, s.Cells[a.Id]).ToDictionary(kv => kv.Key, kv => kv.Value.Cost));   // 费用那张表没变
        var quote = RulePolicies.QuotePath(s, s.Cells[a.Id], [t]);
        Assert.Equal(n, quote.Steps[0].Mid);
        using var session = new MatchSession(s);
        var args = JsonSerializer.SerializeToElement(new { cid = (int)a.Id.Value - 1, from = ObservationV1Codec.Pos(a.Position), path = new[] { ObservationV1Codec.Pos(t) } }, ObservationV1Codec.Json);
        var mid = session.QueryV1(a.OwnerSeat, "quote_path", args)!.Value.GetProperty("steps")[0].GetProperty("mid");
        Assert.Equal((n.Q, n.R), (mid.GetProperty("q").GetInt32(), mid.GetProperty("r").GetInt32()));
    }

    [Fact]
    public void version_三字段分开_save含rng与明文手牌而观测任何档都没有()
    {
        var world = DemoScenario.Create();
        foreach (var c in world.Cells.Values.ToArray())
            world = world.UpdateCell(c.Id, c.Copy(hand: [$"secret-card-{c.OwnerSeat}"]));   // 存档 JSON 会把中文转义，子串断言用 ASCII
        using var session = new MatchSession(world);
        var v = session.Version();
        Assert.Equal(ObservationV1Codec.HostAbi, v.HostAbi); Assert.NotEmpty(v.RulesBuild); Assert.NotEmpty(v.Digest);

        var save = session.Save().Json;
        Assert.Contains("\"Rng\"", save);
        Assert.Contains("secret-card-1", save);
        foreach (var viewer in new[] { 0, ObservationV1Codec.ViewerWatcher })
        {
            var json = ObservationV1Codec.Serialize(session.ObserveV1(viewer));
            Assert.DoesNotContain("\"rng\"", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("secret-card-1", json);
        }
        Assert.Contains("secret-card-0", ObservationV1Codec.Serialize(session.ObserveV1(0)));
    }
}
