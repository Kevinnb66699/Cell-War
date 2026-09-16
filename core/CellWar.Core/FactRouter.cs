namespace CellWar.Core;

/// <summary>一条规则反应：给定已提交事实，返回反应后的世界。反应必须同步、无重入、稳定顺序。</summary>
internal delegate WorldState FactReaction(WorldState s, object fact, IDeterministicRng rng);

/// <summary>
/// 规则事实路由（对应三层设计的 FactRouter）：
/// 跨所有权交互不再让各域直接互调，而是发出已提交事实，由本表按声明顺序分派到反应。
/// 反应在发出点同步执行（S 语义），保证与旧直接调用链产生相同状态与随机消耗。
/// </summary>
internal static class FactRouter
{
    private static readonly Dictionary<Type, FactReaction[]> Reactions = Build();

    public static WorldState Emit(WorldState s, object fact, IDeterministicRng rng)
        => Reactions.TryGetValue(fact.GetType(), out var reactions)
            ? reactions.Aggregate(s, (current, reaction) => reaction(current, fact, rng))
            : s;

    private static Dictionary<Type, FactReaction[]> Build() => new()
    {
        [typeof(PurifyResolvedFact)] = new FactReaction[] { PurifyMemoryBankDraw }
    };

    /// <summary>【免疫记忆库】：每世界回合自身第一次触发【净化】后免费抽 1 张（CellRules → CardRules 的跨域交互）。</summary>
    private static WorldState PurifyMemoryBankDraw(WorldState s, object fact, IDeterministicRng rng)
    {
        var resolved = (PurifyResolvedFact)fact;
        var cell = s.Cells[resolved.CellId];
        if (cell.Equipped.Contains("免疫记忆库") && !CellRules.HasModifier(cell, "免疫记忆库"))
        {
            s = CellRules.AddModifier(s, cell, new("免疫记忆库", ModifierTarget.Move, ModifierStage.Add, SourceLayer.Passive, 0, 0, null, 1, ModifierDuration.Round));
            s = CardRules.DrawOne(s, s.Cells[resolved.CellId], rng);
        }
        return s;
    }
}
