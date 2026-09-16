namespace CellWar.Core;

/// <summary>
/// 细胞域状态变更：能量损失/死亡、座位存活、抗原记忆、运行期修饰、标记、传送、能量收取。
/// 对应离散事件架构三层设计的 CellRules 所有权域。所有规则域与卡牌共用这些原子变更，
/// 避免各自复制“扣血/死亡/记忆”逻辑；本类不负责决策合法性（由各域 Validate 负责）。
/// </summary>
internal static class CellRules
{
    public static WorldState Damage(WorldState s, EntityId id, int amount)
    {
        var c = s.Cells[id];
        var modifiers = c.Modifiers.Where(m => m.Target == ModifierTarget.EnergyLoss).Select(m => m.ToValueModifier()).ToList();
        if (c.Type == CellType.Osteosarcoma && RulePolicies.TypeAbilityOn(s, c) && s.Board.Tissues[c.Position].State == TissueState.SolidifiedCancer)
            modifiers.Add(new ValueModifier(ModifierStage.Multiply, SourceLayer.Passive, 0, 40));  // 【刚性屏障】×40%

        // 树突【I-标记】：被标记的癌细胞下一次受到能量损失时 ×2，随后移除标记（PRD:573）。
        //
        // 2026-09-15 补：此前 Marked / MarkLeft / MarkRound 三个字段建好了、ApplyMark 也在跑，
        // 但**伤害管线里根本没有这一步** —— MarkLeft 只流进了观测。
        // 于是树突整条标记链（含【交叉呈递】【抗原呈递强化】【免疫猎杀】）在 C# 里是零收益。
        //
        // 口径照抄 GDScript 侧 cw_damage.gd:184-187：
        //   · 是**倍增**层（与【刚性屏障】同层，都走 Multiply；×2 写成 200）
        //   · **ON_BENEFIT**：只有确实有伤害可翻倍时才消耗（`amount > 0`）——
        //     不然一次 0 伤害就把标记白白吃掉
        //   · MarkLeft 可能 >1（树突【抗原呈递强化】给 2 层），耗尽才清 Marked
        //
        // ⚠ **一处 PRD 与 GDScript 的偏离，先照 GDScript、没有自作主张**：
        // PRD:573 写的是「下一次受到**免疫细胞造成的**能量损失」，而 GDScript 侧
        // 只判 `marked` 与伤害为正、**不看来源**。两边内核要先一致，
        // 「该不该只认免疫来源」是给 Kevin 的一条待裁项（实践中癌细胞受到的伤害
        // 几乎都来自免疫方，所以今天两种读法大概率同结果，但不等于没差别）。
        var markApplies = c.Marked && amount > 0;
        if (markApplies)
            modifiers.Add(new ValueModifier(ModifierStage.Multiply, SourceLayer.Skill, 0, 200));

        amount = Settlement.ApplyEnergyLoss(amount, modifiers);
        s = ConsumeModifiers(s, id, ModifierTarget.EnergyLoss);
        if (markApplies)
        {
            var marked = s.Cells[id];
            var left = marked.MarkLeft - 1;
            s = s.UpdateCell(id, marked.Copy(markLeft: left, marked: left > 0));
        }
        c = s.Cells[id];
        // 印戒【囊性护甲】：每世界回合第一次能量损失 -0.5，不限来源
        if (c.Type == CellType.SignetRing && RulePolicies.TypeAbilityOn(s, c) && !c.ArmorUsedThisRound)
        {
            amount = Math.Max(0, amount - 5);
            s = s.UpdateCell(id, s.Cells[id].Copy(armor: true));
            c = s.Cells[id];
        }
        // 【BCL-2抗凋亡】：即将受到致命能量损失时免疫该次损失，能量改为 0.5/0.8/1
        if (amount >= c.Energy && HasModifier(c, "BCL-2抗凋亡"))
        {
            var survive = RulePolicies.CancerPhase(s.Turn.WorldRound) switch { 0 => 5, 1 => 8, _ => 10 };
            s = s.UpdateCell(id, c.Copy(energy: survive));
            return RemoveModifiers(s, id, "BCL-2抗凋亡");
        }
        var energy = Math.Max(0, c.Energy - amount);
        s = s.UpdateCell(id, c.Copy(energy: energy, alive: energy > 0, deathRound: energy == 0 ? s.Turn.WorldRound : c.DeathRound));
        if (energy == 0)
        {
            // 【免疫猎杀】：「癌细胞死亡后趋化源留在死亡格」——把位置冻下来、断开跟随。
            // 位置平时不存在状态里（活着现读细胞的 Position），只有这一刻要冻。
            if (s.Turn.TrackCell == id)
                s = s.WithTurn(s.Turn.WithTrack(null, c.Position, s.Turn.TrackRounds));
            s = s.UpdateTissueOccupant(c.Position, null);
            s = SetSeatAlive(s, c.OwnerSeat, s.Cells.Values.Any(x => x.OwnerSeat == c.OwnerSeat && x.IsAlive));
        }
        return s;
    }

