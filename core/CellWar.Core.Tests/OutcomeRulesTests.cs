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

        var (winner, alarm) = OutcomeRules.Evaluate(world);
        Assert.Equal(Faction.Immune, winner);
        Assert.Equal(0, alarm);
    }

    [Fact]
    public void CancerScoreAtNinetyOnConsecutiveRound_IsCancerWin()
    {
        // 90 格癌组织 → 分数 90；上一世界回合即已报警（WorldRound-1）
        var tiles = Enumerable.Range(0, 90).Select(i => Tile(new HexPosition(i, -i, 0), TissueState.Cancer)).ToArray();
        var world = Build(new TurnState { WorldRound = 2, Phase = Phase.E, ActivePlayerSeat = 0, CancerAlarmRound = 1 }, tiles);

        var (winner, alarm) = OutcomeRules.Evaluate(world);
        Assert.Equal(Faction.Cancer, winner);
        Assert.Equal(2, alarm);
    }

    [Fact]
    public void RoundFifteenCancerTilesAtLeastHalf_IsCancerWin()
    {
        var world = Build(new TurnState { WorldRound = 15, Phase = Phase.E, ActivePlayerSeat = 0 },
            [Tile(new HexPosition(0, 0, 0), TissueState.Cancer), Tile(new HexPosition(1, 0, -1), TissueState.Healthy)]);

        var (winner, _) = OutcomeRules.Evaluate(world);
        Assert.Equal(Faction.Cancer, winner);
    }

    [Fact]
    public void RoundFifteenCancerTilesBelowHalf_IsImmuneWin()
    {
        var world = Build(new TurnState { WorldRound = 15, Phase = Phase.E, ActivePlayerSeat = 0 },
            [Tile(new HexPosition(0, 0, 0), TissueState.Cancer),
             Tile(new HexPosition(1, 0, -1), TissueState.Healthy),
             Tile(new HexPosition(2, 0, -2), TissueState.Healthy),
             Tile(new HexPosition(3, 0, -3), TissueState.Healthy)]);

        var (winner, _) = OutcomeRules.Evaluate(world);
        Assert.Equal(Faction.Immune, winner);
    }
}
