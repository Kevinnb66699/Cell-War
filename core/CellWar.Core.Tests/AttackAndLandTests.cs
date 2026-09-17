namespace CellWar.Core.Tests;

/// <summary>
/// 复核工作流（44 个 agent，2026-09-18）抓出来的一批 + 批扫剩下的两类：
/// ① 攻击修饰的消耗时机（【补体调理】【高亲和力克隆】判定前扣，【穿孔素-颗粒酶】【补体级联】只在成功分支扣）；② 【PD-L1表达】多层一次只吃最早一层；
/// ③ 【抗原呈递强化】攻击后施加【标记】；④ 【细胞毒素】脚下格的世界回合闸 + 有目标才发动、toxin_round 只落脚下格；
/// ⑤ 「本世界回合」修饰在 E 阶段第 8 步过期；⑥ enter_tile 后半截（collect_special / update_marks）在定殖 / 净化追出的问答问完之后才做（PendingLand）。
/// </summary>
public class AttackAndLandTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，(-4,0)，30
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，(-1,0)，60
    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static WorldState World()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        var c = s.Cells[Cancer1];
        return s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(P(-3, 0), Cancer1).UpdateCell(Cancer1, c.Copy(position: P(-3, 0)));   // 目标挪到免疫细胞隔壁
    }

    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));
    private static RecordingRng Rng(int seed = 5) => new(new Xoshiro256StarStar((ulong)seed));
    private static ActiveModifier AttackMod(string card, int value) => new(card, ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, value, null, 1, ModifierDuration.Turn);

    private static WorldState Attack(WorldState s, int seed)
    {
        var r = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng(seed));
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    private static WorldState AttackUntil(WorldState s, Func<WorldState, bool> want)
    {
        for (var seed = 1; seed <= 300; seed++)
        {
            var after = Attack(s, seed);
            if (want(after)) return after;
        }
        throw new Xunit.Sdk.XunitException("300 颗种子里没有一次攻击满足条件");
    }

    private static bool Failed(WorldState before, WorldState after) => after.Cells[Cancer1].Energy == before.Cells[Cancer1].Energy && after.Cells[Immune0].Position == P(-4, 0);

    // ---------- ① 攻击修饰的消耗时机 ----------

    [Fact]
    public void 攻击无效时穿孔素与补体级联留着_补体调理与高亲和力判定前就扣()
    {
        var s = World();
        foreach (var m in new[] { AttackMod("穿孔素-颗粒酶", 10), AttackMod("补体级联", 0), AttackMod("补体调理", 5) })
            s = CellRules.AddModifier(s, s.Cells[Immune0], m);
        var failed = AttackUntil(s, after => Failed(s, after));
        Assert.Contains(failed.Cells[Immune0].Modifiers, m => m.Card == "穿孔素-颗粒酶");
        Assert.Contains(failed.Cells[Immune0].Modifiers, m => m.Card == "补体级联");
        Assert.DoesNotContain(failed.Cells[Immune0].Modifiers, m => m.Card == "补体调理");   // 无论结果如何，这次攻击就把它消耗掉

        var success = AttackUntil(failed, after => failed.Cells[Cancer1].Energy - after.Cells[Cancer1].Energy == 20);   // 成功 1.0 + 穿孔素 1.0
        Assert.DoesNotContain(success.Cells[Immune0].Modifiers, m => m.Card == "穿孔素-颗粒酶");
        Assert.DoesNotContain(success.Cells[Immune0].Modifiers, m => m.Card == "补体级联");
    }

    // ---------- ② PD-L1 多层 ----------

    [Fact]
    public void PDL1两层_一次攻击只吃最早的一层()
    {
        var s = World();
        s = CellRules.AddModifier(s, s.Cells[Cancer1], new ActiveModifier("PD-L1表达", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 0, null, 1, ModifierDuration.Game));
        s = CellRules.AddModifier(s, s.Cells[Cancer1], new ActiveModifier("PD-L1表达", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 0, null, 1, ModifierDuration.Game));
        var firstSeq = s.Cells[Cancer1].Modifiers.Min(m => m.Sequence);
        var once = Attack(s, 1);
        var left = once.Cells[Cancer1].Modifiers.Where(m => m.Card == "PD-L1表达").ToList();
        Assert.Single(left);
        Assert.NotEqual(firstSeq, left[0].Sequence);                                       // 吃掉的是最早打出的那层
        var twice = Attack(once, 1);
        Assert.DoesNotContain(twice.Cells[Cancer1].Modifiers, m => m.Card == "PD-L1表达");
    }

    // ---------- ③ 抗原呈递强化 ----------

    [Fact]
    public void 抗原呈递强化_每世界回合首次攻击未标记目标后施加标记_判定无效也算攻过()
    {
        var s = World().UpdateCell(Immune0, World().Cells[Immune0].Copy(equipped: ["抗原呈递强化"]));
        var after = AttackUntil(s, x => x.Cells[Cancer1].IsAlive);
        Assert.True(after.Cells[Cancer1].Marked);
        Assert.Equal(after.Turn.WorldRound, after.Cells[Cancer1].MarkRound);
        Assert.False(CellRules.RoundGateOpen(after.Cells[Immune0], "抗原呈递强化"));

        var failed = AttackUntil(s, x => Failed(s, x));                                     // 攻击无效也算攻过：额度照烧、目标照标
        Assert.True(failed.Cells[Cancer1].Marked);

        var again = after.UpdateCell(Cancer1, after.Cells[Cancer1].Copy(marked: false, markLeft: 0, markRound: -1));   // 本世界回合额度已用掉
        var second = AttackUntil(again, x => x.Cells[Cancer1].IsAlive);
        Assert.False(second.Cells[Cancer1].Marked);
    }

    // ---------- ④ 细胞毒素 ----------

    [Fact]
    public void 细胞毒素_脚下格每世界回合一次_有目标才发动_toxin_round只落脚下格()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.TCell));
        Assert.False(Engine.ValidateDecision(s, new TypeSkillDecision(0, Immune0, "细胞毒素", null)).IsValid);   // 1 环内没有癌组织

        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));
        var d = new TypeSkillDecision(0, Immune0, "细胞毒素", null);
        Assert.True(Engine.ValidateDecision(s, d).IsValid);
        var r = Engine.ExecuteDecision(s, d, Rng());
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Equal(r.NewState.Turn.WorldRound, r.NewState.Board.Tissues[P(-4, 0)].ToxinRound);   // 脚下格盖章
        Assert.Equal(0, r.NewState.Board.Tissues[P(-3, 0)].ToxinRound);                          // 目标格不盖
        Assert.Equal(TissueState.Healthy, r.NewState.Board.Tissues[P(-3, 0)].State);
        Assert.Equal(2, r.NewState.Board.Tissues[P(-3, 0)].NecrosisRounds);

        var again = Tissue(r.NewState, P(-3, -1), t => t.WithState(TissueState.Cancer));
        Assert.False(Engine.ValidateDecision(again, d).IsValid);                                   // 站着不动刷不出来
    }

    // ---------- ⑤ round 修饰在 E 阶段第 8 步过期 ----------

    [Fact]
    public void 本世界回合的修饰在E阶段末过期_S阶段的重置不碰它()
    {
        var s = World();
        s = CellRules.AddModifier(s, s.Cells[Immune0], new ActiveModifier("I型干扰素", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 10, 0, 1, ModifierDuration.Round));
        Assert.Contains(CellRules.ResetRoundFlags(s).Cells[Immune0].Modifiers, m => m.Card == "I型干扰素");
        var evolved = BoardRules.EvolveEndOfRound(s.WithTurn(s.Turn.Copy(phase: Phase.E)), Rng());
        Assert.DoesNotContain(evolved.Cells[Immune0].Modifiers, m => m.Card == "I型干扰素");
    }

    // ---------- ⑥ PendingLand ----------

    [Fact]
    public void 净化抽卡撑爆手牌_先弃置再收骨髓那张_第一次弃置不多摊一张()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(equipped: ["免疫记忆库"], hand: Enumerable.Repeat("细胞膜修复", 8).ToList()));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer).WithType(TissueType.BoneMarrow).WithCharge(1));   // 癌组织 + 存着一张卡的骨髓
        for (var seed = 1; seed <= 300; seed++)
        {
            var r = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng(seed));
            Assert.True(r.Success, r.ErrorMessage);
            var t = r.NewState;
            if (t.Turn.PendingDiscardSeat is null) continue;                  // 记忆库抽到的是抽到即结算的事件卡，没进手：换颗种子
            Assert.Equal(9, t.Cells[Immune0].Hand.Count);                     // 只多了记忆库那一张
            Assert.Equal(1, t.Board.Tissues[P(-3, 0)].Charge);                // 骨髓那张还没收
            Assert.Equal(Immune0, t.Turn.PendingLandCell);
            Assert.Equal(9, Engine.GetAvailableDecisions(t, 0).Count);
            var discarded = Engine.ExecuteDecision(t, new DiscardDecision(0, Immune0, "细胞膜修复"), Rng(1));
            Assert.True(discarded.Success, discarded.ErrorMessage);
            var u = discarded.NewState;
            Assert.Equal(0, u.Board.Tissues[P(-3, 0)].Charge);                // 弃完才收骨髓那张（可能又撑爆 → 再问一次）
            Assert.True(u.Turn.PendingLandCell is null || u.Turn.PendingDiscardSeat is not null);
            return;
        }
        Assert.Fail("300 颗种子记忆库抽到的全是抽到即结算的卡");
    }

    [Fact]
    public void 连锁问在骨髓抽卡之前_连锁结束才收落地那一格()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.Macrophage, chainLeft: 2));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer).WithType(TissueType.BoneMarrow).WithCharge(1));
        s = Tissue(s, P(-2, -1), t => t.WithState(TissueState.Cancer));                     // 落点旁边还有可连锁的癌组织
        var r = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Equal(Immune0, r.NewState.Turn.PendingChainCell);
        Assert.Equal(Immune0, r.NewState.Turn.PendingLandCell);
        Assert.Equal(1, r.NewState.Board.Tissues[P(-3, 0)].Charge);                        // 连锁没问完，骨髓那张先不抽

        var stopped = Engine.ExecuteDecision(r.NewState, new StopChainDecision(0, Immune0), Rng(3));
        Assert.True(stopped.Success, stopped.ErrorMessage);
        Assert.Null(stopped.NewState.Turn.PendingChainCell);
        Assert.Equal(0, stopped.NewState.Board.Tissues[P(-3, 0)].Charge);                  // 出口补做：收落地那一格
    }
}
