namespace CellWar.Core.Tests;

public class ObservationTests
{
    [Fact]
    public void ObservingNeverChangesStateRngOrRevision()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var before = session.Save().Json;
        var first = session.Observe(0);
        for (var i = 0; i < 10; i++)
        {
            Assert.Equal(first.Revision, session.Observe(i % 4).Revision);
            Assert.Empty(session.Observe(null).Options);
        }
        Assert.Equal(before, session.Save().Json);
    }
    [Fact]
    public void ViewRetainsItsRevisionAfterAnotherAction()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var before = session.Observe(0);
        var end = before.Options.Single(o => o.Kind == "EndTurn");
        session.Submit(0, new(before.RequestId!.Value, before.Revision, end.Id));
        Assert.Equal(0, before.ActiveSeat);
        Assert.Equal(1, session.Observe(1).ActiveSeat);
        Assert.NotEqual(before.Revision, session.Observe(1).Revision);
    }

    [Fact]
    public void TissuesProjectOccupyingCellForClientAttackHighlight()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var view = session.Observe(null);
        // DemoScenario 四席各占一格：被占据的格子必须暴露 OccupyingCell，空位为 null。
        var occupied = view.Tissues.Count(t => t.OccupyingCell != null);
        Assert.Equal(4, occupied);
        // 与细胞列表一致：占据的正是那四个细胞。
        foreach (var c in view.Cells)
            Assert.NotNull(view.Tissues.Single(t => t.Position == c.Position).OccupyingCell);
    }
}
