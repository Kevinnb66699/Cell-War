using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 胜负判定所有权域（对应三层设计的 OutcomeRules）：只读世界状态，产出胜者与世界回合结算的告警回合。
/// 不修改棋盘或细胞；写回 Turn 由编排层（Runtime/PhaseRules）负责。
/// </summary>
internal static class OutcomeRules
{
    /// <summary>
    /// 结算 E 阶段末的胜负：
    /// 免疫胜（无存活癌细胞且无可用于复活的固化癌组织）；
    /// 癌症分数报警（癌组织+2×固化癌组织 ≥ 90 连续两世界回合）；
    /// 第 15 世界回合后按癌性组织格数 ≥ 半数判胜。
    /// </summary>
    public static (Faction? Winner, int AlarmRound, string Kind) Evaluate(WorldState s)
    {
        var score = Tiles(s).Sum(t => t.State == TissueState.Cancer ? 1 : t.State == TissueState.SolidifiedCancer ? 2 : 0);
        var revivalSource = Tiles(s).Any(t => t.State == TissueState.SolidifiedCancer && s.GetCellAt(t.Position)?.Faction != Faction.Immune &&
            Tiles(s).Any(p => Cancerous(p) && p.OccupyingCell == null && p.Position.DistanceTo(t.Position) <= 1));
        var immuneWin = s.Cells.Count > 0 && !Cells(s).Any(c => c.IsAlive && c.Faction == Faction.Cancer) && !revivalSource;
        Faction? winner = immuneWin ? Faction.Immune : score >= 90 && s.Turn.CancerAlarmRound > 0 &&
            s.Turn.CancerAlarmRound == s.Turn.WorldRound - 1 ? Faction.Cancer : null;
        // GD 的四个词（cw_game.gd:1110,1132 / cw_world.gd:1226,1231），进 TurnState.WinKind 供观测协议 g.win_kind
        var kind = winner switch { Faction.Immune => "immune_clear", Faction.Cancer => "cancer_weighted", _ => "" };
        if (winner == null && s.Turn.WorldRound >= 15)
        {
            var cancer = Tiles(s).Count(Cancerous) >= s.Board.Tissues.Count / 2;
            winner = cancer ? Faction.Cancer : Faction.Immune;
            kind = cancer ? "limit_cancer" : "limit_immune";
        }
        return (winner, score >= 90 ? s.Turn.WorldRound : 0, kind);
    }
}
