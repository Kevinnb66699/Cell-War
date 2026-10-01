using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// **普通档** = GD <c>CWHeuristicBridge</c>（game/scripts/ai/heuristic_bridge.gd，AI_VERSION v11）的逐函数移植。
///
/// 规矩：**只搬策略，不搬规则**。GD 里策略直接读 <c>game.world.pressure_at</c> / <c>game.actions.antibody_damage</c> 这类
/// 引擎查询的地方，这里一律转调 C# 内核的同名纯查询（<see cref="RulePolicies"/>），一条算式都不抄。
/// 阈值与权重逐字照抄（十分能量：20 = 2.0）—— 改任何一个数，对拍测试（AgreementTests）必须红。
///
/// 与 GD 线上版的两处有意差异（对拍模式下 GD 参照同样这么做，见 agree_rng.gd）：
/// ① 选项按**规范序**看（<see cref="AskView"/>）：「并列取第一个」取的是键最小的那条，不再随引擎枚举序漂；
/// ② 分化种类的并列决胜用 <see cref="SplitMix64Rng.TieIndex"/>（GD 线上是 <c>hash([rng.state, pid])</c>）。
///
/// GD 里三个分支是死代码，没搬：<c>attack_target</c> / <c>differentiate</c> 两种问答引擎从不发、<c>confirm</c>（remutate / lyse_purge）已随规则删除。
/// </summary>
public sealed class NormalPolicy : IPolicy
{
    private readonly bool lifecare;
    private readonly bool fixedLineup;

    public NormalPolicy(AiConfig config) : this(config.Lifecare, config.FixedLineup) { }

    internal NormalPolicy(bool lifecare, bool fixedLineup)
    {
        this.lifecare = lifecare;
        this.fixedLineup = fixedLineup;
    }

    public string Choose(WorldState state, int seat, IReadOnlyList<IDecision> options, IDeterministicRng rng,
        CancellationToken cancellation = default, AiTrace? trace = null)
    {
        var ask = AskView.Build(state, seat, options);
        return Final(new AiView(state), ask, AiPolicies.RootState(rng)).Key;
    }

    /// <summary>答一问并落到**可执行**的那一条：折叠的组选项再按 GD 的第二问挑出子项。</summary>
    internal AiOption Final(AiView g, AskView ask, ulong tieState)
    {
        var chosen = Decide(g, ask, tieState);
        return chosen.Children.Count > 0 ? ResolveGroup(g, chosen) : chosen;
    }

    /// <summary>GD <c>ask()</c> 的分派：返回规范视图里的一条（越界 / -1 按 GD <c>game.ask</c> 的钳位落到下标 0）。</summary>
    internal AiOption Decide(AiView g, AskView ask, ulong tieState)
    {
        var o = ask.Options;
        var i = ask.Kind switch
        {
            "setup_place" => SetupPlace(g, ask.Seat, o),
            "action" => g.FactionOf(ask.Seat) == Faction.Immune ? ImmuneAction(g, ask.Seat, o, tieState) : CancerAction(g, ask.Seat, o),
            "revive" => PickRevive(g, o),
            "free_move" => PickFreeMove(g, ask.Seat, o),
            "pick_cell" => PickStormCenter(g, ask.Tag ?? "", o),
            "pick_tile" => PickTileTake(g, o),
            "pick" => ask.Tag switch
            {
                "基因组不稳定" => PickMutationResult(g, ask.Seat, o),
                "代谢耦联" => PickCouple(g, o),
                _ => 0,
            },
            _ => 0,   // immune_revive / 手牌上限 / effector_target：GD 走 `return 0`
        };
        return o[Math.Clamp(i, 0, o.Count - 1)];
    }

    /// <summary>组选项的第二问（GD 在结算里追问）：趋化源选落点走 <c>_pick_chemo_spot</c>；效应应答选目标 GD 没写分支，<c>return 0</c>。</summary>
    internal AiOption ResolveGroup(AiView g, AiOption group)
        => group.Act == "chemo" ? group.Children[PickChemoSpot(g, group.Children)] : group.Children[0];

    // ============ 开局落子 ============

