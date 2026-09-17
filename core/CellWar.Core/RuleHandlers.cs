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
        context.Log($"Accepted {decision.DecisionType} for seat {decision.PlayerSeat}");
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
        // 阶段结算的演出（骰点 / 侵蚀方向 / 增生…）此前整个被丢掉；日志行仍不写 —— Outbox 的内容与既有观测保持不变，文案账在批 2/3
        foreach (var ev in result.Events) if (ev is IPresentationEvent p) context.Emit(p);
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
    /// <summary>结算事件分两路：演出事件进结构化通道，其余照旧转成日志行。</summary>
    public static void Publish(IEventContext context, IEnumerable<IGameEvent> events)
    {
        foreach (var ev in events)
        {
            if (ev is IPresentationEvent p) context.Emit(p);
            else context.Log(Describe(ev));
        }
    }

    public static void Continue(IEventContext context, IRulesEngine rules)
    {
        var state = context.GetWorldState();
        var options = rules.GetAvailableDecisions(state, state.Turn.ActivePlayerSeat);
        if (options.Count > 0) context.AwaitInput(state.Turn.ActivePlayerSeat, options);
        else if (state.Turn.Phase != Phase.Finished) context.Schedule(context.CurrentTick + 1, "AdvancePhase");
    }

    /// <summary>把结算事件转成人类可读的日志行（只读投影，不承载规则语义）。</summary>
    public static string Describe(IGameEvent ev)
    {
        switch (ev)
        {
            case CellAttackedEvent a:
                return a.IsKill ? $"攻击成功，{a.DefenderId} 已死亡" : $"攻击造成 {a.Damage / 10.0:F1} 能量损失";
            case CellMovedEvent m:
                return $"{m.EntityId} 移动至 ({m.To.Q},{m.To.R})，消耗 {m.EnergyCost / 10.0:F1} 能量";
            case TissueStateChangedEvent t:
                return $"({t.Position.Q},{t.Position.R}) {t.OldState} → {t.NewState}";
            case EnergyChangedEvent e:
                return $"{e.EntityId} 能量 {e.OldValue / 10.0:F1} → {e.NewValue / 10.0:F1}";
            case CellDiedEvent d:
                return $"{d.EntityId} 死亡";
            default:
                return ev.EventType;
        }
    }
}
