namespace CellWar.Core;

public sealed record DecisionRequest(MatchObservation Observation, long ControllerEpoch);

public interface IDecisionSource
{
    ValueTask<InputAnswer?> RequestAsync(DecisionRequest request, CancellationToken cancellationToken);
}

public interface ISession : IDisposable
{
    MatchObservation Observe(int? authorizedSeat);
    ValidationResult Submit(int authorizedSeat, InputAnswer answer);
    int Advance(int budget = 256);
    Checkpoint Save();
}
