using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// **意图档** = GD <c>MechBridge</c>（use_search = false，use_fit_eval = false）：
/// 只接管顶层 <c>action</c> 问答 —— 评估全部 1 / 2 步迁移候选，按阵营手拍 scorer 取最高；
/// 最好的是「动」就走它的第一步，最好的是「不动」或别的问答，一律回落普通档（GD <c>super.ask</c>）。
/// 试走在推演游标上跑（独立随机流从 <c>rng</c> 的状态起步），真局一行不动。
/// </summary>
public sealed class IntentPolicy : IPolicy
{
    private readonly AiConfig config;
    private readonly NormalPolicy normal;
    private readonly NormalPolicy sim;

    public IntentPolicy(AiConfig config)
    {
        this.config = config;
        normal = new NormalPolicy(config);
        sim = new NormalPolicy(config.Lifecare, config.FixedLineup);   // GD image 的陪练：lifecare = cfg.lifecare（sim_no_lifecare 恒 false）
    }

    public string Choose(WorldState state, int seat, IReadOnlyList<IDecision> options, IDeterministicRng rng,
        CancellationToken cancellation = default, AiTrace? trace = null)
    {
        var ask = AskView.Build(state, seat, options);
        var root = AiPolicies.RootState(rng);
        if (ask.Kind == "action")
        {
            var cursor = new RolloutCursor(state, root, sim) { Cancellation = cancellation };
            var fac = state.Players[seat].Faction;
            Func<MechMetrics, double> scorer = fac == Faction.Cancer ? m => MechScores.Cancer(m, config) : MechScores.Immune;
            IReadOnlyList<HexPosition>? best = null;
            try { best = new MechIntent(config, trace).BestBy(cursor, seat, scorer); }
            catch (OperationCanceledException) { }   // 被取消：回落普通档（意图档一问只有几十次单步试走，产品不给它预算）
            if (best is { Count: > 0 } && RolloutCursor.FindMove(ask, best[0]) is { } move) return move.Key;
        }
        return normal.Final(new AiView(state), ask, root).Key;
    }
}

/// <summary>
/// **搜索档** = GD <c>MechBridge</c>（use_search = true，use_fit_eval = true）：意图级 alpha-beta，深度 2，根 TopK 6、对手 3，
/// 叶 = 回合边界的拟合估值（MechValue.position_eval，log 版）。match.gd 的 AI_ABS 档与联机代打用的就是这一档。
///
/// 计划缓存没搬：GD 的 <c>_plan</c> 在 <c>PLAN_HORIZON = 1</c> 下只存「第一手」、下一问必然作废，从不改答案（审计 10-01）。
/// 照搬 GD 的一个缺陷：根选「不动」时按计划第一手配选项用的是 <c>_action_matches</c> —— 只比 act / to / card / cid，
/// **不比分化种类**，所以陪练想分化成树突、真正落下的是规范序里第一个分化选项（先对拍一致，修它是另一次有意改动）。
/// </summary>
public sealed class SearchPolicy : IPolicy
{
    private readonly AiConfig config;
    private readonly NormalPolicy normal;
    private readonly NormalPolicy sim;

    public SearchPolicy(AiConfig config)
    {
        this.config = config;
        normal = new NormalPolicy(config);
        sim = new NormalPolicy(config.Lifecare, config.FixedLineup);
    }

    /// <summary>上一问评了几个根、是不是被预算截断（性能测量与日志用）。</summary>
    public (int Roots, bool Truncated) LastStats { get; private set; }

    public string Choose(WorldState state, int seat, IReadOnlyList<IDecision> options, IDeterministicRng rng,
        CancellationToken cancellation = default, AiTrace? trace = null)
    {
        var ask = AskView.Build(state, seat, options);
        var root = AiPolicies.RootState(rng);
        var view = new AiView(state);
        if (ask.Kind != "action") return normal.Final(view, ask, root).Key;

        // 预算：墙钟到了就不再开新的根（已评完的根里取最好的）；取消令牌打断正在评的那个根。
        // 截断点随机器快慢而变 —— 只在产品路径上给预算，对拍时 BudgetMs = 0、令牌不取消
        using var budget = config.BudgetMs > 0 ? CancellationTokenSource.CreateLinkedTokenSource(cancellation) : null;
        budget?.CancelAfter(config.BudgetMs);
        var token = budget?.Token ?? cancellation;
        bool Stop() => token.IsCancellationRequested;
        var cursor = new RolloutCursor(state, root, sim) { Cancellation = token };
        MechIntent.SearchResult result;
        try { result = new MechIntent(config, trace).SearchBest(cursor, seat, Stop); }
        catch (OperationCanceledException) { result = new MechIntent.SearchResult(null, null, 0, true); }   // 根上的快评都没做完就被取消
        LastStats = (result.Evaluated, result.Truncated);
        if (result is { Path: not null, Plan0: { } plan0 } && FindPlanOption(ask, plan0) is { } hit)
            return (hit.Children.Count > 0 ? normal.ResolveGroup(view, hit) : hit).Key;
        return normal.Final(view, ask, root).Key;
    }

    /// <summary>GD <c>_find_plan_option</c> + <c>_action_matches</c>：act 必同；计划带 to / card / cid 的逐一比对，其余 act 同即命中（取规范序第一条）。</summary>
    private static AiOption? FindPlanOption(AskView ask, AiOption want)
    {
        foreach (var d in ask.Options)
        {
            if (d.Act != want.Act) continue;
            if (want.To != null && d.To != want.To) continue;
            if (want.Card != null && d.Card != want.Card) continue;
            if (want.Cid != null && d.Cid != want.Cid) continue;
            return d;
        }
        return null;
    }
}
