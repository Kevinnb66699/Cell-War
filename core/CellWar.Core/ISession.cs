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
    // ---- 观测协议 v1（docs/观测协议_v1.md；口径二 · 批 0 步 5）：与 GD CWKernel 句柄同形的那几项 ----
    Observation.ObsEnvelope ObserveV1(int viewer, bool openHands = false, long logsFrom = 0);
    Observation.PresentationPage PullPresentation(int viewer, long sinceSeq, int limit = 64);
    ValidationResult SubmitByKey(int seat, long askId, string? key, int index);
    System.Text.Json.JsonElement? QueryV1(int seat, string kind, System.Text.Json.JsonElement args);
    Observation.ObsVersion Version();
}
