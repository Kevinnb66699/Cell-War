namespace CellWar.Core.Observation;

/// <summary>
/// 观测协议 §5.3 的两条 tier B 查询式（换内核 P2，2026-10-01）：不进每帧观测，界面要用时经 `kernel.query(kind, args)` 现问。
///   · `cost_effects_for` = GD `cw_actions.gd cost_effects_for`：某个行动此刻受哪些费用特效影响（行动栏悬浮详情）；
///   · `move_block_reason` = GD `cw_actions.gd move_block_reason`：点了一格却走不过去时给玩家的那句话。
/// 文案与汇总口径逐字照 GD；对拍闸是 L1 `EnvelopeParityTests`（GD 轨迹导出每一步顺带录这两条，C# 重放逐步比）。
/// 纯查询：只读 WorldState，不消耗任何额度。
/// </summary>
internal static class Queries
{
    /// <summary>GD `move_dests` 之后再过 `_is_move_legal_now`：相邻六格（DIRS 序）+ 借道落点，只看盘面、不看能量。</summary>
    public static IEnumerable<HexPosition> LegalMoveDests(WorldState s, Cell c)
    {
        foreach (var n in RulePolicies.GdNeighbors(s, c.Position))
            if (LegalNow(s, c, n)) yield return n;
        foreach (var far in RulePolicies.PassThroughMap(s, c).Keys)
            if (LegalNow(s, c, far)) yield return far;
    }

    /// <summary>
    /// GD `_is_move_legal_now`：C# 的 `QuoteMove` 已经是「只看盘面」的那一半（不在盘上 / 一格一细胞 / 树突【各司其职】/ 借道落点要空），
    /// 只差攻击次数上限那一条（GD 写在同一个谓词里，C# 在 CellRules 里另走一道）。
    /// </summary>
    public static bool LegalNow(WorldState s, Cell c, HexPosition to)
    {
        if (!c.IsAlive || RulePolicies.QuoteMove(s, c, to) is null) return false;
        var attack = s.GetCellAt(to) is { } o && o.Faction != c.Faction;
        return !(attack && CellRules.AttackCapReached(s, c));
    }

    /// <summary>
    /// GD `cost_effects_for`：迁移逐个合法落点报价，按修饰名汇总 —— `changes` 是去重后的「改前→改后」（按落点顺序首次出现的先后），
    /// `targets` = 影响了几个落点，`total` = 一共报了几个价；结果按名字排序。
    /// 技能那一支（homing / jump / ossify / lyse）GD 走 CELL_SKILL / SKILL_MOVE 的费用管线；C# 结算技能时按原价扣、没有修饰，汇总必然为空。
    /// </summary>
    public static IReadOnlyList<CostEffect> CostEffectsFor(WorldState s, Cell c, string act)
    {
        if (act != "move") return [];
        var quotes = LegalMoveDests(s, c).Select(to => RulePolicies.MoveCostSteps(s, c, to)).ToList();
        var byName = new Dictionary<string, (List<string> Changes, int Targets)>(StringComparer.Ordinal);
        foreach (var steps in quotes)
        {
            var hit = new HashSet<string>(StringComparer.Ordinal);
            foreach (var st in steps)
            {
                var note = st.Modifier.Stage == ModifierStage.Free ? "免费豁免" : "";   // 与 cost_rows 同一条（ObservationV1Codec）
                if (st.Before == st.After && note == "") continue;
                var name = st.Modifier.Name;
                if (!byName.TryGetValue(name, out var e)) byName[name] = e = ([], 0);
                var change = $"{Stage.Fmt(st.Before)}→{Stage.Fmt(st.After)}";
                if (!e.Changes.Contains(change)) e.Changes.Add(change);
                hit.Add(name);
            }
            foreach (var name in hit) byName[name] = byName[name] with { Targets = byName[name].Targets + 1 };
        }
        return byName.OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .Select(kv => new CostEffect(kv.Key, kv.Value.Changes.ToArray(), kv.Value.Targets, quotes.Count)).ToArray();
    }

    /// <summary>GD `move_block_reason`：先判树突撞癌细胞，再判「盘面合法但付不起」，最后是相邻格的两种挡法；说不出理由就是空串。</summary>
    public static string MoveBlockReason(WorldState s, Cell c, HexPosition to)
    {
        var occupant = s.GetCellAt(to);
        if (c.Faction == Faction.Immune && c.Type == CellType.Dendritic && occupant is { IsAlive: true, Faction: Faction.Cancer })
            return "【各司其职】树突状细胞不能攻击、也不能移向癌细胞占据的组织";
        if (LegalNow(s, c, to))
        {
            var final = RulePolicies.QuoteMove(s, c, to)!.Value;
            if (Settlement.CanPay(c.Energy, final)) return "";
            var mods = RulePolicies.AppliedMoveModifiers(s, c, to).Select(m => m.Name).ToArray();
            var why = mods.Length == 0 ? "" : $"（含【{string.Join("】【", mods)}】）";
            return $"这一步要 {Stage.Fmt(final)}{why}，账上 {Stage.Fmt(c.Energy)} —— 付完至少要留 0.1";
        }
        if (!c.IsAlive || c.Position.DistanceTo(to) != 1 || !s.Board.Tissues.ContainsKey(to)) return "";
        if (occupant is not null && occupant.Faction == c.Faction)
            return "同阵营不能停留在同一格，但可以穿过去 —— 点它正后方那一格";
        if (c.Faction != Faction.Immune || occupant is not { Faction: Faction.Cancer }) return "";
        var cap = s.Tuning.AttackMaxPerTurn;
        return cap > 0 && c.AttacksThisTurn >= cap ? $"本行动回合的攻击次数已用尽（{c.AttacksThisTurn}/{cap}）" : "";
    }
}

/// <summary>`cost_effects_for` 的一行（GD `{name, changes, targets, total}`）。</summary>
public sealed record CostEffect(string Name, string[] Changes, int Targets, int Total);
