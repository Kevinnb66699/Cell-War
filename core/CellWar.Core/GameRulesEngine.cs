namespace CellWar.Core;

/// <summary>Compatibility facade. All gameplay is implemented by BasicRulesEngine.</summary>
public sealed class GameRulesEngine : IRulesEngine
{
    private readonly BasicRulesEngine rules = new();
    public GameRulesEngine(int playerCount = 4)
    {
        if (playerCount is not (2 or 4 or 6)) throw new ArgumentOutOfRangeException(nameof(playerCount));
    }
    public ValidationResult ValidateDecision(WorldState state, IDecision decision) => rules.ValidateDecision(state, decision);
    public RulesResult ExecuteDecision(WorldState state, IDecision decision, IDeterministicRng rng) => rules.ExecuteDecision(state, decision, rng);
    public RulesResult AdvancePhase(WorldState state, IDeterministicRng rng) => rules.AdvancePhase(state, rng);
    public IReadOnlyList<IDecision> GetAvailableDecisions(WorldState state, int seat) => rules.GetAvailableDecisions(state, seat);
}
