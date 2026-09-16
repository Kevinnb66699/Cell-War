using static CellWar.Core.CellRules;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 阶段编排所有权域（对应三层设计的 PhaseRules）：
/// Setup 选址推进、S 阶段（生产/传送→复活→有氧呼吸）、玩家行动回合轮转、E 阶段演化与胜负写回。
/// 只负责“当前阶段该做什么与下一个阶段是谁”，具体效果分别委托 BoardRules/OutcomeRules/CellRules。
/// </summary>
internal static class PhaseRules
{
    public static bool AliveSeat(WorldState s, int seat) => s.Players.TryGetValue(seat, out var p) && p.IsAlive &&
        (!s.Cells.Values.Any(c => c.OwnerSeat == seat) || s.Cells.Values.Any(c => c.OwnerSeat == seat && c.IsAlive));

    public static RulesResult AdvancePhase(WorldState s, IDeterministicRng rng)
    {
        var before = s;
        if (s.Turn.Phase == Phase.Finished) return new(s, Array.Empty<IGameEvent>(), false, "Game is finished.");
        if (s.Turn.Phase == Phase.Setup)
        {
            var next = PlacementRules.NextUnplacedSeat(s, s.Turn.ActivePlayerSeat);
            s = next is { } seat ? s.WithTurn(s.Turn.Copy(seat: seat)) : PlacementRules.BeginWorldRound(s);
            return new(s, Array.Empty<IGameEvent>(), true);
        }
        if (s.Turn.Phase == Phase.S)
        {
            if (s.Turn.StartStep == 0)
            {
                s = BoardRules.ProduceAndTransport(s);
                s = s.WithTurn(s.Turn.Copy(startStep: 1));
            }
            s = ContinueStart(s);
        }
        else if (s.Turn.Phase == Phase.PlayerAction)
        {
            var next = s.Players.Keys.OrderBy(x => x).Where(x => x > s.Turn.ActivePlayerSeat && AliveSeat(s, x)).Cast<int?>().FirstOrDefault();
            s = s.WithTurn(s.Turn.Copy(phase: next == null ? Phase.E : Phase.PlayerAction, seat: next ?? s.Turn.ActivePlayerSeat));
            if (next is { } seat) s = BeginTurn(s, seat);
        }
        else
        {
            s = BoardRules.EvolveEndOfRound(s, rng);
            var (winner, alarm) = OutcomeRules.Evaluate(s);
            s = s.WithTurn(s.Turn.Copy(phase: winner == null ? Phase.E : Phase.Finished, winner: winner, alarm: alarm));
            if (s.Turn.Phase != Phase.Finished)
                s = s.WithTurn(s.Turn.Copy(phase: Phase.S, round: s.Turn.WorldRound + 1, seat: s.Players.Keys.OrderBy(x => x).FirstOrDefault(), startStep: 0));
        }
        var facts = Cells(s).Where(c => before.Cells.TryGetValue(c.Id, out var previous) && previous.Energy != c.Energy)
            .Select(c => (IGameEvent)new EnergyChangedEvent(before.Turn.WorldRound, before.Turn.Phase, c.Id,
                before.Cells[c.Id].Energy, c.Energy, "Phase settlement")).ToArray();
        return new(s, facts, true);
    }

    /// <summary>进入某玩家的行动回合：重置攻击/抽卡次数与「本行动回合」修饰，并按已装备永久技能续上本回合修饰。</summary>
    private static WorldState BeginTurn(WorldState s, int seat)
    {
        foreach (var c in Cells(s).Where(c => c.OwnerSeat == seat).ToArray())
        {
            s = s.UpdateCell(c.Id, s.Cells[c.Id].Copy(attacks: 0, draws: 0,
                fxTurn: new Dictionary<string, int>(),
                modifiers: s.Cells[c.Id].Modifiers.Where(m => m.Duration != ModifierDuration.Turn).ToList()));
            s = GrantTurnModifiers(s, s.Cells[c.Id]);
        }
        return s;
    }

    /// <summary>
    /// 回合开始时给装备的永久技能发修饰。
    ///
    /// 2026-09-15 两处改动：
    /// ① **不再走 `AddModifier`** —— 那个会 bump `PlayCounter`（`CellRules.cs` 的 AddModifier），
    ///    于是每个回合、每件装备都把「打出先后」那把尺往前推一格，尺子本身就失真了。
    /// ② `Sequence` 改成从 `EquipSeq` 取**装备那一刻**的戳，而不是 0 或当前计数 ——
    ///    PRD:182-184 要的是「同层级按装备的先后」，那个先后只有装备时刻才知道。
    ///
    /// 【组织巡航】发两条修饰，**共用同一个戳**（GD 侧是一个模板名发两条、applied_seq 相同）。
    /// </summary>
    private static WorldState GrantTurnModifiers(WorldState s, Cell c)
    {
        if (HasSkill(s, c, "组织驻留"))
            s = GrantSkillModifier(s, c, new("组织驻留", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Passive, 0, 0, null, 2, ModifierDuration.Turn, ModifierRequirement.MoveToHealthy));
        if (HasSkill(s, c, "LFA-1黏附"))
            s = GrantSkillModifier(s, c, new("LFA-1黏附", ModifierTarget.Move, ModifierStage.Subtract, SourceLayer.Passive, 0, 4, 2, 1, ModifierDuration.Turn, ModifierRequirement.MoveToCancerous));
        if (HasSkill(s, c, "组织巡航"))
        {
            s = GrantSkillModifier(s, c, new("组织巡航", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Passive, 0, 0, null, 1, ModifierDuration.Turn));
            // 第二条刻意也用「组织巡航」取戳：两条是同一件装备发出来的，先后必须一致
            s = GrantSkillModifier(s, c, new("组织巡航·减", ModifierTarget.Move, ModifierStage.Subtract, SourceLayer.Passive, 0, 2, 2, ActiveModifier.Unlimited, ModifierDuration.Turn), stampFrom: "组织巡航");
        }
        if (HasSkill(s, c, "耗竭抵抗"))
            s = GrantSkillModifier(s, c, new("耗竭抵抗", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Passive, 0, 10, 0, 1, ModifierDuration.Round));
        if (HasSkill(s, c, "细胞毒性增强"))
            s = GrantSkillModifier(s, c, new("细胞毒性增强", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Passive, 0, 10, null, 1, ModifierDuration.Turn));
        return s;
    }

