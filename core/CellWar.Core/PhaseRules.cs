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
                // GD round_start：产出时踩着存卡骨髓抽到连走卡 / 撑爆手牌 / 抽到【基因组不稳定】 → **当场问完**才做血管传送。
                // 挂起了就停在 StartStep 3，等 DecisionRouter 的出口把挂起摘干净再 ResumeStart（批扫 6p_1007 第 157 步，2026-09-18）
                s = BoardRules.Produce(s, rng);
                s = s.WithTurn(s.Turn.Copy(startStep: 3));   // 别把产出时挂上的追问（连走 / 弃置 / 二选一）用旧的 Turn 盖掉
                if (!StartPending(s)) s = ResumeStart(s, rng);
            }
            else if (s.Turn.StartStep == 3)
            {
                if (!StartPending(s)) s = ResumeStart(s, rng);
            }
            else s = ContinueStart(s);
        }
        else if (s.Turn.Phase == Phase.PlayerAction)
        {
            // 【E-无氧呼吸】`anaerobic_on_turn_end`（扫描的 `eturn=1`）：改在**这个癌细胞自己的行动回合末**结算，
            // E 阶段那一步同时停掉（`BoardRules.EvolveEndOfRoundA`）。默认 false，这一段整块不跑 —— 零行为改动。
            // 位置对齐 GD `cw_game.gd:_end_turn`：`world.settle_anaerobic_turn(cell)` 排在 `turn.end_turn()`
            //（= 下面那圈清「本回合」修饰）**之前**，让结束回合那一刻的能量是进账后的数。
            // 口径照 GD `CWWorld.settle_anaerobic_turn`：走同一个 `AnaerobicShare`（含瓦伯格与 GLUT1），gain ≤ 0 时什么都不做（加 0 等价）。
            if (s.Tuning.AnaerobicOnTurnEnd)
                foreach (var ac in Cells(s).Where(c => c.OwnerSeat == s.Turn.ActivePlayerSeat && c.IsAlive && c.Faction == Faction.Cancer).ToArray())
                    s = s.UpdateCell(ac.Id, s.Cells[ac.Id].WithEnergy(s.Cells[ac.Id].Energy + AnaerobicShare(s, ac)));
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
            s = s.WithTurn(s.Turn.WithPendingChain(null).WithPendingChemotaxis(null, 0).WithPendingCouple(null, null, null).WithPendingCard(null, null).WithPendingRemodel(null, null, null, 0).WithPendingPickCell(null, null, null).WithPendingLand(null, null, 0).WithPendingMarrow(Array.Empty<HexPosition>(), 0));
            s = s.WithTurn(s.Turn.Copy(phase: next == null ? Phase.E : Phase.PlayerAction, seat: next ?? s.Turn.ActivePlayerSeat));
            if (next is { } seat) s = BeginTurn(s, seat);
        }
        else
        {
            if (s.Turn.EndStep == 0)
            {
                // GD `_resolve_camping`（4.9）是 await：蹲守巨噬的【连续吞噬】、记忆库抽卡带出的走位 / 弃置 / 二选一都在 E 阶段当场问完才做【固化】。
                // 挂起了就停在 EndStep 1，等 DecisionRouter 的出口把挂起摘干净再 FinishEndOfRound（此前 C# 的 E 阶段没有决策点，蹲守巨噬不连锁 —— 2026-09-18 对齐）
                s = BoardRules.EvolveEndOfRoundA(s, rng);
                s = s.WithTurn(s.Turn.Copy(endStep: 1));
            }
            if (!EndPending(s)) s = FinishEndOfRound(s, rng);
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
    /// ⚠ 与世界回合制的那一套（坏死、技能冷却、全局修饰倒计时）**是两套时钟，别混** ——
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
        // 【组织驻留】【LFA-1黏附】【组织巡航】2026-09-18 起不再发修饰：GD 里它们是报价时从 `equipped` 现读的模板 + `fx_turn` 闸门（Store.GATE），
        // 见 RulePolicies.SkillMoveModifiers —— 发成修饰会让 L1 视图的 `mods` 多条目、`fx_turn` 少键，还让回合中途装备的要等下一回合
        // 【耗竭抵抗】不在这里发修饰了（2026-09-16）：它两句合成一个 cut、住在伤害管线的减免层里，
        // 逐位对齐 GD 的 `cw_damage.gd:266-274`。见 `CellRules.Damage`。
        // 【细胞毒性增强】不再是回合修饰：GD 在攻击成功那一刻现读技能、走 fx_turn 闸门 / T 细胞直击（CellRules.Move 攻击分支，2026-09-17 深夜）
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

    /// <summary>有要问玩家的挂起（连走 / 强制弃置 / 【基因组不稳定】二选一 / 连锁 / 推迟的落地 / 风暴选中心）。</summary>
    public static bool AskPending(WorldState s)
        => s.Turn.PendingChemotaxisCell is not null || s.Turn.PendingDiscardSeat is not null || s.Turn.PendingMutationSeat is not null
           || s.Turn.PendingChainCell is not null || s.Turn.PendingLandCell is not null || s.Turn.PendingPickCellSeat is not null;

    /// <summary>S 阶段产出之后还有没有没做完的（要问的挂起，或【骨髓动员】还没收完的骨髓）：有就停在 StartStep 3。</summary>
    public static bool StartPending(WorldState s) => AskPending(s) || s.Turn.PendingMarrow.Count > 0;

    /// <summary>E 阶段 4.9 蹲守净化追出的问答（连锁 / 连走 / 强制弃置 / 二选一 / 推迟的落地）还没问完：停在 EndStep 1。</summary>
    public static bool EndPending(WorldState s) => StartPending(s);

    /// <summary>E 阶段后半：5 → 9.5 结算、判胜负、翻到下一世界回合的 S 阶段。</summary>
    public static WorldState FinishEndOfRound(WorldState s, IDeterministicRng rng)
    {
        s = BoardRules.EvolveEndOfRoundB(s, rng);
        var (winner, streak, kind) = OutcomeRules.Evaluate(s);
        s = s.WithTurn(s.Turn.Copy(phase: winner == null ? Phase.E : Phase.Finished, winner: winner, winKind: kind, streak: streak, endStep: 0));
        if (s.Turn.Phase != Phase.Finished)
            s = s.WithTurn(s.Turn.Copy(phase: Phase.S, round: s.Turn.WorldRound + 1, seat: s.Players.Keys.OrderBy(x => x).FirstOrDefault(), startStep: 0, cancerReviveFrom: 0, immuneReviveFrom: 0));
        return s;
    }

    /// <summary>S.2 血管传送 → 复活 / 有氧 / 过载 / 开打（产出那一步的追问全答完之后从这里接着走）。</summary>
    public static WorldState ResumeStart(WorldState s, IDeterministicRng rng)
    {
        s = BoardRules.Transport(s, rng);
        return ContinueStart(s.WithTurn(s.Turn.Copy(startStep: 1)));
    }

    /// <summary>S.3-S.5：处理复活输入，否则结算存活免疫细胞有氧呼吸并进入行动阶段。</summary>
    public static WorldState ContinueStart(WorldState s)
    {
        s = PassOverUnrevivable(s);   // GD `_ask_each`：没有落点的席位当场推进游标（轮不回来），死了却复活不了的报一句为什么
        var revival = GetRevivalOptions(s);
        if (revival.Count > 0) return s.WithTurn(s.Turn.Copy(seat: revival[0].PlayerSeat));
        s = Aerobic(s);
        s = Overload(s);   // S 阶段第 6 步【过载】：**必须排在【有氧呼吸】之后**
        var first = s.Players.Keys.OrderBy(x => x).Where(x => AliveSeat(s, x)).Cast<int?>().FirstOrDefault();
        // 本世界回合的第一个席位开打之前：0 号起沿途每个席位各走一格完整回合时钟
        s = TickFullTurnsThrough(s, -1, first ?? s.Players.Keys.DefaultIfEmpty(0).Max());
        s = s.WithTurn(s.Turn.Copy(phase: first == null ? Phase.E : Phase.PlayerAction, seat: first ?? 0, startStep: 2));
        return first == null ? s : BeginTurn(s, first.Value);
    }

    /// <summary>S.5 有氧呼吸 = GD `CWWorld._aerobic`：每只存活免疫收 <see cref="AerobicShare"/> 并演 respire；结算完【TGF-β释放】**同名整批消耗**
    /// （减免本身已算在 AerobicShare 里，这里只负责摘条目）。测试迁移规格 A-3 的 `aerobic` 契约步 —— 从 ContinueStart 拆出的具名入口，零行为改动（E-4，Kevin 2026-09-19）。</summary>
    internal static WorldState Aerobic(WorldState s)
    {
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune))
        {
            var income = AerobicShare(s, c);
            s = s.UpdateCell(c.Id, c.WithEnergy(c.Energy + income));
            Stage.Emit(Stage.Fx(s, "respire", ("at", c.Position)));   // GD cw_world.gd:507：每只免疫收完就演
        }
        if (WorldEffects.Stacks(s, "TGF-β释放") > 0) s = s.RemoveEffects("TGF-β释放");
        return s;
    }

    /// <summary>S.6 过载（PRD 2026-09-15）：只扣**存活**的癌细胞，第 4 步刚复活的也在内 ——
    /// PRD 第 6 步写的是「结算【过载】」，没有排除当回合复活的细胞，而复活后的能量同样是能量。`overload` 契约步（同上拆出，零行为改动）。</summary>
    internal static WorldState Overload(WorldState s)
    {
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer).ToArray())
        {
            var lost = OverloadLoss(s, s.Cells[c.Id]);
            if (lost > 0) s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy - lost));
        }
        return s;
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
                if (c.OwnerSeat < s.Turn.ImmuneReviveFrom) continue;   // 这一轮问过 / 报过了（GD flow["i"] 单向推进）
                if (!ImmuneReviveReady(s, c)) continue;
                options.AddRange(ImmuneReviveSpots(s).Select(m => (IDecision)new ReviveDecision(c.OwnerSeat, c.Id, m)));
            }
            else
            {
                if (c.OwnerSeat < s.Turn.CancerReviveFrom) continue;
                var spots = CancerReviveSpots(s);   // 落点 → 依托（坐标最小的那个固化格）
                if (spots.Count == 0) continue;
                options.Add(new SkipReviveDecision(c.OwnerSeat, c.Id));
                options.AddRange(spots.Keys.OrderBy(p => p.Q).ThenBy(p => p.R).Select(p => (IDecision)new ReviveDecision(c.OwnerSeat, c.Id, p, spots[p])));
            }
            if (options.Count > 0) return options;
        }
        return Array.Empty<IDecision>();
    }

    /// <summary>GD `revive_options_immune`：`respawn_round < 0` 或 `round_no < respawn_round` 就不问。只写了 DeathRound 的老夹具按「死后隔一回合」的旧口径兜底。</summary>
    private static bool ImmuneReviveReady(WorldState s, Cell c)
        => c.RespawnRound >= 0 ? s.Turn.WorldRound >= c.RespawnRound : c.DeathRound != null && s.Turn.WorldRound > c.DeathRound + 1;

    /// <summary>盘上的骨髓格，按 GD `CWData.MARROWS` 的序（老夹具 / 测试自己铺在别处的骨髓排在后面，按坐标）。</summary>
    private static IReadOnlyList<HexPosition> MarrowTiles(WorldState s)
        => Tiles(s).Where(t => t.Type == TissueType.BoneMarrow).Select(t => t.Position)
            .OrderBy(p => { var i = Array.IndexOf(MatchSetup.Marrows, p); return i < 0 ? int.MaxValue : i; }).ThenBy(p => p.Q).ThenBy(p => p.R).ToList();

    /// <summary>免疫复活的落点：健康且无人站着的骨髓（GD `revive_options_immune`，按 MARROWS 序）。</summary>
    private static IReadOnlyList<HexPosition> ImmuneReviveSpots(WorldState s)
        => MarrowTiles(s).Where(m => s.Board.Tissues[m].State == TissueState.Healthy && s.Board.Tissues[m].OccupyingCell == null).ToList();

    /// <summary>
    /// GD `advance` 的 revive_immune → revive_cancer 两段 `_ask_each`：按席位序逐个问，**没有落点的席位当场推进游标、这一轮轮不回来**
    /// （别的席位复活碎掉的固化格再造出落点也不回头问）；死了却复活不了的报一句为什么（cw_world.gd `_report_no_revive` / `_report_no_revive_immune`，口径 #93：
    /// 免疫站在固化癌组织上把复活位堵死是有意的战术，但被堵住这件事必须说出来）。停在第一个真有落点要问的席位之前。
    /// 此前 C# 没有落点就 continue、游标不动：同一 S 阶段里别人的复活造出落点后会回头再问（GD 不会），且一声不吭。
    /// </summary>
    private static WorldState PassOverUnrevivable(WorldState s)
    {
        if (s.Turn.Phase != Phase.S || s.Turn.StartStep != 1) return s;
        foreach (var c in Cells(s).Where(c => !c.IsAlive && c.Faction == Faction.Immune).OrderBy(c => c.OwnerSeat))
        {
            if (c.OwnerSeat < s.Turn.ImmuneReviveFrom) continue;
            if (ImmuneReviveReady(s, c))
            {
                if (ImmuneReviveSpots(s).Count > 0) return s;   // 这一席要问，停在这里
                // GD `_report_no_revive_immune`：提示挂在第一格被挡的骨髓上 —— 先被癌化的，没有就有人站着的
                var cancerous = MarrowTiles(s).Where(m => s.Board.Tissues[m].State != TissueState.Healthy).ToList();
                var taken = MarrowTiles(s).Where(m => s.Board.Tissues[m].State == TissueState.Healthy && s.Board.Tissues[m].OccupyingCell != null).ToList();
                var at = cancerous.Count > 0 ? cancerous[0] : taken.Count > 0 ? taken[0] : c.Position;
                Stage.Announce(s, $"{Stage.CellName(s, c)} 无法复活：骨髓不可用", at, true);
            }
            s = s.WithTurn(s.Turn.WithImmuneReviveFrom(c.OwnerSeat + 1));
        }
        foreach (var c in Cells(s).Where(c => !c.IsAlive && c.Faction == Faction.Cancer).OrderBy(c => c.OwnerSeat))
        {
            if (c.OwnerSeat < s.Turn.CancerReviveFrom) continue;
            if (CancerReviveSpots(s).Count > 0) return s;   // 这一席要问，停在这里
            // GD `_report_no_revive`：场上根本没有固化癌组织 vs 有但一格都开不出落点（被免疫占着 / 1 环内没空的癌性组织），提示挂在被堵的那一格上
            var solids = Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer).Select(t => t.Position).OrderBy(p => p.Q).ThenBy(p => p.R).ToList();
            if (solids.Count == 0)
                Stage.Announce(s, $"{Stage.SeatName(s, c.OwnerSeat)} 无法复活：没有固化癌组织", c.Position, true);
            else
            {
                var byImmune = solids.Where(p => s.GetCellAt(p) is { IsAlive: true } occ && occ.Faction != Faction.Cancer).ToList();
                var usable = solids.Where(p => !byImmune.Contains(p)).ToList();
                Stage.Announce(s, $"{Stage.SeatName(s, c.OwnerSeat)} 无法复活：固化癌组织都用不上", byImmune.Count > 0 ? byImmune[0] : usable[0], true);
            }
            s = s.WithTurn(s.Turn.WithCancerReviveFrom(c.OwnerSeat + 1));
        }
        return s;
    }

    /// <summary>癌方复活的落点 → 依托（GD `revive_options_cancer`：固化格 1 环内无人站着的癌性组织，依托取坐标最小的那个固化格）。</summary>
    private static Dictionary<HexPosition, HexPosition> CancerReviveSpots(WorldState s)
    {
        var spots = new Dictionary<HexPosition, HexPosition>();
        foreach (var source in Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer && s.GetCellAt(t.Position)?.Faction != Faction.Immune))
            foreach (var t in Tiles(s).Where(t => Cancerous(t) && t.OccupyingCell == null && t.Position.DistanceTo(source.Position) <= 1))
                if (!spots.TryGetValue(t.Position, out var anchor) || Less(source.Position, anchor)) spots[t.Position] = source.Position;
        return spots;
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
        // GD `revive_*` 只写 alive / energy / respawn_round：**不清 attacks_used**（它在 begin_turn 清；批扫 4p_1009 第 93 步就是这一格）
        s = s.UpdateCell(dead.Id, dead.Copy(alive: true, energy: dead.Faction == Faction.Immune ? 10 : 20, position: revival.TargetPosition, respawnRound: -1));   // GD 复活后 respawn_round = -1
        s = s.UpdateTissueOccupant(revival.TargetPosition, dead.Id);
        s = SetSeatAlive(s, dead.OwnerSeat, true);
        // 癌方这一席问过了（GD `flow["i"] += 1`）：别的癌席复活碎掉的固化格再造出落点，也轮不回来
        if (dead.Faction == Faction.Cancer) s = s.WithTurn(s.Turn.WithCancerReviveFrom(dead.OwnerSeat + 1));
        else s = s.WithTurn(s.Turn.WithImmuneReviveFrom(dead.OwnerSeat + 1));
        // 【癌症干性】：复活能量提高（分期），本世界回合前两次向癌性组织移动免费
        if (dead.Faction == Faction.Cancer && HasSkill(s, dead, "癌症干性"))
        {
            var stem = CancerPhase(s.Turn.WorldRound) switch { 0 => 30, 1 => 40, _ => 50 };
            s = s.UpdateCell(dead.Id, s.Cells[dead.Id].Copy(energy: stem));
            s = AddModifier(s, s.Cells[dead.Id], new("癌症干性", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Card, 0, 0, null, 2, ModifierDuration.Round, ModifierRequirement.MoveToCancerous));
        }
        // 落地算「进入」（GD `revive_immune` / `revive_cancer` 都 `enter_tile`）：骨髓有卡就抽一张 —— 那是带子上的一发，
        // 此前 C# 复活只放占位，L1 6p 第 83 步免疫在存着一张卡的骨髓上复活，GD 念了一条、C# 没念（2026-09-17）
        s = CellRules.ArriveAndLand(s, dead.Id, revival.TargetPosition, rng);
        Stage.Emit(Stage.Fx(s, dead.Faction == Faction.Immune ? "revive_immune" : "revive_cancer", ("at", revival.TargetPosition)));   // GD cw_world.gd:297/367：落地之后演
        // 完整的 enter_tile：落点是健康格就【定殖】、是癌组织就【净化】（GD revive_* 同）
        // 落地追出问答（骨髓抽到连走卡 / 撑爆手牌 / 二选一）：GD 在 revive_* 的 await 里问完才回到 S 流程；这里停住，DecisionRouter 的出口再 ContinueStart
        return new(StartPending(s) ? s : ContinueStart(s), Array.Empty<IGameEvent>(), true);
    }
}
