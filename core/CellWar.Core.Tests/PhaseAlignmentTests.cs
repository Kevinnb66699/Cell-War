namespace CellWar.Core.Tests;

/// <summary>
/// 世界回合阶段与旧实现对齐的契约测试（PRD 未规定处按原项目代码）。能量均为整数十分位。
/// </summary>
public class PhaseAlignmentTests
{
    private static WorldState Build(TurnState turn, params Tissue[] tiles)
    {
        var map = new Dictionary<HexPosition, Tissue>();
        foreach (var t in tiles) map[t.Position] = t;
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
        };
        return new WorldState { Board = new Board { Radius = 6, Tissues = map }, Cells = new Dictionary<EntityId, Cell>(), Players = players, Turn = turn };
    }

    private static Tissue Tile(HexPosition p, TissueType type = TissueType.Normal, TissueState state = TissueState.Healthy)
        => new() { Position = p, Type = type, State = state, SolidificationCount = 0, OccupyingCell = null, Charge = 0 };

    private static Cell Immune(HexPosition p, int energy) => new()
    {
        Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
        Position = p, Energy = energy, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>()
    };

    private static Cell Cancer(HexPosition p, CellType type, int energy) => new()
    {
        Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Cancer, Type = type,
        Position = p, Energy = energy, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>()
    };

    [Fact]
    public void HealthyMetabolicCore_EmitsOnSecondWorldRound()
    {
        var corePos = new HexPosition(0, 0, 0);
        var core = Tile(corePos, TissueType.MetabolicCore).WithProductionCounter(1);
        var world = Build(new TurnState { WorldRound = 2, Phase = Phase.S, ActivePlayerSeat = 0, StartStep = 0 }, core);

        var result = new BasicRulesEngine().AdvancePhase(world, new Xoshiro256StarStar(1));
        var after = result.NewState.Board.Tissues[corePos];
        Assert.Equal(10, after.Charge);
        Assert.Equal(0, after.ProductionCounter);
    }

    [Fact]
    public void CancerMetabolicCore_EmitsPointFourEveryRound()
    {
        var corePos = new HexPosition(0, 0, 0);
        var core = Tile(corePos, TissueType.MetabolicCore, TissueState.Cancer);
        var world = Build(new TurnState { WorldRound = 3, Phase = Phase.S, ActivePlayerSeat = 0, StartStep = 0 }, core);

        var result = new BasicRulesEngine().AdvancePhase(world, new Xoshiro256StarStar(1));
        Assert.Equal(4, result.NewState.Board.Tissues[corePos].Charge);
    }

    [Fact]
    public void MarrowCancerPeriodIsTwo_MarrowHealthyPeriodIsThree()
    {
        var cancerPos = new HexPosition(0, 0, 0);
        var healthyPos = new HexPosition(1, 0, -1);
        var world = Build(new TurnState { WorldRound = 4, Phase = Phase.S, ActivePlayerSeat = 0, StartStep = 0 },
            Tile(cancerPos, TissueType.BoneMarrow, TissueState.Cancer).WithProductionCounter(1),
            Tile(healthyPos, TissueType.BoneMarrow).WithProductionCounter(1));

        var result = new BasicRulesEngine().AdvancePhase(world, new Xoshiro256StarStar(1));
        Assert.Equal(1, result.NewState.Board.Tissues[cancerPos].Charge);
        Assert.Equal(0, result.NewState.Board.Tissues[healthyPos].Charge);
    }

    [Fact]
    public void StandingCellCollectsProductionImmediately()
    {
        var corePos = new HexPosition(0, 0, 0);
        var core = Tile(corePos, TissueType.MetabolicCore).WithProductionCounter(1);
        var world = Build(new TurnState { WorldRound = 2, Phase = Phase.S, ActivePlayerSeat = 0, StartStep = 0 }, core);
        var cell = Immune(corePos, 0);
        world = world.UpdateCell(cell.Id, cell);
        world = world.UpdateTissueOccupant(corePos, cell.Id);

        var result = new BasicRulesEngine().AdvancePhase(world, new Xoshiro256StarStar(1));
        // 0 起始 + 产出即收取 10 + S 阶段有氧呼吸 20
        Assert.Equal(30, result.NewState.Cells[cell.Id].Energy);
        Assert.Equal(0, result.NewState.Board.Tissues[corePos].Charge);
    }

    [Fact]
    public void NecroticTissueHalvesAerobicRespiration()
    {
        var pos = new HexPosition(0, 0, 0);
        var cell = Immune(pos, 0);
        var world = Build(new TurnState { WorldRound = 1, Phase = Phase.S, ActivePlayerSeat = 0, StartStep = 1 }, Tile(pos));
        world = world.UpdateCell(cell.Id, cell);
        world = world.UpdateTissueOccupant(pos, cell.Id);
        world = world.WithBoard(world.Board.UpdateTissue(pos, world.Board.Tissues[pos].WithNecrosis(1)));

        var result = new BasicRulesEngine().AdvancePhase(world, new Xoshiro256StarStar(1));
        Assert.Equal(10, result.NewState.Cells[cell.Id].Energy);
    }

    [Fact]
    public void MucusSurchargesImmuneMigrationByPointTwo()
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var world = Build(new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 },
            Tile(from), Tile(to).WithMucus(true));
        var cell = Immune(from, 30);
        world = world.UpdateCell(cell.Id, cell);

        Assert.Equal(7, BasicRulesEngine.BaseMoveCost(world, cell, to));
        world = world.WithBoard(world.Board.UpdateTissue(to, world.Board.Tissues[to].WithMucus(false)));
        Assert.Equal(5, BasicRulesEngine.BaseMoveCost(world, cell, to));
    }

    [Fact]
    public void SmallCellLungPaysPointSevenForHealthy()
    {
        var pos = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var world = Build(new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 1 }, Tile(pos), Tile(to));
        var cell = Cancer(pos, CellType.SmallCellLung, 30);
        world = world.UpdateCell(cell.Id, cell);
        Assert.Equal(7, BasicRulesEngine.BaseMoveCost(world, cell, to));
    }

    [Fact]
    public void MelanomaPseudopodDiscountsWhenThreeCancerousNeighbours()
    {
        var pos = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var world = Build(new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 1 }, Tile(pos), Tile(to));
        var cell = Cancer(pos, CellType.Melanoma, 30);
        world = world.UpdateCell(cell.Id, cell);
        Assert.Equal(12, BasicRulesEngine.BaseMoveCost(world, cell, to));

        var cancerous = to.GetNeighbors().Where(n => n != pos).Take(3).ToArray();
        foreach (var n in cancerous)
            world = world.WithBoard(world.Board.UpdateTissue(n, Tile(n, state: TissueState.Cancer)));
        Assert.Equal(5, BasicRulesEngine.BaseMoveCost(world, cell, to));
    }
}

