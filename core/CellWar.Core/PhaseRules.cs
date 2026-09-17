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
                s = BoardRules.ProduceAndTransport(s, rng);
                s = s.WithTurn(s.Turn.Copy(startStep: 1));
            }
            s = ContinueStart(s);
        }
        else if (s.Turn.Phase == Phase.PlayerAction)
        {
            // 「效果持续至本回合结束」的修饰在**结束回合这一刻**过期（GD `CWTurn.end_turn` → `clear_mods(cell, "turn")`，只清本人的）。
            // 此前 C# 放在下一次 BeginTurn 才清 —— E 阶段与别人的回合里它还挂着，L1 第 107 步席位 2 的【补体调理】就是这么多出来的（2026-09-17）
            foreach (var c in Cells(s).Where(c => c.OwnerSeat == s.Turn.ActivePlayerSeat).ToArray())
                s = s.UpdateCell(c.Id, s.Cells[c.Id].Copy(modifiers: s.Cells[c.Id].Modifiers.Where(m => m.Duration != ModifierDuration.Turn).ToList()));
            var next = s.Players.Keys.OrderBy(x => x).Where(x => x > s.Turn.ActivePlayerSeat && AliveSeat(s, x)).Cast<int?>().FirstOrDefault();
            // 完整回合时钟：走到下一个开打的席位之前，沿途每个席位各走一格（死的也计入）
            s = TickFullTurnsThrough(s, s.Turn.ActivePlayerSeat,
                next ?? s.Players.Keys.DefaultIfEmpty(s.Turn.ActivePlayerSeat).Max());
            // 挂起态跨不出这一回合：GD 的连锁 / 趋化是 play() 里的一段 await，语法上就出不了这次打牌。
            // 正常路径到不了这里（挂起时「结束回合」被 Validate 驳回），这是防御 —— 谁绕开 Execute 直接推阶段，
            // 也不能让原主人在别人的回合里把剩下的几步走完。
            s = s.WithTurn(s.Turn.WithPendingChain(null).WithPendingChemotaxis(null, 0).WithPendingCouple(null, null, null).WithPendingCard(null, null).WithPendingRemodel(null, null, null, 0));
            s = s.WithTurn(s.Turn.Copy(phase: next == null ? Phase.E : Phase.PlayerAction, seat: next ?? s.Turn.ActivePlayerSeat));
            if (next is { } seat) s = BeginTurn(s, seat);
        }
        else
        {
            s = BoardRules.EvolveEndOfRound(s, rng);
            var (winner, alarm) = OutcomeRules.Evaluate(s);
            s = s.WithTurn(s.Turn.Copy(phase: winner == null ? Phase.E : Phase.Finished, winner: winner, alarm: alarm));
            if (s.Turn.Phase != Phase.Finished)
                s = s.WithTurn(s.Turn.Copy(phase: Phase.S, round: s.Turn.WorldRound + 1, seat: s.Players.Keys.OrderBy(x => x).FirstOrDefault(), startStep: 0, cancerReviveFrom: 0));
        }
        var facts = Cells(s).Where(c => before.Cells.TryGetValue(c.Id, out var previous) && previous.Energy != c.Energy)
            .Select(c => (IGameEvent)new EnergyChangedEvent(before.Turn.WorldRound, before.Turn.Phase, c.Id,
                before.Cells[c.Id].Energy, c.Energy, "Phase settlement")).ToArray();
        return new(s, facts, true);
    }

    /// <summary>
    /// 「持续 n **完整回合**」的时钟（PRD 游戏流程 4：「当前玩家结束回合后，下 n 次该玩家行动回合前效果消失」）。
    /// **每个席位开打之前各走一格**，而且 4.1 明写「死亡的那一回合自动跳过但仍然计入」。
    ///
    /// ⚠ 与世界回合制的那一套（坏死、技能冷却、世界事件）**是两套时钟，别混** ——
    /// GD 在 `CWWorld.tick_full_turn` 上专门写了这句警告。
    /// 2026-09-16 之前 C# 把【I-趋化源】的存续塞在 E 阶段第 8 步，整条时钟都是错的。
    ///
    /// 眼下只有【I-趋化源】走这套；源消散那一刻给**建立它的细胞**记上技能冷却。
    /// **先取 creator 再清** —— 清完就没地方问是谁立的了。
    /// </summary>
    private static WorldState TickFullTurn(WorldState s, int seat)
    {
        if (s.Turn.ChemoRounds <= 0 || s.Turn.ChemoOwner != seat) return s;
        var rounds = s.Turn.ChemoRounds - 1;
        var creator = s.Turn.ChemoCreator;
        s = s.WithTurn(s.Turn.WithChemo(rounds > 0 ? s.Turn.ChemoAt : null, rounds,
            rounds > 0 ? s.Turn.ChemoOwner : -1, rounds > 0 ? creator : null));
        if (rounds <= 0 && creator is { } id && s.Cells.ContainsKey(id))
            s = s.UpdateCell(id, s.Cells[id].Copy(chemoCooldown: BoardRules.ChemoCooldownRounds));
        return s;
    }

    /// <summary>
    /// 从 `from`（不含）走到 `to`（含）之间**每一个**席位各走一格完整回合时钟 ——
    /// 中间被跳过的死亡席位也要计入（PRD 4.1）。
    /// </summary>
    private static WorldState TickFullTurnsThrough(WorldState s, int from, int to)
    {
        foreach (var seat in s.Players.Keys.OrderBy(x => x).Where(x => x > from && x <= to))
            s = TickFullTurn(s, seat);
        return s;
    }

    /// <summary>进入某玩家的行动回合：重置攻击/抽卡次数与「本行动回合」修饰，并按已装备永久技能续上本回合修饰。</summary>
    private static WorldState BeginTurn(WorldState s, int seat)
    {
        foreach (var c in Cells(s).Where(c => c.OwnerSeat == seat).ToArray())
        {
            s = s.UpdateCell(c.Id, s.Cells[c.Id].Copy(attacks: 0, draws: 0,
                fxTurn: new Dictionary<string, int>(), chainLeft: 0,   // 连锁额度是「本行动回合」的
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
        // 【耗竭抵抗】不在这里发修饰了（2026-09-16）：它两句合成一个 cut、住在伤害管线的减免层里，
        // 逐位对齐 GD 的 `cw_damage.gd:266-274`。见 `CellRules.Damage`。
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
        // 【TGF-β释放】结算完**同名整批消耗**（对齐 GD 的 CWWorld._aerobic）。
        // 减免本身已经算在 AerobicShare 里了，这里只负责摘条目。
        if (WorldEffects.Stacks(s, "TGF-β释放") > 0) s = s.RemoveEffects("TGF-β释放");
        // S 阶段第 6 步【过载】（PRD 2026-09-15）：**必须排在【有氧呼吸】之后**。
        // 只扣**存活**的癌细胞；第 4 步刚复活的也在内 ——
        // PRD 第 6 步写的是「结算【过载】」，没有排除当回合复活的细胞，而复活后的能量同样是能量。
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer).ToArray())
        {
            var lost = OverloadLoss(s, s.Cells[c.Id]);
            if (lost > 0) s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy - lost));
        }
        var first = s.Players.Keys.OrderBy(x => x).Where(x => AliveSeat(s, x)).Cast<int?>().FirstOrDefault();
        // 本世界回合的第一个席位开打之前：0 号起沿途每个席位各走一格完整回合时钟
        s = TickFullTurnsThrough(s, -1, first ?? s.Players.Keys.DefaultIfEmpty(0).Max());
        s = s.WithTurn(s.Turn.Copy(phase: first == null ? Phase.E : Phase.PlayerAction, seat: first ?? 0, startStep: 2));
        return first == null ? s : BeginTurn(s, first.Value);
    }

    /// <summary>
    /// 这一刻该问谁复活、有哪些选项。免疫先（GD `revive_immune` 阶段在前）、再癌方；每方按席位。
    /// 癌方（GD `revive_options_cancer`）：下标 0 是「放弃本回合复活」；每个落点**只出一条**，依托取坐标最小的固化格
    /// （同一落点可能落在好几个固化格的 1 环里，GD 不为「碎哪一格」多加一问，取最小值也让结果不依赖遍历顺序）；
    /// 席位小于 <see cref="TurnState.CancerReviveFrom"/> 的这一轮已经问过，不再问。
    /// </summary>
    public static IReadOnlyList<IDecision> GetRevivalOptions(WorldState s)
    {
        if (s.Turn.Phase != Phase.S || s.Turn.StartStep != 1) return Array.Empty<IDecision>();
        foreach (var c in Cells(s).Where(c => !c.IsAlive).OrderBy(c => c.Faction == Faction.Immune ? 0 : 1).ThenBy(c => c.OwnerSeat))
        {
            var options = new List<IDecision>();
            if (c.Faction == Faction.Immune)
            {
                // GD `revive_options_immune`：`respawn_round < 0` 或 `round_no < respawn_round` 就不问。
                // 只写了 DeathRound 的老夹具（C# 自己造的死细胞）按「死后隔一回合」的旧口径兜底
                var ready = c.RespawnRound >= 0 ? s.Turn.WorldRound >= c.RespawnRound : c.DeathRound != null && s.Turn.WorldRound > c.DeathRound + 1;
                if (!ready) continue;
                options.AddRange(Tiles(s).Where(t => t.Type == TissueType.BoneMarrow && t.State == TissueState.Healthy && t.OccupyingCell == null)
                    .Select(t => (IDecision)new ReviveDecision(c.OwnerSeat, c.Id, t.Position)));
            }
            else
            {
                if (c.OwnerSeat < s.Turn.CancerReviveFrom) continue;
                var spots = new Dictionary<HexPosition, HexPosition>();   // 落点 → 依托（坐标最小的那个固化格）
                foreach (var source in Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer && s.GetCellAt(t.Position)?.Faction != Faction.Immune))
                    foreach (var t in Tiles(s).Where(t => Cancerous(t) && t.OccupyingCell == null && t.Position.DistanceTo(source.Position) <= 1))
                        if (!spots.TryGetValue(t.Position, out var anchor) || Less(source.Position, anchor)) spots[t.Position] = source.Position;
                if (spots.Count == 0) continue;
                options.Add(new SkipReviveDecision(c.OwnerSeat, c.Id));
                options.AddRange(spots.Keys.OrderBy(p => p.Q).ThenBy(p => p.R).Select(p => (IDecision)new ReviveDecision(c.OwnerSeat, c.Id, p, spots[p])));
            }
            if (options.Count > 0) return options;
        }
        return Array.Empty<IDecision>();
    }

    /// <summary>GD `Vector2i` 的 `<`：先比 x（q）再比 y（r）。依托「取坐标最小」用的就是这把尺。</summary>
    private static bool Less(HexPosition a, HexPosition b) => a.Q < b.Q || (a.Q == b.Q && a.R < b.R);

    /// <summary>癌方放弃本回合复活：细胞照旧死着，光标推到下一席，S 阶段继续。</summary>
    public static RulesResult SkipRevive(WorldState s, SkipReviveDecision skip)
        => new(ContinueStart(s.WithTurn(s.Turn.WithCancerReviveFrom(skip.PlayerSeat + 1))), Array.Empty<IGameEvent>(), true);

    /// <summary>S.3/S.4 复活结算：落位/能量/占用与癌症干性被动，随后继续 S 阶段。</summary>
    public static RulesResult Revive(WorldState s, ReviveDecision revival, IDeterministicRng rng)
    {
        var dead = s.Cells[revival.CellId];
        if (revival.SourcePosition is { } source)
            s = CardRules.CrackToCancer(s, source);   // GD `crack_to_cancer`：固化格拆回普通癌组织（to_cancer(false)，五项一起清）
        s = s.UpdateCell(dead.Id, dead.Copy(alive: true, energy: dead.Faction == Faction.Immune ? 10 : 20, position: revival.TargetPosition, attacks: 0, respawnRound: -1));   // GD 复活后 respawn_round = -1
        s = s.UpdateTissueOccupant(revival.TargetPosition, dead.Id);
        s = SetSeatAlive(s, dead.OwnerSeat, true);
        // 癌方这一席问过了（GD `flow["i"] += 1`）：别的癌席复活碎掉的固化格再造出落点，也轮不回来
        if (dead.Faction == Faction.Cancer) s = s.WithTurn(s.Turn.WithCancerReviveFrom(dead.OwnerSeat + 1));
        // 【癌症干性】：复活能量提高（分期），本世界回合前两次向癌性组织移动免费
        if (dead.Faction == Faction.Cancer && HasSkill(s, dead, "癌症干性"))
        {
            var stem = CancerPhase(s.Turn.WorldRound) switch { 0 => 30, 1 => 40, _ => 50 };
            s = s.UpdateCell(dead.Id, s.Cells[dead.Id].Copy(energy: stem));
            s = AddModifier(s, s.Cells[dead.Id], new("癌症干性", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Card, 0, 0, null, 2, ModifierDuration.Round, ModifierRequirement.MoveToCancerous));
        }
        // 落地算「进入」（GD `revive_immune` / `revive_cancer` 都 `enter_tile`）：骨髓有卡就抽一张 —— 那是带子上的一发，
        // 此前 C# 复活只放占位，L1 6p 第 83 步免疫在存着一张卡的骨髓上复活，GD 念了一条、C# 没念（2026-09-17）
        s = CellRules.Land(s, dead.Id, rng);
        return new(ContinueStart(s), Array.Empty<IGameEvent>(), true);
    }
}