    /// <summary>挂一条永久技能的修饰：戳取自装备时刻，**不推进** PlayCounter。</summary>
    private static WorldState GrantSkillModifier(WorldState s, Cell c, ActiveModifier modifier, string? stampFrom = null)
    {
        var current = s.Cells[c.Id];
        var seq = current.EquipSeq.TryGetValue(stampFrom ?? modifier.Card, out var v) ? v : 0;
        var list = current.Modifiers.ToList();
        list.Add(modifier with { Sequence = seq });
        return s.UpdateCell(c.Id, current.Copy(modifiers: list));
    }

    /// <summary>S.3-S.5：处理复活输入，否则结算存活免疫细胞有氧呼吸并进入行动阶段。</summary>
    public static WorldState ContinueStart(WorldState s)
    {
        var revival = GetRevivalOptions(s);
        if (revival.Count > 0) return s.WithTurn(s.Turn.Copy(seat: revival[0].PlayerSeat));
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune))
        {
            var income = AerobicShare(s, c);
            s = s.UpdateCell(c.Id, c.WithEnergy(c.Energy + income));
        }
        if (s.Turn.TgfStacks > 0) s = s.WithTurn(s.Turn.Copy(tgf: 0));
        var first = s.Players.Keys.OrderBy(x => x).Where(x => AliveSeat(s, x)).Cast<int?>().FirstOrDefault();
        s = s.WithTurn(s.Turn.Copy(phase: first == null ? Phase.E : Phase.PlayerAction, seat: first ?? 0, startStep: 2));
        return first == null ? s : BeginTurn(s, first.Value);
    }

    public static IReadOnlyList<ReviveDecision> GetRevivalOptions(WorldState s)
    {
        if (s.Turn.Phase != Phase.S || s.Turn.StartStep != 1) return Array.Empty<ReviveDecision>();
        foreach (var c in Cells(s).Where(c => !c.IsAlive).OrderBy(c => c.Faction == Faction.Immune ? 0 : 1).ThenBy(c => c.OwnerSeat))
        {
            var options = new List<ReviveDecision>();
            if (c.Faction == Faction.Immune)
            {
                if (c.DeathRound == null || s.Turn.WorldRound <= c.DeathRound + 1) continue;
                options.AddRange(Tiles(s).Where(t => t.Type == TissueType.BoneMarrow && t.State == TissueState.Healthy && t.OccupyingCell == null)
                    .Select(t => new ReviveDecision(c.OwnerSeat, c.Id, t.Position)));
            }
            else
            {
                foreach (var source in Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer && s.GetCellAt(t.Position)?.Faction != Faction.Immune))
                    options.AddRange(Tiles(s).Where(t => Cancerous(t) && t.OccupyingCell == null && t.Position.DistanceTo(source.Position) <= 1)
                        .Select(t => new ReviveDecision(c.OwnerSeat, c.Id, t.Position, source.Position)));
            }
            if (options.Count > 0) return options;
        }
        return Array.Empty<ReviveDecision>();
    }

    /// <summary>S.3/S.4 复活结算：落位/能量/占用与癌症干性被动，随后继续 S 阶段。</summary>
    public static RulesResult Revive(WorldState s, ReviveDecision revival)
    {
        var dead = s.Cells[revival.CellId];
        if (revival.SourcePosition is { } source)
            s = s.UpdateTissueState(source, TissueState.Cancer).UpdateTissueSolidification(source, 0);
        s = s.UpdateCell(dead.Id, dead.Copy(alive: true, energy: dead.Faction == Faction.Immune ? 10 : 20, position: revival.TargetPosition, attacks: 0));
        s = s.UpdateTissueOccupant(revival.TargetPosition, dead.Id);
        s = SetSeatAlive(s, dead.OwnerSeat, true);
        // 【癌症干性】：复活能量提高（分期），本世界回合前两次向癌性组织移动免费
        if (dead.Faction == Faction.Cancer && HasSkill(s, dead, "癌症干性"))
        {
            var stem = CancerPhase(s.Turn.WorldRound) switch { 0 => 30, 1 => 40, _ => 50 };
            s = s.UpdateCell(dead.Id, s.Cells[dead.Id].Copy(energy: stem));
            s = AddModifier(s, s.Cells[dead.Id], new("癌症干性", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Card, 0, 0, null, 2, ModifierDuration.Round, ModifierRequirement.MoveToCancerous));
        }
        return new(ContinueStart(s), Array.Empty<IGameEvent>(), true);
    }
}