    private static int SetupPlace(AiView g, int seat, IReadOnlyList<AiOption> options)
    {
        var faction = g.FactionOf(seat);
        var best = 0;
        var bestScore = -999999;
        for (var i = 0; i < options.Count; i++)
        {
            var c = options[i].To!.Value;
            int score;
            if (faction == Faction.Cancer)
            {
                // 远离已落子的免疫细胞是第一要务（开局 3.0 能量扛不住围攻），其次靠中心、独占一格
                var safety = 99;
                foreach (var other in g.Living(Faction.Immune)) safety = Math.Min(safety, AiView.Dist(c, other.Position));
                score = Math.Min(safety, 6) * 5 - AiView.Dist(c, AiView.Hex(0, 0)) * 2 - g.CellsAtCount(c) * 3;
            }
            else
            {
                // 距最近癌性组织 2 格最理想（首回合可接敌但不至于立刻被围），并与队友拉开距离
                var d = g.DistToNearestCancerous(c);
                var spread = 99;
                foreach (var other in g.Living(Faction.Immune)) spread = Math.Min(spread, AiView.Dist(c, other.Position));
                score = -Math.Abs(d - 2) * 10 + Math.Min(spread, 6);
            }
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    // ============ 免疫回合 ============

    private int ImmuneAction(AiView g, int seat, IReadOnlyList<AiOption> options, ulong tieState)
    {
        var me = g.CellOf(seat)!;
        var e = me.Energy;
        // 1. 分化免费，永远优先；选哪一种按种子随机（v2）
        var i = PickDifferentiationOption(seat, options, tieState);
        if (i >= 0) return i;
        // 1.5 惜命（v2）：脚下这格回合末的【微环境压迫】会把自己压死 → 先挪到活得下去的格
        if (lifecare && RulePolicies.PressureAt(g.S, me.Position) >= e)
        {
            i = BestEscape(g, options, me);
            if (i >= 0) return i;
        }
        // 2. 打牌（出牌免费；攻击增益要赶在攻击之前打出）
        i = BestPlay(g, seat, options);
        if (i >= 0) return i;
        // 3. T 细胞站在固化格上 → 裂解
        i = Find(options, "lyse");
        if (i >= 0 && e >= 20) return i;
        // 4. B 细胞抗体：目标够多、且这一发还打得出伤害（v8：同回合递减）
        i = Find(options, "antibody");
        if (i >= 0 && RulePolicies.AntibodyDamage(g.Tune, me.AntibodyThisRound, RulePolicies.HasSkill(g.S, me, "抗体亲和力成熟")) >= 5)
        {
            var n = AntibodyTargetCount(g);
            if ((n >= 2 && e >= 25) || (n >= 1 && e >= 40)) return i;
        }
        // 5. T 细胞毒素：一次至少清 2 格
        i = Find(options, "toxin");
        if (i >= 0 && e >= 25 && ToxinTargets(g, me).Count >= 2) return i;
        // 5.5 树突【I-趋化源】：建得起就建，只留一步迁移的钱（CHEMO_COST 3.0 + 1.0）
        i = Find(options, "chemo");
        if (i >= 0 && e >= ChemoCost + 10) return i;
        // 6. 攻击相邻癌细胞：留足「攻击费 + 反弹反击」的储备
        var atkReserve = g.Tune.ImmuneMoveCancerous[g.ImmuneLevelGd] + g.Tune.CounterDamageOnFail + 10;
        if (e >= Math.Max(25, atkReserve))
        {
            var atk = BestAttack(g, options);
            if (atk >= 0) return atk;
        }
        // 7. 净化：进入相邻的无人癌组织
        var purgeCost = g.Tune.ImmuneMoveCancerous[g.ImmuneLevelGd];
        if (e >= purgeCost + 10)
        {
            var purge = BestPurgeMove(g, options, me);
            if (purge >= 0) return purge;
        }
        // 8. 手上余粮多就抽卡（排在净化之后：转地是即时收益，卡是期货）
        i = Find(options, "draw");
        if (i >= 0 && e >= 30) return i;
        // 9. 接近最近的癌性组织
        if (e >= 20)
        {
            var approach = BestApproach(g, options, me);
            if (approach >= 0) return approach;
        }
        return Find(options, "end");
    }

    /// <summary>GD <c>CWData.CHEMO_COST</c>。</summary>
    private const int ChemoCost = 30;
    /// <summary>GD <c>CWData.MARK_RANGE</c>（树突【I-标记】光环 2 格，v10）。</summary>
    private const int MarkRange = 2;
    /// <summary>GD <c>CWData.MUCUS_RADIUS</c>。</summary>
    private const int MucusRadius = 2;
    /// <summary>GD <c>CWData.HAND_MAX</c>。</summary>
    private const int HandMax = 8;

    private static int AntibodyTargetCount(AiView g)
    {
        var n = 0;
        foreach (var c in g.Living(Faction.Cancer))
            if (g.Neighbors(c.Position).Any(nb => g.Tile(nb).State == TissueState.Healthy)) n++;
        return n;
    }

    /// <summary>GD <c>CWActions._toxin_targets</c>：1 环内（含脚下）的**普通**癌组织。</summary>
    private static List<HexPosition> ToxinTargets(AiView g, Cell me)
        => g.AllTiles.Where(p => AiView.Dist(p, me.Position) <= 1 && g.Tile(p).State == TissueState.Cancer).ToList();

    /// <summary>攻击目标格里能量最低的敌人所在选项</summary>
    private static int BestAttack(AiView g, IReadOnlyList<AiOption> options)
    {
        var best = -1;
        var bestEnergy = 999999;
        for (var i = 0; i < options.Count; i++)
        {
            if (options[i].Act != "move") continue;
            foreach (var en in g.CellsAt(options[i].To!.Value, Faction.Cancer))
                if (en.Energy < bestEnergy) { bestEnergy = en.Energy; best = i; }
        }
        return best;
    }

    /// <summary>可净化的相邻癌组织（无人、非固化），优先癌性邻格多的 —— 但走进去之后得活过回合末的压迫（v2 惜命）</summary>
    private int BestPurgeMove(AiView g, IReadOnlyList<AiOption> options, Cell me)
    {
        var best = -1;
        var bestScore = -1;
        for (var i = 0; i < options.Count; i++)
        {
            var d = options[i];
            if (d.Act != "move") continue;
            var to = d.To!.Value;
            if (g.Tile(to).State != TissueState.Cancer) continue;
            if (g.AnyAt(to, Faction.Cancer)) continue;
            if (lifecare && !SurvivesAt(g, me, to, d.CostOr0)) continue;
            var score = g.CancerousNeighbors(to);
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    private int BestApproach(AiView g, IReadOnlyList<AiOption> options, Cell me)
    {
        // 目标：无人癌性组织（树突：癌细胞光环范围内的格 —— 它只能靠光环输出）
        var targets = new List<HexPosition>();
        if (me.Type == CellType.Dendritic)
        {
            foreach (var t in g.AllTiles)
            {
                if (g.AnyAt(t, Faction.Cancer)) continue;
                if (g.Living(Faction.Cancer).Any(c => AiView.Dist(t, c.Position) <= MarkRange)) targets.Add(t);
            }
        }
        else
        {
            foreach (var c in g.AllTiles)
                if (g.IsCancerous(c) && !g.AnyAt(c, Faction.Cancer)) targets.Add(c);
        }
        if (targets.Count == 0) return -1;
        var dist = DistMap(g, targets, c => g.AnyAt(c, Faction.Cancer));
        var now = dist.GetValueOrDefault(me.Position, 9999);
        var best = -1;
        var bestD = now;   // 必须严格变近，否则原地攒能量
        for (var i = 0; i < options.Count; i++)
        {
            var d = options[i];
            if (d.Act != "move") continue;
            var to = d.To!.Value;
            if (g.AnyAt(to, Faction.Cancer)) continue;   // 接近阶段不打架
            if (lifecare && !SurvivesAt(g, me, to, d.CostOr0)) continue;   // v2 惜命
            var nd = dist.GetValueOrDefault(to, 9999);
            if (nd < bestD) { bestD = nd; best = i; }
        }
        return best;
    }

    /// <summary>惜命（v2）：走进一格之后账上剩的能量必须**高于**那一格此刻的压迫损失。</summary>
    private static bool SurvivesAt(AiView g, Cell me, HexPosition to, int cost)
        => me.Energy - cost > RulePolicies.PressureAt(g.S, to);

    /// <summary>脚下会被压死时的逃生：付得起、活得下去的迁移里，优先能顺手净化的，其次压迫最轻的</summary>
    private static int BestEscape(AiView g, IReadOnlyList<AiOption> options, Cell me)
    {
        var best = -1;
        var bestScore = -999999;
        for (var i = 0; i < options.Count; i++)
        {
            var d = options[i];
            if (d.Act != "move") continue;
            var to = d.To!.Value;
            if (g.AnyAt(to, Faction.Cancer)) continue;
            var cost = d.CostOr0;
            if (!SurvivesAt(g, me, to, cost)) continue;
            var score = -RulePolicies.PressureAt(g.S, to) - cost / 5;
            if (g.Tile(to).State == TissueState.Cancer) score += 20;
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    /// <summary>
    /// 分化选哪一种：在可选种类里按「这一问的 rng 状态 + 席位」决胜，**不消耗**随机数（v2）。
    /// 顶层是 <c>Choose</c> 收到的那条流的初始状态；推演里是推演流此刻的状态（GD 对拍模式同口径，见 agree_rng.gd）。
    /// </summary>
    private int PickDifferentiationOption(int seat, IReadOnlyList<AiOption> options, ulong tieState)
    {
        var idx = new List<int>();
        for (var i = 0; i < options.Count; i++)
            if (options[i].Act == "differentiate") idx.Add(i);
        if (idx.Count == 0) return -1;
        if (fixedLineup) return idx[0];
        return idx[SplitMix64Rng.TieIndex(tieState, seat, idx.Count)];
    }

    // ============ 癌症回合 ============

    private int CancerAction(AiView g, int seat, IReadOnlyList<AiOption> options)
    {
        var me = g.CellOf(seat)!;
        var e = me.Energy;
        var threat = g.DistToNearestImmune(me.Position);
        // 0. 打牌（EMT 这类移动折扣要赶在移动之前打出）
        var pi = BestPlay(g, seat, options);
        if (pi >= 0) return pi;
        // 1. 印戒【黏液破裂】：一次能染一大片、且有复活据点时才引爆（自毁技能）
        var i = Find(options, "mucus");
        if (i >= 0 && g.CountTissue(TissueState.SolidifiedCancer) >= 1)
        {
            var n = g.AllTiles.Count(c => AiView.Dist(c, me.Position) <= MucusRadius && g.Tile(c).State == TissueState.Healthy);
            if (n >= 6) return i;
        }
        // 2. 黑色素瘤【早期血行转移】：站在血管上就是白捡一格地盘
        i = Find(options, "homing");
        if (i >= 0 && e >= 20) return i;
        // 2.5 骨肉瘤【骨样硬化】（v9）：还没有复活据点、且不是贴脸时，标记脚下两回合后固化
        i = Find(options, "ossify");
        if (i >= 0 && e >= 35 && threat >= 2 && g.CountTissue(TissueState.SolidifiedCancer) == 0) return i;
        // 3. 小细胞肺癌【转移】：远离威胁时用来抢空地
        i = Find(options, "jump");
        if (i >= 0 && e >= 25 && threat <= 2) return i;
        // 4. 突变：免疫方有记忆可削时才赌
        i = Find(options, "mutate");
        if (i >= 0 && e >= 30 && g.Memory >= 2) return i;
        // 4.5 攒够了就抽卡：贴脸时别停下抽卡送头
        i = Find(options, "draw");
        if (i >= 0 && e >= 45 && threat >= 2) return i;
        // 4. 蹲点固化：安全时停在原地
        if (threat >= 3 && WorthSolidifying(g, me)) return Find(options, "end");
        // 5. 移动：安全 / 占地 / 前景 / 成本 统一打分
        var mv = BestCancerMove(g, options, me);
        if (mv >= 0) return mv;
        // 6. 收尾回据点（v6）
        i = BaseReturn(g, options, me);
        if (i >= 0) return i;
        return Find(options, "end");
    }

    /// <summary>收尾回据点：本回合已经没有值得走的占地步了，就退到固化计数最高的那一格结束回合（v6）。</summary>
    private static int BaseReturn(AiView g, IReadOnlyList<AiOption> options, Cell me)
    {
        var best = -1;
        var bestSolid = g.Tile(me.Position).SolidificationCount;
        for (var i = 0; i < options.Count; i++)
        {
            var d = options[i];
            if (d.Act != "move") continue;
            var t = g.Tile(d.To!.Value);
            if (t.State != TissueState.Cancer || t.SolidificationCount <= bestSolid) continue;
            if (me.Energy < d.CostOr0 + 5) continue;   // 回据点不该把自己走到濒死
            bestSolid = t.SolidificationCount;
            best = i;
        }
        return best;
    }

    /// <summary>脚下这格值不值得蹲：癌组织、不是刚铺的（策略层的「新生」）、不是血管（v11）。</summary>
    private static bool WorthSolidifying(AiView g, Cell me)
    {
        var t = g.Tile(me.Position);
        if (t.State != TissueState.Cancer || t.Newborn || t.Type == TissueType.BloodVessel) return false;
        if (t.SolidificationCount >= g.SolidifyThreshold - 1) return true;   // 差最后一轮就固化
        return g.CountTissue(TissueState.SolidifiedCancer) == 0;           // 场上还没有任何复活据点时，值得从头熬一个
    }

    /// <summary>趋化源建在哪：癌区最密的那一格（免疫朝它走、癌方背它走，两头收益同在一处）。</summary>
    private static int PickChemoSpot(AiView g, IReadOnlyList<AiOption> options)
    {
        var best = -1;
        var bestScore = -1;
        for (var i = 0; i < options.Count; i++)
        {
            var c = options[i].To!.Value;
            var score = g.CancerousNeighbors(c);
            if (g.IsCancerous(c)) score += 1;
            if (g.AnyAt(c, Faction.Cancer)) score += 2;   // 有癌细胞站着的格更值：它下一步一定要动，一动就交钱
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return Math.Max(best, 0);
    }

    /// <summary>距免疫细胞不同距离的安全分（GD <c>SAFETY_BY_DIST</c>）：1 格处是断崖式惩罚。</summary>
    private static readonly int[] SafetyByDist = [-999, -40, -5, 6, 12];
    /// <summary>惜命（v2）：停在免疫 2 格内时账上要留的储备 3.0（GD <c>CANCER_RESERVE_NEAR</c>）。</summary>
    private const int CancerReserveNear = 30;

    /// <summary>
    /// 癌细胞移动打分：安全 + 定殖 + 扩张前景 − 成本。
    /// GD 这里还算了一张 <c>immune_reach_field</c> 赋给 <c>threat_to</c>，但**从没用到**（威胁 v2 的半截）—— 纯函数、结果丢弃，不搬。
    /// </summary>
    private int BestCancerMove(AiView g, IReadOnlyList<AiOption> options, Cell me)
    {
        var best = -1;
        var bestScore = -999999;
        for (var i = 0; i < options.Count; i++)
        {
            var d = options[i];
            if (d.Act != "move") continue;
            var to = d.To!.Value;
            var reserve = lifecare && g.DistToNearestImmune(to) <= 2 ? CancerReserveNear : 5;
            if (me.Energy < d.CostOr0 + reserve) continue;
            var score = SafetyByDist[Math.Min(g.DistToNearestImmune(to), 4)];
            if (!g.IsCancerous(to)) score += 15;   // 定殖：永久 +1 格地盘
            foreach (var n in g.Neighbors(to))
                if (g.Tile(n).State == TissueState.Healthy) score += 2;   // 前景
            score -= d.CostOr0;
            if (score > bestScore) { bestScore = score; best = i; }
        }
        var stayScore = SafetyByDist[Math.Min(g.DistToNearestImmune(me.Position), 4)];
        return bestScore > stayScore ? best : -1;
    }

    // ============ 打牌 ============

    private static int BestPlay(AiView g, int seat, IReadOnlyList<AiOption> options)
    {
        var best = -1;
        var bestScore = 0;
        for (var i = 0; i < options.Count; i++)
        {
            if (options[i].Act != "play") continue;
            var score = ScorePlay(g, seat, options[i], options);
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    /// <summary>出牌免费，打分只回答「现在打时机对不对」（GD <c>_score_play</c>）。</summary>
    private static int ScorePlay(AiView g, int seat, AiOption d, IReadOnlyList<AiOption> options)
    {
        var me = g.CellOf(seat)!;
        var card = d.Card!;
        // 永久技能：免费、永久生效、还腾出手牌位，永远第一时间装上
        if (CardCatalog.ByCardName(card).Any(x => x.Category == CardCategory.Permanent)) return 100;
        switch (card)
        {
            case "抗体依赖细胞毒作用" or "放疗" or "IFN-γ高峰" or "溶酶体强化" or "基质降解" or "基质重塑" or "乳酸酸化" or "TNF-α局部炎症":
                return 90;
            case "交叉呈递": return 80;
            case "基质硬化": return 55;
            case "代谢耦联": return 40;
            case "免疫增援": return g.DistToNearestCancerous(me.Position) >= 3 ? 35 : 0;
            case "肿瘤细胞募集":
                return g.CellOf(d.Cid!.Value) is { } target && g.DistToNearestImmune(target.Position) <= 1 ? 45 : 0;
            case "炎症性趋化":
                return g.Tile(d.To!.Value).State == TissueState.Cancer && CanPay(me, d.CostOr0 + 10) ? 55 : 0;
            case "补体调理" or "穿孔素-颗粒酶" or "高亲和力克隆" or "补体级联":
                return AttackReady(g, me, options) ? 60 : 0;
            case "炎症趋化" or "CXCR3趋化": return StepTargetExists(g, me, true) ? 30 : 0;
            case "上皮—间质转化": return StepTargetExists(g, me, false) ? 30 : 0;
            case "细胞膜修复" or "缺氧适应" or "PD-L1表达" or "DNA损伤修复":
                return DistToNearestEnemy(g, me) <= 2 ? 50 : 0;
        }
        return 0;
    }

    /// <summary>GD <c>game.can_pay</c>：严格大于（能量不能付到 0）。</summary>
    private static bool CanPay(Cell c, int cost) => c.Energy > cost;

    private static bool AttackReady(AiView g, Cell me, IReadOnlyList<AiOption> options)
    {
        if (BestAttack(g, options) < 0) return false;
        var reserve = g.Tune.ImmuneMoveCancerous[g.ImmuneLevelGd] + g.Tune.CounterDamageOnFail + 10;
        return me.Energy >= Math.Max(25, reserve);
    }

    private static bool StepTargetExists(AiView g, Cell me, bool wantCancerous)
    {
        foreach (var n in g.Neighbors(me.Position))
        {
            if (g.CellsAtCount(n) > 0) continue;
            if (wantCancerous && g.IsCancerous(n)) return true;
            if (!wantCancerous && g.Tile(n).State == TissueState.Healthy) return true;
        }
        return false;
    }

    private static int DistToNearestEnemy(AiView g, Cell me)
    {
        var enemy = me.Faction == Faction.Immune ? Faction.Cancer : Faction.Immune;
        var best = 99;
        foreach (var c in g.Living(enemy)) best = Math.Min(best, AiView.Dist(me.Position, c.Position));
        return best;
    }

    // ============ 子询问 ============

    /// <summary>options[0] 恒为「放弃」；有位置就复活，选癌性邻格最多的</summary>
    private static int PickRevive(AiView g, IReadOnlyList<AiOption> options)
    {
        var best = 0;
        var bestScore = -1;
        for (var i = 1; i < options.Count; i++)
        {
            var score = g.CancerousNeighbors(options[i].To!.Value);
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    /// <summary>卡牌给的「走一步 / 停」：options[0] 恒为停止（0 分），没有正收益就不白走；有癌细胞的格（动员的攻击）保守跳过。</summary>
    private static int PickFreeMove(AiView g, int seat, IReadOnlyList<AiOption> options)
    {
        var me = g.CellOf(seat)!;
        var nowD = g.DistToNearestCancerous(me.Position);
        var best = 0;
        var bestScore = 0;
        for (var i = 1; i < options.Count; i++)
        {
            var d = options[i];
            if (d.To is not { } to) continue;
            if (g.AnyAt(to, Faction.Cancer)) continue;
            var t = g.Tile(to);
            var score = 0;
            if (t.State == TissueState.Cancer) score += 15;   // 净化：转地 + 记忆
            if (t.Type == TissueType.MetabolicCore && (t.Charge ?? 0) > 0) score += 10;
            if (t.Type == TissueType.BoneMarrow && (t.Charge ?? 0) > 0 && me.Hand.Count < HandMax) score += 8;
            if (g.DistToNearestCancerous(to) < nowD) score += 4;
            score -= d.CostOr0 / 5;   // 动员的迁移要付费，白走不划算
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    /// <summary>风暴类「选 1 个免疫细胞」：选波及面最大的（范围内癌细胞×2 + 普通癌组织×1）</summary>
    private static int PickStormCenter(AiView g, string tag, IReadOnlyList<AiOption> options)
    {
        var r = tag == "免疫风暴" ? 2 : 1;
        var best = 0;
        var bestScore = -1;
        for (var i = 0; i < options.Count; i++)
        {
            var center = options[i].To!.Value;
            var score = 0;
            foreach (var c in g.AllTiles)
            {
                if (AiView.Dist(center, c) > r) continue;
                if (g.Tile(c).State == TissueState.Cancer) score += 1;
                score += g.CellsAt(c, Faction.Cancer).Count() * 2;
            }
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    /// <summary>卡牌递过来的「选一格」：递到眼前的都是纯收益，有得选就不选「停止」；同类里挑癌性邻格最多的</summary>
    private static int PickTileTake(AiView g, IReadOnlyList<AiOption> options)
    {
        var best = 0;
        var bestScore = 0;
        for (var i = 0; i < options.Count; i++)
        {
            if (options[i].To is not { } to) continue;   // 「停止 / 放弃」项不带 to，保持 0 分
            var score = 1 + g.CancerousNeighbors(to);
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    /// <summary>
    /// 【代谢耦联】两连问：方向问句带 from —— 选转出方能量高的一侧；数额问句 —— 拉满 = 最后一条。
    /// 规范序里「取消」排最前，档位按键排（pay=10 / 15 / 20 同为两位数，字典序 = 数值序），「最后一条」仍是最高档。
    /// </summary>
    private static int PickCouple(AiView g, IReadOnlyList<AiOption> options)
    {
        if (options.Any(o => o.From != null))
        {
            var best = -1;
            var bestE = -1;
            for (var i = 0; i < options.Count; i++)
            {
                if (options[i].From is not { } from) continue;
                var payer = g.CellOf(from)!;
                if (payer.Energy > bestE) { bestE = payer.Energy; best = i; }
            }
            return best;
        }
        return options.Count - 1;
    }

    /// <summary>【基因组不稳定】的二择：抽卡那档几乎总是最优；记忆厚、能量足时 -3 记忆更值</summary>
    private static int PickMutationResult(AiView g, int seat, IReadOnlyList<AiOption> options)
    {
        var me = g.CellOf(seat)!;
        var best = 0;
        var bestScore = -99;
        for (var i = 0; i < options.Count; i++)
        {
            var score = options[i].R switch
            {
                2 => 5 + (g.Memory > 0 ? 3 : 0),
                3 => (g.Memory >= 3 ? 8 : -2) - (me.Energy <= 20 ? 5 : 0),
                _ => 0,
            };
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return best;
    }

    // ============ 工具 ============

    internal static int Find(IReadOnlyList<AiOption> options, string act)
    {
        for (var i = 0; i < options.Count; i++)
            if (options[i].Act == act) return i;
        return -1;
    }

    /// <summary>多源 BFS：每格 → 到最近目标的步数；blocked 为真的格不可通行（目标本身除外）</summary>
    private static Dictionary<HexPosition, int> DistMap(AiView g, IReadOnlyList<HexPosition> targets, Func<HexPosition, bool> blocked)
    {
        var dist = new Dictionary<HexPosition, int>();
        var queue = new Queue<HexPosition>();
        foreach (var t in targets)
            if (dist.TryAdd(t, 0)) queue.Enqueue(t);
        while (queue.TryDequeue(out var cur))
            foreach (var n in g.Neighbors(cur))
            {
                if (dist.ContainsKey(n) || blocked(n)) continue;
                dist[n] = dist[cur] + 1;
                queue.Enqueue(n);
            }
        return dist;
    }
}
