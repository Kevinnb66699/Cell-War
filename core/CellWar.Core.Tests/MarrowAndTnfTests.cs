namespace CellWar.Core.Tests;

/// <summary>
/// Kevin 2026-09-18 两条裁定：
/// ① 【骨髓动员】GD `_marrow_mobilization` 补上漏掉的 await（协议 v29），C# 照嵌套语义：按骨髓序，站在刚存了卡的骨髓上的细胞当场收（抽卡）；
///    一次抽卡追出问答就停下，剩下的骨髓挂 `TurnState.PendingMarrow`，答完在 DecisionRouter 出口接着收。
/// ② 【TNF-α局部炎症】的冻结名单从格上的 `SolidLockRound` 搬进事件容器（GD `install_event("TNF-α局部炎症", 1, frozen)`），E 阶段第 8 步随 tick 解冻。
/// </summary>
public class MarrowAndTnfTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，(-4,0)
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，(-1,0)
    private static readonly EntityId Immune2 = new(3);   // 席位 2：免疫
    private static readonly HexPosition MarrowA = new(3, -3, 0);   // CWData.MARROWS[0]
    private static readonly HexPosition MarrowB = new(0, 3, -3);   // CWData.MARROWS[1]
    private static HexPosition P(int q, int r) => new(q, r, -q - r);
    private static RecordingRng Rng(int seed = 5) => new(new Xoshiro256StarStar((ulong)seed));
    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));

    private static WorldState MoveTo(WorldState s, EntityId id, HexPosition to)
    {
        var c = s.Cells[id];
        return s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(to, id).UpdateCell(id, c.Copy(position: to));
    }

    /// <summary>六个骨髓全部健康、空仓。</summary>
    private static WorldState World()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        foreach (var m in MatchSetup.Marrows) s = Tissue(s, m, t => t.WithType(TissueType.BoneMarrow).WithState(TissueState.Healthy).WithCharge(0));   // DemoScenario 没铺特殊组织
        return s;
    }

    // ---------- ① 骨髓动员 ----------

    [Fact]
    public void 骨髓动员_站在空仓骨髓上的细胞当场收走那张卡_没人站的骨髓留着()
    {
        var s = MoveTo(World(), Immune0, MarrowA);
        for (var seed = 1; seed <= 60; seed++)
        {
            var t = CardRules.Resolve(s, s.Cells[Immune0], "骨髓动员", Rng(seed));
            Assert.Equal(s.Cells[Immune0].Energy + 5, t.Cells[Immune0].Energy);
            Assert.Equal(s.Cells[Immune2].Energy + 5, t.Cells[Immune2].Energy);
            Assert.Equal(0, t.Board.Tissues[MarrowA].Charge);                      // 脚下那张当场收走
            Assert.Equal(1, t.Board.Tissues[MarrowB].Charge);                      // 没人站的骨髓留着
            Assert.Empty(t.Turn.PendingMarrow);
            if (t.Cells[Immune0].Hand.Count == s.Cells[Immune0].Hand.Count + 1) return;   // 抽到的是进手的卡
        }
        Assert.Fail("60 颗种子抽到的全是抽到即结算的事件卡");
    }

    [Fact]
    public void 骨髓动员_抽卡撑爆手牌_先弃置再收下一个骨髓()
    {
        var s = MoveTo(MoveTo(World(), Immune0, MarrowA), Immune2, MarrowB);
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: Enumerable.Repeat("细胞膜修复", 8).ToList()));
        for (var seed = 1; seed <= 60; seed++)
        {
            var t = CardRules.Resolve(s, s.Cells[Immune0], "骨髓动员", Rng(seed));
            if (t.Turn.PendingDiscardSeat is null) continue;                       // 抽到即结算的事件卡没撑爆：换颗种子
            Assert.Equal(0, t.Turn.PendingDiscardSeat);
            Assert.Equal(MatchSetup.Marrows.Skip(1), t.Turn.PendingMarrow);        // 剩下五个骨髓（含没人站的）等弃置问完再按序过一遍
            Assert.Equal(1, t.Board.Tissues[MarrowB].Charge);
            Assert.Empty(t.Cells[Immune2].Hand);
            Assert.DoesNotContain(new DiscardDecision(0, Immune0, "细胞膜修复"), Engine.GetAvailableDecisions(t, 2));   // 问的是席位 0

            var r = Engine.ExecuteDecision(t, new DiscardDecision(0, Immune0, "细胞膜修复"), Rng(1));
            Assert.True(r.Success, r.ErrorMessage);
            var u = r.NewState;
            Assert.Empty(u.Turn.PendingMarrow);
            Assert.Equal(0, u.Board.Tissues[MarrowB].Charge);                      // 弃完接着收第二个骨髓
            return;
        }
        Assert.Fail("60 颗种子没有一次撑爆手牌");
    }

    // ---------- ② TNF-α 冻结名单在事件容器里 ----------

    [Fact]
    public void TNF_冻结名单挂在事件容器_本回合固化加不上去_回合末解冻()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: ["TNF-α局部炎症"]));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));
        s = s.UpdateTissueSolidification(P(-3, 0), 15);
        s = MoveTo(s, Cancer1, P(-3, 0));

        var r = Engine.ExecuteDecision(s, new PlayCardDecision(0, Immune0, "TNF-α局部炎症", null), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var t = r.NewState;
        Assert.Equal(50, t.Cells[Cancer1].Energy);                                 // 60 − 1.0
        Assert.Equal(5, t.Board.Tissues[P(-3, 0)].SolidificationCount);          // 15 − 1.0
        var entry = Assert.Single(t.Effects, e => e.Name == "TNF-α局部炎症");
        Assert.Equal(1, entry.Left);
        Assert.Equal([WorldEffects.TileKey(P(-3, 0))], entry.Data.Keys.ToArray());   // 只冻普通癌组织
        Assert.True(WorldEffects.SolidFrozen(t, P(-3, 0)));
        Assert.False(WorldEffects.SolidFrozen(t, P(-4, 0)));
        Assert.Equal(5, BoardRules.RaiseSolid(t, P(-3, 0), 10).Board.Tissues[P(-3, 0)].SolidificationCount);   // 本回合加不上去

        var evolved = BoardRules.EvolveEndOfRound(t.WithTurn(t.Turn.Copy(phase: Phase.E)), Rng());
        Assert.DoesNotContain(evolved.Effects, e => e.Name == "TNF-α局部炎症");    // 第 8 步 tick 掉
        Assert.False(WorldEffects.SolidFrozen(evolved, P(-3, 0)));
    }
}
