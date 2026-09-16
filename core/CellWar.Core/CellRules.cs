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
        if (c.Type == CellType.Osteosarcoma && s.Board.Tissues[c.Position].State == TissueState.SolidifiedCancer)
            modifiers.Add(new ValueModifier(ModifierStage.Multiply, SourceLayer.Passive, 0, 40));  // 【刚性屏障】×40%
        amount = Settlement.ApplyEnergyLoss(amount, modifiers);
        s = ConsumeModifiers(s, id, ModifierTarget.EnergyLoss);
        c = s.Cells[id];
        // 印戒【囊性护甲】：每世界回合第一次能量损失 -0.5，不限来源
        if (c.Type == CellType.SignetRing && !c.ArmorUsedThisRound)
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
        var charges = by.Faction == Faction.Immune && by.Type == CellType.Dendritic && by.Equipped.Contains("抗原呈递强化") ? 2 : 1;
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
                modifiers: c.Modifiers.Where(m => m.Duration != ModifierDuration.Round).ToList()));
        return s;
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
    public static RulesResult Move(WorldState s, MoveDecision move, IDeterministicRng rng)
    {
        var cell = s.Cells[move.CellId];
        var cost = RulePolicies.QuoteMove(s, cell, move.TargetPosition)!.Value;
        var target = s.GetCellAt(move.TargetPosition);
        var events = new List<IGameEvent>();
        var attacker = cell.Copy(energy: cell.Energy - cost);
        s = s.UpdateCell(cell.Id, attacker);
        s = ConsumeModifiers(s, cell.Id, ModifierTarget.Move, move.TargetPosition);
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
            var outcome = hasAffinity ? "crit" : RulePolicies.AttackOutcome(roll, attackerCell);
            if (outcome == "fail" && hasOpsonin)
            {
                roll = rng.NextIntRange(1, 7);   // 【补体调理】的重掷，同样是 1..6
                outcome = RulePolicies.AttackOutcome(roll, s.Cells[cell.Id]);
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
                if (s.Cells[cell.Id].Equipped.Contains("抗体亲和力成熟") && RulePolicies.AdjacentHealthy(s, move.TargetPosition)) extra += 5;
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
                if (s.Cells[cell.Id].Equipped.Contains("吞噬体成熟") && s.Cells[target.Id].IsAlive && s.Cells[target.Id].Energy <= threshold)
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
                    var heal = Math.Max(0, Math.Min(3, cost - 1));
                    if (heal > 0) s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
                }
                // 【免疫记忆库】等净化跨域反应：发出已提交事实，由 FactRouter 按目录稳定顺序分派
                s = FactRouter.Emit(s, new PurifyResolvedFact(s.Turn.WorldRound, cell.Id), rng);
                // 【模式识别增强】：每世界回合第一次【净化】后恢复 0.5 能量
                if (s.Cells[cell.Id].Equipped.Contains("模式识别增强") && !HasModifier(s.Cells[cell.Id], "模式识别增强"))
                {
                    s = AddModifier(s, s.Cells[cell.Id], new("模式识别增强", ModifierTarget.Move, ModifierStage.Add, SourceLayer.Passive, 0, 0, null, 1, ModifierDuration.Round));
                    s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
                }
                // 【效应记忆形成】：每世界回合第一次【净化】后免疫方 +1 抗原记忆、自身恢复 0.5
                if (s.Cells[cell.Id].Equipped.Contains("效应记忆形成") && !HasModifier(s.Cells[cell.Id], "效应记忆形成"))
                {
                    s = AddModifier(s, s.Cells[cell.Id], new("效应记忆形成", ModifierTarget.Move, ModifierStage.Add, SourceLayer.Passive, 0, 0, null, 1, ModifierDuration.Round));
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
            if (s.Cells[cell.Id].Equipped.Contains("RAS持续激活") && !HasModifier(s.Cells[cell.Id], "RAS持续激活"))
            {
                var heal = RulePolicies.CancerPhase(s.Turn.WorldRound) switch { 0 => 3, 1 => 5, _ => 7 };
                s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
                s = AddModifier(s, s.Cells[cell.Id], new("RAS持续激活", ModifierTarget.Move, ModifierStage.Add, SourceLayer.Passive, 0, 0, null, 1, ModifierDuration.Turn));
            }
        }
        s = CollectEnergy(s, cell.Id);
        events.Add(new CellMovedEvent(s.Turn.WorldRound, s.Turn.Phase, cell.Id, cell.Position, move.TargetPosition, cost));
        return new(UpdateMarks(s), events, true);
    }
}
