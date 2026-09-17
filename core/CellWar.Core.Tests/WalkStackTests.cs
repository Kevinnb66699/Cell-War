using static CellWar.Core.RulePolicies;

namespace CellWar.Core.Tests;

/// <summary>
/// 嵌套连走是栈（2026-09-17 深夜，口径一第三批第 4 步）：GD `_free_walk` 是协程 —— 连走的一步踩到存卡的骨髓、抽到【趋化募集】这种抽到即走的卡，
/// 内层先走完，外层再从新位置把剩下的步问完；「停在这里」只退一层。C# 此前是单槽，内层把外层整组覆写、外层剩余步数丢掉。
/// </summary>
public class WalkStackTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，站 (-4,0,4)，六邻全健康
    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static WorldState World()
    {
        var s = DemoScenario.Create();
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
    }

    private static RecordingRng Rng(int seed = 5) => new(new Xoshiro256StarStar((ulong)seed));

    private static WorldState Do(WorldState s, IDecision d, RecordingRng? rng = null)
    {
        var r = Engine.ExecuteDecision(s, d, rng ?? Rng());
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    private static (EntityId? Cell, int Left, string? Card) Top(WorldState s) => (s.Turn.PendingChemotaxisCell, s.Turn.ChemotaxisStepsLeft, s.Turn.PendingWalkCard);

    [Fact]
    public void 外层连走中途抽到趋化募集_内层压栈_走完弹回外层继续问剩下的步()
    {
        var s = CardRules.Resolve(World(), World().Cells[Immune0], "趋化募集", Rng());   // 外层：2 步
        s = Do(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0)));                     // 外层走了 1 步，剩 1
        Assert.Equal((Immune0, 1, "趋化募集"), Top(s));

        var nested = CardRules.Resolve(s, s.Cells[Immune0], "趋化募集", Rng());          // 这一步里抽到的：内层 2 步压在上面
        Assert.Equal((Immune0, 2, "趋化募集"), Top(nested));
        Assert.Equal(new[] { new WalkFrame(Immune0, 1, "趋化募集") }, nested.Turn.WalkOuter);

        var inner1 = Do(nested, new ChemotaxisStepDecision(0, Immune0, P(-2, -1)));
        Assert.Equal((Immune0, 1, "趋化募集"), Top(inner1));
        Assert.Single(inner1.Turn.WalkOuter);
        var inner2 = Do(inner1, new ChemotaxisStepDecision(0, Immune0, P(-2, -2)));      // 内层走满 → 弹栈 → 外层露出来
        Assert.Equal((Immune0, 1, "趋化募集"), Top(inner2));
        Assert.Empty(inner2.Turn.WalkOuter);
        Assert.Equal(P(-2, -2), inner2.Cells[Immune0].Position);                          // 外层从新位置接着走
        Assert.NotEmpty(Engine.GetAvailableDecisions(inner2, 0).OfType<ChemotaxisStepDecision>());

        var outerDone = Do(inner2, new ChemotaxisStepDecision(0, Immune0, P(-3, -2)));   // 外层最后一步 → 整条摘干净
        Assert.Null(outerDone.Turn.PendingChemotaxisCell);
        Assert.Empty(outerDone.Turn.WalkOuter);
        Assert.NotEmpty(Engine.GetAvailableDecisions(outerDone, 0).OfType<MoveDecision>());   // 回到行动栏
    }

    [Fact]
    public void 停在这里只退一层_外层的卡名与步数原样露出来()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: ["炎症性趋化"]));
        var play = Engine.GetAvailableDecisions(s, 0).OfType<PlayCardDecision>().First(p => p.Card == "炎症性趋化");
        var walking = Do(s, play);                                                          // 外层：付费连走 3 步
        Assert.Equal((Immune0, CellRules.ChemotaxisMaxSteps - 1, "炎症性趋化"), Top(walking));   // 打出时第一步已经走了

        var nested = CardRules.Resolve(walking, walking.Cells[Immune0], "效应细胞浸润", Rng());   // 内层：免费、可进癌组织
        Assert.Equal((Immune0, 2, "效应细胞浸润"), Top(nested));
        Assert.Equal("k=free_move|g=效应细胞浸润|stop=1", L1.SemanticKey.Of(nested, new StopChemotaxisDecision(0, Immune0)));

        var stopped = Do(nested, new StopChemotaxisDecision(0, Immune0));
        Assert.Equal((Immune0, CellRules.ChemotaxisMaxSteps - 1, "炎症性趋化"), Top(stopped));   // 只退一层：外层原样
        Assert.Empty(stopped.Turn.WalkOuter);
        Assert.Equal("k=free_move|g=炎症性趋化|stop=1", L1.SemanticKey.Of(stopped, new StopChemotaxisDecision(0, Immune0)));
        Assert.Equal("炎症性趋化", stopped.Turn.PendingCard);                                   // 打出的卡还没离手：外层没走完

        var stoppedAgain = Do(stopped, new StopChemotaxisDecision(0, Immune0));
        Assert.Null(stoppedAgain.Turn.PendingChemotaxisCell);
        Assert.Null(stoppedAgain.Turn.PendingCard);                                            // 整条走完才收尾离手
    }

    [Fact]
    public void 踩到存卡的骨髓抽到连走卡_端到端就是嵌套()
    {
        var s = CardRules.Resolve(World(), World().Cells[Immune0], "趋化募集", Rng());
        s = s.WithBoard(s.Board.UpdateTissue(P(-3, 0), s.Board.Tissues[P(-3, 0)].WithType(TissueType.BoneMarrow).WithCharge(1)));
        for (var seed = 1; seed <= 400; seed++)
        {
            var after = Do(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0)), Rng(seed));   // 骨髓抽一张（带子一发）
            if (after.Turn.WalkOuter.Count == 0) continue;                                   // 这颗种子没抽到连走卡
            Assert.Equal(new[] { new WalkFrame(Immune0, 1, "趋化募集") }, after.Turn.WalkOuter);   // 外层那 1 步还在
            Assert.Contains(after.Turn.PendingWalkCard, new[] { "趋化募集", "效应细胞浸润" });
            Assert.Equal(CellRules.FreeWalkMaxSteps, after.Turn.ChemotaxisStepsLeft);
            return;
        }
        Assert.Fail("400 颗种子骨髓一次都没抽到连走卡");
    }

    [Fact]
    public void 内层没路可走_当场弹掉露出外层()
    {
        var s = CardRules.Resolve(World(), World().Cells[Immune0], "趋化募集", Rng());
        s = Do(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0)));
        foreach (var n in GdNeighbors(s, P(-3, 0))) s = s.UpdateTissueState(n, TissueState.Cancer);   // 内层【趋化募集】一格都进不了
        var nested = CardRules.Resolve(s, s.Cells[Immune0], "趋化募集", Rng());
        var normalized = CellRules.NormalizeChemotaxis(nested);
        Assert.Empty(normalized.Turn.WalkOuter);
        Assert.Null(normalized.Turn.PendingChemotaxisCell);   // 外层同样没路 → 一路弹空
    }

    [Fact]
    public void 阶段推进的防御性清场把整条栈一起清()
    {
        var t = World().Turn.PushWalk(Immune0, 2, "趋化募集").PushWalk(Immune0, 2, "效应细胞浸润");
        Assert.Single(t.WalkOuter);
        var cleared = t.WithPendingChemotaxis(null, 0);
        Assert.Null(cleared.PendingChemotaxisCell);
        Assert.Empty(cleared.WalkOuter);
    }
}
