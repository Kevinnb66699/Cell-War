using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 胜负判定所有权域（对应三层设计的 OutcomeRules）：只读世界状态，产出胜者与更新后的连续达标计数。
/// 不修改棋盘或细胞；写回 Turn 由编排层（Runtime/PhaseRules）负责。
/// </summary>
internal static class OutcomeRules
{
    /// <summary>
    /// 结算 E 阶段末的胜负：
    /// 免疫胜（无存活癌细胞且无可用于复活的固化癌组织）；
    /// 癌症加权占地（癌组织 + 2 × 固化 ≥ 90）连续 `cancer_win_hold_rounds` 个世界回合末（计数器 `CancerWinStreak`）；
    /// 第 15 世界回合后按癌性组织格数 ≥ 半数判胜。
    /// </summary>
    /// <summary>【E-癌症胜利】加权占地线：癌组织 + 2 × 固化 ≥ 90（GD `CWData.CANCER_WIN_WEIGHTED`）。</summary>
    internal const int CancerWinWeighted = 90;

    public static (Faction? Winner, int Streak, string Kind) Evaluate(WorldState s)
    {
        var score = Tiles(s).Sum(t => t.State == TissueState.Cancer ? 1 : t.State == TissueState.SolidifiedCancer ? 2 : 0);
        var revivalSource = Tiles(s).Any(t => t.State == TissueState.SolidifiedCancer && s.GetCellAt(t.Position)?.Faction != Faction.Immune &&
            Tiles(s).Any(p => Cancerous(p) && p.OccupyingCell == null && p.Position.DistanceTo(t.Position) <= 1));
        var immuneWin = s.Cells.Count > 0 && !Cells(s).Any(c => c.IsAlive && c.Faction == Faction.Cancer) && !revivalSource;
        // 【E-癌症胜利】要**连续 hold 个世界回合末**都达标才判胜（GD `cw_game.gd:check_cancer_win` 读 `tune.cancer_win_hold_rounds`：
        // 默认 2 = 团队 2026-09-01 定案 B「首次达标只拉警报」；1 = 定案前的旧规则「达标即胜」）。
        // 计数器 `Turn.CancerWinStreak` 与 GD `cancer_win_streak` 同义：达标 +1、回落归零、已分胜负不动（GD 开头 `if winner >= 0: return`）。
        // 2026-09-19 之前 C# 只存「上一次达标的回合号」，hold ≥ 3 只能抛错；Kevin 拍板改真计数器后任意 hold 都算得出。
        var hold = s.Tuning.CancerWinHoldRounds;
        var streak = immuneWin ? s.Turn.CancerWinStreak : score >= CancerWinWeighted ? s.Turn.CancerWinStreak + 1 : 0;
        Faction? winner = immuneWin ? Faction.Immune : score >= CancerWinWeighted && streak >= hold ? Faction.Cancer : null;
        // GD 的四个词（cw_game.gd:1110,1132 / cw_world.gd:1226,1231），进 TurnState.WinKind 供观测协议 g.win_kind
        var kind = winner switch { Faction.Immune => "immune_clear", Faction.Cancer => "cancer_weighted", _ => "" };
        if (winner == null && s.Turn.WorldRound >= 15)
        {
            var cancer = Tiles(s).Count(Cancerous) >= s.Board.Tissues.Count / 2;
            winner = cancer ? Faction.Cancer : Faction.Immune;
            kind = cancer ? "limit_cancer" : "limit_immune";
        }
        return (winner, streak, kind);
    }
}
