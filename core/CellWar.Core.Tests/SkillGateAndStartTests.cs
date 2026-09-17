using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests;

/// <summary>
/// M4 批扫（20 种子 × 3 人数）撞出来的一批（2026-09-18）：
/// ① 永久技能的迁移费在 GD 是报价时从 `equipped` 现读的模板 + `fx_turn` 闸门，不是 mods 条目（C# 此前 BeginTurn 发 Turn 修饰）；
/// ② 【基因组不稳定】两次判定相同就不问；③ 血管传送走完整 enter_tile、哪端坏死整条作废、不分阵营；
/// ④ S 阶段产出时踩骨髓抽到连走卡要当场问完才传送；⑤ enter_tile 只在落点不是蹲守格时清蹲守。
/// </summary>
public class SkillGateAndStartTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，(-4,0)，30
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，(-1,0)
    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static WorldState World()
    {
        var s = DemoScenario.Create();
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
    }

    private static WorldState Equip(WorldState s, EntityId id, string skill, int seq = 1)
        => s.UpdateCell(id, s.Cells[id].Copy(equipped: [skill], equipSeq: new Dictionary<string, int> { [skill] = seq }));

    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));
    private static RecordingRng Rng(int seed = 5) => new(new Xoshiro256StarStar((ulong)seed));

    private static WorldState Move(WorldState s, EntityId id, HexPosition to)
    {
        var r = CellRules.Move(s, new MoveDecision(s.Cells[id].OwnerSeat, id, to), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    private static int Gate(WorldState s, EntityId id, string skill) => s.Cells[id].FxTurn.GetValueOrDefault(skill);

    // ---------- ① 闸门形状 ----------

    [Fact]
    public void 组织驻留_向健康组织前两次迁移免费_闸门计数_第三次照价_不进mods()
    {
        var s = Equip(World(), Immune0, "组织驻留");
        Assert.Equal(0, RulePolicies.QuoteMove(s, s.Cells[Immune0], P(-3, 0), null));
        var one = Move(s, Immune0, P(-3, 0));
        Assert.Equal(30, one.Cells[Immune0].Energy);
        Assert.Equal(1, Gate(one, Immune0, "组织驻留"));
        Assert.DoesNotContain(one.Cells[Immune0].Modifiers, m => m.Card == "组织驻留");   // GD 的 mods 里没有它

        var two = Move(one, Immune0, P(-3, -1));
        Assert.Equal(30, two.Cells[Immune0].Energy);
        Assert.Equal(2, Gate(two, Immune0, "组织驻留"));

        var raw = RulePolicies.RawMoveCost(two, two.Cells[Immune0], P(-2, -2));
        Assert.True(raw > 0);
        Assert.Equal(raw, RulePolicies.QuoteMove(two, two.Cells[Immune0], P(-2, -2), null));   // 额度用完
        var three = Move(two, Immune0, P(-2, -2));
        Assert.Equal(30 - raw, three.Cells[Immune0].Energy);
        Assert.Equal(2, Gate(three, Immune0, "组织驻留"));                                  // 没用上就不烧
    }

    [Fact]
    public void LFA1黏附_每行动回合首次走上癌组织减0_4下限0_2_只在用上时烧闸门()
    {
        var s = Equip(World(), Immune0, "LFA-1黏附");
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));
        s = Tissue(s, P(-2, -1), t => t.WithState(TissueState.Cancer));
        var raw = RulePolicies.RawMoveCost(s, s.Cells[Immune0], P(-3, 0));
        var quoted = RulePolicies.QuoteMove(s, s.Cells[Immune0], P(-3, 0), null)!.Value;
        Assert.Equal(Math.Max(2, raw - 4), quoted);
        var one = Move(s, Immune0, P(-3, 0));
        Assert.Equal(quoted != raw ? 1 : 0, Gate(one, Immune0, "LFA-1黏附"));
        Assert.DoesNotContain(one.Cells[Immune0].Modifiers, m => m.Card == "LFA-1黏附");

        var raw2 = RulePolicies.RawMoveCost(one, one.Cells[Immune0], P(-2, -1));
        Assert.Equal(raw2, RulePolicies.QuoteMove(one, one.Cells[Immune0], P(-2, -1), null));   // 本回合第二次：闸门关了，照价
    }

    [Fact]
    public void 组织巡航_首移免费_之后每次减0_2下限0_2_减那条不烧闸门()
    {
        var s = Equip(World(), Immune0, "组织巡航");
        var one = Move(s, Immune0, P(-3, 0));
        Assert.Equal(30, one.Cells[Immune0].Energy);
        Assert.Equal(1, Gate(one, Immune0, "组织巡航"));

        var raw = RulePolicies.RawMoveCost(one, one.Cells[Immune0], P(-3, -1));
        Assert.Equal(Math.Max(2, raw - 2), RulePolicies.QuoteMove(one, one.Cells[Immune0], P(-3, -1), null));
        var two = Move(one, Immune0, P(-3, -1));
        Assert.Equal(1, Gate(two, Immune0, "组织巡航"));                                    // 减 0.2 那条是 Store.NONE
        Assert.DoesNotContain(two.Cells[Immune0].Modifiers, m => m.Card.StartsWith("组织巡航"));
    }

    [Fact]
    public void 回合中途装备的永久技能当回合就生效()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: ["组织巡航"]));
        var r = Engine.ExecuteDecision(s, new PlayCardDecision(0, Immune0, "组织巡航", null, null), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Equal(0, RulePolicies.QuoteMove(r.NewState, r.NewState.Cells[Immune0], P(-3, 0), null));   // 此前要等下一个 BeginTurn 才发修饰
    }

    [Fact]
    public void 被中和抗体压住的永久技能一条模板都不发()
    {
        var s = Equip(World(), Immune0, "组织巡航");
        var neutralized = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(neutralUntil: s.Turn.WorldRound));
        var raw = RulePolicies.RawMoveCost(neutralized, neutralized.Cells[Immune0], P(-3, 0));
        Assert.Equal(raw, RulePolicies.QuoteMove(neutralized, neutralized.Cells[Immune0], P(-3, 0), null));
    }

    [Fact]
    public void 两件技能同时出条目_按装备先后排_都是闸门()
    {
        var s = World().UpdateCell(Immune0, World().Cells[Immune0].Copy(equipped: ["组织巡航", "组织驻留"],
            equipSeq: new Dictionary<string, int> { ["组织巡航"] = 2, ["组织驻留"] = 1 }));
        var mods = RulePolicies.SkillMoveModifiers(s, s.Cells[Immune0], P(-3, 0)).ToList();
        Assert.Equal(new[] { "组织驻留", "组织巡航" }, mods.OrderBy(m => m.Sequence).Select(m => m.Name));
        Assert.All(mods, m => Assert.True(RulePolicies.IsGateMoveModifier(m)));
        var moved = Move(s, Immune0, P(-3, 0));                                             // 免费竞争只选先装的那条
        Assert.Equal(1, Gate(moved, Immune0, "组织驻留"));
        Assert.Equal(0, Gate(moved, Immune0, "组织巡航"));
    }

    // ---------- ② 【基因组不稳定】 ----------

    [Fact]
    public void 基因组不稳定_两次判定相同就不问_不同才二选一()
    {
        var s = World().WithTurn(World().Turn.Copy(seat: 1));
        var cell = s.Cells[Cancer1];
        var same = CardRules.Resolve(s, cell, "基因组不稳定", new TapeRng(new[] { new long[] { 1, 3, 1 }, new long[] { 1, 3, 1 } }));
        Assert.Null(same.Turn.PendingMutationSeat);                                         // 掷到 1/1：无事发生、不问
        var differ = CardRules.Resolve(s, cell, "基因组不稳定", new TapeRng(new[] { new long[] { 1, 3, 1 }, new long[] { 1, 3, 3 } }));
        Assert.Equal(1, differ.Turn.PendingMutationSeat);
        Assert.Equal((1, 3), (differ.Turn.PendingMutationA, differ.Turn.PendingMutationB));
    }

    // ---------- ③ 血管传送 ----------

    private static WorldState Vessels(WorldState s)
        => Tissue(Tissue(s, P(6, 0), t => t.WithType(TissueType.BloodVessel)), P(-6, 0), t => t.WithType(TissueType.BloodVessel));

    private static WorldState MoveTo(WorldState s, EntityId id, HexPosition to)
    {
        var c = s.Cells[id];
        return s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(to, id).UpdateCell(id, c.Copy(position: to));
    }

    [Fact]
    public void 血管传送_两边都有就交换不分阵营_落地走完整enter_tile()
    {
        var s = Vessels(World());
        s = MoveTo(s, Immune0, P(6, 0));
        s = MoveTo(s, Cancer1, P(-6, 0));
        s = Tissue(s, P(-6, 0), t => t.WithState(TissueState.Cancer));   // 癌细胞站着的那端是癌组织
        var after = BoardRules.Transport(s, Rng());
        Assert.Equal(P(-6, 0), after.Cells[Immune0].Position);
        Assert.Equal(P(6, 0), after.Cells[Cancer1].Position);
        Assert.Equal(Immune0, after.Board.Tissues[P(-6, 0)].OccupyingCell);
        Assert.Equal(Cancer1, after.Board.Tissues[P(6, 0)].OccupyingCell);
        Assert.Equal(TissueState.Healthy, after.Board.Tissues[P(-6, 0)].State);   // 免疫落地【净化】（此前旧条款「敌对同格则取消」整条不传）
        Assert.Equal(TissueState.Cancer, after.Board.Tissues[P(6, 0)].State);     // 癌落地【定殖】
    }

    [Fact]
    public void 血管传送_哪一端坏死整条作废()
    {
        var s = MoveTo(Vessels(World()), Immune0, P(6, 0));
        s = Tissue(s, P(-6, 0), t => t.WithNecrosis(1));
        var after = BoardRules.Transport(s, Rng());
        Assert.Equal(P(6, 0), after.Cells[Immune0].Position);
    }

    // ---------- ④ S 阶段产出时的追问 ----------

    [Fact]
    public void S阶段产出踩骨髓抽到连走卡_当场问完才传送开打()
    {
        var s = DemoScenario.Create();
        s = Tissue(s, P(-4, 0), t => t.WithType(TissueType.BoneMarrow).WithCharge(1));       // 免疫细胞就站在存着一张卡的骨髓上
        s = s.WithTurn(s.Turn.Copy(phase: Phase.S, round: 2, startStep: 0));
        for (var seed = 1; seed <= 300; seed++)
        {
            var r = Engine.AdvancePhase(s, new Xoshiro256StarStar((ulong)seed));
            var t = r.NewState;
            if (t.Turn.PendingChemotaxisCell is null) continue;                          // 这颗种子没抽到连走卡
            Assert.Equal(Phase.S, t.Turn.Phase);
            Assert.Equal(3, t.Turn.StartStep);                                              // 停在「产出完、传送前」
            Assert.NotEmpty(Engine.GetAvailableDecisions(t, 0).OfType<ChemotaxisStepDecision>());
            Assert.Empty(Engine.GetAvailableDecisions(t, 1));
            var done = Engine.ExecuteDecision(t, new StopChemotaxisDecision(0, Immune0), new Xoshiro256StarStar(1));
            Assert.True(done.Success, done.ErrorMessage);
            Assert.Null(done.NewState.Turn.PendingChemotaxisCell);
            Assert.NotEqual(3, done.NewState.Turn.StartStep);                               // 出口接着走：传送 → 复活 / 开打
            Assert.True(done.NewState.Turn.Phase == Phase.PlayerAction || done.NewState.Turn.StartStep == 1);
            return;
        }
        Assert.Fail("300 颗种子骨髓一次都没抽到连走卡");
    }

    // ---------- ⑤ 蹲守清除条件 ----------

    [Fact]
    public void 进格只在落点不是蹲守格时清蹲守()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(campRound: s.Turn.WorldRound, campPosition: P(-5, 1)));
        var back = CellRules.EnterTile(s, Immune0, P(-5, 1), Rng());
        Assert.Equal(s.Turn.WorldRound, back.Cells[Immune0].CampRound);                    // 回到蹲守格：不作废
        var away = CellRules.EnterTile(s, Immune0, P(-5, 2), Rng());
        Assert.Equal(-1, away.Cells[Immune0].CampRound);
    }
}
