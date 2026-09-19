namespace CellWar.Core.Tests;

/// <summary>
/// PRD【S-复活】的**死亡惩罚 X**（PRD 2026-09-19 落字，issue #63）：
/// 「免疫细胞死亡回合后的下 X 世界回合无法复活；X 初始为 1，免疫细胞每结算一次复活该免疫细胞的 X 增加 1」。
///
/// 落在引擎上就是两句：<see cref="CellRules.Kill"/> 写 `RespawnRound = 回合 + 1 + X`，
/// X = 旋钮 <see cref="RuleTuning.ImmuneRespawnDelay"/>（初始值）+ 该细胞的 <see cref="Cell.Revives"/>；
/// <see cref="PhaseRules.Revive"/> 结算后 `Revives + 1`。GD 半边是 `cw_game.gd kill` / `cw_world.gd revive_immune`，
/// 护栏是 `headless_test.gd t_immune_respawn` —— **两侧逐位同一个数**。
/// </summary>
public class ImmuneReviveTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);    // DemoScenario 席位 0：免疫，站 (-4,0)
    private static readonly EntityId Cancer1 = new(2);    // 席位 1：黑色素瘤，站 (-1,0)
    private static readonly HexPosition MarrowA = new(3, -3, 0);   // CWData.MARROWS[0]

    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f)
        => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));

    /// <summary>六个骨髓健康空置（DemoScenario 没铺特殊组织），世界回合停在 <paramref name="round"/>。</summary>
    private static WorldState World(int round)
    {
        var s = DemoScenario.Create();
        foreach (var m in MatchSetup.Marrows) s = Tissue(s, m, t => t.WithType(TissueType.BoneMarrow).WithState(TissueState.Healthy).WithCharge(0));
        return s.WithTurn(s.Turn.Copy(round: round, phase: Phase.S, startStep: 1, immuneReviveFrom: 0));
    }

    /// <summary>把局面推到第 <paramref name="round"/> 回合的复活窗口，让席位 0 在 MarrowA 复活。</summary>
    private static WorldState ReviveAt(WorldState s, int round)
    {
        s = s.WithTurn(s.Turn.Copy(round: round, phase: Phase.S, startStep: 1, immuneReviveFrom: 0));
        var option = Assert.IsType<ReviveDecision>(Engine.GetAvailableDecisions(s, 0).Single(d => d is ReviveDecision { TargetPosition: var p } && p == MarrowA));
        return Engine.ExecuteDecision(s, option, new Xoshiro256StarStar(1)).NewState;
    }

    [Fact]
    public void 每复活一次罚停就长一个世界回合()
    {
        var s = World(3);
        Assert.Equal(0, s.Cells[Immune0].Revives);

        // 第一次死：X = 旋钮初始值 1 → 死于第 3 回合，第 5 回合的 S 阶段才复活
        s = CellRules.Kill(s, Immune0);
        Assert.Equal(3 + 1 + 1, s.Cells[Immune0].RespawnRound);
        Assert.Empty(Engine.GetAvailableDecisions(s.WithTurn(s.Turn.Copy(round: 4)), 0));   // 第 4 回合还罚着，一条也不问

        s = ReviveAt(s, 5);
        Assert.True(s.Cells[Immune0].IsAlive);
        Assert.Equal(-1, s.Cells[Immune0].RespawnRound);
        Assert.Equal(1, s.Cells[Immune0].Revives);

        // 第二次死：X = 1 + 1 = 2 → 死于第 5 回合，第 8 回合才复活
        s = s.WithTurn(s.Turn.Copy(round: 5));
        s = CellRules.Kill(s, Immune0);
        Assert.Equal(5 + 1 + 2, s.Cells[Immune0].RespawnRound);
        Assert.Empty(Engine.GetAvailableDecisions(s.WithTurn(s.Turn.Copy(round: 7)), 0));

        s = ReviveAt(s, 8);
        Assert.Equal(2, s.Cells[Immune0].Revives);

        // 第三次死：X = 1 + 2 = 3
        s = s.WithTurn(s.Turn.Copy(round: 8));
        s = CellRules.Kill(s, Immune0);
        Assert.Equal(8 + 1 + 3, s.Cells[Immune0].RespawnRound);
    }

    [Fact]
    public void 旋钮负一仍是永久死亡_复活次数不参与()
    {
        var s = World(3);
        s = s.WithTuning(s.Tuning with { ImmuneRespawnDelay = -1 });
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(revives: 4));
        s = CellRules.Kill(s, Immune0);
        Assert.Equal(-1, s.Cells[Immune0].RespawnRound);
    }

    [Fact]
    public void 癌细胞不吃死亡惩罚_复活次数恒零()
    {
        var s = World(3);
        s = Tissue(s, s.Cells[Cancer1].Position, t => t.WithState(TissueState.SolidifiedCancer));
        s = CellRules.Kill(s, Cancer1);
        Assert.Equal(-1, s.Cells[Cancer1].RespawnRound);   // 癌方的复活看固化癌组织，不看这个字段

        s = s.WithTurn(s.Turn.Copy(cancerReviveFrom: 0));
        var spot = Assert.IsType<ReviveDecision>(Engine.GetAvailableDecisions(s, 1).First(d => d is ReviveDecision));
        s = Engine.ExecuteDecision(s, spot, new Xoshiro256StarStar(1)).NewState;
        Assert.True(s.Cells[Cancer1].IsAlive);
        Assert.Equal(0, s.Cells[Cancer1].Revives);
    }
}
