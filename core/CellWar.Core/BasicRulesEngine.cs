namespace CellWar.Core;

/// <summary>
/// 规则门面（唯一 IRulesEngine 实现）：只装配与转发，不承载任何规则语义。
/// 校验/执行/可选行动全部委托 <see cref="DecisionRouter"/> 分发到各所有权域；
/// 数值与派生值委托 <see cref="RulePolicies"/>。纯 C#、同步、无宿主/UI/存储依赖。
/// </summary>
public sealed class BasicRulesEngine : IRulesEngine
{
    /// <summary>Solidification progress 0..1 for presentation; healthy 0, solidified 1. -1 means not applicable.</summary>
    public double SolidFraction(WorldState s, Tissue t) => RulePolicies.SolidFraction(s, t);

    /// <summary>Store fill 0..1 for metabolic core / bone marrow; -1 for other tissues.</summary>
    public double StoreFraction(Tissue t) => RulePolicies.StoreFraction(t);

    public ValidationResult ValidateDecision(WorldState state, IDecision decision) => DecisionRouter.Validate(state, decision);

    /// <summary>移动基础费用（含修饰后的实付），委托 RulePolicies，保留旧公开入口。</summary>
    public static int BaseMoveCost(WorldState s, Cell c, HexPosition destination) => RulePolicies.BaseMoveCost(s, c, destination);

    public int? QuoteMove(WorldState s, Cell cell, HexPosition destination) => RulePolicies.QuoteMove(s, cell, destination);

    public RulesResult ExecuteDecision(WorldState state, IDecision decision, IDeterministicRng rng) => DecisionRouter.Execute(state, decision, rng);

    public RulesResult AdvancePhase(WorldState s, IDeterministicRng rng) => PhaseRules.AdvancePhase(s, rng);

    public IReadOnlyList<IDecision> GetAvailableDecisions(WorldState s, int seat) => DecisionRouter.Available(s, seat);
}
