namespace CellWar.Core.Tests;

/// <summary>
/// 路径规划报价（RulePolicies.QuotePath）独立契约测试：
/// 逐步模拟【定殖】/【净化】与代谢核心收入，纯查询不消耗额度。
/// 对齐旧实现 `CWActions.quote_path` 的可观察语义（费用逐步变、核心收钱、占据阻挡）。
/// </summary>
public class PathQuoteTests
{
    private static WorldState Build(
        CellType type = CellType.Melanoma,
        Faction faction = Faction.Cancer,
        int energy = 60,
        Action<Dictionary<HexPosition, Tissue>>? tissues = null,
        HexPosition? cellPos = null)
    {
        var map = new Dictionary<HexPosition, Tissue>();
        for (var q = -3; q <= 3; q++)
            for (var r = -3; r <= 3; r++)
                if (Math.Abs(q + r) <= 3)
                {
                    var p = new HexPosition(q, r, -q - r);
                    map[p] = new Tissue { Position = p, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = null, Charge = 0 };
                }
        tissues?.Invoke(map);
        var pos = cellPos ?? new HexPosition(0, 0, 0);
        var id = new EntityId(1);
        var cells = new Dictionary<EntityId, Cell>
        {
            [id] = new() { Id = id, OwnerSeat = 0, Faction = faction, Type = type, Position = pos, Energy = energy, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>() }
        };
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = faction, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = type },
            [1] = new() { Seat = 1, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I }
        };
        return new WorldState
        {
            Board = new Board { Radius = 3, Tissues = map }, Cells = cells, Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    [Fact]
    public void CancerPathIntoHealthy_ColonizesEachStepAndSumsCosts()
    {
        // 癌方从 (0,0) 往 (1,0) 走：第一步健康 1.2，定殖后 (1,0) 变癌；
        // 第二步走到 (2,0) 仍是健康 1.2（前面定殖只影响脚下那格，不影响下一格单价）。
        var world = Build();
        var quote = new BasicRulesEngine();
        var cell = world.Cells[new EntityId(1)];
        var path = new[] { new HexPosition(1, 0, -1), new HexPosition(2, 0, -2) };
        var result = RulePolicies.QuotePath(world, cell, path);
        Assert.Equal(2, result.Steps.Length);
        Assert.Equal(12, result.Steps[0].Cost);   // 1.2
        Assert.Equal(12, result.Steps[1].Cost);   // 1.2（健康组织移动价）
        Assert.Equal(24, result.Total);
        Assert.True(result.Ok);
        Assert.Equal(60 - 24, result.Left);
    }

    [Fact]
    public void ImmunePathIntoCancer_PurifiesPerStep()
    {
        // 免疫从 (0,0) 起步；(1,0) 和 (2,0) 都是癌。第一步迁癌 1.0（I 级），净化后变健康；
        // 第二步从 (1,0)（已净化）迁往 (2,0) 癌 → 仍 1.0。
        var world = Build(faction: Faction.Immune, type: CellType.ImmuneBasic, energy: 30, tissues: m =>
        {
            m[new HexPosition(1, 0, -1)] = m[new HexPosition(1, 0, -1)].WithState(TissueState.Cancer);
            m[new HexPosition(2, 0, -2)] = m[new HexPosition(2, 0, -2)].WithState(TissueState.Cancer);
        });
        var cell = world.Cells[new EntityId(1)];
        var path = new[] { new HexPosition(1, 0, -1), new HexPosition(2, 0, -2) };
        var result = RulePolicies.QuotePath(world, cell, path);
        Assert.True(result.Ok);
        Assert.Equal(10, result.Steps[0].Cost);  // I 级迁癌 1.0
        Assert.Equal(10, result.Steps[1].Cost);
        Assert.Equal(20, result.Total);
    }

    [Fact]
    public void MetabolicCoreIncome_CreditsBudgetOnce()
    {
        // 癌方从 (0,0) 出发，第二步踩上代谢核心（charge 2.0 = 20 十分位），拿到 2.0。
        var world = Build(tissues: m =>
        {
            var core = new HexPosition(2, 0, -2);
            m[core] = new() { Position = core, Type = TissueType.MetabolicCore, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = null, Charge = 20 };
        });
        var cell = world.Cells[new EntityId(1)];
        var path = new[] { new HexPosition(1, 0, -1), new HexPosition(2, 0, -2) };
        var result = RulePolicies.QuotePath(world, cell, path);
        Assert.Equal(20, result.Gained);
        // 走完预算 = 初始 60 − 1.2×2 + 2.0 = 58.4（十分位 584）
        Assert.Equal(60 - 12 - 12 + 20, result.Left);
    }

    [Fact]
    public void OccupiedTile_BlocksAndStopsPlan()
    {
        var world = Build();
        var map = world.Board.Tissues.ToDictionary(kv => kv.Key, kv => kv.Value);
        map[new HexPosition(1, 0, -1)] = map[new HexPosition(1, 0, -1)].WithOccupyingCell(new EntityId(99));
        var cells = world.Cells.ToDictionary(kv => kv.Key, kv => kv.Value);
        cells[new EntityId(99)] = new() { Id = new EntityId(99), OwnerSeat = 1, Faction = Faction.Immune, Type = CellType.ImmuneBasic, Position = new HexPosition(1, 0, -1), Energy = 30, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>() };
        world = new WorldState { Board = new Board { Radius = 3, Tissues = map }, Cells = cells, Players = world.Players, Turn = world.Turn };
        var cell = world.Cells[new EntityId(1)];
        var path = new[] { new HexPosition(1, 0, -1) };
        var result = RulePolicies.QuotePath(world, cell, path);
        Assert.False(result.Ok);
        Assert.Equal(0, result.Stop);
        Assert.False(result.Steps[0].Afford);
        Assert.Contains("占据", result.Steps[0].Reason);
    }

    [Fact]
    public void SessionQuotePath_RequiresOwnershipAndQuotes()
    {
        using var session = new MatchSession(DemoScenario.Create());
        // DemoScenario 席位 0 = 免疫，细胞 id 1 在 (-4,0)，能量 3.0。
        // 免疫迁健康 0.5 / 迁癌 1.0（I 级）；(-3,0) 可能在癌组织内，费用随盘面走。
        var quote = session.QuotePath(0, new EntityId(1), new[] { new HexPosition(-3, 0, 3), new HexPosition(-2, 0, 2) });
        Assert.Equal(2, quote.Steps.Length);
        Assert.True(quote.Ok);
        Assert.All(quote.Steps, s => Assert.InRange(s.Cost, 5, 10));
        Assert.Equal(quote.Steps.Sum(s => s.Cost), quote.Total);
        // 别人不能规划我的细胞
        var other = session.QuotePath(1, new EntityId(1), new[] { new HexPosition(-3, 0, 3) });
        Assert.False(other.Ok);
        Assert.Empty(other.Steps);
    }

    [Fact]
    public void SessionPlanNextDests_ReturnsAdjacentAndEmpty()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var dests = session.PlanNextDests(0, new EntityId(1), new HexPosition(-4, 0, 4));
        // 免疫在 (-4,0)：相邻空格均可迁；不含被占据格。
        Assert.Contains(new HexPosition(-3, 0, 3), dests);
        Assert.DoesNotContain(new HexPosition(-1, 0, 1), dests);  // 席位 1 的癌细胞占据
    }
}
