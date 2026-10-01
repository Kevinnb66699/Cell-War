namespace CellWar.Core.Tests;

/// <summary>
/// OutcomeRules 独立契约测试（PRD §123-133）：免疫胜、癌症分数报警、第 15 回合多数判定。
/// 该域只读世界、只产出胜者，不修改棋盘或阶段。
/// </summary>
public class OutcomeRulesTests
{
    private static WorldState Build(TurnState turn, IEnumerable<Tissue> tiles, params Cell[] cells)
    {
        var map = new Dictionary<HexPosition, Tissue>();
        foreach (var t in tiles) map[t.Position] = t;
        var cellMap = new Dictionary<EntityId, Cell>();
        foreach (var c in cells) cellMap[c.Id] = c;
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
        };
        return new WorldState { Board = new Board { Radius = 6, Tissues = map }, Cells = cellMap, Players = players, Turn = turn };
    }

    private static Tissue Tile(HexPosition p, TissueState state)
        => new() { Position = p, Type = TissueType.Normal, State = state, SolidificationCount = 0, OccupyingCell = null, Charge = 0 };

    private static Cell Immune(HexPosition p) => new()
    {
        Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
        Position = p, Energy = 30, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>()
    };

    [Fact]
    public void NoLiveCancerAndNoRevivalSource_IsImmuneWin()
    {
        var pos = new HexPosition(0, 0, 0);
        var world = Build(new TurnState { WorldRound = 3, Phase = Phase.E, ActivePlayerSeat = 0 },
            [Tile(pos, TissueState.Healthy)], Immune(pos));

        var (winner, alarm, _) = OutcomeRules.Evaluate(world);
        Assert.Equal(Faction.Immune, winner);
        Assert.Equal(0, alarm);
    }

    [Fact]
    public void CancerScoreAtNinetyOnConsecutiveRound_IsCancerWin()
    {
        // 90 格癌组织 → 分数 90；上一世界回合末已达标一次（计数 1），这一回合末仍达标 → 计数 2 = hold → 判胜
        var tiles = Enumerable.Range(0, 90).Select(i => Tile(new HexPosition(i, -i, 0), TissueState.Cancer)).ToArray();
        var world = Build(new TurnState { WorldRound = 2, Phase = Phase.E, ActivePlayerSeat = 0, CancerWinStreak = 1 }, tiles);

        var (winner, alarm, _) = OutcomeRules.Evaluate(world);
        Assert.Equal(Faction.Cancer, winner);
        Assert.Equal(2, alarm);
    }

    /// <summary>第 15 回合按癌性组织格数判：门槛是 GD 写死的 63（⌊1/2×127⌋），**不随盘子大小变** —— 教程放大到半径 12 的盘上也是 63。</summary>
    private static IEnumerable<Tissue> Board(int radius, int cancerous)
    {
        var all = new List<Tissue>();
        for (var q = -radius; q <= radius; q++)
            for (var r = Math.Max(-radius, -q - radius); r <= Math.Min(radius, -q + radius); r++)
                all.Add(Tile(new HexPosition(q, r, -q - r), all.Count < cancerous ? TissueState.Cancer : TissueState.Healthy));
        return all;
    }

    [Theory]
    [InlineData(6, 63, Faction.Cancer)]
    [InlineData(6, 62, Faction.Immune)]
    [InlineData(12, 63, Faction.Cancer)]    // 469 格的盘：2026-10-01 之前 C# 按「本盘一半」= 234 判成免疫胜，GD 判癌症胜
    [InlineData(12, 62, Faction.Immune)]
    public void RoundFifteen_CancerousTilesAgainstFixedLimit63(int radius, int cancerous, Faction expected)
    {
        var world = Build(new TurnState { WorldRound = 15, Phase = Phase.E, ActivePlayerSeat = 0 }, Board(radius, cancerous));
        var (winner, _, kind) = OutcomeRules.Evaluate(world);
        Assert.Equal(expected, winner);
        Assert.Equal(expected == Faction.Cancer ? "limit_cancer" : "limit_immune", kind);
    }
}
