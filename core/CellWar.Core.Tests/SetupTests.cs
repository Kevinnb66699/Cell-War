namespace CellWar.Core.Tests;

public class SetupTests
{
    [Fact]
    public void MatchSetup_LayoutIsConnectedIncludesCenterAndAvoidsSpecials()
    {
        var world = MatchSetup.Create(4, 1234);
        Assert.Equal(Phase.Setup, world.Turn.Phase);
        var cancer = world.Board.Tissues.Values.Where(t => t.State == TissueState.Cancer).Select(t => t.Position).ToHashSet();
        Assert.Equal(15, cancer.Count);
        Assert.Contains(new HexPosition(0, 0, 0), cancer);
        Assert.All(cancer, p => Assert.Equal(TissueType.Normal, world.Board.Tissues[p].Type));

        var seen = new HashSet<HexPosition> { cancer.First() };
        var stack = new Stack<HexPosition>();
        stack.Push(cancer.First());
        while (stack.Count > 0)
            foreach (var neighbor in stack.Pop().GetNeighbors())
                if (cancer.Contains(neighbor) && seen.Add(neighbor))
                    stack.Push(neighbor);
        Assert.Equal(cancer.Count, seen.Count);
    }

    [Fact]
    public void MatchSetup_IsDeterministicForSeed()
    {
        var a = MatchSetup.Create(4, 77);
        var b = MatchSetup.Create(4, 77);
        Assert.Equal(
            a.Board.Tissues.Values.Where(t => t.State == TissueState.Cancer).Select(t => t.Position).OrderBy(p => p.Q).ThenBy(p => p.R),
            b.Board.Tissues.Values.Where(t => t.State == TissueState.Cancer).Select(t => t.Position).OrderBy(p => p.Q).ThenBy(p => p.R));
    }

    [Fact]
    public void MatchSetup_InitialCancerDoesNotDependOnSeed()
    {
        // 初始癌组织布局按旧实现是确定性 BFS（不掷骰），与种子无关。
        var a = MatchSetup.Create(4, 1);
        var b = MatchSetup.Create(4, 999);
        Assert.Equal(
            a.Board.Tissues.Values.Where(t => t.State == TissueState.Cancer).Select(t => t.Position).OrderBy(p => p.Q).ThenBy(p => p.R),
            b.Board.Tissues.Values.Where(t => t.State == TissueState.Cancer).Select(t => t.Position).OrderBy(p => p.Q).ThenBy(p => p.R));
    }

    [Fact]
    public void MatchSetup_PlacesSpecialTissuesPerOldLayout()
    {
        var world = MatchSetup.Create(4, 3);
        var byType = (TissueType type) =>
            world.Board.Tissues.Values.Where(t => t.Type == type).Select(t => t.Position).ToHashSet();
        Assert.Equal(3, byType(TissueType.MetabolicCore).Count);
        Assert.Equal(6, byType(TissueType.BoneMarrow).Count);
        Assert.Equal(2, byType(TissueType.BloodVessel).Count);
        Assert.Contains(new HexPosition(0, -3, 3), byType(TissueType.MetabolicCore));
        Assert.Contains(new HexPosition(6, 0, -6), byType(TissueType.BloodVessel));
        Assert.Equal(TissueType.Normal, world.Board.Tissues[new HexPosition(0, 0, 0)].Type);
    }

    [Fact]
    public void MatchSetup_SixPlayersUseTwentyFourCancerTiles()
    {
        var world = MatchSetup.Create(6, 9);
        Assert.Equal(24, world.Board.Tissues.Values.Count(t => t.State == TissueState.Cancer));
    }

    [Fact]
    public void Placement_RespectsTissueFactionAndOccupancy()
    {
        var engine = new BasicRulesEngine();
        var world = MatchSetup.Create(4, 5);
        var cancerTile = world.Board.Tissues.Values.First(t => t.State == TissueState.Cancer).Position;
        var healthyTile = world.Board.Tissues.Values.First(t => t.State == TissueState.Healthy).Position;
        Assert.True(engine.ValidateDecision(world, new PlaceDecision(0, healthyTile)).IsValid);
        Assert.False(engine.ValidateDecision(world, new PlaceDecision(0, cancerTile)).IsValid);
        Assert.False(engine.ValidateDecision(world, new PlaceDecision(1, healthyTile)).IsValid);

        var afterImmune = engine.ExecuteDecision(world, new PlaceDecision(0, healthyTile), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(1, afterImmune.Turn.ActivePlayerSeat);
        var afterCancer = engine.ExecuteDecision(afterImmune, new PlaceDecision(1, cancerTile), new Xoshiro256StarStar(1)).NewState;
        Assert.False(engine.ValidateDecision(afterCancer, new PlaceDecision(2, healthyTile)).IsValid);
    }

    [Fact]
    public void SessionSetup_PlacesAllSeatsThenEntersPlay()
    {
        using var session = MatchSession.Start(4, 42);
        for (var seat = 0; seat < 4; seat++)
        {
            var view = session.Observe(seat);
            Assert.Equal(Phase.Setup, view.Phase);
            Assert.Equal(seat, view.ActiveSeat);
            var place = view.Options.First(o => o.Kind == "Place");
            Assert.True(session.Submit(seat, new(view.RequestId!.Value, view.Revision, place.Id)).IsValid);
        }
        var after = session.Observe(0);
        Assert.Equal(4, after.Cells.Length);
        Assert.Equal(Phase.PlayerAction, after.Phase);
        Assert.Equal(0, after.ActiveSeat);
        Assert.All(after.Cells, c => Assert.True(c.Position.IsValid));
    }
}
