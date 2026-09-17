using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests;

/// <summary>
/// 癌方复活的形状跟 GD（Kevin 2026-09-16 拍板）：下标 0 是「放弃本回合复活」（`{skip: true}`）、
/// 每个落点只出一条、依托取坐标最小的固化格、问过的席位这一轮不再问（GD `flow["i"]` 光标）。
/// 权威实现：cw_world.gd `revive_options_cancer` / `revive_cancer`。
/// </summary>
public class CancerReviveTests
{
    private static readonly EntityId Seat1Cell = new(2);   // DemoScenario：席位 1 = 黑色素瘤，站 (-1,0,1)
    private static readonly EntityId Seat3Cell = new(4);   // 席位 3 = 印戒，站 (1,0,-1)
    private static readonly HexPosition Center = new(0, 0, 0);
    private static readonly HexPosition SolidA = new(1, -1, 0);   // Center 的邻格
    private static readonly HexPosition SolidB = new(0, -1, 1);   // Center 的邻格，坐标更小 → 该是依托
    private static readonly BasicRulesEngine Engine = new();

    /// <summary>复活窗口（S 阶段第 1 步）里，席位 1 的癌细胞死着，中心格两侧各一个固化格。</summary>
    private static WorldState ReviveWindow(bool killSeat3 = false)
    {
        var s = DemoScenario.Create();
        s = Kill(s, Seat1Cell);
        if (killSeat3) s = Kill(s, Seat3Cell);
        s = s.UpdateTissueState(SolidA, TissueState.SolidifiedCancer).UpdateTissueState(SolidB, TissueState.SolidifiedCancer);
        return s.WithTurn(s.Turn.Copy(phase: Phase.S, startStep: 1));
    }

    private static WorldState Kill(WorldState s, EntityId id)
    {
        var c = s.Cells[id];
        return s.UpdateCell(id, c.Copy(alive: false, energy: 0, deathRound: s.Turn.WorldRound)).UpdateTissueOccupant(c.Position, null);
    }

    [Fact]
    public void 下标零是放弃本回合复活_每个落点只出一条()
    {
        var s = ReviveWindow();
        var options = Engine.GetAvailableDecisions(s, 1);

        Assert.IsType<SkipReviveDecision>(options[0]);
        var revives = options.Skip(1).Cast<ReviveDecision>().ToList();
        Assert.NotEmpty(revives);
        Assert.Equal(revives.Count, revives.Select(r => r.TargetPosition).Distinct().Count());   // 一个落点一条
        Assert.All(revives, r => Assert.NotNull(r.SourcePosition));
    }

    [Fact]
    public void 依托取坐标最小的固化格()
    {
        var s = ReviveWindow();
        var center = Engine.GetAvailableDecisions(s, 1).OfType<ReviveDecision>().Single(r => r.TargetPosition == Center);

        Assert.Equal(SolidB, center.SourcePosition);   // (0,-1) < (1,-1)：先比 q 再比 r，GD Vector2i 的 <

        var revived = Engine.ExecuteDecision(s, center, new Xoshiro256StarStar(1)).NewState;
        Assert.True(revived.Cells[Seat1Cell].IsAlive);
        Assert.Equal(TissueState.Cancer, revived.Board.Tissues[SolidB].State);           // 碎的是依托
        Assert.Equal(TissueState.SolidifiedCancer, revived.Board.Tissues[SolidA].State); // 另一格不动
    }

    [Fact]
    public void 放弃之后这一轮不再问同一席_轮到下一席()
    {
        var s = ReviveWindow(killSeat3: true);
        Assert.NotEmpty(Engine.GetAvailableDecisions(s, 1));
        Assert.Empty(Engine.GetAvailableDecisions(s, 3));   // 先问席位 1

        var skipped = Engine.ExecuteDecision(s, new SkipReviveDecision(1, Seat1Cell), new Xoshiro256StarStar(1)).NewState;

        Assert.False(skipped.Cells[Seat1Cell].IsAlive);
        Assert.Equal(2, skipped.Turn.CancerReviveFrom);
        Assert.Empty(Engine.GetAvailableDecisions(skipped, 1));   // 没有它的事了（GD flow["i"] += 1）
        Assert.NotEmpty(Engine.GetAvailableDecisions(skipped, 3));
        Assert.IsType<SkipReviveDecision>(Engine.GetAvailableDecisions(skipped, 3)[0]);

        // 最后一席也放弃：S 阶段继续走完（有氧 / 过载），进玩家回合
        var done = Engine.ExecuteDecision(skipped, new SkipReviveDecision(3, Seat3Cell), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(Phase.PlayerAction, done.Turn.Phase);
    }

    [Fact]
    public void 别的席位替你放弃一律驳回()
    {
        var s = ReviveWindow();
        Assert.False(Engine.ValidateDecision(s, new SkipReviveDecision(3, Seat1Cell)).IsValid);
        Assert.False(Engine.ValidateDecision(s, new SkipReviveDecision(0, Seat1Cell)).IsValid);
        Assert.True(Engine.ValidateDecision(s, new SkipReviveDecision(1, Seat1Cell)).IsValid);
    }

    [Fact]
    public void 席位光标换回合归零()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.E).WithCancerReviveFrom(2));

        var next = Engine.AdvancePhase(s, new Xoshiro256StarStar(1)).NewState;

        Assert.Equal(Phase.S, next.Turn.Phase);
        Assert.Equal(0, next.Turn.CancerReviveFrom);
    }

    [Fact]
    public void 放弃的语义键是GD那条()
    {
        var s = ReviveWindow();
        Assert.Equal("k=revive|skip=1", SemanticKey.Of(s, new SkipReviveDecision(1, Seat1Cell)));
    }
}
