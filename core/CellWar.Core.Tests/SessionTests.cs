namespace CellWar.Core.Tests;

public class SessionTests
{
    private sealed class DeferredSource : IDecisionSource
    {
        public TaskCompletionSource<InputAnswer?> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public ValueTask<InputAnswer?> RequestAsync(DecisionRequest request, CancellationToken cancellationToken) => new(Completion.Task);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LateSourceCannotAnswerAfterControllerChangeOrClose(bool close)
    {
        using var session = new MatchSession(DemoScenario.Create());
        var view = session.Observe(0);
        var source = new DeferredSource();
        var pending = session.RequestAsync(0, source);
        if (close) session.Dispose(); else session.ReplaceController(0);
        source.Completion.SetResult(new(view.RequestId!.Value, view.Revision, 0));
        Assert.False((await pending).IsValid);
        if (!close) Assert.Equal(view.Revision, session.Observe(0).Revision);
    }
}
