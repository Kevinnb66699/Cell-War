using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>规划路径的一步：目标格、这一步的费用（十分位）、是否合法/付得起、阻挡原因、踩核心获得的能量。</summary>
public sealed record PathStep(HexPosition To, int Cost, bool Legal, bool Afford, string Reason, int Gain, HexPosition? Mid = null);   // Mid = 借道的第一跳（GD quote_path 的 mid），走得到的相邻格为 null

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
        // 骨髓：与 GD `CWData.store_progress` 同口径 —— 存满就是 1，没存满按产出周期走进度（健康 3 回合 / 癌性 2 回合，同 BoardRules.Produce 的周期）
        TissueType.BoneMarrow => (t.Charge ?? 0) >= BoneMarrowStoreMax ? 1 : Math.Clamp(t.ProductionCounter / (double)(t.State == TissueState.Healthy ? 3 : 2), 0, 1),
        _ => -1
    };

    /// <param name="rawCostOverride">
    /// 卡面自带的起价（【炎症性趋化】每步 0.2）。null = 按细胞与地形现算。
    /// 它顶掉的只是 <see cref="RawMoveCost"/> 的结果，修饰管线整条照跑 —— 包括 Replace 阶段，
    /// 所以【炎症趋化】那类「费用改为 X」仍会盖掉它（GD 侧 0.2 进的是 `ctx.base_cost`，REPLACE 排在其后）。
    /// </param>
    public static int BaseMoveCost(WorldState s, Cell c, HexPosition destination, int? rawCostOverride = null)
        => Settlement.ApplyValue(RawFor(s, c, destination, rawCostOverride), MoveModifiers(s, c, destination));

    /// <summary>
    /// 这一步的**起价**（修饰之前）：相邻 = <see cref="RawMoveCost"/>；借道 = 沿途每格 <see cref="RawMoveCost"/> 之和
    /// （GD `_move_base_cost`：非相邻走 `pass_through_map`，那张表累计的是 `_one_step_base`）。修饰管线随后**只跑一遍**、按落点评估
    /// （GD `_move_cost_mod(cell, dest, base)`）。2026-09-19 之前 C# 借道是逐段跑修饰再相加（0.4-bis #6 的 KNOWN_GAP），
    /// 报价碰巧常常相同、`cost_rows` 却从落点单格的起价起算 —— 树突建源夹具第 249 步把它揪出来（`chemo-move-quote`）。
    /// 借不到的非相邻格退回落点单格起价（QuoteMove 在此之前已判「走不到」）。
    /// </summary>
    private static int RawFor(WorldState s, Cell c, HexPosition destination, int? rawCostOverride)
    {
        if (rawCostOverride is { } o) return o;
        if (c.Position.DistanceTo(destination) != 1 && PassThroughRoutes(s, c).TryGetValue(destination, out var route)) return route.Cost;
        return RawMoveCost(s, c, destination);
    }

    /// <summary>
    /// 这一步移动**真改了价**的修饰（GD `quote().applied`）—— 提交时只消耗这些（ON_BENEFIT）。
    /// 与 <see cref="BaseMoveCost"/> 走同一份修饰列表、同一条管线，报价与消耗才不会各算各的。
    /// </summary>
    public static IReadOnlyCollection<ValueModifier> AppliedMoveModifiers(WorldState s, Cell c, HexPosition destination, int? rawCostOverride = null)
    {
        var applied = new List<ValueModifier>();
        Settlement.ApplyValue(RawFor(s, c, destination, rawCostOverride), MoveModifiers(s, c, destination), applied);
        return applied;
    }

    /// <summary>移动费用管线吃的全部修饰：细胞身上适用的 + 场上的（趋化源 / 黏液侵染）。</summary>
    /// <summary>迁移报价的逐段明细（观测协议 `options[].cost_rows`）：与 <see cref="BaseMoveCost"/> 同一条管线，只是把每一段记下来。</summary>
    public static IReadOnlyList<Settlement.CostStep> MoveCostSteps(WorldState s, Cell c, HexPosition destination, int? rawCostOverride = null)
    {
        var steps = new List<Settlement.CostStep>();
        Settlement.ApplyValue(RawFor(s, c, destination, rawCostOverride), MoveModifiers(s, c, destination), null, steps);
        return steps;
    }

    private static List<ValueModifier> MoveModifiers(WorldState s, Cell c, HexPosition destination)
    {
        var cancerous = Cancerous(s.Board.Tissues[destination]);
        var modifiers = c.Modifiers.Where(m => m.Target == ModifierTarget.Move && RequirementMet(m.Requirement, cancerous))
            .Select(m => m.ToValueModifier()).ToList();
        modifiers.AddRange(SkillMoveModifiers(s, c, destination));
        // 【I-趋化源】是**场上实体**，不住在任何人的 mods / equipped 里，单独发一条
        // （GD 侧 cw_cost.gd:347-350 也是 `_collect()` 里单独 emit）。
        if (ChemoModifier(s, c, destination) is { } chemo) modifiers.Add(chemo);
        // 印戒「黏液侵染」：免疫**踏进**黏液格迁移费 +0.2（PRD:523）。
        // 和趋化源一样是**格子上的状态**，不住在任何人的 mods 里，单独发一条。
        // GD 那边还判了一句 `mucus_move_surcharge > 0` 才发这条修饰（它要让旋钮关掉时
        // 悬浮详情里也不出现这一行）。C# 没有那个展示面，而 `Add 0` 本身就是恒等操作 ——
        // **没有任何测试能区分加不加这句**，也就是死条件，不留。
        if (c.Faction == Faction.Immune && s.Board.Tissues[destination].Mucus)
            modifiers.Add(new ValueModifier(ModifierStage.Add, SourceLayer.Skill, 0, s.Tuning.MucusMoveSurcharge, Name: "黏液侵染"));
        return modifiers;
    }

    /// <summary>永久技能的迁移费修饰（GD cw_cost.gd `_collect`：从 `equipped` 逐条 `_emit`，模板见 TEMPLATES；被【中和抗体】压住一条都不发；
    /// 身上已有同名 mods 条目的跳过）。它们**不是 mods 条目**：额度记在 `fx_turn` 闸门里（Store.GATE，GD `GATE_USES`：【组织驻留】2 次、其余 1 次），
    /// 打出先后 = `equip_seq`。此前 C# 在 BeginTurn 把它们发成 Turn 修饰：判定前就被消耗、回合中途装备的要等下一回合才生效、
    /// L1 视图的 `mods` 凭空多几条、`fx_turn` 少一个键（批扫 60 条轨迹撞了十几条，2026-09-18）。</summary>
    internal static IEnumerable<ValueModifier> SkillMoveModifiers(WorldState s, Cell c, HexPosition destination)
    {
        var cancerous = Cancerous(s.Board.Tissues[destination]);
        bool Emits(string skill) => HasSkill(s, c, skill) && c.Modifiers.All(m => m.Card != skill);
        int Seq(string skill) => c.EquipSeq.GetValueOrDefault(skill);
        // 【组织驻留】：向健康组织的前两次迁移免费（cond to_healthy + gate_open，GATE_USES 2）
        if (Emits("组织驻留") && !cancerous && CellRules.TurnGateOpen(c, "组织驻留"))
            yield return new ValueModifier(ModifierStage.Free, SourceLayer.Passive, Seq("组织驻留"), 0, null, "组织驻留");
        // 【LFA-1黏附】：每行动回合首次走上癌性组织 −0.4、下限 0.2（cond to_cancerous + gate_open）
        if (Emits("LFA-1黏附") && cancerous && CellRules.TurnGateOpen(c, "LFA-1黏附"))
            yield return new ValueModifier(ModifierStage.Subtract, SourceLayer.Passive, Seq("LFA-1黏附"), 4, 2, "LFA-1黏附");
        // 【组织浸润】：向癌性组织的迁移 −0.3、下限 0.2（GD cw_cost.gd:88 TEMPLATES，cond to_cancerous、Store.NONE —— 不是闸门、不烧 fx_turn）。
        // 此前 C# 只在 CardRules.Registry 里挂了一条 mods 版，而永久卡在 PlayCard 的 Permanent 分支就 return、够不着那条 ⇒ 装了等于没装
        //（批 5a 实测 GD 7 / C# 10，空档 infiltration-from-equipped，2026-09-19 合上）
        if (Emits("组织浸润") && cancerous)
            yield return new ValueModifier(ModifierStage.Subtract, SourceLayer.Passive, Seq("组织浸润"), 3, 2, "组织浸润");
        // 【组织巡航】：每行动回合一次任意迁移免费（gate_open）；额度用掉后本回合后续迁移 −0.2、下限 0.2（gate_closed）—— 两条共用装备的戳
        if (Emits("组织巡航"))
            yield return CellRules.TurnGateOpen(c, "组织巡航")
                ? new ValueModifier(ModifierStage.Free, SourceLayer.Passive, Seq("组织巡航"), 0, null, "组织巡航")
                : new ValueModifier(ModifierStage.Subtract, SourceLayer.Passive, Seq("组织巡航"), 2, 2, "组织巡航");
    }

    /// <summary>这条修饰是不是闸门额度（GD Store.GATE）：用上了就烧 `fx_turn`，而不是扣 mods。【组织巡航】只有免费那一条是闸门，减 0.2 那条是 Store.NONE。</summary>
    internal static bool IsGateMoveModifier(ValueModifier m)
        => m.Name is "组织驻留" or "LFA-1黏附" || (m.Name == "组织巡航" && m.Stage == ModifierStage.Free);

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
        var typeOn = TypeAbilityOn(s, c);   // 【中和抗体】压住癌种被动
        var tune = s.Tuning;
        int cost;
        if (c.Faction == Faction.Cancer)
        {
            if (Cancerous(target)) cost = tune.CancerMoveCancerous;
            else if (typeOn && c.Type == CellType.SmallCellLung) cost = tune.SclcMoveHealthy;   // 【极简胞浆】
            else if (typeOn && c.Type == CellType.Melanoma)
            {
                var adjacent = destination.GetNeighbors().Count(n => s.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t));
                // 【伪足穿透】门槛与折扣**不是旋钮**（GD 侧也是 CWData 常量直接用，不过 tune）
                cost = adjacent >= PseudopodMinAdjacent
                    ? Math.Max(0, tune.PseudopodCost - PseudopodDiscount * (adjacent - PseudopodMinAdjacent))
                    : tune.CancerMoveHealthy;
            }
            else cost = tune.CancerMoveHealthy;
        }
        else
        {
            var level = s.Players[c.OwnerSeat].ImmuneLevel;
            // III/X 不再另有减免（Kevin 2026-09-15 按 PRD 裁定：只有 II 级那句 0.8）—— 现在由表说了算
            cost = RuleTuning.ByLevel(Cancerous(target) ? tune.ImmuneMoveCancerous : tune.ImmuneMoveHealthy, level);
        }
        return cost;
    }

    /// <summary>【伪足穿透】的邻接门槛与每多一格的折扣（GD `PSEUDOPOD_MIN_ADJ` / `PSEUDOPOD_DISCOUNT`，常量不是旋钮）。</summary>
    public const int PseudopodMinAdjacent = 3;
    public const int PseudopodDiscount = 1;

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
        var delta = ChemoDelta(s, c, destination);
        var trackDelta = TrackDelta(s, c, destination);
        // 两个源**取 OR**：朝任意一个走就算「朝向」，背离任意一个就算「远离」
        // （GD 的 `_cond_ok` 里 `chemo_toward` = `_chemo_delta < 0 or _track_delta < 0`）
        var toward = delta < 0 || trackDelta < 0;
        var away = delta > 0 || trackDelta > 0;

        int pct;
        if (c.Faction == Faction.Immune && toward) pct = c.OwnerSeat == s.Turn.ChemoOwner ? 50 : 70;
        else if (c.Faction == Faction.Cancer && away) pct = 120;
        else return null;
        return new ValueModifier(ModifierStage.Multiply, SourceLayer.Skill, 0, pct, Name: "趋化源");
    }

    /// <summary>走这一步之后，离【I-趋化源】是远了还是近了（负 = 更近）。场上没有就 0。</summary>
    private static int ChemoDelta(WorldState s, Cell c, HexPosition destination)
    {
        if (s.Turn.ChemoRounds <= 0 || s.Turn.ChemoAt is not { } at) return 0;
        return destination.DistanceTo(at) - c.Position.DistanceTo(at);
    }

    /// <summary>
    /// 走这一步之后，离【追踪趋化源】（【免疫猎杀】附着的那个）是远了还是近了。
    ///
    /// **特例：被追的那个癌细胞自己「移动视为远离趋化源」**（PRD 明文）——
    /// 源跟着它走，不特判的话它怎么挪 delta 都是 0，加价永远打不到它身上。
    /// </summary>
    private static int TrackDelta(WorldState s, Cell c, HexPosition destination)
    {
        if (s.Turn.TrackRounds <= 0) return 0;
        if (s.Turn.TrackCell == c.Id) return 1;
        if (TrackAt(s) is not { } at) return 0;
        return destination.DistanceTo(at) - c.Position.DistanceTo(at);
    }

    /// <summary>
    /// 【追踪趋化源】此刻在哪：被追的细胞活着就是它现在站的格，死了就是冻在死亡格上的那个。
    /// 对齐 GD 的 `CWGame.chemo_track_at()`。
    /// </summary>
    public static HexPosition? TrackAt(WorldState s)
    {
        if (s.Turn.TrackRounds <= 0) return null;
        if (s.Turn.TrackCell is { } id && s.Cells.TryGetValue(id, out var c) && c.IsAlive) return c.Position;
        return s.Turn.TrackFrozenAt;
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
            var occupied = world.GetCellAt(to) != null;
            // GD quote_path：占位那一支**根本不报价**（cost 留 0）—— 规划器只规划移动，撞上谁就停在这儿；
            // 敌方占位时 QuoteMove 给得出价钱（那是攻击价），不能让它漏进 steps[].cost（批 1 F12，2026-09-19）
            var quote = occupied ? null : QuoteMove(world, current, to);
            var cost = quote ?? 0;
            string reason;
            if (occupied) reason = "有细胞占据 —— 攻击请单独点它";
            else if (quote == null) reason = "走不到这一格";
            else if (!Settlement.CanPay(budget, cost)) reason = $"能量只剩 {U(budget)}，这一步要 {U(cost)} —— 付完至少要留 0.1";
            else reason = "";
            var legal = reason == "";
            var afford = legal;
            var gain = 0;
            steps.Add(new PathStep(to, cost, legal, afford, reason, gain, PassThroughMid(world, current, to)));   // GD quote_path：mid 在判合法之前就取
            if (!afford) { stop = i; break; }
            budget -= cost;
            total += cost;
            // 这一步花掉的**额度**也要预演（GD issue #35 `burn_allowances`）：【组织驻留】那类「前 N 次免费」的闸门、限次修饰。
            // 不预演的话第二步照样算自己是第一次，整条路线全是 0。在这份丢掉的 world 上烧，与真提交同一条 ConsumeModifiers
            //（批 1 F2，2026-09-19：装【组织驻留】走三步 GD 0/0/5、C# 原来 0/0/0）
            world = world.UpdateCell(current.Id, current);
            world = CellRules.ConsumeModifiers(world, current.Id, ModifierTarget.Move, to);
            current = world.Cells[current.Id];
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

    /// <param name="rawCostOverride">
    /// 卡面自带的起价，见 <see cref="BaseMoveCost"/>。只在「与 cell 相邻」那条分支上生效 ——
    /// 借道前进是一条多格路径，每格各自计价，卡面那个「每步的起价」在那里没有意义。
    /// </param>
    public static int? QuoteMove(WorldState s, Cell cell, HexPosition destination, int? rawCostOverride = null)
    {
        if (!s.Board.Tissues.ContainsKey(destination) || destination == cell.Position) return null;
        var occupant = s.GetCellAt(destination);
        if (cell.Type == CellType.Dendritic && occupant != null) return null;  // 【各司其职】：树突不能向癌细胞移动
        if (occupant != null && (occupant.Faction == cell.Faction || cell.Faction != Faction.Immune || !occupant.IsAlive)) return null;
        if (cell.Position.DistanceTo(destination) == 1) return BaseMoveCost(s, cell, destination, rawCostOverride);
        if (occupant != null) return null; // Passing through allies cannot launch an attack.
        // 借道：起价 = 沿途 raw 之和（RawFor），修饰按落点只跑一遍 —— 与相邻迁移走同一条管线（GD `_move_cost_mod`）
        if (PassThroughRoutes(s, cell).ContainsKey(destination)) return BaseMoveCost(s, cell, destination);
        return null;
    }

    /// <summary>
    /// 借道前进的落点表：{ 落点 → 沿途**起价**之和（修饰之前，GD `pass_through_map`）}。报价要再过一遍修饰管线（<see cref="QuoteMove"/>）——
    /// 从自己出发只在友军占据的格上扩展，任何到达过的友军格相邻的空格都是合法落点，
    /// 费用 = 走到那个友军格的累计 + 落点自己的费用，取最便宜的一条（Dijkstra 小规模版）。
    /// 本来就与自己相邻的格不进这张表（普通迁移更便宜）。
    /// </summary>
    public static Dictionary<HexPosition, int> PassThroughMap(WorldState s, Cell cell)
        => PassThroughRoutes(s, cell).ToDictionary(kv => kv.Key, kv => kv.Value.Cost);

    /// <summary>
    /// 借道落点 → (总价, 第一跳)。与 GD `cw_actions.gd pass_through_map` 同形（那边的值是 `[费用, 第一跳]`）。
    /// 邻居按 <see cref="GdNeighbors"/>（DIRS 序）走：费用取最小与次序无关，**第一跳在同价时取先到的**，次序不同就会挑到另一条同价路 —— 观测协议 `quote_path.mid` 要和 GD 逐字相同。
    /// </summary>
    public static Dictionary<HexPosition, (int Cost, HexPosition First)> PassThroughRoutes(WorldState s, Cell cell)
    {
        var outMap = new Dictionary<HexPosition, (int Cost, HexPosition First)>();
        var reached = new Dictionary<HexPosition, (int Cost, HexPosition First)>();
        var queue = new Queue<HexPosition>();
        foreach (var n in GdNeighbors(s, cell.Position))
        {
            if (!AllyTile(s, cell, n)) continue;
            reached[n] = (RawMoveCost(s, cell, n), n);   // 累计的是**起价**（GD `_one_step_base`），修饰不在这里跑
            queue.Enqueue(n);
        }
        while (queue.Count > 0)
        {
            var cur = queue.Dequeue();
            var (acc, first) = reached[cur];
            foreach (var m in GdNeighbors(s, cur))
            {
                if (m == cell.Position || !s.Board.Tissues.ContainsKey(m)) continue;
                var total = acc + RawMoveCost(s, cell, m);
                if (AllyTile(s, cell, m))
                {
                    if (!reached.TryGetValue(m, out var previous) || total < previous.Cost)
                    {
                        reached[m] = (total, first);
                        queue.Enqueue(m);
                    }
                }
                else if (s.GetCellAt(m) == null)
                {
                    if (!outMap.TryGetValue(m, out var prev) || total < prev.Cost) outMap[m] = (total, first);
                }
            }
        }
        foreach (var n in GdNeighbors(s, cell.Position)) outMap.Remove(n);
        return outMap;
    }

    /// <summary>GD `pass_through_mid`：借道到 <paramref name="to"/> 的第一跳；不在板上 / 原地 / 本来就相邻（那是普通迁移）/ 借不到 = null。</summary>
    public static HexPosition? PassThroughMid(WorldState s, Cell cell, HexPosition to)
    {
        if (!s.Board.Tissues.ContainsKey(to) || to == cell.Position || GdNeighbors(s, cell.Position).Contains(to)) return null;
        return PassThroughRoutes(s, cell).TryGetValue(to, out var route) ? route.First : null;
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
        => Cells(s).Any(c => c.IsAlive && c.Faction == Faction.Immune && HasSkill(s, c, "免疫监视") && c.Position.DistanceTo(pos) <= 3);

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

    // ==== 【中和抗体】闸门 ====
    //
    // PRD:627「所有与健康组织相邻的癌细胞的**种类特殊效果**/**永久卡牌效果**失效，持续 2 世界回合」。
    //
    // GD 把这两件事收在 `type_ability_on()` 与 `has_skill()` 两个闸后面，
    // 并在注释里明写「**别在各处自己写 ctype 判断**」（cw_game.gd:583-592）。
    // C# 此前正是「各处自己写」：`Equipped.Contains(...)` 25 处、`c.Type == CellType.X` 若干，
    // 而那个全局标记只被查了**两处**（【极简胞浆】【伪足穿透】）——
    // 也就是说【中和抗体】几乎什么都没压住：【刚性屏障】【囊性护甲】【瓦伯格超速糖酵解】
    // 与**全部永久技能**都照常生效。

    /// <summary>这个细胞此刻被【中和抗体】压着吗。</summary>
    public static bool Neutralized(WorldState s, Cell c) => s.Turn.WorldRound <= c.NeutralUntil;

    /// <summary>
    /// 这个细胞的**种类特殊效果**此刻生效吗。
    /// 四个癌种的主动技能与被动（伪足穿透 / 极简胞浆 / 刚性屏障 / 囊性护甲 / 瓦伯格）
    /// 都过这一道 —— 别在各处自己写 `c.Type == ...` 判断。
    /// </summary>
    public static bool TypeAbilityOn(WorldState s, Cell c) => !Neutralized(s, c);

    /// <summary>
    /// 这个细胞装着并且**此刻生效**的永久技能吗。
    /// 效果判断一律走这里，别直接 `Equipped.Contains(...)` ——
    /// 那样【中和抗体】压不住它。（「已装备过、别重复抽/重复装」那类**不是效果判断**，
    /// 照旧直接查 `Equipped`。）
    /// </summary>
    /// <summary>
    /// 净化给不给抗原记忆（GD `purify_gives_memory`）：正在结算一张卡就不给 ——
    /// 同步的那段看 `CardResolveDepth`，跨决策点的那段（趋化第 2/3 步）看 `PendingCard`。
    /// **只挡净化给的那一份**：【抗原摄取】那类卡的正业就是送记忆，照给；技能给的（【效应记忆形成】）也照给。
    /// </summary>
    public static bool PurifyGivesMemory(WorldState s)
        => s.Turn.CardResolveDepth <= 0 && s.Turn.PendingCard is null && s.Turn.PendingWalkCard is null;   // 事件卡的连走（GD 嵌在 draw() 的深度里）同样不给

    public static bool HasSkill(WorldState s, Cell c, string skill)
        => !Neutralized(s, c) && c.Equipped.Contains(skill);

    public static bool AdjacentHealthy(WorldState s, HexPosition pos)
        => pos.GetNeighbors().Any(n => s.Board.Tissues.TryGetValue(n, out var t) && t.State == TissueState.Healthy);

    public static bool AdjacentCancerous(WorldState s, HexPosition pos, int atLeast)
        => pos.GetNeighbors().Count(n => s.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t)) >= atLeast;

    public static int AnaerobicShare(WorldState s, Cell c)
    {
        var block = Blocks(s, true).FirstOrDefault(b => b.Contains(c.Position));
        if (block == null) return 0;
        var tune = s.Tuning;
        var living = s.Cells.Values.Count(x => x.IsAlive && x.Faction == Faction.Cancer && block.Contains(x.Position));

        // 逐步对齐 GDScript 的 `CWWorld._anaerobic_pool()` + `_split_share()`（cw_world.gd:797-833）。
        // 单位一律是**十分能量**，和那边一样。
        //
        // 2026-09-19（规格 §0.6.7「四个具名入口」）：这两段**原样**抽成 <see cref="AnaerobicPool"/> 与
        // <see cref="SplitShare"/> —— 一个算符都没动，只是把 GD 本来就分开的两个函数名补上，
        // 好让靶场 / AI 评估单取其中一段（此前只能整条 `AnaerobicShare` 一起取）。
        // GD `anaerobic_gain_for` 写的是 `_split_share(pool, maxi(count, 1))`，`_anaerobic` 那一路则
        // 先 `if here.is_empty(): continue` —— 两条都保证进 `_split_share` 的 count ≥ 1。
        // C# 把这两路合成了一条 `AnaerobicShare`，所以那一刀挪到这里（此前写在 `SplitShare` 里面，
        // 让具名入口 `SplitShare(tune, pool, 0)` 变成一个 GD 没有的口径）。
        // **零行为改动**：living = 0 时 k 的下标 `clamp(0-1,0,2)` 与 `clamp(1-1,0,2)` 同为 0，除数同为 1。
        var income = SplitShare(tune, AnaerobicPool(s, block), Math.Max(1, living));
        // 【瓦伯格超速糖酵解】110% 向上取整到十分位 —— GD `int(ceil(gain * WARBURG_PERCENT / 100.0))`：先乘 110 再除，50 → 55.0 恰好；
        // 此前 C# `income * 1.1` 是浮点 55.00000000000001，ceil 成 56（批扫 4p_1006 / 4p_1009 各多 0.1，2026-09-18）
        if (TypeAbilityOn(s, c) && c.Type == CellType.SmallCellLung) income = (int)Math.Ceiling(income * 110 / 100.0);
        if (HasSkill(s, c, "GLUT1高表达")) income += CancerPhase(s.Turn.WorldRound) switch { 0 => 5, 1 => 8, _ => 10 };
        return income;
    }

    /// <summary>
    /// 【E-无氧呼吸】一个癌性连通块这一次供多少能，**十分能量的浮点数**（规格 §0.6.7 的具名入口之一）。
    /// 逐字对 GD `cw_world.gd:_anaerobic_pool(block)`（797-819）。
    ///
    /// ⚠ **不在这里取整**：GD 那边明写「四舍五入只做一次，在 `_split_share` 里除完再做」。
    /// 先把池子冻成十分整数会取整两次 —— 块内 2 个癌细胞、池子 30.6 时
    /// GD 得 `round(15.3) = 15`，先冻则是 `round(31/2) = 16`。所以返回 `double`。
    ///
    /// 签名对照：GD `_anaerobic_pool(block: Array) -> float`，`game.tiles` / `game.count_tissue` /
    /// `game.order.size()` / `game.tune` 全是环境量；C# 把那个 `game` 显式成第一个参数 `s`。
    ///
    /// 登记一处 C# 今天没有的分支：GD 在 `coef <= 0` 时退回 09-04 之前的**线性求和**
    /// （每格癌组织 `anaerobic_per_cancer`、每格固化 `anaerobic_per_solid`），供对照档用；
    /// C# 从来没实现过它，这一步**照旧不实现**（要改就是行为改动）。默认值下 `coef > 0`，走不到。
    /// </summary>
    internal static double AnaerobicPool(WorldState s, IReadOnlyCollection<HexPosition> block)
    {
        var tune = s.Tuning;
        var ordinary = block.Count(p => s.Board.Tissues[p].State == TissueState.Cancer);
        var solid = Tiles(s).Count(t => t.State == TissueState.SolidifiedCancer);

        // 逐字对 GD `cw_world.gd:_anaerobic_pool`：旋钮 -1 = 按人数取（表里没有的人数退回缺省 —— balance_scan 会扫 5 人 / 7 人这类非正式人数，不能崩）；
        // >0 = 整体覆盖；**0 = 退回 09-04 之前的线性求和**（对照档）。此前 C# 先查分档表，旋钮永远够不着（批 3 KG-1）
        var coef = tune.AnaerobicBlockCoefOverride;
        if (coef < 0) coef = tune.AnaerobicBlockCoefByPlayers.TryGetValue(s.Players.Count, out var cf) ? cf : tune.AnaerobicBlockCoef;
        if (coef > 0)
        {
            var exp = tune.AnaerobicBlockExpOverride;
            if (exp < 0) exp = tune.AnaerobicBlockExpByPlayers.TryGetValue(s.Players.Count, out var ex) ? ex : tune.AnaerobicBlockExp;
            return (ordinary > 0 ? Math.Pow(ordinary, exp / 100.0) : 0.0) * coef + solid * tune.AnaerobicSolidBonus;
        }
        return block.Sum(p => s.Board.Tissues[p].State == TissueState.SolidifiedCancer ? tune.AnaerobicPerSolid : tune.AnaerobicPerCancer);
    }

    /// <summary>
    /// 【E-无氧呼吸】把池子分到一个癌细胞头上（规格 §0.6.7 的具名入口之一），十分能量。
    /// 逐字对 GD `cw_world.gd:_split_share(pool, count)`（828-831）：人数系数 k → 均分 → 四舍五入 → 兜底 → 封顶。
    ///
    /// 签名对照：GD `_split_share(pool: float, count: int) -> int`，`game.tune` 是环境量；
    /// 这一段除 `tune` 外不读世界的任何别的东西，所以 C# 只把 `tune` 显式成第一个参数。
    /// </summary>
    internal static int SplitShare(RuleTuning tune, double pool, int count)
    {
        // `count <= 0`：**GD 那边是未定义行为，不是规则**，所以 C# 不复刻。
        // 实测（Godot 4.5 headless，2026-09-19）：`_split_share(pool, 0)` 走 `scaled / float(0)` 得 inf（pool=0 时 nan），
        // `int(round(inf))` 落成 INT64_MIN，再被 `clamp_income` 的 `anaerobic_floor` 兜成 2.0 ——
        // 答案完全由「地板恰好开着」决定，换个 floor 或换个平台就变。
        // GD 的两个真调用处都保证 ≥ 1（`_anaerobic` 先跳空块、`anaerobic_gain_for` 写 `maxi(count, 1)`），
        // C# 把那一刀放在 `AnaerobicShare` 的调用处。具名入口（规格 §0.6.7）直接被喂 0 时**当场炸**，
        // 不静默给一个 GD 没有的数（COVERAGE 空档 split-share-count-zero 就此收）。
        if (count <= 0)
            throw new NotSupportedException(
                $"split_share(pool, {count})：GD `cw_world.gd:_split_share` 在 count ≤ 0 时是 `scaled / 0.0` 的溢出"
                + "（int(inf) = INT64_MIN，随后被 anaerobic_floor 兜成地板值），那是 UB 不是规则 —— C# 不复刻。"
                + "两个真调用处都保证 count ≥ 1；探针面禁 count ≤ 0");

        // **人数系数 k**（PRD 2026-09-14 / issue #43）：块内 1/2/3 个癌细胞 → 80%/100%/120%，
        // 乘在**整条分式外面**；兜底 2.0 排在它**之后**（PRD 写的是 `max{2, k × …}`）。
        // 2026-09-15 补：C# 此前**完全没有这个系数** —— 独占一块的癌细胞每回合多拿 20%。
        var k = tune.AnaerobicCellsK[Math.Clamp(count - 1, 0, tune.AnaerobicCellsK.Count - 1)];
        var scaled = pool * k / 100.0;

        // 四舍五入**只在这里做一次**：池子是浮点，先取整再除会取整两次（GD 那边专门写了这句注释）
        var income = (int)Math.Round(tune.AnaerobicSplit ? scaled / count : scaled,
            MidpointRounding.AwayFromZero);
        if (tune.AnaerobicFloor > 0) income = Math.Max(tune.AnaerobicFloor, income);
        if (tune.AnaerobicCap > 0) income = Math.Min(tune.AnaerobicCap, income);
        return income;
    }

    /// <summary>
    /// 【S-过载】这个细胞这一次损失多少（十分能量）。PRD 2026-09-15 新增，S 阶段**第 6 步**，
    /// 排在【有氧呼吸】之后。逐位对齐 GDScript 的 `CWWorld.overload_loss()`。
    ///
    /// 公式 `min{15, max{0, ((x − 10) ÷ 2)^1.18}}`，四条实现口径照抄 GD 的注释：
    ///   ① `x ≤ 门槛` 直接 0 —— 底数为负时实数域没有 1.18 次幂，`max{0, …}` 工程上必须钳在**底数**上；
    ///   ② 上限 `OverloadCap`（29.8 能量起损失到顶 15.0，之后恒定）；
    ///   ③ 损失**不超过当前能量** —— 有了 ② 之后默认值下打不到（「扣不死细胞」成了数学性质），
    ///      但**不能删**：上限是旋钮，扫描时抬高或关掉它，交叉点就回来了；
    ///   ④ `OverloadDiv ≤ 0` 关闭整条规则（扫描的对照档，顺带兜住除零）。
    /// </summary>
    public static int OverloadLoss(WorldState s, Cell c)
    {
        var tune = s.Tuning;
        if (tune.OverloadDiv <= 0) return 0;
        var over = c.Energy - tune.OverloadThreshold;
        if (over <= 0) return 0;
        // 换算成显示单位再套 PRD 的式子，最后乘 10 回到十分能量
        var b = over / 10.0 / tune.OverloadDiv;
        var loss = (int)Math.Round(Math.Pow(b, tune.OverloadExp / 100.0) * 10.0, MidpointRounding.AwayFromZero);
        if (tune.OverloadCap > 0) loss = Math.Min(tune.OverloadCap, loss);
        return Math.Min(loss, c.Energy);
    }

    /// <summary>
    /// 【E-微环境压迫】这个免疫细胞这一次损失多少（十分能量），**纯查询**。
    ///
    /// 抽成纯函数有三个读者：E 阶段结算、L0 对拍靶场、以及将来的 AI 评估
    /// （对拍规格 P2 点名的四条纯查询之一）。抽之前它埋在 `BoardRules.Pressure` 的循环里，
    /// 那三个读者只能各自复制一份算式 —— 那正是「同一条规则三个实现」的起点。
    /// </summary>
    public static int PressureAt(WorldState s, HexPosition at)
    {
        // 只读 `State` 一个字段：坏死是叠在健康组织上的计数，坏死格照算健康
        // （所以**不能**图省事改用 Cancerous —— 那会把健康组织的抵消项整个丢掉）。
        var raw = s.Board.GetAdjacentPositions(at).Sum(p => s.Board.Tissues[p].State switch
            { TissueState.Healthy => PressureHealthyWeight, TissueState.Cancer => PressureCancerWeight, _ => PressureSolidWeight });
        // **分期倍率并进乘数，整条只取整一次**（GD `pressure_at` 明写这句）。
        //
        // 2026-09-16 修：C# 原来是「先 round_tenth(raw×10/4)，再 ×3/2 或 ×2」—— **取整了两次**。
        // 实锤：raw=3 的 II 期，GD (3×15+2)/4 = 1.1，C# round(7.5)=8 再 ×3/2 = 1.2。
        // 与今早伤害侧那个「多条倍率要合成一次除法」是同一个形状。
        return Settlement.RoundDiv(Math.Max(0, raw) * PressureMultiplierByStage[Stage(s) - 1], PressureDivisor);
    }

    /// <summary>压迫的三个权重与分期倍率（GD `CWData.PRESSURE_*`，常量不是旋钮）。</summary>
    public const int PressureCancerWeight = 1;
    public const int PressureSolidWeight = 2;
    public const int PressureHealthyWeight = -1;
    public const int PressureDivisor = 4;
    public static readonly IReadOnlyList<int> PressureMultiplierByStage = [10, 15, 20];

    /// <summary>
    /// 【E-增生】这一格这一次转化的概率（**千分率**），**纯查询**。
    ///
    /// 千分率而不是浮点：对拍的随机数带子记的是整数区间抽取
    /// （`randi_range(1,1000) <= chance`），浮点在带子上没有对应物。
    /// 已经是癌性 / 被免疫占着 / 被【免疫监视】盯着的格子返回 0 —— 那几种 GD 也**不掷骰**。
    /// </summary>
    public static int ProliferateChance(WorldState s, HexPosition at)
    {
        if (!s.Board.Tissues.TryGetValue(at, out var t) || Cancerous(t)) return 0;
        if (s.GetCellAt(at)?.Faction == Faction.Immune || Watched(s, at)) return 0;
        return ProliferateChanceRaw(s, at);
    }

    /// <summary>不带闸的千分率（观测协议 `tiles[].d.proliferate_chance`）：与 GD 公开查询 `CWWorld.proliferate_chance(c)` 同口径 ——
    /// GD 那边「健康 / 没被免疫占 / 没被监视」的闸在 E 阶段循环里，公开查询不含它；C# 的闸留在上面的 <see cref="ProliferateChance"/>，规则调用不变。</summary>
    public static int ProliferateChanceRaw(WorldState s, HexPosition at)
    {
        if (!s.Board.Tissues.ContainsKey(at)) return 0;
        var adjacent = at.GetNeighbors().Where(p => s.Board.Tissues.TryGetValue(p, out var n) && Cancerous(n)).ToArray();
        if (adjacent.Length == 0) return 0;

        var stage = Stage(s);
        var blocks = Blocks(s, true);
        var solid = blocks.Where(b => adjacent.Any(b.Contains))
            .Sum(b => b.Count(p => s.Board.Tissues[p].State == TissueState.SolidifiedCancer));
        var permille = RuleTuning.ByStage(s.Tuning.ProliferatePerAdjacent, stage)
            + solid * RuleTuning.ByStage(s.Tuning.ProliferatePerSolid, stage);
        return adjacent.Length * permille;
    }

    public static int AerobicShare(WorldState s, Cell c)
    {
        // GD `aerobic_income` = necrosis_cut(aerobic_share() + _aerobic_bonus)：每份走 AerobicBase（旋钮 aerobic_by_level / aerobic_level_base）
        // → aerobic_split 开时按**存活免疫细胞数**均分（GD `_split_aerobic`，旋钮 aerobic_split_ref）
        // → 【TGF-β释放】逐份 ×80% 向下取整（定案 #63，强度是同名条目求和；只算不结算，消耗在 PhaseRules 的有氧那一步）
        // → **之外**再加【代谢适应】【自分泌生存信号】的额外获得（不吃 TGF-β，口径 #69）→ 站在坏死格整份打 5 折四舍五入。
        // 此前 C# 先加了额外获得再打 TGF 折：6p 第 187 步 GD 16 + 5 = 21、C# (20 + 5) × 0.8 = 20（2026-09-17）
        var share = AerobicBase(s, c);
        // GD `aerobic_share` 的 `clamp_income(aerobic_floor, aerobic_cap)`（cw_tuning.gd:199）夹在**基准**上、
        // **排在均分之前** —— 顺序反过来的话 2.0 的低保会把 2.5÷3=0.8 顶回 2.0，均分等于没开
        // （GD 注释里记着 2026-09-05 t_batch2_rules 当场抓到这条）。
        // 2026-09-19 迁：此前 C# 整条没有（`AerobicShare` 那句注释写的「批 5b」是笔误，应为批 2 第二段，
        // COVERAGE 空档 aerobic-floor-cap-not-migrated）。两个旋钮默认都是 0 = 恒等 ⇒ 默认值下这两行逐位不改结果。
        if (s.Tuning.AerobicFloor > 0) share = Math.Max(s.Tuning.AerobicFloor, share);
        if (s.Tuning.AerobicCap > 0) share = Math.Min(s.Tuning.AerobicCap, share);
        if (s.Tuning.AerobicSplit) share = SplitAerobic(s.Tuning, share, Cells(s).Count(x => x.IsAlive && x.Faction == Faction.Immune));
        for (var i = 0; i < WorldEffects.Stacks(s, "TGF-β释放"); i++) share = share * 8 / 10;
        var bonus = (HasSkill(s, c, "代谢适应") ? 5 : 0) + (HasSkill(s, c, "自分泌生存信号") ? 8 : 0);   // AEROBIC_ADAPT / AEROBIC_AUTOCRINE
        var income = share + bonus;
        if (s.Board.Tissues[c.Position].NecrosisRounds > 0) income = NecrosisCut(s.Tuning, income);   // 旋钮 necrosis_aerobic_pct（默认 50 = 减半）
        return income;
    }

    /// <summary>GD `CWData.TOTAL_TILES`（常量不是旋钮）：棋盘总格数 **127**，盘面式有氧的分母。
    /// **不是「当前棋盘有几格」** —— GD 那边写死的就是这个常量，所以 L0 的小盘面同样除 127。</summary>
    public const int TotalTiles = 127;

    /// <summary>GD `CWData.AEROBIC_LEVEL_BASE_BY_PLAYERS` / `AEROBIC_LEVEL_BASE`（常量不是旋钮，所以不进 `RuleTuning`）：
    /// `aerobic_level_base &lt; 0` 时按人数取基数（二人 2.0 / 四人 2.0 / 六人 1.8，09-05 方案 f）；
    /// 表里没有的人数退回 <see cref="AerobicLevelBaseDefault"/> —— balance_scan 会扫 5 人 / 7 人这类非正式人数，不能崩。</summary>
    public const int AerobicLevelBaseDefault = 20;
    public static readonly IReadOnlyDictionary<int, int> AerobicLevelBaseByPlayers =
        new Dictionary<int, int> { [2] = 20, [4] = 20, [6] = 18 };

    /// <summary>
    /// 一份【有氧呼吸】的基准 = GD `CWWorld._aerobic_base`（cw_world.gd:557）。三条档，**表档最优先**：
    ///   ① `aerobic_by_level` 非空 ⇒ 按抗原记忆等级查表（GD 是 `clampi(immune_level, 0, size-1)`；
    ///      C# 的 `ImmuneLevel` 枚举 1 起，减一正好是 GD 那个 0 起的下标）；
    ///   ② 置空 ⇒ 线性档 `base + step × 等级`，`base &lt; 0` 先按人数取（<see cref="AerobicLevelBaseByPlayers"/>）；
    ///   ③ `base == 0` ⇒ 退回 09-04 之前的**盘面式** `(健康 − 坏死) × aerobic_mult_at(round) ÷ TOTAL_TILES`，
    ///      四舍五入到十分位（GD `CWData.round_tenth` ≡ <see cref="Settlement.RoundDiv"/>）。
    ///      「坏死」格照旧要数：它虽然是健康组织，但**不为免疫供能**。这一条 GD 明写「必须逐位不变」，
    ///      否则 09-04 之前的扫描数据全作废。
    ///
    /// 2026-09-19 迁 ②③（COVERAGE 空档 aerobic-board-formula-not-migrated）：此前两条都抛 NotSupportedException。
    /// 盘面式的系数 = GD `tune.aerobic_mult_at(n)` = `maxi(aerobic_mult + aerobic_mult_growth × maxi(n−1, 0), 0)`；
    /// `aerobic_mult_growth` 是 E-3 **判死**的旋钮（B 档，两侧拧了都当场红），C# 没有它 ⇒ 只剩 `maxi(aerobic_mult, 0)`，
    /// 与 GD 在 growth = 0（唯一可装载的取值）时逐位相同。**那个 `maxi(…, 0)` 不能删**：负系数会让整数除法
    /// 从「向下取整」翻成「向零截断」，取整口径当场翻面（GD 2026-09-01 第一版就漏过这句）。
    /// </summary>
    internal static int AerobicBase(WorldState s, Cell c)
    {
        var t = s.Tuning;
        var level = (int)s.Players[c.OwnerSeat].ImmuneLevel - 1;   // GD `game.immune_level` 是 0 起
        if (t.AerobicByLevel.Count > 0) return t.AerobicByLevel[Math.Clamp(level, 0, t.AerobicByLevel.Count - 1)];

        // -1 = 按人数取；>0 = 整体覆盖；0 = 退回盘面式（GD `_aerobic_base` 的三句照抄）
        var b = t.AerobicLevelBase;
        if (b < 0) b = AerobicLevelBaseByPlayers.TryGetValue(s.Players.Count, out var byPlayers) ? byPlayers : AerobicLevelBaseDefault;
        if (b > 0) return b + t.AerobicLevelStep * level;

        var healthy = 0;
        var necrotic = 0;
        foreach (var tile in Tiles(s))
        {
            if (tile.State != TissueState.Healthy) continue;
            healthy++;
            if (tile.NecrosisRounds > 0) necrotic++;
        }
        return Settlement.RoundDiv((healthy - necrotic) * Math.Max(t.AerobicMult, 0), TotalTiles);
    }

    /// <summary>【有氧呼吸】按存活免疫细胞数均分 = GD `CWWorld._split_aerobic`（cw_world.gd:542）：
    /// `ref` 份总额均分、四舍五入到十分位（`(2p·ref + n) / (2n)` 的整数写法）；
    /// `ref ≤ 0` 退化成纯「÷ n」，`n ≤ ref` 每人全额。**纯函数**，测试直接核对。</summary>
    internal static int SplitAerobic(RuleTuning t, int perCell, int n)
    {
        var refN = t.AerobicSplitRef;
        if (n <= 0) return perCell;
        if (refN <= 0) return (2 * perCell + n) / (2 * n);
        if (n <= refN) return perCell;
        return (2 * perCell * refN + n) / (2 * n);
    }

    /// <summary>站在坏死格上那一份打折 = GD `CWWorld.necrosis_cut`（cw_world.gd:440）：
    /// `CWData.round_tenth(gain × pct, 100)` = `(gain × pct + 50) / 100` 的整数四舍五入（PRD 通用规则 1）。
    /// pct = 50 时与此前写死的 `Settlement.RoundTenth(income × 0.5)` 对每个非负 income 逐位相同。</summary>
    internal static int NecrosisCut(RuleTuning t, int gain) => (gain * t.NecrosisAerobicPct + 50) / 100;

    /// <summary>GD `CWData.DIRS` 序的六邻（(1,0)(1,-1)(0,-1)(-1,0)(-1,1)(0,1)），裁掉板外格。
    /// 凡是「按下标抽格」或「逐格出选项」的地方都走它 —— <see cref="HexPosition.GetNeighbors"/> 是另一个顺序，
    /// 同一个带子值会指到不同的格（【放疗】的扩区就靠这一条对带子）。</summary>
    public static IEnumerable<HexPosition> GdNeighbors(WorldState s, HexPosition p)
    {
        foreach (var (dq, dr) in GdDirs)
        {
            var n = new HexPosition(p.Q + dq, p.R + dr, -(p.Q + dq) - (p.R + dr));
            if (s.Board.Tissues.ContainsKey(n)) yield return n;
        }
    }
    private static readonly (int Dq, int Dr)[] GdDirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];

    /// <summary>GD `blocks_of(pred)`（cw_game.gd）的**逐格同序**版：按 `game.tiles.keys()`（Q↑R↑）起点、
    /// 栈式深搜（`queue.pop_back()`）、邻格按 DIRS 序入栈。块与块内的顺序都和 GD 一样 ——
    /// 【侵蚀】的候选表是按这个顺序拼起来再 pick_n 的，顺序差一位带子就指错格。
    /// 只在需要**顺序**的地方用它；只要集合的地方 <see cref="Blocks"/> 更便宜。</summary>
    public static List<List<HexPosition>> GdBlocks(WorldState s, Func<Tissue, bool> pred)
    {
        var seen = new HashSet<HexPosition>();
        var result = new List<List<HexPosition>>();
        foreach (var t in Tiles(s))
        {
            if (seen.Contains(t.Position) || !pred(t)) continue;
            var block = new List<HexPosition>();
            var stack = new List<HexPosition> { t.Position };
            seen.Add(t.Position);
            while (stack.Count > 0)
            {
                var cur = stack[^1];
                stack.RemoveAt(stack.Count - 1);
                block.Add(cur);
                foreach (var n in GdNeighbors(s, cur))
                    if (!seen.Contains(n) && pred(s.Board.Tissues[n])) { seen.Add(n); stack.Add(n); }
            }
            result.Add(block);
        }
        return result;
    }

    /// <summary>GD `_empty_healthy_in_range`（cw_card_fx.gd）：center 的 rings 环内、无细胞占据的健康组织，**含中心格**；
    /// 顺序 = <see cref="Tiles"/> 的 (Q,R) 升序 = GD `game.tiles.keys()` 的插入序 —— 按下标抽落点的带子就靠这一条对上。
    /// 选项层与结算层共用这一份列表（GD 的 `hand_options` 与 `_reinforce` 调的是同一个函数）。</summary>
    public static IReadOnlyList<HexPosition> EmptyHealthyWithin(WorldState s, HexPosition center, int rings)
        => Tiles(s).Where(t => t.State == TissueState.Healthy && t.OccupyingCell == null && t.Position.DistanceTo(center) <= rings)
                   .Select(t => t.Position).ToList();

    /// <summary>GD `_empty_cancerous_in_range`：rings 环内、无细胞占据的癌性组织（**含固化**），含中心格，顺序同上。</summary>
    public static IReadOnlyList<HexPosition> CancerousLandings(WorldState s, HexPosition center, int rings)
        => Tiles(s).Where(t => Cancerous(t) && t.OccupyingCell == null && t.Position.DistanceTo(center) <= rings)
                   .Select(t => t.Position).ToList();

    /// <summary>【放疗】的随机连通区域，逐行照 GD `_radiotherapy`（cw_card_fx.gd:987-1004）：
    /// frontier 是**允许重复入队的多重集**，每轮只掷一发 `NextInt(frontier.Count)`（Count==1 时带子零消耗），
    /// 弹到已在区域里的格照样消耗这一发但区域不长；直到 <paramref name="count"/> 格或 frontier 空。
    /// 此前的 ConnectedRegion 是「选生长点 + 选方向」两发一格的另一套形状，带子对不上，2026-09-17 整个换掉。</summary>
    public static List<HexPosition> RadioRegion(WorldState s, HexPosition start, int count, IDeterministicRng rng)
    {
        var region = new List<HexPosition> { start };
        var inRegion = new HashSet<HexPosition> { start };
        var frontier = new List<HexPosition>(GdNeighbors(s, start));
        while (region.Count < count && frontier.Count > 0)
        {
            var i = rng.NextInt(frontier.Count);
            var c = frontier[i];
            frontier.RemoveAt(i);
            if (!inRegion.Add(c)) continue;
            region.Add(c);
            foreach (var n in GdNeighbors(s, c))
                if (!inRegion.Contains(n)) frontier.Add(n);
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
    public static int AntibodyDamage(RuleTuning tune, int used, bool matured = false)
    {
        var tenths = matured ? 20 : 15;
        if (tune.AntibodyHalve) for (var i = 0; i < used; i++) tenths /= 2;   // GD cw_actions.gd:1223 `if not game.tune.antibody_halve: return dmg`：旋钮关掉 = 2026-09-01~09-04 那版「每次都打满」的老行为，用来做对照局
        return tenths;
    }

    /// <summary>
    /// 攻击判词。收 `WorldState` 只为了把【免疫突触成熟】也走 `HasSkill` ——
    /// 今天它压不到（【中和抗体】只落在癌细胞上，而这是免疫技能），
    /// 但「效果判断一律过闸」这条规矩不留例外，例外正是这类 bug 的住处。
    /// </summary>
    public static string AttackOutcome(WorldState s, int roll, Cell attacker)
        => HasSkill(s, attacker, "免疫突触成熟")
            ? roll >= 5 ? "crit" : roll == 1 ? "fail" : "success"
            : roll == 6 ? "crit" : roll <= 2 ? "fail" : "success";
}
