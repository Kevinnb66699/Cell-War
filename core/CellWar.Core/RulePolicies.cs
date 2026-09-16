using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>规划路径的一步：目标格、这一步的费用（十分位）、是否合法/付得起、阻挡原因、踩核心获得的能量。</summary>
public sealed record PathStep(HexPosition To, int Cost, bool Legal, bool Afford, string Reason, int Gain);

/// <summary>整条规划路径的报价：逐步模拟【定殖】/【净化】与代谢核心收入，纯查询不消耗任何额度。</summary>
public sealed record PathQuote(ImmutableArray<PathStep> Steps, int Total, int Gained, bool Ok, int Left, int Stop);

/// <summary>
/// 规则纯策略与只读查询：数值公式、几何、棋盘连通块等，不修改世界状态。
/// 对应离散事件架构的三层设计「RulePolicies」所有权域，供各规则域与卡牌共用。
/// 移动费用、呼吸收入、压迫/增生数值、投影派生值都必须从这里取，避免各域二次实现公式。
/// </summary>
internal static class RulePolicies
{
    public const int MetabolicCoreStoreMax = 20;  // 2.0 能量的十分位
    public const int BoneMarrowStoreMax = 1;

    /// <summary>能量单位（如 2.5）→ 整数十分能量（25）。所有落库数值都走这里。</summary>
    public static int Round(double energyUnits) => Settlement.RoundTenth(energyUnits * 10);

    /// <summary>整数十分能量 → 能量单位（仅用于显示/投影与浮点公式）。</summary>
    public static double U(int tenths) => tenths / 10.0;

