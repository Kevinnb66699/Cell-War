using static CellWar.Core.CellRules;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 棋盘与组织演化所有权域（对应三层设计的 BoardRules）：
/// S 阶段特殊组织生产/血管传送，E 阶段微环境压迫、增生、侵蚀、无氧呼吸、蹲守净化、固化与特殊状态计时。
/// 只做棋盘/组织层演化，不决定阶段转换与胜负（分别由 PhaseRules 编排与 <see cref="OutcomeRules"/> 判定）。
/// </summary>
internal static class BoardRules
{
    /// <summary>S.1/S.2：特殊组织生产（含产出即收取）与血管传送。</summary>
    public static WorldState ProduceAndTransport(WorldState s)
    {
        s = ResetRoundFlags(s);
        foreach (var t in Tiles(s))
        {
            var current = t.Charge ?? 0;
            var prod = t.ProductionCounter;
            var nextProd = prod;
            var gain = 0;
            switch (t.Type)
            {
                case TissueType.MetabolicCore:
                    if (t.State == TissueState.Healthy)
                    {
                        nextProd = prod + 1;
                        if (nextProd >= 2) { nextProd = 0; gain = 10; }
                    }
                    else gain = 4;  // 癌性：每世界回合 +0.4
                    break;
                case TissueType.BoneMarrow:
                    nextProd = prod + 1;
                    if (nextProd >= (t.State == TissueState.Healthy ? 3 : 2)) { nextProd = 0; gain = 1; }
                    break;
            }
            if (nextProd == prod && gain == 0) continue;
            var cap = t.Type == TissueType.MetabolicCore ? MetabolicCoreStoreMax : BoneMarrowStoreMax;
            var charge = Math.Min(cap, current + gain);
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithProductionCounter(nextProd).WithCharge(charge)));
            // 产出瞬间站在其上的细胞立即收取（旧实现 collect_special）
            if (charge > 0 && s.GetCellAt(t.Position) is { IsAlive: true } occupant)
                s = CollectEnergy(s, occupant.Id);
        }
        return Transport(s);
    }

    public static WorldState Transport(WorldState s)
    {
        var vessels = Tiles(s).Where(t => t.Type == TissueType.BloodVessel).ToArray();
        if (vessels.Length != 2) return s;
        var a = s.GetCellAt(vessels[0].Position);
        var b = s.GetCellAt(vessels[1].Position);
        if (a != null && b != null && a.Faction != b.Faction) return s;
        s = s.UpdateTissueOccupant(vessels[0].Position, b?.Id).UpdateTissueOccupant(vessels[1].Position, a?.Id);
        if (a != null) s = s.UpdateCell(a.Id, a.WithPosition(vessels[1].Position));
        if (b != null) s = s.UpdateCell(b.Id, b.WithPosition(vessels[0].Position));
        foreach (var c in new[] { a, b }.OfType<Cell>())
        {
            var position = s.Cells[c.Id].Position;
            if (c.Faction == Faction.Cancer && s.Board.Tissues[position].State == TissueState.Healthy)
            {
                s = s.UpdateTissueState(position, TissueState.Cancer);
                s = s.WithBoard(s.Board.UpdateTissue(position, s.Board.Tissues[position].WithNewborn(true)));
            }
            else if (c.Faction == Faction.Immune && s.Board.Tissues[position].State == TissueState.Cancer)
                s = s.UpdateTissueState(position, TissueState.Healthy);
            s = CollectEnergy(s, c.Id);
        }
        return s;
    }
    /// <summary>
    /// E 阶段组织演化。**步序逐条对齐 GDScript 的 `CWWorld.e_phase()`（cw_world.gd:53-82）** ——
    /// 那边把 E 阶段写成 21 个具名步、每步一行并标着 PRD 的步号；
    /// C# 这边 2026-09-15 之前是一个 125 行的大函数，**顺序和 GD 对不上**，而且没人看得出来。
    ///
    /// 拆开之后当场暴露两条真差异（见各步自己的注释）：
    ///   · 【无氧呼吸】GD 是**第 1 步**、算的是**增生/侵蚀之前**那份盘面；C# 算在它们之后
    ///   · 【根深蒂固】加的计数 GD 走 `raise_solid`（门槛 / TNF-α 冻结 / 血管三道判据），C# 全绕过了
    ///
    /// 不改变 Turn.Phase，也不决定胜负（由 <see cref="OutcomeRules.Evaluate"/> 负责）。
    /// </summary>
    public static WorldState EvolveEndOfRound(WorldState s, IDeterministicRng rng)
    {
        s = Anaerobic(s);                              // 1  【无氧呼吸】
        // 1.5 【代谢消耗】—— C# 未实现。GD 侧是 PRD 之外的平衡候选③（旋钮 cancer_upkeep_pct，默认关）。
        s = Pressure(s);                               // 2  【微环境压迫】
        var fresh = Proliferate(s, rng, out s);        // 3  【增生】
        s = Erosion(s, rng, fresh);                    // 4  【侵蚀】
        s = ResolveCamping(s);                         // 4.9 骨样硬化标记格上的蹲守净化
        s = Solidify(s);                               // 5  【固化】
        s = Rooted(s, rng);                            // 5  【根深蒂固】
        s = Ossify(s);                                 // 5  骨肉瘤【骨样硬化】标记到期
        s = Decay(s);                                  // 6  固化计数衰减
        // 7 树突【E-组织黏连】/【紊乱】返回原位 —— C# 未实现
        // 8 世界事件倒计时 + 「本世界回合」修饰过期 —— C# 没有事件容器；
        //   Round 时长的修饰改在下一个 S 阶段的 ResetRoundFlags 里清（其间没有别的结算，等价）
        s = TickNecrosis(s);                           // 8  「坏死」倒计时
        // 8 树突【I-趋化源】技能冷却 / 【免疫猎杀】追踪源倒计时 —— C# 没有 chemo_cd / chemo_track
        s = TickChemo(s);                              // 8  趋化源本身的存续回合
        s = ExpireMarks(s);                            // 8  树突【I-标记】到期
        s = ClearNewborn(s);                           // 9  移除「新生」
        // 9.5 能量上限 —— C# 未实现（旋钮 energy_cap，PRD 之外）
        return s;                                      // 10 胜负检查由 PhaseRules 编排
    }

    /// <summary>
    /// 1 【E-无氧呼吸】：每个癌性连通块的池子按块内癌细胞均分。
    ///
    /// **它是第 1 步，算的是本回合增生/侵蚀之前那份盘面**（GD `e_phase()` 第一行）。
    /// C# 原来排在增生+侵蚀之后、还重算了一遍连通块 —— 于是每个世界回合都按
    /// **长大之后**的盘面发钱，癌方稳定多收。E 阶段每回合都走，这条差异是累积的。
    /// </summary>
    private static WorldState Anaerobic(WorldState s)
    {
        var blocks = Blocks(s, true);
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer))
        {
            if (!blocks.Any(b => b.Contains(c.Position))) continue;
            s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy + AnaerobicShare(s, c)));
        }
        return s;
    }

    /// <summary>
    /// 2 【E-微环境压迫】：损失 = max(0, 1/4 ×(相邻癌组织 + 相邻固化癌组织×2 − 相邻健康组织))，按分期加成。
    /// </summary>
    private static WorldState Pressure(WorldState s)
    {
        var stage = Stage(s);
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune))
        {
            var pressure = s.Board.GetAdjacentPositions(c.Position).Sum(p => s.Board.Tissues[p].State switch
                { TissueState.Healthy => -1, TissueState.Cancer => 1, _ => 2 });
            var loss = Settlement.RoundTenth(Math.Max(0, pressure) * 10.0 / 4);
            if (stage == 2) loss = loss * 3 / 2;
            else if (stage == 3) loss = loss * 2;
            // 【耗竭抵抗】后半句（PRD:1277 第二段）：「结算【微环境压迫】时，自身受到的能量损失**额外 -0.5**，最低为 0」。
            // 前半句（每世界回合首次损失 -1.0）挂在 PhaseRules 的 EnergyLoss 修饰上；
            // 这一句**只在压迫这一条路上**生效，而 CellRules.Damage 不知道「谁造成的」——
            // 所以在调用点减，这是唯一不用给整条伤害管线加来源参数的位置。
            // 对齐 GDScript 的 cw_damage.gd:271-272（`if ev["ability"] == "微环境压迫"`）。
            if (RulePolicies.HasSkill(s, c, "耗竭抵抗")) loss = Math.Max(0, loss - 5);
            s = Damage(s, c.Id, loss);
        }
        return s;
    }

    /// <summary>
    /// 3 【E-增生】：每格非癌性组织按相邻癌性格数与块内固化数掷点转化。
    /// 返回**本轮新造出来的格子**交给【侵蚀】—— PRD 的「注」要求侵蚀不拿它们当来源
    /// （Kevin 2026-09-09 定的读法）。
    /// </summary>
    private static IReadOnlyCollection<HexPosition> Proliferate(WorldState s, IDeterministicRng rng, out WorldState next)
    {
        var stage = Stage(s);
        var beforeGrowth = s;
        var cancerBlocks = Blocks(s, true);
        var fresh = new List<HexPosition>();
        foreach (var t in Tiles(beforeGrowth).Where(t => !Cancerous(t) && s.GetCellAt(t.Position)?.Faction != Faction.Immune && !Watched(s, t.Position)))
        {
            var adjacent = t.Position.GetNeighbors().Where(p => beforeGrowth.Board.Tissues.TryGetValue(p, out var n) && Cancerous(n)).ToArray();
            if (adjacent.Length == 0) continue;
            var solid = cancerBlocks.Where(b => adjacent.Any(b.Contains)).Sum(b => b.Count(p => beforeGrowth.Board.Tissues[p].State == TissueState.SolidifiedCancer));
            // **整数千分位掷点**，对齐 GDScript 侧 cw_world.gd:709-722 的
            // `n_adj * (rate + per_solid * solids)` 再 `randi_range(1, 1000) <= chance`。
            //
            // 为什么必须是整数：这是双内核对拍的硬阻塞。随机数带子记的是整数区间抽取，
            // 浮点抽取在带子上**没有任何对应物** —— 实测不改的话 2 人局跑 40 步就撞
            // 64 条 RNG_NO_COUNTERPART，而 E 阶段 100% 走这一行、每回合约 27 次。
            //
            // 比较方向也对齐：`randi_range(1,1000)` 出 1..1000、判 `<= chance`；
            // 这里 `NextIntRange(1, 1001)`（半开）同样出 1..1000，同样判 `<=`。
            var permille = (stage == 1 ? 30 : stage == 2 ? 35 : 40) + solid * (stage == 1 ? 5 : 10);
            if (rng.NextIntRange(1, 1001) <= adjacent.Length * permille)
            {
                s = s.UpdateTissueState(t.Position, TissueState.Cancer);
                s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithNewborn(true)));
                fresh.Add(t.Position);
            }
        }
        next = s;
        return fresh;
    }

    /// <summary>
    /// 4 【E-侵蚀】：每个**封闭的**健康连通块里随机若干格转癌。
    /// `fresh` 是本轮【增生】刚造出来的格子，不得当作侵蚀的来源（PRD 的「注」）。
    /// </summary>
    private static WorldState Erosion(WorldState s, IDeterministicRng rng, IReadOnlyCollection<HexPosition> fresh)
    {
        var stage = Stage(s);
        foreach (var block in Blocks(s, false))
        {
            if (block.Any(p => p.GetNeighbors().Any(n => !s.Board.Tissues.ContainsKey(n)))) continue;
            var candidates = block.OrderBy(p => p.Q).ThenBy(p => p.R).Where(p => s.GetCellAt(p)?.Faction != Faction.Immune && !Watched(s, p) &&
                p.GetNeighbors().Any(n => s.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t) && !fresh.Contains(n))).ToArray();
            if (candidates.Length == 0) continue;
            var count = rng.NextInt(3) < 2 ? (stage == 3 ? 3 : 2) : (stage == 3 ? 5 : 3);
            foreach (var p in rng.Shuffle(candidates).Take(count))
            {
                s = s.UpdateTissueState(p, TissueState.Cancer);
                s = s.WithBoard(s.Board.UpdateTissue(p, s.Board.Tissues[p].WithNewborn(true)));
            }
        }
        return s;
    }

    /// <summary>
    /// 4.9 骨样硬化标记格上的蹲守净化：免疫踏进标记格不能立刻净化，得在那儿站到世界回合结束。
    /// 挪过窝、或格子已固化/被别人净化，标记作废。**排在【固化】之前**（GD 同序）。
    /// </summary>
    private static WorldState ResolveCamping(WorldState s)
    {
        foreach (var loopCell in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune && c.CampRound >= 0).ToArray())
        {
            var at = loopCell.CampPosition;
            var cell = s.Cells[loopCell.Id].Copy(campRound: -1);
            s = s.UpdateCell(loopCell.Id, cell);
            if (at is not { } atPos || cell.Position != atPos) continue;
            if (s.Board.Tissues[atPos].State != TissueState.Cancer) continue;
            s = s.UpdateTissueState(atPos, TissueState.Healthy);
            s = AddMemory(s, 1);
        }
        return s;
    }

    /// <summary>
    /// **加固化计数的唯一口子**，对齐 GDScript 的 `CWGame.raise_solid()`（cw_game.gd:628-640）。
    /// 三道判据都在这里，调用方不许自己写：
    ///   · 【TNF-α局部炎症】冻住的格本世界回合不得增加计数
    ///   · 血管不可固化（Kevin 2026-09-06）
    ///   · 加完够门槛就**当场**转固化癌组织
    ///
    /// 2026-09-15 补：C# 此前【根深蒂固】直接改字段，三道判据一道都没过 ——
    /// 于是它能给血管、给被 TNF-α 冻住的格加计数，而且推过门槛也要等下一回合才转。
    /// </summary>
    internal static WorldState RaiseSolid(WorldState s, HexPosition pos, int amount)
    {
        var t = s.Board.Tissues[pos];
        if (t.SolidLockRound == s.Turn.WorldRound) return s;   // 【TNF-α局部炎症】
        if (t.Type == TissueType.BloodVessel) return s;        // 血管不可固化
        var count = t.SolidificationCount + amount;
        s = s.UpdateTissueSolidification(pos, count);
        return count >= SolidifyThreshold(s) ? s.UpdateTissueState(pos, TissueState.SolidifiedCancer) : s;
    }

    /// <summary>固化门槛：环境恶化 I 期 3.0，II/III 期 2.0。</summary>
    internal static int SolidifyThreshold(WorldState s) => Stage(s) == 1 ? 30 : 20;

    /// <summary>5 【E-固化】：有癌细胞停留的癌组织按格加计数（说明 #22；同一格只算一次）。</summary>
    private static WorldState Solidify(WorldState s)
    {
        var counted = new HashSet<HexPosition>();
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer))
        {
            if (!counted.Add(c.Position)) continue;
            if (s.Board.Tissues[c.Position].State != TissueState.Cancer) continue;
            s = RaiseSolid(s, c.Position, 10);
        }
        return s;
    }

    /// <summary>
    /// 5 【根深蒂固】（环境恶化 II/III 期）：每格固化癌组织随机使相邻最多 1/3 格癌组织计数 +1.0。
    /// 走 <see cref="RaiseSolid"/> —— 门槛、TNF-α 冻结、血管三道判据一道都不能少。
    /// </summary>
    private static WorldState Rooted(WorldState s, IDeterministicRng rng)
    {
        var stage = Stage(s);
        if (stage < 2) return s;
        var limit = stage == 2 ? 1 : 3;
        foreach (var t in Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer)
                     .OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R).ToArray())
        {
            var targets = t.Position.GetNeighbors()
                .Where(n => s.Board.Tissues.TryGetValue(n, out var x) && x.State == TissueState.Cancer).ToArray();
            if (targets.Length == 0) continue;
            foreach (var n in rng.Shuffle(targets).Take(limit)) s = RaiseSolid(s, n, 10);
        }
        return s;
    }

    /// <summary>5 骨肉瘤【骨样硬化】标记到期：到期那一回合的 E 阶段转固化癌组织。</summary>
    private static WorldState Ossify(WorldState s)
    {
        foreach (var t in Tiles(s).Where(t => t.OssifyAtRound > 0).ToArray())
        {
            if (s.Turn.WorldRound < t.OssifyAtRound) continue;
            if (s.Board.Tissues[t.Position].State == TissueState.Cancer)
                s = s.UpdateTissueState(t.Position, TissueState.SolidifiedCancer);
            else
                s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithOssifyAt(0)));
        }
        return s;
    }

    /// <summary>
    /// 6 固化计数衰减：**没有癌细胞停留**的癌组织每回合 −0.5。
    /// 【基质稳定】那一回合整步跳过（GD 是直接 return，C# 这边判 PausedDecayRound）。
    /// </summary>
    private static WorldState Decay(WorldState s)
    {
        if (s.Turn.PausedDecayRound == s.Turn.WorldRound) return s;
        foreach (var t in Tiles(s).Where(t => t.State == TissueState.Cancer && t.SolidificationCount > 0))
        {
            var occupant = s.GetCellAt(t.Position);
            if (occupant is { IsAlive: true, Faction: Faction.Cancer }) continue;
            s = s.UpdateTissueSolidification(t.Position, Math.Max(0, t.SolidificationCount - 5));
        }
        return s;
    }

    /// <summary>8 「坏死」倒计时。</summary>
    private static WorldState TickNecrosis(WorldState s)
    {
        foreach (var t in Tiles(s).Where(t => t.NecrosisRounds > 0))
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithNecrosis(t.NecrosisRounds - 1)));
        return s;
    }

    /// <summary>8 树突【I-趋化源】的存续回合。</summary>
    private static WorldState TickChemo(WorldState s)
    {
        if (s.Turn.ChemoRounds <= 0) return s;
        var rounds = s.Turn.ChemoRounds - 1;
        return s.WithTurn(s.Turn.WithChemo(rounds > 0 ? s.Turn.ChemoAt : null, rounds, rounds > 0 ? s.Turn.ChemoOwner : -1));
    }

    /// <summary>
    /// 8 树突【I-标记】到期：标记后**第二次**世界回合结算移除（PRD 2026-09-12）。
    ///
    /// 2026-09-15 补：C# 此前**根本没有这一步** —— 标记一旦挂上就永不过期，
    /// 只能靠「被一次伤害消费掉」摘除。而标记是 ×2 倍伤，挂着不掉是实打实的强化。
    /// 口径照 GDScript 的 `_expire_marks()`（cw_world.gd:1201-1211）：`round_no >= mark_round + 1` 即移除。
    /// </summary>
    private static WorldState ExpireMarks(WorldState s)
    {
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Marked).ToArray())
        {
            // 没记施加回合的（测试手摆的）按本回合算，与 GD 的 `born < 0` 分支同口径
            var born = c.MarkRound < 0 ? s.Turn.WorldRound : c.MarkRound;
            if (s.Turn.WorldRound >= born + 1) s = s.UpdateCell(c.Id, s.Cells[c.Id].Copy(marked: false, markLeft: 0));
        }
        return s;
    }

    /// <summary>9 移除「新生」标记。</summary>
    private static WorldState ClearNewborn(WorldState s)
    {
        foreach (var t in Tiles(s).Where(t => t.Newborn))
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithNewborn(false)));
        return s;
    }
}
