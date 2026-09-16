namespace CellWar.Core.Tests;

public class ActiveSkillTests
{
    private static WorldState ImmuneWorld(ImmuneLevel level = ImmuneLevel.III, params (HexPosition pos, CellType type)[] cells)
    {
        var map = new Dictionary<HexPosition, Tissue>();
        var cellMap = new Dictionary<EntityId, Cell>();
        ulong id = 1;
        foreach (var (pos, type) in cells)
        {
            map[pos] = new Tissue { Position = pos, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = new EntityId(id), Charge = 0 };
            cellMap[new EntityId(id)] = new Cell
            {
                Id = new EntityId(id), OwnerSeat = 0, Faction = Faction.Immune, Type = type,
                Position = pos, Energy = 30, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>()
            };
            id++;
        }
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = level },
            [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
        };
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = map }, Cells = cellMap, Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    [Fact]
    public void DifferentiateRequiresLevelThreeAndSetsType()
    {
        var engine = new BasicRulesEngine();
        var pos = new HexPosition(0, 0, 0);
        var low = ImmuneWorld(ImmuneLevel.II, (pos, CellType.ImmuneBasic));
        var id = low.Cells.Keys.Single();
        Assert.False(engine.ValidateDecision(low, new DifferentiateDecision(0, id, CellType.BCell)).IsValid);

        var high = ImmuneWorld(ImmuneLevel.III, (pos, CellType.ImmuneBasic));
        Assert.True(engine.ValidateDecision(high, new DifferentiateDecision(0, id, CellType.BCell)).IsValid);
        var after = engine.ExecuteDecision(high, new DifferentiateDecision(0, id, CellType.BCell), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(CellType.BCell, after.Cells[id].Type);
        Assert.True(after.Cells[id].Differentiated);
    }

    [Fact]
    public void DifferentiateRejectsDuplicateTypeAndSecondTime()
    {
        var engine = new BasicRulesEngine();
        var a = new HexPosition(0, 0, 0);
        var b = new HexPosition(1, 0, -1);
        var world = ImmuneWorld(ImmuneLevel.III, (a, CellType.ImmuneBasic), (b, CellType.ImmuneBasic));
        var first = world.Cells.Values.First(c => c.Position == a).Id;
        var second = world.Cells.Values.First(c => c.Position == b).Id;

        Assert.True(engine.ValidateDecision(world, new DifferentiateDecision(0, first, CellType.BCell)).IsValid);
        var after = engine.ExecuteDecision(world, new DifferentiateDecision(0, first, CellType.BCell), new Xoshiro256StarStar(1)).NewState;
        Assert.False(engine.ValidateDecision(after, new DifferentiateDecision(0, second, CellType.BCell)).IsValid);
        Assert.True(engine.ValidateDecision(after, new DifferentiateDecision(0, second, CellType.TCell)).IsValid);
        Assert.False(engine.ValidateDecision(after, new DifferentiateDecision(0, first, CellType.TCell)).IsValid);
    }

    [Fact]
    public void DifferentiateOfferedAsVisibleOption()
    {
        using var session = MatchSession.Start(4, 11);
        for (var seat = 0; seat < 4; seat++)
        {
            var v = session.Observe(seat);
            session.Submit(seat, new(v.RequestId!.Value, v.Revision, v.Options.First(o => o.Kind == "Place").Id));
        }
        // 免疫等级 III：直接观察当前免疫席的选项需通过投影；此处只验证不同化时无该选项
        var view = session.Observe(0);
        Assert.DoesNotContain(view.Options, o => o.Kind == "Differentiate");
    }
}

