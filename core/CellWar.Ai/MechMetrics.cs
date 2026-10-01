using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// 「做完之后的地图和能量」读数 = GD <c>MechIntent._read_metrics</c>（game/scripts/ai/mech/mech_intent.gd）。
/// 字段名、缺省值（无行动细胞：能量 0 / 固化回合 -1 / 距离 999 / 能量距离 9999）逐个照抄 —— 对拍逐字段比。
///
/// 每个读数转调内核：总无氧供给 = 每只存活癌细胞的 <see cref="RulePolicies.AnaerobicShare"/>
/// （GD 那边是 MechValue 自己镜像了一份引擎公式，「默认规则下逐位一致」—— 对拍会逐字段验它）；
/// 压迫 = <see cref="RulePolicies.PressureAt"/>；压迫致死 = 同一条护盾管线（<see cref="CellRules.ShieldGroups"/>），
/// 内核没有「伤害预览」纯函数，这里只用它的护盾组，不另抄一份减免数学。
/// </summary>
public sealed record MechMetrics
{
    public int Faction { get; init; }
    public int RoundNo { get; init; }
    public int CancerSupply { get; init; }
    public int CancerTiles { get; init; }
    public int SolidTiles { get; init; }
    public int WinProgress { get; init; }
    public int ImmuneLevel { get; init; }
    public int Memory { get; init; }
    public int ImmuneEnergy { get; init; }
    public int CancerEnergy { get; init; }
    public int ActorEnergy { get; init; }
    public int ActorSolidRounds { get; init; } = -1;
    public int ActorMinImmuneDist { get; init; } = 999;
    public int ActorImmuneReachCost { get; init; } = 9999;
    public int ImmuneAlive { get; init; }
    public int CancerAlive { get; init; }
    public int ImmunePressureTotal { get; init; }
    public int ImmuneLethalCount { get; init; }
    public int MinImmuneEnergy { get; init; }
    public int HealthyMarrows { get; init; }
    public int CancerMarrows { get; init; }
    public bool Ok { get; init; } = true;
    public int StepsDone { get; init; }

    /// <summary>GD 字典键 → 值（对拍按这张表逐字段比；<c>ok</c> 记 1/0）。</summary>
    public IReadOnlyDictionary<string, long> Fields() => new Dictionary<string, long>(StringComparer.Ordinal)
    {
        ["faction"] = Faction, ["round_no"] = RoundNo, ["cancer_supply"] = CancerSupply,
        ["cancer_tiles"] = CancerTiles, ["solid_tiles"] = SolidTiles, ["win_progress"] = WinProgress,
        ["immune_level"] = ImmuneLevel, ["memory"] = Memory, ["immune_energy"] = ImmuneEnergy,
        ["cancer_energy"] = CancerEnergy, ["actor_energy"] = ActorEnergy, ["actor_solid_rounds"] = ActorSolidRounds,
        ["actor_min_immune_dist"] = ActorMinImmuneDist, ["actor_immune_reach_cost"] = ActorImmuneReachCost,
        ["immune_alive"] = ImmuneAlive, ["cancer_alive"] = CancerAlive, ["immune_pressure_total"] = ImmunePressureTotal,
        ["immune_lethal_count"] = ImmuneLethalCount, ["min_immune_energy"] = MinImmuneEnergy,
        ["healthy_marrows"] = HealthyMarrows, ["cancer_marrows"] = CancerMarrows,
        ["ok"] = Ok ? 1 : 0, ["steps_done"] = StepsDone,
    };

    /// <summary>GD <c>CWData.SOLIDIFY_STEP</c>：癌细胞停留一回合 +1.0。</summary>
    private const int SolidifyStep = 10;

    public static MechMetrics Read(WorldState s, int seat)
    {
        var g = new AiView(s);
        var ct = g.CountTissue(TissueState.Cancer);
        var st = g.CountTissue(TissueState.SolidifiedCancer);
        var immune = g.Living(Core.Faction.Immune);
        var cancer = g.Living(Core.Faction.Cancer);
        var actor = RulePolicies.Cells(s).FirstOrDefault(c => c.IsAlive && c.OwnerSeat == seat);   // GD：该 pid 第一只活细胞
        int actorEnergy = 0, solidRounds = -1, minDist = 999, reach = 9999;
        if (actor != null)
        {
            actorEnergy = actor.Energy;
            var ap = actor.Position;
            var tile = g.Tile(ap);
            if (tile.State == TissueState.Cancer)
                solidRounds = RoundsToSolidify(tile.SolidificationCount, g.SolidifyThreshold);
            foreach (var im in immune) minDist = Math.Min(minDist, AiView.Dist(ap, im.Position));
            reach = ImmuneReachCost(g, ap);
        }
        int pressure = 0, lethal = 0, minImmuneEnergy = 0;
        var first = true;
        foreach (var im in immune)
        {
            pressure += RulePolicies.PressureAt(s, im.Position);
            if (PressureLethal(s, im)) lethal++;
            if (first || im.Energy < minImmuneEnergy) { minImmuneEnergy = im.Energy; first = false; }
        }
        int healthyMarrows = 0, cancerMarrows = 0;
        foreach (var mc in MatchSetup.Marrows)
        {
            var mt = g.Tile(mc).State;
            if (mt == TissueState.Healthy) healthyMarrows++;
            else cancerMarrows++;
        }
        return new MechMetrics
        {
            Faction = s.Players[seat].Faction == Core.Faction.Immune ? 0 : 1,
            RoundNo = s.Turn.WorldRound,
            CancerSupply = TotalSupply(s, cancer),
            CancerTiles = ct, SolidTiles = st, WinProgress = ct + 2 * st,
            ImmuneLevel = g.ImmuneLevelGd, Memory = g.Memory,
            ImmuneEnergy = immune.Sum(c => c.Energy), CancerEnergy = cancer.Sum(c => c.Energy),
            ActorEnergy = actorEnergy, ActorSolidRounds = solidRounds,
            ActorMinImmuneDist = minDist, ActorImmuneReachCost = reach,
            ImmuneAlive = immune.Count, CancerAlive = cancer.Count,
            ImmunePressureTotal = pressure, ImmuneLethalCount = lethal, MinImmuneEnergy = minImmuneEnergy,
            HealthyMarrows = healthyMarrows, CancerMarrows = cancerMarrows,
        };
    }

