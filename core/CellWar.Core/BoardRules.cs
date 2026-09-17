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
    /// <summary>S.1：特殊组织生产（含产出即收取）。血管传送是下一步 <see cref="Transport"/> —— 中间可能要问玩家
    /// （踩着存卡骨髓抽到连走卡 / 撑爆手牌 / 抽到【基因组不稳定】），GD `round_start` 是 await 问完才传送。</summary>
    public static WorldState Produce(WorldState s, IDeterministicRng rng)
    {
        s = ResetRoundFlags(s);
        foreach (var pos in Tiles(s).Select(x => x.Position).ToArray())
        {
            var t = s.Board.Tissues[pos];   // 现读（GD cw_world.gd:105 拿的是活引用）：上一格收取时的结算可能已经改了这一格（【骨髓动员】存卡、【全身性免疫清除】翻面），拿进循环时的快照写回会把它盖掉
            if (t.NecrosisRounds > 0) continue;   // 坏死期间不产也不攒（GD _tissue_production，Kevin 2026-09-13 issue #31）
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
            if (t.Type != TissueType.MetabolicCore && t.Type != TissueType.BoneMarrow) continue;
            var cap = t.Type == TissueType.MetabolicCore ? MetabolicCoreStoreMax : BoneMarrowStoreMax;
            var charge = Math.Min(cap, current + gain);
            if (nextProd != prod || gain != 0)
                s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithProductionCounter(nextProd).WithCharge(charge)));
            // 有存货且有细胞站着就当场收取（GD `if store > 0 or cards > 0: collect_special(here[0])`，不看这回合有没有新产出）：
            // 代谢核心收能量 **或** 骨髓抽卡 —— 骨髓那一抽是带子上的一发，此前 C# 只收能量，
            // 2p / 6p 轨迹一录出来就各在第一次骨髓产出时少念一条（2026-09-17）
            if (charge > 0 && s.GetCellAt(t.Position) is { IsAlive: true } occupant)
                s = CollectSpecial(s, occupant.Id, rng);
        }
        return s;
    }

    /// <summary>S.2 血管传送 = GD `_vessel_teleport`（cw_world.gd:133-165）：两端都空就没事；**哪一端坏死整条作废**；两边都有就交换
    /// （不分阵营 —— 旧的「敌对同格则取消」已作废）；先送 a 端（GD VESSELS[0] = (6,0)）的细胞到 b、再送 b 端的到 a，
    /// 每次落地都是完整的 `enter_tile`（定殖 / 蹲守 / 净化 → 黏液 → collect_special → 标记）。
    /// 此前 C# 自写了一遍：留着作废条款、无坏死闸、一次性换位、只收能量不抽卡、无标记刷新（2026-09-18）。【营养输送】那一挂随世界事件整块不做。</summary>
    public static WorldState Transport(WorldState s, IDeterministicRng rng)
    {
        var vessels = Tiles(s).Where(t => t.Type == TissueType.BloodVessel).OrderByDescending(t => t.Position.Q).ToArray();
        if (vessels.Length != 2) return s;
        var a = vessels[0].Position;
        var b = vessels[1].Position;
        var ca = s.GetCellAt(a);
        var cb = s.GetCellAt(b);
        if (ca is null && cb is null) return s;
        if (s.Board.Tissues[a].NecrosisRounds > 0 || s.Board.Tissues[b].NecrosisRounds > 0) return s;
        // C# 的占位是格上的字段（GD 靠扫细胞坐标）：先把两端占位整体换好，再按 GD 的先后各落地一次
        s = s.UpdateTissueOccupant(a, cb?.Id).UpdateTissueOccupant(b, ca?.Id);
        if (ca is not null) s = CellRules.ArriveAndLand(s.UpdateCell(ca.Id, s.Cells[ca.Id].WithPosition(b)), ca.Id, b, rng);
        if (cb is not null) s = CellRules.ArriveAndLand(s.UpdateCell(cb.Id, s.Cells[cb.Id].WithPosition(a)), cb.Id, a, rng);
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
    public static WorldState EvolveEndOfRound(WorldState s, IDeterministicRng rng) => EvolveEndOfRoundB(EvolveEndOfRoundA(s, rng), rng);

    /// <summary>E 阶段前半（1 → 4.9）：到蹲守净化为止 —— 它可能追出要问玩家的（【连续吞噬】、记忆库抽卡带出的走位…），后半要等问完。</summary>
    public static WorldState EvolveEndOfRoundA(WorldState s, IDeterministicRng rng)
    {
        s = Anaerobic(s);                              // 1  【无氧呼吸】
        s = CancerUpkeep(s);                           // 1.5 【代谢消耗】（PRD 之外的平衡候选③）
        s = Pressure(s);                               // 2  【微环境压迫】
        var fresh = Proliferate(s, rng, out s);        // 3  【增生】
        s = Erosion(s, rng, fresh);                    // 4  【侵蚀】
        s = ResolveCamping(s, rng);                    // 4.9 骨样硬化标记格上的蹲守净化
        return s;
    }

    /// <summary>E 阶段后半（5 → 9.5）。</summary>
    public static WorldState EvolveEndOfRoundB(WorldState s, IDeterministicRng rng)
    {
        s = Solidify(s);                               // 5  【固化】
        s = Rooted(s, rng);                            // 5  【根深蒂固】
        s = Ossify(s);                                 // 5  骨肉瘤【骨样硬化】标记到期
        s = Decay(s);                                  // 6  固化计数衰减
        s = MarkAdhesion(s);                           // 7  树突【E-组织黏连】
        // 7 【紊乱】返回原位 —— C# 未实现（世界事件，EV-1）
        s = TickDurations(s);                          // 8  世界事件 / 全局修饰倒计时
        // 8 「本世界回合」时长的**细胞身上**那些修饰，改在下一个 S 阶段的 ResetRoundFlags 里清
        //   （E 步 8 到下一个 S 之间没有别的结算，等价）
        s = TickNecrosis(s);                           // 8  「坏死」倒计时
        // 8 【I-趋化源】**源本身**不在这里过期 —— 它走的是另一套时钟（「持续 n **完整回合**」，
        //   PhaseRules.TickFullTurn，每个席位开打前各走一格）。GD 那边专门警告过「两套时钟别混」。
        s = TickChemoCooldown(s);                      // 8  趋化源的**技能冷却**（这条才是世界回合制）
        s = TickChemoTrack(s);                         // 8  【免疫猎杀】的追踪趋化源倒计时
        s = ExpireMarks(s);                            // 8  树突【I-标记】到期
        s = ClearNewborn(s);                           // 9  移除「新生」
        s = CapEnergy(s);                              // 9.5 能量上限（PRD 之外，口径 #92）
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
    /// 1.5 【代谢消耗】（平衡候选③，PRD 之外，默认关）：每个癌细胞按**当前能量的百分比**自动损能。
    ///
    /// 团队 2026-09-01 定的三条口径，每条都有代价，别顺手改（照抄 GD 的注释）：
    ///   ① 扣在【无氧呼吸】**之后** —— 所以税的是「存款 + 这回合刚进的账」，不只是存款；
    ///   ② **不算伤害事件** —— 不走伤害管线，【缺氧适应】【囊性护甲】【耗竭抵抗】一概挡不住，
    ///      BCL-2 也不介入。它是「代谢开销」不是「谁打了谁」，进管线会让一堆减伤牌凭空多出一层用途；
    ///   ③ 向下取整（整数除法）。
    ///
    /// ⚠ **它杀不死细胞**，这是数学性质不是防呆：按比例扣永远到不了 0，
    /// 而且能量低到 `energy × pct < 100` 时整除直接得 0。正因为杀不死人，这里不需要死亡检查。
    /// </summary>
    private static WorldState CancerUpkeep(WorldState s)
    {
        var pct = s.Tuning.CancerUpkeepPercent;
        if (pct <= 0) return s;
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer).ToArray())
        {
            var lost = s.Cells[c.Id].Energy * pct / 100;
            if (lost > 0) s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy - lost));
        }
        return s;
    }

    /// <summary>
    /// 9.5 【E-能量上限】：所有**存活**细胞（两个阵营都算）的能量削到上限；0 = 不启用。
    /// 管的是**存量不是流量** —— 囤积是靠这个封的（口径 #92）。
    /// </summary>
    private static WorldState CapEnergy(WorldState s)
    {
        var cap = s.Tuning.EnergyCap;
        if (cap <= 0) return s;
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Energy > cap).ToArray())
            s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(cap));
        return s;
    }

    /// <summary>
    /// 2 【E-微环境压迫】：损失 = max(0, 1/4 ×(相邻癌组织 + 相邻固化癌组织×2 − 相邻健康组织))，按分期加成。
    /// </summary>
    private static WorldState Pressure(WorldState s)
    {
        // 算式住在 `RulePolicies.PressureAt`（纯查询，L0 靶场与 AI 也读它）——
        // 这里只负责「对谁扣、扣下去」。**来源报给管线**：【耗竭抵抗】的第二句要看它。
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune))
        {
            var loss = RulePolicies.PressureAt(s, s.Cells[c.Id].Position);
            // 压不到就**不进管线**（GD `_pressure` 的 `if loss <= 0: continue`）：一次 0 伤害的 Damage 也会把
            // 【细胞膜修复】那类一次性护盾白白吃掉（L1 第 131 步：席位 0 四周全是健康组织，GD 的盾还在、C# 的没了）
            if (loss <= 0) continue;
            s = Damage(s, c.Id, loss, LossSource.World, "微环境压迫");
        }
        return s;
    }

    /// <summary>
    /// 3 【E-增生】：每格非癌性组织按相邻癌性格数与块内固化数掷点转化。
    /// 返回**本轮新造出来的格子**交给【侵蚀】—— PRD 的「注」要求侵蚀不拿它们当来源
    /// （Kevin 2026-09-09 定的读法）。
    /// </summary>
    internal static IReadOnlyCollection<HexPosition> Proliferate(WorldState s, IDeterministicRng rng, out WorldState next)
    {
        // **整批同时结算**：算概率一律拿**增生之前**那份盘面
        // （GD 明写「先转的格不该成为后转格的来源」）。算式住在 `RulePolicies.ProliferateChance`。
        var beforeGrowth = s;
        var fresh = new List<HexPosition>();
        foreach (var t in Tiles(beforeGrowth))
        {
            var chance = ProliferateChance(beforeGrowth, t.Position);
            // 概率为 0 就**不掷骰**（GD 同）—— 被【免疫监视】盯着的格子随之少消耗一次 rng，
            // 而随机数带子逐笔对齐，少掷一次就是一条差异
            if (chance <= 0) continue;
            // **整数千分位掷点**，对齐 GDScript 的 `randi_range(1, 1000) <= chance`。
            // 为什么必须是整数：随机数带子记的是整数区间抽取，浮点在带子上**没有任何对应物** ——
            // 实测不改的话 2 人局跑 40 步就撞 64 条 RNG_NO_COUNTERPART，而 E 阶段每回合走约 27 次。
            // `NextIntRange(1, 1001)`（半开）同样出 1..1000，同样判 `<=`。
            if (rng.NextIntRange(1, 1001) <= chance)
            {
                s = CardRules.ToCancer(s, t.Position, newborn: true);   // GD `CWTissue.to_cancer(tile, true)`，与【侵蚀】同一入口
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
    internal static WorldState Erosion(WorldState s, IDeterministicRng rng, IReadOnlyCollection<HexPosition> fresh)
    {
        // 形状照 GD `_erosion`（cw_world.gd）：**全盘一份**候选表（各封闭健康块按 GD 的块序 / 块内序拼起来）、
        // **一次** d3 定格数、**一次** pick_n。此前 C# 是逐块各掷一次 d3 各挑一次 —— 两个封闭块就多一个 d3，
        // L1 第 56 步的带子上 GD 是 [1,3] 后接 [0,1]（候选只有 2 格），C# 要第二个 [1,3]（2026-09-17）。
        // 候选顺序必须逐格同 GD：pick_n 抽的是下标。
        var eligible = new List<HexPosition>();
        foreach (var block in GdBlocks(s, t => !Cancerous(t)))
        {
            if (block.Any(p => p.GetNeighbors().Any(n => !s.Board.Tissues.ContainsKey(n)))) continue;   // 与棋盘外缘连接 → 未被完全包围
            foreach (var p in block)
            {
                if (s.GetCellAt(p)?.Faction == Faction.Immune) continue;   // 免疫细胞所在格无法被侵蚀
                if (Watched(s, p)) continue;                                // 【免疫监视】守护范围内不能被侵蚀
                // 本回合增生刚造的格子不算「来源」——它要到下一世界回合才参与侵蚀结算
                if (p.GetNeighbors().Any(n => s.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t) && !fresh.Contains(n)))
                    eligible.Add(p);
            }
        }
        if (eligible.Count == 0) return s;
        // 2/3 概率取常见值、1/3 取少见值。**掷的是 d3（1..3）判 `<= 2`**，逐位对齐 GD 的 `roll_d3()` = `randi_range(1, 3)`
        // （抽取区间才是带子记的东西，`NextInt(3) < 2` 概率一样、区间不一样）。格数按肿瘤分期查表。
        var tiles = RuleTuning.ByStage(s.Tuning.ErosionTiles, Stage(s));
        var count = rng.NextIntRange(1, 4) <= 2 ? tiles.Common : tiles.Rare;
        foreach (var p in rng.PickRandom(eligible, count))
            s = CardRules.ToCancer(s, p, newborn: true);   // GD `CWTissue.to_cancer(tile, true)`
        return s;
    }

    /// <summary>
    /// 4.9 骨样硬化标记格上的蹲守净化：免疫踏进标记格不能立刻净化，得在那儿站到世界回合结束。
    /// 挪过窝、或格子已固化/被别人净化，标记作废。**排在【固化】之前**（GD 同序）。
    /// </summary>
    private static WorldState ResolveCamping(WorldState s, IDeterministicRng rng)
    {
        foreach (var loopCell in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune && c.CampRound >= 0).ToArray())
        {
            var at = loopCell.CampPosition;
            var cell = s.Cells[loopCell.Id].Copy(campRound: -1);
            s = s.UpdateCell(loopCell.Id, cell);
            if (at is not { } atPos || cell.Position != atPos) continue;
            if (s.Board.Tissues[atPos].State != TissueState.Cancer) continue;
            // GD `_resolve_camping` → `purify_here(cell, at, -1)`：整条净化口径（转健康、记忆闸、巨噬不回能、_on_purify 三张技能）。
            // 此前 C# 是裸翻面 + 无条件记忆。【连续吞噬】GD 会在 E 阶段当场追问 —— 这里照样挂起，PhaseRules 停在 EndStep 1 等答完（2026-09-18）
            s = CellRules.PurifyHere(s, loopCell.Id, atPos, -1, rng);
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
        if (WorldEffects.SolidFrozen(s, pos)) return s;      // 【TNF-α局部炎症】：冻结名单在事件容器里
        if (t.Type == TissueType.BloodVessel) return s;        // 血管不可固化
        var count = t.SolidificationCount + amount;
        s = s.UpdateTissueSolidification(pos, count);
        return count >= SolidifyThreshold(s) ? s.UpdateTissueState(pos, TissueState.SolidifiedCancer) : s;
    }

    /// <summary>固化门槛：走旋钮（默认 I 期 3.0，II/III 期 2.0）。</summary>
    internal static int SolidifyThreshold(WorldState s) => RuleTuning.ByStage(s.Tuning.SolidifyThreshold, Stage(s));

    /// <summary>5 【E-固化】：有癌细胞停留的癌组织按格加计数（说明 #22；同一格只算一次）。</summary>
    private static WorldState Solidify(WorldState s)
    {
        var counted = new HashSet<HexPosition>();
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer))
        {
            if (!counted.Add(c.Position)) continue;
            var tile = s.Board.Tissues[c.Position];
            if (tile.State != TissueState.Cancer) continue;
            // 「新生」保护是旋钮（Kevin 2026-09-04 拍板取消，默认关）：关掉后当回合新铺的格子当回合就累计
            if (s.Tuning.NewbornProtect && tile.Newborn) continue;
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
            // 候选按 GD DIRS 序（`game.neighbors`）：pick_random 抽的是下标，序不同就抽到不同的格（2p 第 85 步，2026-09-17）
            var targets = GdNeighbors(s, t.Position).Where(n => s.Board.Tissues[n].State == TissueState.Cancer).ToArray();
            if (targets.Length == 0) continue;
            foreach (var n in rng.PickRandom(targets, limit)) s = RaiseSolid(s, n, 10);
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
    /// 【基质稳定】在场那一回合整步跳过（GD 也是直接 return）。
    /// </summary>
    private static WorldState Decay(WorldState s)
    {
        if (WorldEffects.Active(s, "基质稳定")) return s;
        foreach (var t in Tiles(s).Where(t => t.State == TissueState.Cancer && t.SolidificationCount > 0))
        {
            var occupant = s.GetCellAt(t.Position);
            if (occupant is { IsAlive: true, Faction: Faction.Cancer }) continue;
            s = s.UpdateTissueSolidification(t.Position, Math.Max(0, t.SolidificationCount - 5));
        }
        return s;
    }

    /// <summary>
    /// 7 树突【E-组织黏连】（PRD:579）：被标记的癌细胞把标记传染给 2 环内的所有癌细胞，
    /// **本阶段造成的感染不会再次感染**。
    ///
    /// 「不会再次感染」靠**先把传染源快照下来**做到（GD `_mark_adhesion` 同法）——
    /// 边传边加进源集合的话，一次 E 阶段就能顺着一串癌细胞蔓延到天边。
    ///
    /// 场上没有树突就整步不发生：标记是树突的机制，`ApplyMark` 还要拿它判
    /// 【抗原呈递强化】给 1 层还是 2 层。取**第一只**树突，与 GD 同。
    /// </summary>
    private static WorldState MarkAdhesion(WorldState s)
    {
        var dendritic = Cells(s).FirstOrDefault(c => c.IsAlive && c.Faction == Faction.Immune && c.Type == CellType.Dendritic);
        if (dendritic == null) return s;

        // **先快照**：本阶段新染上的不能再当源
        var carriers = Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Marked)
            .Select(c => c.Position).ToArray();
        if (carriers.Length == 0) return s;

        foreach (var target in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && !c.Marked).ToArray())
            if (carriers.Any(src => target.Position.DistanceTo(src) <= AdhesionRange))
                s = ApplyMark(s, target.Id, dendritic);
        return s;
    }

    /// <summary>【E-组织黏连】的传染范围（GD `ADHESION_RANGE`，PRD「2 环内」）。</summary>
    internal const int AdhesionRange = 2;

    /// <summary>
    /// 8 世界事件与卡牌全局修饰的倒计时：每条 `Left` −1，归零移除。
    /// 对齐 GD 的 `CWWorldFx.tick_durations()`。
    /// </summary>
    private static WorldState TickDurations(WorldState s)
    {
        if (s.Effects.Count > 0) s = s.Copy(effects: s.Effects.Select(e => e.Tick()).Where(e => !e.Expired).ToList());
        return CellRules.ExpireRoundModifiers(s);   // GD tick_durations 末尾 `clear_mods(cell, "round")`
    }

    /// <summary>8 「坏死」倒计时。</summary>
    private static WorldState TickNecrosis(WorldState s)
    {
        foreach (var t in Tiles(s).Where(t => t.NecrosisRounds > 0))
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithNecrosis(t.NecrosisRounds - 1)));
        return s;
    }

    /// <summary>【趋化源】消散后的技能冷却回合数（GD `CHEMO_COOLDOWN_ROUNDS`）。</summary>
    internal const int ChemoCooldownRounds = 1;

    /// <summary>8 【免疫猎杀】附着的【追踪趋化源】倒计时：每个世界回合末 −1，归零即消散。</summary>
    private static WorldState TickChemoTrack(WorldState s)
    {
        if (s.Turn.TrackRounds <= 0) return s;
        var left = s.Turn.TrackRounds - 1;
        return s.WithTurn(left > 0
            ? s.Turn.Copy(trackRounds: left)
            : s.Turn.WithTrack(null, null, 0));
    }

    /// <summary>8 树突【I-趋化源】的技能冷却：每个世界回合末 −1，归零即可再次建立。</summary>
    private static WorldState TickChemoCooldown(WorldState s)
    {
        foreach (var c in Cells(s).Where(c => c.ChemoCooldown > 0).ToArray())
            s = s.UpdateCell(c.Id, s.Cells[c.Id].Copy(chemoCooldown: s.Cells[c.Id].ChemoCooldown - 1));
        return s;
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