    public static IEnumerable<Tissue> Tiles(WorldState s) => s.Board.Tissues.Values.OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R);
    public static IEnumerable<Cell> Cells(WorldState s) => s.Cells.Values.OrderBy(c => c.OwnerSeat).ThenBy(c => c.Id.Value);
    public static bool Cancerous(Tissue t) => t.State != TissueState.Healthy;

    /// <summary>World-round stage; owns the solidification threshold used by the E phase.</summary>
    public static int Stage(WorldState s) => s.Turn.WorldRound <= 5 ? 1 : s.Turn.WorldRound <= 10 ? 2 : 3;

    /// <summary>肿瘤分期（癌症卡权重与部分效果用）：世界回合 1-5 / 6-10 / 11+。</summary>
    public static int CancerPhase(int round) => round <= 5 ? 0 : round <= 10 ? 1 : 2;

    /// <summary>Solidification progress 0..1 for presentation; healthy 0, solidified 1. -1 means not applicable.</summary>
    public static double SolidFraction(WorldState s, Tissue t)
    {
        if (t.State == TissueState.Healthy) return 0;
        if (t.State == TissueState.SolidifiedCancer) return 1;
        if (t.Type == TissueType.BloodVessel) return 0;
        return Math.Clamp((double)t.SolidificationCount / (Stage(s) == 1 ? 30 : 20), 0, 1);
    }

    /// <summary>Store fill 0..1 for metabolic core / bone marrow; -1 for other tissues.</summary>
    public static double StoreFraction(Tissue t) => t.Type switch
    {
        TissueType.MetabolicCore => Math.Clamp((t.Charge ?? 0) / (double)MetabolicCoreStoreMax, 0, 1),
        TissueType.BoneMarrow => Math.Clamp(t.Charge ?? 0, 0, 1),
        _ => -1
    };

    public static int BaseMoveCost(WorldState s, Cell c, HexPosition destination)
    {
        var cancerous = Cancerous(s.Board.Tissues[destination]);
        var modifiers = c.Modifiers.Where(m => m.Target == ModifierTarget.Move && RequirementMet(m.Requirement, cancerous))
            .Select(m => m.ToValueModifier()).ToList();
        // 【I-趋化源】是**场上实体**，不住在任何人的 mods / equipped 里，单独发一条
        // （GD 侧 cw_cost.gd:347-350 也是 `_collect()` 里单独 emit）。
        if (ChemoModifier(s, c, destination) is { } chemo) modifiers.Add(chemo);
        return Settlement.ApplyValue(RawMoveCost(s, c, destination), modifiers);
    }

    public static bool RequirementMet(ModifierRequirement requirement, bool cancerous) => requirement switch
    {
        ModifierRequirement.MoveToHealthy => !cancerous,
        ModifierRequirement.MoveToCancerous => cancerous,
        _ => true
    };

    /// <summary>移动基础费用（整数十分能量，与旧实现一致）。</summary>
    public static int RawMoveCost(WorldState s, Cell c, HexPosition destination)
    {
        var target = s.Board.Tissues[destination];
        var disabled = s.Turn.CancerEffectsDisabledUntil >= s.Turn.WorldRound;  // 【中和抗体】
        int cost;
        if (c.Faction == Faction.Cancer)
        {
            if (Cancerous(target)) cost = 2;                       // 0.2
            else if (!disabled && c.Type == CellType.SmallCellLung) cost = 7;   // 【极简胞浆】0.7
            else if (!disabled && c.Type == CellType.Melanoma)
            {
                var adjacent = destination.GetNeighbors().Count(n => s.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t));
                cost = adjacent >= 3 ? Math.Max(0, 5 - 1 * (adjacent - 3)) : 12;  // 【伪足穿透】
            }
            else cost = 12;                                        // 1.2
        }
        else
        {
            cost = !Cancerous(target) ? 5
                : s.Players[c.OwnerSeat].ImmuneLevel switch { ImmuneLevel.I => 10, ImmuneLevel.II => 8, _ => 8 };   // III/X 不再另有减免（Kevin 2026-09-15 按 PRD 裁定：只有 II 级那句 0.8）
        }
        if (c.Faction == Faction.Immune && target.Mucus) cost += 2;  // 免疫迁入「黏液侵染」格 +0.2
        return cost;
    }

    /// <summary>
    /// 树突【I-趋化源】的百分比费用修饰，没命中就返回 null。
    ///
    /// 2026-09-15 从 `RawMoveCost` 里搬出来。搬之前它是**烤进基础费用**的，
    /// 也就是在整条修饰管线**之前**乘掉；GD 侧它是管线里的 MULT/DIV 条目，
    /// 排在固定加费（黏液侵染）与固定减费（LFA-1黏附 / 组织浸润 / 组织巡航·减）**之后**。
    /// 这个位置差会直接改数：
    ///   免疫 I 级、装【LFA-1黏附】、朝趋化源走上癌组织（基础 1.0）
    ///     GD : 1.0 → 减费 max(0.2, 1.0−0.4)=0.6 → ×70% → 0.4
    ///     C#旧: 1.0 → ×70% = 0.7 → 减费 max(0.2, 0.7−0.4)=0.3
    ///
    /// 三档百分比与 GD 的 `CWData.CHEMO_*_PCT` 同源：自身 50 / 其余免疫 70 / 癌方 120。
    /// 「自身」认的是**建立者的席位**（GD 判 `chemo["by"] == actor["pid"]`），不是「是不是树突」。
    ///
    /// 两条方向互斥（一条只认免疫、一条只认癌方），所以一次最多命中一条 ——
    /// 这也是把 GD 的 DIV（免疫减免）与 MULT（癌方加价）在这里都落到 Multiply 的前提：
    /// C# 的 `ValueModifier` 没有 GD 那套 `pct` / `value` 双语义，
    /// 而 Multiply 恰好就是「×Value%」。两条不互斥了就必须重新看阶段。
    ///
    /// **仍缺**：GD 还有 `chemo_track`（【免疫猎杀】附着的追踪趋化源，走同一套修饰），
    /// C# 里根本没有这个状态 —— 另一张工单。
    /// </summary>
    public static ValueModifier? ChemoModifier(WorldState s, Cell c, HexPosition destination)
    {
        if (s.Turn.ChemoRounds <= 0 || s.Turn.ChemoAt is not { } chemo) return null;
        var before = c.Position.DistanceTo(chemo);
        var after = destination.DistanceTo(chemo);
        int pct;
        if (c.Faction == Faction.Immune && after < before) pct = c.OwnerSeat == s.Turn.ChemoOwner ? 50 : 70;
        else if (c.Faction == Faction.Cancer && after > before) pct = 120;
        else return null;
        return new ValueModifier(ModifierStage.Multiply, SourceLayer.Skill, 0, pct, Name: "趋化源");
    }

    /// <summary>
    /// 沿 path（依次要落脚的格，不含起点）逐格报价，等价于旧实现的 `CWActions.quote_path`：
    /// 每步费用随走到那一步时的盘面（定殖/净化翻面、踩核心收能量）逐步变化，所以必须由引擎模拟。
    /// 只模拟影响费用或余额的三件事：细胞位置、组织按【定殖】/【净化】翻面、踩【代谢核心】收能量。
    /// 纯查询：不改动传入世界，通过结构共享只复制被修改的小块状态。
    /// </summary>
    public static PathQuote QuotePath(WorldState s, Cell cell, IReadOnlyList<HexPosition> path)
    {
        var world = s;
        var current = cell;
        var budget = cell.Energy;
        var total = 0;
        var gained = 0;
        var stop = -1;
        var steps = new List<PathStep>();
        for (var i = 0; i < path.Count; i++)
        {
            var to = path[i];
            var quote = QuoteMove(world, current, to);
            var cost = quote ?? 0;
            var occupied = world.GetCellAt(to) != null;
            string reason;
            if (occupied) reason = "有细胞占据 —— 攻击请单独点它";
            else if (quote == null) reason = "走不到这一格";
            else if (!Settlement.CanPay(budget, cost)) reason = $"能量只剩 {U(budget)}，这一步要 {U(cost)} —— 付完至少要留 0.1";
            else reason = "";
            var legal = reason == "";
            var afford = legal;
            var gain = 0;
            steps.Add(new PathStep(to, cost, legal, afford, reason, gain));
            if (!afford) { stop = i; break; }
            budget -= cost;
            total += cost;
            var tile = world.Board.Tissues[to];
            if (tile.Type == TissueType.MetabolicCore && (tile.Charge ?? 0) > 0)
            {
                gain = tile.Charge!.Value;
                gained += gain;
                budget += gain;
                world = world.WithBoard(world.Board.UpdateTissue(to, tile.WithCharge(0)));
            }
            if (current.Faction == Faction.Cancer && tile.State == TissueState.Healthy)
                world = world.UpdateTissueState(to, TissueState.Cancer);
            else if (current.Faction == Faction.Immune && tile.State == TissueState.Cancer)
                world = world.UpdateTissueState(to, TissueState.Healthy);
            world = world.UpdateTissueOccupant(current.Position, null).UpdateTissueOccupant(to, current.Id);
            current = current.WithPosition(to);
            steps[i] = steps[i] with { Gain = gain };
        }
        return new(steps.ToImmutableArray(), total, gained, stop < 0, budget, stop);
    }

    public static int? QuoteMove(WorldState s, Cell cell, HexPosition destination)
    {
        if (!s.Board.Tissues.ContainsKey(destination) || destination == cell.Position) return null;
        var occupant = s.GetCellAt(destination);
        if (cell.Type == CellType.Dendritic && occupant != null) return null;  // 【各司其职】：树突不能向癌细胞移动
        if (occupant != null && (occupant.Faction == cell.Faction || cell.Faction != Faction.Immune || !occupant.IsAlive)) return null;
        if (cell.Position.DistanceTo(destination) == 1) return BaseMoveCost(s, cell, destination);
        if (occupant != null) return null; // Passing through allies cannot launch an attack.
        if (PassThroughMap(s, cell).TryGetValue(destination, out var cost)) return cost;
        return null;
    }

    /// <summary>
    /// 借道前进的落点表：{ 落点 → 总费用 }。与旧实现 `CWActions.pass_through_map` 等价 ——
    /// 从自己出发只在友军占据的格上扩展，任何到达过的友军格相邻的空格都是合法落点，
    /// 费用 = 走到那个友军格的累计 + 落点自己的费用，取最便宜的一条（Dijkstra 小规模版）。
    /// 本来就与自己相邻的格不进这张表（普通迁移更便宜）。
    /// </summary>
    public static Dictionary<HexPosition, int> PassThroughMap(WorldState s, Cell cell)
    {
        var outMap = new Dictionary<HexPosition, int>();
        var reached = new Dictionary<HexPosition, int>();
        var queue = new Queue<HexPosition>();
        foreach (var n in cell.Position.GetNeighbors())
        {
            if (!AllyTile(s, cell, n)) continue;
            reached[n] = BaseMoveCost(s, cell, n);
            queue.Enqueue(n);
        }
        while (queue.Count > 0)
        {
            var cur = queue.Dequeue();
            var acc = reached[cur];
            foreach (var m in cur.GetNeighbors())
            {
                if (m == cell.Position || !s.Board.Tissues.ContainsKey(m)) continue;
                var total = acc + BaseMoveCost(s, cell, m);
                if (AllyTile(s, cell, m))
                {
                    if (!reached.TryGetValue(m, out var previous) || total < previous)
                    {
                        reached[m] = total;
                        queue.Enqueue(m);
                    }
                }
                else if (s.GetCellAt(m) == null)
                {
                    if (!outMap.TryGetValue(m, out var prev) || total < prev) outMap[m] = total;
                }
            }
        }
        foreach (var n in cell.Position.GetNeighbors()) outMap.Remove(n);
        return outMap;
    }

    /// <summary>借道前进的可落点：所有穿过友军可达的空格。</summary>
    public static IEnumerable<HexPosition> PassThroughDests(WorldState s, Cell cell)
    {
        foreach (var n in cell.Position.GetNeighbors())
            if (s.GetCellAt(n) == null) yield return n;
        foreach (var far in PassThroughMap(s, cell).Keys)
            if (s.GetCellAt(far) == null) yield return far;
    }

    private static bool AllyTile(WorldState s, Cell cell, HexPosition pos)
    {
        var occ = s.GetCellAt(pos);
        return occ != null && occ.IsAlive && occ.Faction == cell.Faction;
    }

    /// <summary>树突【I-标记】光环：2 环内有免疫细胞装备【免疫监视】时压制增生/侵蚀。</summary>
    public static bool Watched(WorldState s, HexPosition pos)
        => Cells(s).Any(c => c.IsAlive && c.Faction == Faction.Immune && c.Equipped.Contains("免疫监视") && c.Position.DistanceTo(pos) <= 3);

    public static List<HashSet<HexPosition>> Blocks(WorldState s, bool cancerous)
    {
        var result = new List<HashSet<HexPosition>>();
        var visited = new HashSet<HexPosition>();
        foreach (var t in Tiles(s).Where(t => Cancerous(t) == cancerous))
        {
            if (!visited.Add(t.Position)) continue;
            var block = new HashSet<HexPosition> { t.Position };
            var queue = new Queue<HexPosition>(); queue.Enqueue(t.Position);
            while (queue.TryDequeue(out var p))
                foreach (var n in p.GetNeighbors())
                    if (s.Board.Tissues.TryGetValue(n, out var tile) && Cancerous(tile) == cancerous && visited.Add(n))
                    { block.Add(n); queue.Enqueue(n); }
            result.Add(block);
        }
        return result;
    }

    public static bool AdjacentHealthy(WorldState s, HexPosition pos)
        => pos.GetNeighbors().Any(n => s.Board.Tissues.TryGetValue(n, out var t) && t.State == TissueState.Healthy);

    public static bool AdjacentCancerous(WorldState s, HexPosition pos, int atLeast)
        => pos.GetNeighbors().Count(n => s.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t)) >= atLeast;

    public static int AnaerobicShare(WorldState s, Cell c)
    {
        var block = Blocks(s, true).FirstOrDefault(b => b.Contains(c.Position));
        if (block == null) return 0;
        var living = s.Cells.Values.Count(x => x.IsAlive && x.Faction == Faction.Cancer && block.Contains(x.Position));
        var ordinary = block.Count(p => s.Board.Tissues[p].State == TissueState.Cancer);
        var solid = Tiles(s).Count(t => t.State == TissueState.SolidifiedCancer);
        // 2026-09-15 按 GDScript 对齐（Kevin 裁定）。原来写死 `six ? 0.35 : 0.3` 与 `six ? 2.8 : 2.0`，
        // 两处都和权威实现对不上：
        //   · **指数**：六人 0.35 只活了一个白天 —— issue #29 当晚就改回 0.3，
        //     GDScript 的 ANAEROBIC_BLOCK_EXP_BY_PLAYERS 是 {2:30, 4:30, 6:30}，**三档全是 0.30**；
        //   · **系数**：GDScript 的 ANAEROBIC_BLOCK_COEF_BY_PLAYERS 是 {2:28, 4:20, 6:28} ——
        //     **2 人局是 2.8 不是 2.0**，而这里的 `six ? … : 2.0` 把 2 人局也当成了 2.0。
        // 这两条会让双内核对拍在 E 阶段直接分叉（无氧每回合都走）。
        // 表里没有的人数退回缺省（balance_scan 会扫 5 人 / 7 人这类非正式人数，不能崩）。
        var coefPermille = s.Players.Count switch { 4 => 200, _ => 280 };   // 十分能量 ×100：2.0 / 2.8
        var expPermille = 30;                                              // 百分数：三档都是 0.30
        var income = Round(Math.Max(2.0, (Math.Pow(ordinary, expPermille / 100.0) * (coefPermille / 100.0) + solid) / Math.Max(1, living)));
        var disabled = s.Turn.CancerEffectsDisabledUntil >= s.Turn.WorldRound;  // 【中和抗体】
        if (!disabled && c.Type == CellType.SmallCellLung) income = (int)Math.Ceiling(income * 1.1);  // 【瓦伯格超速糖酵解】110% 向上取整到十分位
        if (!disabled && c.Equipped.Contains("GLUT1高表达")) income += CancerPhase(s.Turn.WorldRound) switch { 0 => 5, 1 => 8, _ => 10 };
        return income;
    }

    public static int AerobicShare(WorldState s, Cell c)
    {
        var income = s.Players[c.OwnerSeat].ImmuneLevel switch
            { ImmuneLevel.I => 20, ImmuneLevel.II => 30, ImmuneLevel.III => 45, _ => 50 };
        if (c.Equipped.Contains("代谢适应")) income += 5;        // 每次结算有氧额外 +0.5
        if (c.Equipped.Contains("自分泌生存信号")) income += 8;  // 每次结算有氧额外 +0.8
        for (var i = 0; i < s.Turn.TgfStacks; i++) income = income * 80 / 100;  // 【TGF-β释放】每层 -20% 向下取整
        if (s.Board.Tissues[c.Position].NecrosisRounds > 0) income = Settlement.RoundTenth(income * 0.5);
        return income;
    }

    public static HexPosition? RandomHealthyWithin(WorldState s, HexPosition center, int rings, IDeterministicRng rng)
    {
        var options = Tiles(s).Where(t => t.State == TissueState.Healthy && t.OccupyingCell == null && t.Position.DistanceTo(center) <= rings).ToArray();
        return options.Length == 0 ? null : options[rng.NextInt(options.Length)].Position;
    }

    public static HexPosition? RandomCancerousWithin(WorldState s, HexPosition center, int rings, IDeterministicRng rng)
    {
        var options = Tiles(s).Where(t => Cancerous(t) && t.OccupyingCell == null && t.Position.DistanceTo(center) <= rings).ToArray();
        return options.Length == 0 ? null : options[rng.NextInt(options.Length)].Position;
    }

    /// <summary>含起点的随机连通区域（放疗用），最多 count 格。</summary>
    public static List<HexPosition> ConnectedRegion(WorldState s, HexPosition start, int count, IDeterministicRng rng)
    {
        var region = new List<HexPosition> { start };
        var frontier = new List<HexPosition> { start };
        while (region.Count < count && frontier.Count > 0)
        {
            var index = rng.NextInt(frontier.Count);
            var current = frontier[index];
            var neighbors = current.GetNeighbors().Where(n => s.Board.Tissues.ContainsKey(n) && !region.Contains(n)).ToArray();
            if (neighbors.Length == 0) { frontier.RemoveAt(index); continue; }
            var next = neighbors[rng.NextInt(neighbors.Length)];
            region.Add(next);
            frontier.Add(next);
        }
        return region;
    }

    public static HexPosition? RayDirection(HexPosition from, HexPosition to)
    {
        var dq = to.Q - from.Q;
        var dr = to.R - from.R;
        foreach (var neighbor in from.GetNeighbors())
        {
            var vq = neighbor.Q - from.Q;
            var vr = neighbor.R - from.R;
            if (vq == 0 && vr == 0) continue;
            if (vq * dr - vr * dq == 0 && vq * dq + vr * dr > 0) return new HexPosition(vq, vr, -vq - vr);
        }
        return null;
    }

    /// <summary>
    /// 【抗体】的伤害：基数每在本世界回合用过一次就折半（整数除法，所以会衰减到 0 而不是留个尾巴）。
    /// `matured` = B 细胞装了【抗体亲和力成熟】：基数由 1.5 改为 **2.0**（PRD:1325；
    /// 卡面 2026-09-07 从 1.5 改成 2，对齐 GDScript 的 MATURED_ANTIBODY_DMG := 20）。
    /// </summary>
    public static int AntibodyDamage(int used, bool matured = false)
    {
        var tenths = matured ? 20 : 15;
        for (var i = 0; i < used; i++) tenths /= 2;
        return tenths;
    }

    public static string AttackOutcome(int roll, Cell attacker)
        => attacker.Equipped.Contains("免疫突触成熟")
            ? roll >= 5 ? "crit" : roll == 1 ? "fail" : "success"
            : roll == 6 ? "crit" : roll <= 2 ? "fail" : "success";
}
