namespace CellWar.Core;

public sealed class PlayerDecisionHandler : IRuleHandler
{
    private readonly IRulesEngine rules;
    public string EventType => "PlayerDecision";
    public PlayerDecisionHandler(IRulesEngine rulesEngine) => rules = rulesEngine;
    public void Handle(IEventContext context)
    {
        if (context.CurrentEvent.Payload is not IDecision decision)
            throw new InvalidOperationException("PlayerDecision requires a typed decision.");
        var result = rules.ExecuteDecision(context.GetWorldState(), decision, context.Rng);
        if (!result.Success) throw new InvalidOperationException(result.ErrorMessage);
        context.SetWorldState(result.NewState);
        RuleFlow.Publish(context, result.Events);
        RuleFlow.Continue(context, rules);
    }
}

public sealed class AdvancePhaseHandler : IRuleHandler
{
    private readonly IRulesEngine rules;
    public string EventType => "AdvancePhase";
    public AdvancePhaseHandler(IRulesEngine rulesEngine) => rules = rulesEngine;
    public void Handle(IEventContext context)
    {
        var result = rules.AdvancePhase(context.GetWorldState(), context.Rng);
        if (!result.Success) throw new InvalidOperationException(result.ErrorMessage);
        context.SetWorldState(result.NewState);
        // 阶段结算的演出（骰点 / 侵蚀方向 / 增生…）与日志原文（P2）都走演出通道；规则事实（EnergyChangedEvent 那类）不写进日志
        RuleFlow.Publish(context, result.Events);
        RuleFlow.Continue(context, rules);
    }
}

public sealed class TurnStartHandler : IRuleHandler
{
    public string EventType => "TurnStart";
    public void Handle(IEventContext context) => context.Schedule(context.CurrentTick, "AdvancePhase");
}

internal static class RuleFlow
{
    /// <summary>结算事件里只有演出（含日志原文 <see cref="LogLine"/>）进通道。
    /// 2026-10-01 之前非演出的规则事实会被 `Describe` 成「Accepted …」「(q,r) Healthy → Cancer」这类调试串写进玩家日志 —— P2 起日志只装 GD 原文。</summary>
    public static void Publish(IEventContext context, IEnumerable<IGameEvent> events)
    {
        foreach (var ev in events)
            if (ev is IPresentationEvent p) context.Emit(p);
    }

    public static void Continue(IEventContext context, IRulesEngine rules)
    {
        var state = context.GetWorldState();
        var options = rules.GetAvailableDecisions(state, state.Turn.ActivePlayerSeat);
        if (options.Count > 0) context.AwaitInput(state.Turn.ActivePlayerSeat, options);
        else if (state.Turn.Phase != Phase.Finished) context.Schedule(context.CurrentTick + 1, "AdvancePhase");
        // GD `run_game()` 跑完循环的最后一句（cw_game.gd:169）：`log_msg("=== 对局结束：%s ===" % win_reason)`。
        // 它不在规则结算里而在驱动循环里 —— C# 的驱动循环就是这里（分胜负之后不再排任何事件，所以只走到一次）。
        // L1 重放直接驱动 BasicRulesEngine、xcheck_export 也不走 run_game，两边夹具里都没有这一行
        else if (state.Turn.Winner is not null) context.Log($"=== 对局结束：{Observation.ObservationV1Codec.WinReason(state)} ===");
    }
}

/// <summary>
/// 从**装载好的世界**续跑（换内核 P5，新手教程的关首 / 关内换盘）：直接按 <see cref="RuleFlow.Continue"/> 问当前席位。
/// 不能走 TurnStart —— 那会从阶段开头推一格（PhaseRules.AdvancePhase），把世界里写好的「正在第 N 席的行动回合中」直接结束掉
/// （GD 侧同一件事是 cw_tutorial_stage.gd 的 `_point_cursor`：把流程游标对到 seat 那一席）。
/// </summary>
public sealed class ResumeHandler : IRuleHandler
{
    private readonly IRulesEngine rules;
    public string EventType => "Resume";
    public ResumeHandler(IRulesEngine rulesEngine) => rules = rulesEngine;
    public void Handle(IEventContext context) => RuleFlow.Continue(context, rules);
}
