namespace CellWar.Core.Tests;

public class IntegrationTests
{
    private static void EndTurn(MatchSession session)
    {
        var seat = session.Observe(null).ActiveSeat;
        var view = session.Observe(seat);
        var option = view.Options.Single(o => o.Kind == "EndTurn");
        Assert.True(session.Submit(seat, new(view.RequestId!.Value, view.Revision, option.Id)).IsValid);
    }
    [Fact]
    public void CompleteGameFlow_ShouldWorkEndToEnd()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var view = session.Observe(0);
        var move = view.Options.First(o => o.Kind == "Move");
        var original = view.Cells.Single(c => c.Id == move.CellId);
        Assert.True(session.Submit(0, new(view.RequestId!.Value, view.Revision, move.Id)).IsValid);
        var after = session.Observe(0);
        Assert.Equal(move.Position, after.Cells.Single(c => c.Id == move.CellId).Position);
        Assert.Equal(original.Energy - move.Cost, after.Cells.Single(c => c.Id == move.CellId).Energy);
        EndTurn(session);
        Assert.Equal(1, session.Observe(1).ActiveSeat);
        Assert.Equal(Phase.PlayerAction, session.Observe(1).Phase);
    }
    [Fact]
    public void MultiplePlayerTurns_ShouldRotateCorrectly()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var initial = session.Observe(0);
        for (var seat = 0; seat < 4; seat++)
        {
            var view = session.Observe(seat);
            Assert.Equal(1, view.WorldRound); Assert.Equal(seat, view.ActiveSeat);
            Assert.Equal(initial.Cells.Single(c => c.OwnerSeat == 0).Energy, view.Cells.Single(c => c.OwnerSeat == 0).Energy);
            EndTurn(session);
        }
        var next = session.Observe(0);
        Assert.Equal(2, next.WorldRound); Assert.Equal(0, next.ActiveSeat);
        Assert.Equal(initial.Cells.Single(c => c.OwnerSeat == 0).Energy + 2, next.Cells.Single(c => c.OwnerSeat == 0).Energy);
    }
    [Fact]
    public void CheckpointAndForkContinueWithIdenticalDecisionsAndRng()
    {
        using var session = new MatchSession(DemoScenario.Create(), 987);
        EndTurn(session);
        var checkpoint = session.Save();
        using var restored = MatchSession.Restore(checkpoint);
        using var fork = session.Fork();
        Assert.Equal(checkpoint.Json, restored.Save().Json);
        for (var i = 0; i < 8; i++)
        {
            EndTurn(session); EndTurn(restored); EndTurn(fork);
            Assert.Equal(session.Save().Json, restored.Save().Json);
            Assert.Equal(session.Save().Json, fork.Save().Json);
        }
    }
    [Fact]
    public void SpectatorOtherSeatAndDuplicateAnswerHaveNoAuthority()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var view = session.Observe(0);
        Assert.Empty(session.Observe(null).Options); Assert.Null(session.Observe(null).RequestId);
        Assert.Empty(session.Observe(1).Options);
        var answer = new InputAnswer(view.RequestId!.Value, view.Revision, view.Options.Single(o => o.Kind == "EndTurn").Id);
        Assert.False(session.Submit(1, answer).IsValid);
        Assert.True(session.Submit(0, answer).IsValid);
        Assert.False(session.Submit(0, answer).IsValid);
    }

    [Fact]
    public void DeathDelayedRevivalBarrierSurvivesForkAndCheckpoint()
    {
        var state = DemoScenario.Create();
        var cell = state.Cells[new EntityId(1)];
        state = state.UpdateCell(cell.Id, cell.Copy(alive: false, energy: 0, deathRound: 1)).UpdateTissueOccupant(cell.Position, null);
        state = state.WithBoard(state.Board.UpdateTissue(cell.Position, new Tissue
        {
            Position = cell.Position, Type = TissueType.BoneMarrow, State = TissueState.Healthy,
            OccupyingCell = null, SolidificationCount = 0, Charge = 0
        })).WithTurn(state.Turn.Copy(round: 3));
        using var session = new MatchSession(state);
        var pending = session.Observe(0);
        Assert.Equal(Phase.S, pending.Phase);
        Assert.All(pending.Options, o => Assert.Equal("Revive", o.Kind));
        using var restored = MatchSession.Restore(session.Save());
        using var fork = session.Fork();
        var answer = new InputAnswer(pending.RequestId!.Value, pending.Revision, pending.Options[0].Id);
        Assert.True(restored.Submit(0, answer).IsValid);
        Assert.True(fork.Submit(0, answer).IsValid);
        Assert.False(session.Observe(0).Cells.Single(c => c.Id == cell.Id).IsAlive);
        Assert.Equal(restored.Save().Json, fork.Save().Json);
        Assert.True(restored.Observe(0).Cells.Single(c => c.Id == cell.Id).IsAlive);
        Assert.Equal(3, restored.Observe(0).Cells.Single(c => c.Id == cell.Id).Energy);
    }
}
