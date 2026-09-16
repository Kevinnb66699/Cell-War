namespace CellWar.Core.Tests;

public class RuleContractTests
{
    private readonly BasicRulesEngine rules = new();
    [Theory]
    [InlineData(Faction.Cancer, TissueState.Healthy, ImmuneLevel.I, 12)]
    [InlineData(Faction.Cancer, TissueState.SolidifiedCancer, ImmuneLevel.I, 2)]
    [InlineData(Faction.Immune, TissueState.Healthy, ImmuneLevel.I, 5)]
    [InlineData(Faction.Immune, TissueState.Cancer, ImmuneLevel.I, 10)]
    // ⚠ 2026-09-15 更正：这一行原来写 7 —— 那是**当时代码里的值**，不是 PRD 的值。
    // 函数名叫 MatchPrd，断言的却是实现，于是它非但没抓到偏离，反而把偏离钉住了。
    // PRD:359 只写了 II 级「到癌性组织的【迁移】耗能降为 0.8」，**III/X 没有再降的条文**；
    // GDScript 的 IMMUNE_MOVE_CANCEROUS 是 [10, 8, 8, 8]。Kevin 2026-09-15 裁定按 PRD 走 0.8。
    // （这是本轮第三次遇到同一形状：前两次是【糖酵解爆发】权重、值域测试测到了 rng 助手。）
    [InlineData(Faction.Immune, TissueState.SolidifiedCancer, ImmuneLevel.III, 8)]
    public void MigrationCostsAndStrictPaymentMatchPrd(Faction faction, TissueState terrain, ImmuneLevel level, int expected)
    {
        var s = DemoScenario.Create();
        var seat = faction == Faction.Immune ? 0 : 3;  // 席 3 是印戒细胞癌，无移动被动，隔离基础费率
        var c = s.Cells.Values.Single(c => c.OwnerSeat == seat);
        var pos = c.Position.GetNeighbors().First(p => s.Board.Tissues.ContainsKey(p) && s.GetCellAt(p) == null);
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: seat));
        s = s.UpdatePlayer(seat, s.Players[seat].WithImmuneLevel(level)).UpdateTissueState(pos, terrain);
        s = s.UpdateCell(c.Id, c.WithEnergy(expected));
        var move = new MoveDecision(seat, c.Id, pos);
        Assert.Equal(expected, rules.QuoteMove(s, c, pos));
        Assert.False(rules.ValidateDecision(s, move).IsValid);
        s = s.UpdateCell(c.Id, c.WithEnergy(expected + 1));
        Assert.True(rules.ValidateDecision(s, move).IsValid);
    }
    [Fact]
    public void DeadSeatIsSkippedWithinSameWorldRound()
    {
        var s = DemoScenario.Create();
        var c = s.Cells[new EntityId(2)];
        s = s.UpdateCell(c.Id, c.Copy(alive: false, energy: 0, deathRound: 1)).UpdateTissueOccupant(c.Position, null);
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0));
        var next = rules.ExecuteDecision(s, new EndTurnDecision(0), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(2, next.Turn.ActivePlayerSeat); Assert.Equal(1, next.Turn.WorldRound);
    }
    [Fact]
    public void ImmuneRevivalWaitsOneWorldRoundAndUsesPlayerInput()
    {
        var s = DemoScenario.Create();
        var c = s.Cells[new EntityId(1)];
        var pos = c.Position;
        s = s.UpdateCell(c.Id, c.Copy(alive: false, energy: 0, deathRound: 1)).UpdateTissueOccupant(pos, null);
        var tile = s.Board.Tissues[pos];
        s = s.WithBoard(s.Board.UpdateTissue(pos, new Tissue { Position = pos, Type = TissueType.BoneMarrow,
            State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = null, Charge = 0 }));
        var rng = new Xoshiro256StarStar(1);
        var round2 = rules.AdvancePhase(s.WithTurn(s.Turn.Copy(round: 2)), rng).NewState;
        Assert.False(round2.Cells[c.Id].IsAlive);
        var round3 = rules.AdvancePhase(s.WithTurn(s.Turn.Copy(round: 3)), rng).NewState;
        var choice = Assert.IsType<ReviveDecision>(Assert.Single(rules.GetAvailableDecisions(round3, 0)));
        Assert.False(round3.Cells[c.Id].IsAlive);
        var revived = rules.ExecuteDecision(round3, choice, rng).NewState;
        Assert.True(revived.Cells[c.Id].IsAlive);
        Assert.Equal(30, revived.Cells[c.Id].Energy); // 复活 10，再经同一次 S 阶段有氧呼吸 +20
        Assert.Equal(c.Id, revived.Board.Tissues[pos].OccupyingCell);
    }
    [Fact]
    public void CancerMetabolicProductionRetainsFractionalEnergy()
    {
        var s = DemoScenario.Create();
        var p = new HexPosition(0, 0, 0);
        s = s.WithBoard(s.Board.UpdateTissue(p, new Tissue { Position = p, Type = TissueType.MetabolicCore,
            State = TissueState.Cancer, SolidificationCount = 0, OccupyingCell = null, Charge = 0 }));
        var result = rules.AdvancePhase(s, new Xoshiro256StarStar(1));
        Assert.Equal(4, result.NewState.Board.Tissues[p].Charge);
    }
}
