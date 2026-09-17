namespace CellWar.Core.Tests;

/// <summary>
/// 口径一最后两处结构性对齐（2026-09-18）：
/// ① 净化抽到的连走卡（【趋化募集】/【效应细胞浸润】）在 GD 里嵌在 draw() 内部、先走完才回到【连续吞噬】的循环问下一跳 ——
///    C# 用 PendingChainWalkDepth 记下挂起连锁时的走位栈深，栈更深时连锁让路；走位弹掉后若已无下一跳，连锁直接摘掉（GD 的 while 当场退出）。
/// ② E 阶段 4.9 蹲守净化在 GD 是 await：蹲守的巨噬当场追问【连续吞噬】。C# 停在 EndStep 1，问完再做 5 → 9.5、判胜负、翻到下一回合。
/// </summary>
public class ChainOrderAndEndPhaseTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，(-4,0)
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，(-1,0)
    private static HexPosition P(int q, int r) => new(q, r, -q - r);
    private static RecordingRng Rng(int seed = 5) => new(new Xoshiro256StarStar((ulong)seed));
    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));

    /// <summary>席位 0 换成巨噬（跳数 2），(-3,0)、(-2,0) 两格癌组织：踩进 (-3,0) 净化后 (-2,0) 是下一跳。</summary>
    private static WorldState World()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.Macrophage, chainLeft: 2));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));
        return Tissue(s, P(-2, 0), t => t.WithState(TissueState.Cancer));
    }

    // ---------- ① 连锁 vs 抽卡走位 ----------

    [Fact]
    public void 净化抽到连走卡_先走完那条走位_再问连续吞噬()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(equipped: ["免疫记忆库"]));
        for (var seed = 1; seed <= 400; seed++)
        {
            var r = Engine.ExecuteDecision(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng(seed));
            Assert.True(r.Success, r.ErrorMessage);
            var t = r.NewState;
            if (t.Turn.PendingChemotaxisCell != Immune0 || t.Turn.PendingChainCell != Immune0) continue;   // 记忆库没抽到连走卡：换颗种子
            Assert.True(CellRules.ChainDeferred(t));
            var offered = Engine.GetAvailableDecisions(t, 0);
            Assert.DoesNotContain(offered, d => d is ChainMoveDecision or StopChainDecision);            // 连锁让路
            Assert.Contains(offered, d => d is StopChemotaxisDecision);                                  // 先问走位
            Assert.False(Engine.ValidateDecision(t, new ChainMoveDecision(0, Immune0, P(-2, 0))).IsValid);

            var stopped = Engine.ExecuteDecision(t, new StopChemotaxisDecision(0, Immune0), Rng(1));
            Assert.True(stopped.Success, stopped.ErrorMessage);
            var u = stopped.NewState;
            Assert.Null(u.Turn.PendingChemotaxisCell);
            Assert.Equal(Immune0, u.Turn.PendingChainCell);                                             // 走位停了，连锁露出来
            Assert.Contains(Engine.GetAvailableDecisions(u, 0), d => d is ChainMoveDecision hop && hop.Target == P(-2, 0));
            return;
        }
        Assert.Fail("400 颗种子记忆库都没抽到连走卡");
    }

    [Fact]
    public void 走位弹掉后已无下一跳_连锁直接摘掉不问()
    {
        var s = World();
        s = Tissue(Tissue(s, P(-2, 0), t => t.WithState(TissueState.Healthy)), P(-3, 0), t => t.WithState(TissueState.Healthy));   // 没有下一跳
        s = s.WithTurn(s.Turn.WithPendingChain(Immune0, 0).PushWalk(Immune0, 1, "趋化募集"));   // 连锁挂在走位底下
        Assert.True(CellRules.ChainDeferred(s));
        var r = Engine.ExecuteDecision(s, new StopChemotaxisDecision(0, Immune0), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Null(r.NewState.Turn.PendingChemotaxisCell);
        Assert.Null(r.NewState.Turn.PendingChainCell);
    }

    [Fact]
    public void 走位这一步自己踩出的连锁不让路_连锁先问()
    {
        var s = World();
        s = s.WithTurn(s.Turn.PushWalk(Immune0, 2, "效应细胞浸润"));   // 正在连走（这张能踩进癌组织）
        var r = Engine.ExecuteDecision(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0)), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var t = r.NewState;
        Assert.Equal(Immune0, t.Turn.PendingChainCell);
        Assert.Equal(1, t.Turn.PendingChainWalkDepth);
        Assert.False(CellRules.ChainDeferred(t));
        Assert.Contains(Engine.GetAvailableDecisions(t, 0), d => d is ChainMoveDecision);
        Assert.DoesNotContain(Engine.GetAvailableDecisions(t, 0), d => d is ChemotaxisStepDecision);
    }

    // ---------- ② E 阶段蹲守净化的连锁 ----------

    /// <summary>巨噬蹲在 (-4,0) 的癌组织上（骨样硬化标记格），隔壁 (-3,0) 是癌组织：E 阶段净化脚下之后该问要不要连过去。</summary>
    private static WorldState Camping()
    {
        var s = World();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.E));
        s = Tissue(s, P(-4, 0), t => t.WithState(TissueState.Cancer));
        return s.UpdateCell(Immune0, s.Cells[Immune0].Copy(campRound: s.Turn.WorldRound, campPosition: P(-4, 0)));
    }

    [Fact]
    public void E阶段蹲守净化后停下来问连续吞噬_答完才翻到下一回合()
    {
        var s = Camping();
        var round = s.Turn.WorldRound;
        var r = Engine.AdvancePhase(s, Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var t = r.NewState;
        Assert.Equal(Phase.E, t.Turn.Phase);
        Assert.Equal(1, t.Turn.EndStep);
        Assert.Equal(round, t.Turn.WorldRound);
        Assert.Equal(TissueState.Healthy, t.Board.Tissues[P(-4, 0)].State);   // 脚下已净化
        Assert.Equal(Immune0, t.Turn.PendingChainCell);
        Assert.Contains(Engine.GetAvailableDecisions(t, 0), d => d is ChainMoveDecision hop && hop.Target == P(-3, 0));
        Assert.Empty(Engine.GetAvailableDecisions(t, 1));                       // 问的是巨噬的主人

        var stopped = Engine.ExecuteDecision(t, new StopChainDecision(0, Immune0), Rng());
        Assert.True(stopped.Success, stopped.ErrorMessage);
        Assert.Equal(Phase.S, stopped.NewState.Turn.Phase);                   // 后半做完、翻页
        Assert.Equal(round + 1, stopped.NewState.Turn.WorldRound);
        Assert.Equal(0, stopped.NewState.Turn.EndStep);
    }

    [Fact]
    public void E阶段连过去再净化一格_跳数用完就自动翻页()
    {
        var s = Camping();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(chainLeft: 1));
        var t = Engine.AdvancePhase(s, Rng()).NewState;
        var hop = Engine.ExecuteDecision(t, new ChainMoveDecision(0, Immune0, P(-3, 0)), Rng());
        Assert.True(hop.Success, hop.ErrorMessage);
        var u = hop.NewState;
        Assert.Equal(P(-3, 0), u.Cells[Immune0].Position);
        Assert.Equal(TissueState.Healthy, u.Board.Tissues[P(-3, 0)].State);
        Assert.Null(u.Turn.PendingChainCell);                                  // 跳数用完，GD 的循环退出
        Assert.Equal(Phase.S, u.Turn.Phase);
        Assert.Equal(s.Turn.WorldRound + 1, u.Turn.WorldRound);
    }

    [Fact]
    public void 没人蹲守的E阶段一步到位_游标不留痕()
    {
        var s = World().WithTurn(World().Turn.Copy(phase: Phase.E));
        var r = Engine.AdvancePhase(s, Rng());
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Equal(Phase.S, r.NewState.Turn.Phase);
        Assert.Equal(0, r.NewState.Turn.EndStep);
    }
}