    /// <summary>GD <c>MechValue.rounds_to_solidify</c>：从当前计数到固化还要持续停留几回合。</summary>
    internal static int RoundsToSolidify(int solid, int threshold)
        => solid >= threshold ? 0 : (int)Math.Ceiling((double)(threshold - solid) / SolidifyStep);

    /// <summary>GD <c>MechValue.total_supply</c>：全部存活癌细胞此刻的无氧份额之和（转调内核同一个函数）。</summary>
    internal static int TotalSupply(WorldState s, IReadOnlyList<Cell> livingCancer)
    {
        if (livingCancer.Count == 0) return 0;
        var blocks = RulePolicies.Blocks(s, true);   // 块划分一次算好，每只细胞共用
        var total = 0;
        foreach (var c in livingCancer) total += RulePolicies.AnaerobicShare(s, c, blocks);
        return total;
    }

    /// <summary>
    /// GD <c>CWWorld.pressure_lethal</c>：回合末的【微环境压迫】会不会把这只免疫细胞压死。
    /// GD 走的是伤害管线的预览（<c>damage.preview_amount(..., WORLD, [CANCER], "微环境压迫")</c>）：
    /// 免疫目标上倍率层恒为 1（【刚性屏障】只给骨肉瘤、【标记】只认免疫来源），只剩第 ⑤ 层固定减免 —— 照内核的护盾组逐组减。
    /// 判 <c>&gt;=</c>：能量减到 0 就算死。
    /// </summary>
    internal static bool PressureLethal(WorldState s, Cell c)
    {
        if (!c.IsAlive || c.Faction != Core.Faction.Immune) return false;
        var loss = RulePolicies.PressureAt(s, c.Position);
        if (loss <= 0) return false;
        foreach (var grp in CellRules.ShieldGroups(s, c, LossSource.World, "微环境压迫"))
        {
            if (loss <= 0) break;
            var after = Math.Max(0, loss - grp.Cut);
            if (after == loss) continue;   // 这一组没起作用 → 不消耗（ON_BENEFIT）
            loss = after;
        }
        return loss >= c.Energy;
    }

    /// <summary>
    /// GD <c>mech_dist.gd:immune_reach_field</c> 在 <paramref name="target"/> 这一格的值：免疫方活细胞走到这里的最小迁移能量（多源 Dijkstra，十分能量）。
    /// 进格单价 = 目标格癌性 ? <c>immune_move_cancerous[等级]</c> : <c>immune_move_healthy[等级]</c>（简化同 GD：不建模走动中的翻面与费用修饰）。
    /// GD 算整张场、只读这一格；这里出队到目标就停（最短路的值相同，省掉剩下的半张盘）。够不着 / 免疫全灭 = 9999（GD 的缺省）。
    /// GD 线上版还有一层静态缓存，键里没有组织状态（同回合被定殖翻面的格会读旧场）且跨局共享 —— 那是脏读，C# 不搬，每次现算；
    /// GD 参照在对拍模式下同样不走缓存。
    /// </summary>
    internal static int ImmuneReachCost(AiView g, HexPosition target)
    {
        var sources = g.Living(Core.Faction.Immune);
        if (sources.Count == 0) return 9999;
        var lv = g.ImmuneLevelGd;
        var healthy = g.Tune.ImmuneMoveHealthy[lv];
        var cancerous = g.Tune.ImmuneMoveCancerous[lv];
        var dist = new Dictionary<HexPosition, int>();
        var queue = new PriorityQueue<HexPosition, int>();
        foreach (var c in sources)
            if (dist.TryAdd(c.Position, 0)) queue.Enqueue(c.Position, 0);
        while (queue.TryDequeue(out var p, out var cost))
        {
            if (cost > dist[p]) continue;   // 过期条目
            if (p == target) return cost;
            foreach (var n in g.Neighbors(p))
            {
                var nd = cost + (g.IsCancerous(n) ? cancerous : healthy);
                if (nd < dist.GetValueOrDefault(n, 99999)) { dist[n] = nd; queue.Enqueue(n, nd); }
            }
        }
        return 9999;
    }
}