    public static WorldState SetSeatAlive(WorldState s, int seat, bool alive)
        => s.UpdatePlayer(seat, s.Players[seat].WithIsAlive(alive));

    public static WorldState AddMemory(WorldState s, int amount)
    {
        foreach (var p in s.Players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat))
        {
            var memory = p.AntigenMemory + amount;
            var level = memory >= (s.Players.Count == 6 ? 70 : 50) ? ImmuneLevel.X :
                memory >= (s.Players.Count == 6 ? 30 : 20) ? ImmuneLevel.III : memory >= 10 ? ImmuneLevel.II : ImmuneLevel.I;
            if (level < p.ImmuneLevel) level = p.ImmuneLevel;
            if (level == ImmuneLevel.X && p.ImmuneLevel != ImmuneLevel.X) memory = 0;
            s = s.UpdatePlayer(p.Seat, p.WithAntigenMemory(memory).WithImmuneLevel(level));
        }
        return s;
    }

    public static WorldState ReduceMemory(WorldState s, int amount)
    {
        foreach (var p in s.Players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat).ToArray())
            s = s.UpdatePlayer(p.Seat, p.WithAntigenMemory(Math.Max(0, p.AntigenMemory - amount)));
        return s;
    }

    /// <summary>挂上一条运行期修饰，序号取自该细胞的打出计数。</summary>
    public static WorldState AddModifier(WorldState s, Cell cell, ActiveModifier modifier)
    {
        var current = s.Cells[cell.Id];
        var list = current.Modifiers.ToList();
        list.Add(modifier with { Sequence = current.PlayCounter + 1 });
        return s.UpdateCell(cell.Id, current.Copy(playCounter: current.PlayCounter + 1, modifiers: list));
    }

    public static bool HasModifier(Cell c, string card) => c.Modifiers.Any(m => m.Card == card);

    public static WorldState RemoveModifiers(WorldState s, EntityId id, string card)
    {
        var c = s.Cells[id];
        return s.UpdateCell(id, c.Copy(modifiers: c.Modifiers.Where(m => m.Card != card).ToList()));
    }

    /// <summary>消耗一次目标数值的修饰（次数-1，耗尽即移除）；Uses=-1 不受影响。</summary>
    public static WorldState ConsumeModifiers(WorldState s, EntityId id, ModifierTarget target, HexPosition? destination = null)
    {
        var c = s.Cells[id];
        var cancerous = destination is { } dest && RulePolicies.Cancerous(s.Board.Tissues[dest]);
        var kept = new List<ActiveModifier>();
        foreach (var m in c.Modifiers)
        {
            if (m.Target != target || m.Uses < 0 || (destination is { } && !RulePolicies.RequirementMet(m.Requirement, cancerous))) { kept.Add(m); continue; }
            var used = m.Consume();
            if (!used.Expired) kept.Add(used);
        }
        return s.UpdateCell(id, c.Copy(modifiers: kept));
    }

    /// <summary>【连续吞噬】最多连几次 / 每连一格下一次攻击的加成（GD `CHAIN_PHAGO_MAX` / `CHAIN_PHAGO_BONUS`）。</summary>
    internal const int ChainPhagoMax = 5;
    internal const int ChainPhagoBonus = 5;

    /// <summary>【连续吞噬】这一跳能落在哪：相邻的**癌组织**、且没有细胞占着。</summary>
    public static IReadOnlyList<HexPosition> ChainTargets(WorldState s, Cell c)
        => c.Position.GetNeighbors()
            .Where(n => s.Board.Tissues.TryGetValue(n, out var t)
                && t.State == TissueState.Cancer && s.GetCellAt(n) == null)
            .OrderBy(n => n.Q).ThenBy(n => n.R).ToArray();

    /// <summary>
    /// 【连续吞噬】走一跳：**免费**迁移（不进费用管线），随后照常触发净化 ——
    /// 于是能不能再连由那一步自己决定（`Move` 里净化之后会重新挂起）。
    /// </summary>
    public static RulesResult ChainMove(WorldState s, ChainMoveDecision d, IDeterministicRng rng)
    {
        var c = s.Cells[d.CellId];
        s = s.UpdateCell(d.CellId, c.Copy(chainLeft: c.ChainLeft - 1, chainBonus: c.ChainBonus + ChainPhagoBonus));
        s = s.WithTurn(s.Turn.WithPendingChain(null));   // 先摘挂起；这一跳的净化会视情况重新挂上
        return Move(s, new MoveDecision(d.PlayerSeat, d.CellId, d.Target), rng, free: true);
    }

    /// <summary>树突【I-标记】光环：任意时刻处于树突 2 环内的癌细胞自动获得标记。</summary>
    public static WorldState UpdateMarks(WorldState s)
    {
        foreach (var dendritic in RulePolicies.Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune && c.Type == CellType.Dendritic).ToArray())
            foreach (var cancer in RulePolicies.Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.MarkRound != s.Turn.WorldRound && c.Position.DistanceTo(dendritic.Position) <= 2).ToArray())
                s = ApplyMark(s, cancer.Id, dendritic);
        return s;
    }

    /// <summary>施加【标记】（同一世界回合同一癌细胞只能获得一次；树突【抗原呈递强化】为 2 次）。</summary>
    public static WorldState ApplyMark(WorldState s, EntityId targetId, Cell by)
    {
        var target = s.Cells[targetId];
        if (target.MarkRound == s.Turn.WorldRound) return s;
        var charges = by.Faction == Faction.Immune && by.Type == CellType.Dendritic && RulePolicies.HasSkill(s, by, "抗原呈递强化") ? 2 : 1;
        return s.UpdateCell(targetId, target.Copy(marked: true, markRound: s.Turn.WorldRound, markLeft: Math.Max(target.MarkLeft, charges)));
    }

    public static WorldState Teleport(WorldState s, EntityId id, HexPosition dest)
    {
        var c = s.Cells[id];
        s = s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(dest, id);
        s = s.UpdateCell(id, c.Copy(position: dest, campRound: -1));
        var tile = s.Board.Tissues[dest];
        if (c.Faction == Faction.Cancer && tile.State == TissueState.Healthy)
        {
            s = s.UpdateTissueState(dest, TissueState.Cancer);
            s = s.WithBoard(s.Board.UpdateTissue(dest, s.Board.Tissues[dest].WithNewborn(true)));
        }
        else if (c.Faction == Faction.Immune && tile.State == TissueState.Cancer)
        {
            s = s.UpdateTissueState(dest, TissueState.Healthy);
            s = AddMemory(s, 1);
        }
        return s;
    }

    public static WorldState CollectEnergy(WorldState s, EntityId id)
    {
        var c = s.Cells[id];
        var t = s.Board.Tissues[c.Position];
        if (t.Type == TissueType.MetabolicCore && t.Charge > 0)
        {
            s = s.UpdateCell(id, c.WithEnergy(c.Energy + t.Charge.Value));
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithCharge(0)));
        }
        return s;
    }

    public static WorldState AddToHand(WorldState s, Cell cell, string name)
    {
        var hand = cell.Hand.ToList();
        hand.Add(name);
        s = s.UpdateCell(cell.Id, cell.Copy(hand: hand));
        return hand.Count > cell.HandMax ? s.WithTurn(s.Turn.WithPendingDiscard(cell.OwnerSeat)) : s;
    }

    /// <summary>世界回合 S 阶段开头：重置「每世界回合」额度与修饰（旧实现 _reset_round_flags）。</summary>
    public static WorldState ResetRoundFlags(WorldState s)
    {
        foreach (var c in RulePolicies.Cells(s))
            s = s.UpdateCell(c.Id, c.Copy(toxin: 0, mutateUsed: false, antibody: 0, metastasis: false, jump: 0, armor: false,
                fxRound: [],
                modifiers: c.Modifiers.Where(m => m.Duration != ModifierDuration.Round).ToList()));
        return s;
    }

    // ==== 永久技能的「第一次」闸门 ====
    //
    // 对齐 GDScript 的 `CWGame.first_this_turn` / `first_this_round`（cw_game.gd:596-612）。
    // 那边是「查+记账」一把做完并返回「这一次是不是第一次」；C# 状态不可变，
    // 所以拆成**只读的问**与**写状态的烧**两半 —— 报价、预演这类只读场合只调前者，
    // 免得把闸门白白烧掉（GD 那边专门为此写了警告注释）。

    /// <summary>
    /// 「每行动回合前 N 次」的额度，不写 = 1 次（GD 侧 CWCost.GATE_USES）。
    ///
    /// GD 那张表今天只有一行【组织驻留】= 2，而 C# 的【组织驻留】还没走闸门 ——
    /// 它是一条 `Uses: 2` 的 Free Move 修饰，**行为一致、只是额度记在 `mods` 里**。
    /// 搬它要连 GD 的 `Store.GATE`（修饰在表里、额度在 fx_turn 里）一起搬，是下一张工单；
    /// 在那之前这里不预先写死一个没人读的数。
    /// </summary>
    private static int GateUses(string key) => 1;

    /// <summary>这个「每行动回合」闸门还开着吗（只读，不记账）。</summary>
    public static bool TurnGateOpen(Cell c, string key) => c.FxTurn.GetValueOrDefault(key) < GateUses(key);

    /// <summary>这个「每世界回合」闸门还开着吗（只读，不记账）。</summary>
    public static bool RoundGateOpen(Cell c, string key) => !c.FxRound.Contains(key);

    /// <summary>烧掉一次「每行动回合」额度。</summary>
    public static WorldState BurnTurnGate(WorldState s, EntityId id, string key)
    {
        var c = s.Cells[id];
        return s.UpdateCell(id, c.Copy(fxTurn: new Dictionary<string, int>(c.FxTurn) { [key] = c.FxTurn.GetValueOrDefault(key) + 1 }));
    }

    /// <summary>关上一个「每世界回合」闸门。</summary>
    public static WorldState BurnRoundGate(WorldState s, EntityId id, string key)
    {
        var c = s.Cells[id];
        return s.UpdateCell(id, c.Copy(fxRound: [.. c.FxRound, key]));
    }

    /// <summary>移动合法性的域内校验（不包含阶段/回合/存活等公共前提，由编排层先行检查）。</summary>
    public static ValidationResult ValidateMove(WorldState s, MoveDecision move)
    {
        if (!s.Cells.TryGetValue(move.CellId, out var cell) || !cell.IsAlive)
            return new(false, "细胞不存在或已死亡");
        if (cell.OwnerSeat != move.PlayerSeat) return new(false, "不能移动其他玩家的细胞");
        if (!s.Board.Tissues.TryGetValue(move.TargetPosition, out var target)) return new(false, "目标位置不在棋盘内");
        var cost = RulePolicies.QuoteMove(s, cell, move.TargetPosition);
        if (cost == null) return new(false, "目标位置不可达或被占据");
        if (cell.Energy <= cost) return new(false, "能量不足，非自毁费用必须保留正能量");
        if (target.OccupyingCell.HasValue && cell.AttacksThisTurn >= 3) return new(false, "攻击次数已达上限");
        return new(true);
    }

    /// <summary>
    /// 移动/攻击/净化/定殖结算（PRD J 组）。净化触发的跨域反应（如【免疫记忆库】免费抽卡）
    /// 通过发出 <see cref="PurifyResolvedFact"/> 交给 <see cref="FactRouter"/> 分派，保持 CellRules 不反向依赖卡域。
    /// </summary>
    /// <param name="free">
    /// 真免费：**不进费用管线**、也不消耗任何限次修饰（巨噬【连续吞噬】的连锁跳用它）。
    /// 实付 0 顺带让【I-吞噬】那条「回量不超过实付 −0.1」自然算出 0，不用另写分支。
    /// </param>
    public static RulesResult Move(WorldState s, MoveDecision move, IDeterministicRng rng, bool free = false)
    {
        var cell = s.Cells[move.CellId];
        var cost = free ? 0 : RulePolicies.QuoteMove(s, cell, move.TargetPosition)!.Value;
        var target = s.GetCellAt(move.TargetPosition);
        var events = new List<IGameEvent>();
        var attacker = cell.Copy(energy: cell.Energy - cost);
        s = s.UpdateCell(cell.Id, attacker);
        if (!free) s = ConsumeModifiers(s, cell.Id, ModifierTarget.Move, move.TargetPosition);
        if (target != null)
        {
            // 六面骰，**1..6**。原来写的是 NextInt(6)，那产出 0..5 —— 而 AttackOutcome 判
            // `roll == 6` 为暴击，于是暴击永远掷不出来（实测 60000 次 crit 0%，应为 16.7%）。
            // 用 NextIntRange(1, 7)（半开）而不是 NextInt(6) + 1：把「1..6」写进代码里，
            // 下一个人不用去推。PRD 只给概率不给面数，骰面值域由 Kevin 2026-09-15 裁定为 6 面。
            var roll = rng.NextIntRange(1, 7);
            var attackerCell = s.Cells[cell.Id];
            var attackMods = attackerCell.Modifiers.Where(m => m.Target == ModifierTarget.Attack).ToList();
            var attackExtra = attackMods.Sum(m => m.Value);
            var hasOpsonin = attackMods.Any(m => m.Card == "补体调理");
            var hasAffinity = attackMods.Any(m => m.Card == "高亲和力克隆");
            var hasCascade = attackMods.Any(m => m.Card == "补体级联");
            s = ConsumeModifiers(s, cell.Id, ModifierTarget.Attack);
            var outcome = hasAffinity ? "crit" : RulePolicies.AttackOutcome(s, roll, attackerCell);
            if (outcome == "fail" && hasOpsonin)
            {
                roll = rng.NextIntRange(1, 7);   // 【补体调理】的重掷，同样是 1..6
                outcome = RulePolicies.AttackOutcome(s, roll, s.Cells[cell.Id]);
            }
            if (HasModifier(s.Cells[target.Id], "PD-L1表达"))
            {
                outcome = outcome == "crit" ? "success" : "fail";  // 大成功→成功、成功/无效→无效
                s = RemoveModifiers(s, target.Id, "PD-L1表达");
            }
            var damage = outcome == "fail" ? 0 : outcome == "crit" ? 20 : 10;
            var extra = 0;
            if (outcome != "fail")
            {
                extra = attackExtra;
                // 【连续吞噬】连续净化攒的加成：**用掉即清**，不按回合过期
                var chain = s.Cells[cell.Id].ChainBonus;
                if (chain > 0)
                {
                    extra += chain;
                    s = s.UpdateCell(cell.Id, s.Cells[cell.Id].Copy(chainBonus: 0));
                }
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "抗体亲和力成熟") && RulePolicies.AdjacentHealthy(s, move.TargetPosition)) extra += 5;
            }
            attacker = s.Cells[cell.Id].Copy(attacks: cell.AttacksThisTurn + 1);
            s = s.UpdateCell(cell.Id, attacker);
            if (damage == 0) s = Damage(s, cell.Id, 5);
            else
            {
                var actual = Math.Min(target.Energy, damage);
                s = Damage(s, target.Id, damage + extra);
                s = AddMemory(s, actual / 10);
                // 【吞噬体成熟】：攻击成功后目标余量不超过阈值则直接死亡
                var threshold = s.Cells[cell.Id].Type == CellType.Macrophage ? 15 : 5;
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "吞噬体成熟") && s.Cells[target.Id].IsAlive && s.Cells[target.Id].Energy <= threshold)
                {
                    s = Damage(s, target.Id, s.Cells[target.Id].Energy);
                    if (s.Cells[cell.Id].Type == CellType.Macrophage)
                        s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
                }
                // 【补体级联】：攻击成功后转化目标相邻最多 2 格无细胞占据的普通癌组织
                if (hasCascade)
                {
                    var cascade = target.Position.GetNeighbors()
                        .Where(n => s.Board.Tissues.TryGetValue(n, out var x) && x.State == TissueState.Cancer && x.OccupyingCell == null)
                        .ToArray();
                    foreach (var pick in rng.Shuffle(cascade).Take(2))
                        s = s.UpdateTissueState(pick, TissueState.Healthy);
                }
                // 【I-吞噬】：攻击成功造成能量损失后恢复受击方损失的 1/2（向上取整到十分位）
                if (s.Cells[cell.Id].Type == CellType.Macrophage)
                {
                    var loss = Math.Min(target.Energy, damage + extra);
                    var heal = (loss + 1) / 2;
                    if (heal > 0) s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
                }
            }
            events.Add(new CellAttackedEvent(s.Turn.WorldRound, s.Turn.Phase, cell.Id, target.Id, damage, !s.Cells[target.Id].IsAlive));
            if (s.Cells[target.Id].IsAlive || !s.Cells[cell.Id].IsAlive) return new(UpdateMarks(s), events, true);
        }
        s = s.UpdateTissueOccupant(cell.Position, null).UpdateTissueOccupant(move.TargetPosition, cell.Id);
        s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithPosition(move.TargetPosition).Copy(campRound: -1));
        var tissue = s.Board.Tissues[move.TargetPosition];
        if (cell.Faction == Faction.Immune && tissue.Mucus)
        {
            s = s.WithBoard(s.Board.UpdateTissue(move.TargetPosition, tissue.WithMucus(false)));
            tissue = s.Board.Tissues[move.TargetPosition];
        }
        if (cell.Faction == Faction.Immune && tissue.State == TissueState.Cancer)
        {
            if (tissue.OssifyAtRound > 0)
            {
                // 骨样硬化标记格：进入不能立即净化，须停留到世界回合结束
                s = s.UpdateCell(cell.Id, s.Cells[cell.Id].Copy(campRound: s.Turn.WorldRound, campPosition: move.TargetPosition));
            }
            else
            {
                s = s.UpdateTissueState(move.TargetPosition, TissueState.Healthy);
                s = AddMemory(s, 1);
                events.Add(new TissueStateChangedEvent(s.Turn.WorldRound, s.Turn.Phase, move.TargetPosition, tissue.State, TissueState.Healthy));
                // 【I-吞噬】：巨噬细胞通过【迁移】触发净化后恢复，回量不超过本次实付 -0.1
                if (s.Cells[cell.Id].Type == CellType.Macrophage)
                {
                    var heal = Math.Max(0, Math.Min(2, cost - 1));   // 【I-吞噬】回 0.2（PRD:597，09-12 覆盖版 0.3→0.2）；上限「实付 −0.1」照旧
                    if (heal > 0) s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
                }
                // 【免疫记忆库】等净化跨域反应：发出已提交事实，由 FactRouter 按目录稳定顺序分派
                s = FactRouter.Emit(s, new PurifyResolvedFact(s.Turn.WorldRound, cell.Id), rng);
                // 巨噬【连续吞噬】：净化之后**当场**接着走（PRD:605）。
                // GD 那边是个 await 循环 + `chain_running` 再入闸；这里每一跳是一个独立决策，
                // 所以挂起等玩家选就行，不需要那道闸。
                if (s.Cells[cell.Id].Type == CellType.Macrophage && s.Cells[cell.Id].ChainLeft > 0
                        && ChainTargets(s, s.Cells[cell.Id]).Count > 0)
                    s = s.WithTurn(s.Turn.WithPendingChain(cell.Id));
                // 【模式识别增强】：每世界回合第一次【净化】后恢复 0.5 能量
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "模式识别增强") && RoundGateOpen(s.Cells[cell.Id], "模式识别增强"))
                {
                    s = BurnRoundGate(s, cell.Id, "模式识别增强");
                    s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
                }
                // 【效应记忆形成】：每世界回合第一次【净化】后免疫方 +1 抗原记忆、自身恢复 0.5
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "效应记忆形成") && RoundGateOpen(s.Cells[cell.Id], "效应记忆形成"))
                {
                    s = BurnRoundGate(s, cell.Id, "效应记忆形成");
                    s = AddMemory(s, 1);
                    s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
                }
            }
        }
        else if (cell.Faction == Faction.Cancer && tissue.State == TissueState.Healthy)
        {
            s = s.UpdateTissueState(move.TargetPosition, TissueState.Cancer);
            s = s.WithBoard(s.Board.UpdateTissue(move.TargetPosition, s.Board.Tissues[move.TargetPosition].WithNewborn(true)));
            events.Add(new TissueStateChangedEvent(s.Turn.WorldRound, s.Turn.Phase, move.TargetPosition, tissue.State, TissueState.Cancer));
            // 【RAS持续激活】：每行动回合第一次通过【移动】触发【定殖】后恢复
            if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "RAS持续激活") && TurnGateOpen(s.Cells[cell.Id], "RAS持续激活"))
            {
                var heal = RulePolicies.CancerPhase(s.Turn.WorldRound) switch { 0 => 3, 1 => 5, _ => 7 };
                s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
                s = BurnTurnGate(s, cell.Id, "RAS持续激活");
            }
        }
        s = CollectEnergy(s, cell.Id);
        events.Add(new CellMovedEvent(s.Turn.WorldRound, s.Turn.Phase, cell.Id, cell.Position, move.TargetPosition, cost));
        return new(UpdateMarks(s), events, true);
    }
}
