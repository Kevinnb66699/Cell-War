using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// L0 探针表（P 族）：**名字 → 一个纯查询**。
///
/// 只收纯查询 —— 不推进流程、不掷骰、不改状态。L0 的全部价值就在这条约束上：
/// 每条用例互相独立，C# 少一条规则**只污染那一行**，不会顺着流程污染一整局。
/// 会改状态的那一族（S 族契约步）住在 `L0/Steps.cs`。
/// 要验流程编排与修饰器叠加顺序得靠 L1，那是另一件事（L0 全绿不是出口条件，只是必要条件）。
///
/// 加探针的规矩：**名字与 GDScript 那边的入口同名**，
/// 否则「两边跑同一份 JSON」这件事在名字这一层就先散了。
///
/// **两边签名不同的怎么办（Kevin 2026-09-19 拍 E-6，三条规矩）**：
/// 1. **GD 的边界是权威**（它是口径二的正本），要挪就 C# 挪；
/// 2. 挪不动的（会动 C# 骨架的）**登记 `OUT_OF_SCOPE` 不进 L0**，对应断言留 GD 并在 `xcheck/COVERAGE.md` 里显式列出；
/// 3. **一律不写转换层** —— 硬凑等于在靶场里再写一遍规则。
///
/// 分派集合由 `game/tests/contract_ops.json` 定死（§0.6.4 第 4 条）：
/// 表里 `status ∈ {OK, KNOWN_GAP, UNDEFINED}` 的 P 族行 ≡ <see cref="Names"/>，**16 条**。
/// 其中 6 条是**空壳**（`deferred`：本批未开工，调用即抛）——
/// 批 0 已把 `const`（<see cref="ConstTable"/>）与 `settle_loss` 两条填上。
/// </summary>
public static class Probes
{
    /// <summary>
    /// 返回值放宽成 `object`（规格 A-1 / C-1 步 9）：`scalar` 是整数、`tree` 是一棵字面 JSON 树（如 `quote_path`）。
    /// 判定不在这里做，交给 <see cref="L0Expect.Judge"/>。
    /// </summary>
    public delegate object Probe(WorldState s, Args args);

    internal static readonly Dictionary<string, Probe> Table = new(StringComparer.Ordinal)
    {
        // ---- 移动费用 ----
        ["move_cost"] = (s, a) => RulePolicies.QuoteMove(s, a.Cell(s), a.Pos("to"))
            ?? throw new InvalidOperationException("这一步走不到 —— 用例要么写错了目标，要么该改成验「走不到」"),

        // ---- 收入 ----
        ["anaerobic_share"] = (s, a) => RulePolicies.AnaerobicShare(s, a.Cell(s)),
        ["aerobic_share"] = (s, a) => RulePolicies.AerobicShare(s, a.Cell(s)),

        // ---- E 阶段 ----
        // 对的是 GD 的 `pressure_at`（**原始值**，不含【耗竭抵抗】的 −0.5）——
        // 那 −0.5 两边住的地方不同（GD 在伤害管线、C# 在调用点），
        // 拿含它的值对会把**分工差异**误报成**规则差异**
        ["pressure_at"] = (s, a) => RulePolicies.PressureAt(s, a.Pos("at")),
        ["proliferate_chance"] = (s, a) => RulePolicies.ProliferateChance(s, a.Pos("at")),
        ["solidify_threshold"] = (s, _) => BoardRules.SolidifyThreshold(s),

        // ---- S 阶段 ----
        ["overload_loss"] = (s, a) => RulePolicies.OverloadLoss(s, a.Cell(s)),

        // ---- 攻击 ----
        // 判词是字符串，这里编码成 0/1/2 —— 与 GD 的 `attack_outcome` 同一套整数值域
        ["attack_outcome"] = (s, a) => RulePolicies.AttackOutcome(s, a.Int("roll"), a.Cell(s)) switch
        {
            "fail" => 0,
            "success" => 1,
            "crit" => 2,
            var other => throw new InvalidOperationException($"不认识的攻击判词：{other}"),
        },

        // ---- 空壳（§0.6.4 第 5 条：进分派表、零用例；调用即抛）----
        // 空壳也必须在表里：双射断言比的是**分派表的键集合**，缺一个两侧就对不上。
        ["move_raw_cost"] = Deferred("move_raw_cost"),
        ["pass_through_cost"] = Deferred("pass_through_cost"),   // KNOWN_GAP（0.4-bis #6）
        ["quote_path"] = Deferred("quote_path"),
        // §0.6.7 四条里还没开工的三条：Kevin 2026-09-19 接受，C# 入口已开（MoveLegal / AnaerobicPool / SplitShare）；探针面随各批定
        ["move_legal"] = Deferred("move_legal"),
        ["anaerobic_pool"] = Deferred("anaerobic_pool"),
        ["split_share"] = Deferred("split_share"),

        // ---- 批 0：常量表 + 纯静态五进一出 ----
        // 一个探针管一整张常量表（§B 批 0：**不要一个常量一个探针**），表在 ConstTable
        ["const"] = Const,
        // PRD「能量损失计算顺序」①基础 ②固定加 ③倍增 ④倍减 ⑤固定减、兜 0；GD 侧 CWGame.settle_loss 同一套五参
        ["settle_loss"] = (_, a) => Settlement.SettleLoss(a.Int("base"), a.Int("add"), a.Int("mult"), a.Int("div"), a.Int("cut")),

        // 【抗体】的伤害暂不进探针表：GD 的 `antibody_damage(cell)` 收的是**细胞**
        // （自己从细胞身上读用过几次、装没装【抗体亲和力成熟】），C# 的是 `(used, matured)` 两个标量。
        // 按上面 E-6 的规矩 1，要么 C# 挪齐边界，要么它登记 OUT_OF_SCOPE 不进 L0。
    };

    private static Probe Deferred(string name)
        => (_, _) => throw new NotImplementedException($"本批未开工：探针 {name} 在 contract_ops.json 里是 deferred（空壳）");

    /// <summary>
    /// 常量表（探针 <c>const</c>）：**GD 全名 → 一个取值**。一个探针管一整张表
    /// （规格 §B 批 0：「不要一个常量一个探针」），键与 GD 侧 `game/tests/l0_runner.gd:_build_consts`
    /// **逐字相同**（人工核，没有机器闸）。
    ///
    /// 表项只**转调 / 取值，一行算式都不写**（纪律 3）—— 写了就从「两边算出同一个数」
    /// 变成「两边各抄了一份同样的算式」，那种绿灯不作数。
    ///
    /// **传输形状**（两侧表项逐字同一套，GD 侧 l0_runner.gd 上有同一段注释）：
    /// * int → <c>scalar</c>，裸整数原样；
    /// * bool → <c>scalar</c>，写 1 / 0（本表里只有 <c>is_world_event_round</c>）；
    /// * float → 按**千分位**冻成整数 <c>round(x * 1000)</c> —— 批 0 一个都没有，口径先立着；
    /// * 表 / 字典 → <c>tree</c>：坐标写 <c>"q,r"</c>（这边调 <see cref="WorldLoader.At"/>，
    ///   GD 那边由 runner 的 <c>_to_json()</c> 收口，出来的字符串逐字相同）、枚举写整数值。
    ///
    /// **21 个符号 C# 没有对应物**（或只有 <c>private</c>）：进表但抛 <see cref="NotSupportedException"/>，
    /// 对应断言留在 GD 的老 <c>check()</c> 里、用例不进仓库（清单见 `contract_ops.json` 的 `const` 行 `note`，
    /// 空档记在 `xcheck/COVERAGE.md`）。**不许**在这儿写个字面量假装有对应物 —— 那是把靶画在自己身上。
    /// </summary>
    internal static readonly Dictionary<string, Func<WorldState, Args, object>> ConstTable = new(StringComparer.Ordinal)
    {
        // ---- CWData · 常量（int → scalar）----
        ["CWData.BOARD_RADIUS"] = (_, _) => MatchSetup.BoardRadius,
        ["CWData.TOTAL_TILES"] = NoCs("CWData.TOTAL_TILES", "RulePolicies.cs:638 只在注释里提到，没有具名常量"),
        ["CWData.ANAEROBIC_BLOCK_EXP"] = (_, _) => RuleTuning.Default.AnaerobicBlockExp,
        ["CWData.ANAEROBIC_BLOCK_COEF"] = (_, _) => RuleTuning.Default.AnaerobicBlockCoef,
        ["CWData.ANAEROBIC_SOLID_BONUS"] = (_, _) => RuleTuning.Default.AnaerobicSolidBonus,
        ["CWData.NECROSIS_AEROBIC_PCT"] = (_, _) => RuleTuning.Default.NecrosisAerobicPct,
        ["CWData.DIFFERENTIATE_MIN_LEVEL"] = NoCs("CWData.DIFFERENTIATE_MIN_LEVEL", "PlacementRules.cs:37 直接比 ImmuneLevel.III 枚举，没有具名常量"),
        ["CWData.HAND_MAX"] = NoCs("CWData.HAND_MAX", "只有 Cell.HandMax 的 record 字段缺省（WorldState.cs:431），Cell 有 required 成员，取不到静态值"),
        ["CWData.PSEUDOPOD_COST"] = (_, _) => RuleTuning.Default.PseudopodCost,
        ["CWData.EMT_MOVE_COST"] = NoCs("CWData.EMT_MOVE_COST", "CardRules.cs:170 行内字面量 2"),
        ["CWData.MUTATE_EXTRA_LOSS"] = NoCs("CWData.MUTATE_EXTRA_LOSS", "CardRules.cs:645 行内 8"),
        ["CWData.MUTATE_MEMORY_CUT"] = NoCs("CWData.MUTATE_MEMORY_CUT", "grep 全 core 无具名常量"),
        ["CWData.ATTACK_MAX_PER_TURN"] = (_, _) => RuleTuning.Default.AttackMaxPerTurn,
        ["CWData.MACRO_MOVE_NET_MIN"] = (_, _) => CellRules.MacroMoveNetMin,
        ["CWData.CHEMO_IMMUNE_PCT"] = NoCs("CWData.CHEMO_IMMUNE_PCT", "grep 全 core 无具名常量"),
        ["CWData.CHEMO_SELF_PCT"] = NoCs("CWData.CHEMO_SELF_PCT", "grep 全 core 无具名常量"),
        ["CWData.MARK_RANGE"] = NoCs("CWData.MARK_RANGE", "grep MarkRange / MarkRadius 都没有"),
        ["CWData.HUNT_CHEMO_ROUNDS"] = (_, _) => SkillRules.HuntChemoRounds,
        // ---- CWData · 常量表（表 / 字典 → tree）----
        ["CWData.LEVEL_MIN_MEMORY"] = NoCs("CWData.LEVEL_MIN_MEMORY", "免疫等级门槛表 C# 侧整张没有（grep 全 core）"),
        ["CWData.AEROBIC_BY_LEVEL"] = (_, _) => RuleTuning.Default.AerobicByLevel,
        ["CWData.PROLIFERATE_BASE_BY_STAGE"] = (_, _) => RuleTuning.Default.ProliferatePerAdjacent,   // 名字两边不同，值域同（[30, 35, 40]）
        ["CWData.PROLIFERATE_SOLID_BY_STAGE"] = (_, _) => RuleTuning.Default.ProliferatePerSolid,   // 同上（[5, 10, 10]）
        ["CWData.VESSELS"] = NoCs("CWData.VESSELS", "MatchSetup.Vessels 是 private static readonly（MatchSetup.cs:20），测试够不着"),
        ["CWData.EFFECTOR_NAMES"] = NoCs("CWData.EFFECTOR_NAMES", "文案表，C# 没搬（SemanticKey.cs:161 只在注释里提到）"),
        ["CWData.IMMUNE_TYPE_TEXT"] = NoCs("CWData.IMMUNE_TYPE_TEXT", "细胞详情文案，C# 没搬"),
        // ---- CWData · 静态函数 ----
        ["CWData.init_cancer_tiles"] = NoCs("CWData.init_cancer_tiles", "MatchSetup.cs:74 私有方法里的 `playerCount >= 6 ? 24 : 15`，没有具名入口"),
        ["CWData.aerobic_level_base"] = NoCs("CWData.aerobic_level_base", "C# 只有标量 AerobicLevelBase，没有按人数分档表（RulePolicies.cs:637 / RuleTuning.cs:107 明写未迁）"),
        // GD `anaerobic_cells_k(n_cells)` 的 n_cells 是 1 起的块内癌细胞数，C# 的表是 0 起的裸表
        // （clamp 住在 RulePolicies.cs:520 的调用点上，不在表上）—— 这里只换下标基，不补 clamp
        ["CWData.anaerobic_cells_k"] = (_, a) => Row(RuleTuning.Default.AnaerobicCellsK, a.Int("a") - 1, "CWData.anaerobic_cells_k"),
        ["CWData.level_min_memory"] = NoCs("CWData.level_min_memory", "同 LEVEL_MIN_MEMORY，按人数分档表 C# 也没有"),
        ["CWData.antibody_no_target_x"] = (_, a) => Row(SkillRules.AntibodyNoTargetX, a.Int("a"), "CWData.antibody_no_target_x"),
        ["CWData.skill_text"] = NoCs("CWData.skill_text", "技能文案，C# 没搬"),
        ["CWData.all_coords"] = NoCs("CWData.all_coords", "MatchSetup.AllCoords 是 private（MatchSetup.cs:95），测试够不着"),
        ["CWData.ring"] = NoCs("CWData.ring", "SkillRules.cs:247 用 DistanceTo <= n 内联，没有具名入口"),
        ["CWData.neighbors"] = (s, a) => RulePolicies.GdNeighbors(s, a.Pos("a")).Select(WorldLoader.At).ToList(),   // DIRS 序、裁板外；GD 那边按 board_radius 裁，这边按 s.Board 裁 —— 同一个盘面上等价
        ["CWData.hex_dist"] = (_, a) => a.Pos("a").DistanceTo(a.Pos("b")),   // GD 是两参静态函数，C# 是实例方法：转调，不算无对应物
        ["CWData.dir_toward"] = (_, a) => Stage.DirToward(a.Pos("a"), a.Pos("b")),   // a = dest，b = from（同 GD 的形参序）
        ["CWData.is_world_event_round"] = (_, a) => WorldEffects.IsWorldEventRound(a.Int("a")) ? 1 : 0,   // bool → scalar 的 1 / 0：两侧表项各自冻，不靠 runner 的隐式转换
        // ---- CWCardData ----
        ["CWCardData.CARDS"] = NoCs("CWCardData.CARDS", "C# 是 CardDefinition 记录表（Cards.All），GD 是「文案 + 双阵营权重」字典 —— 等值比不可能成立"),
        ["CWCardData.cancer_phase"] = (_, a) => RulePolicies.CancerPhase(a.Int("a")),
        ["CWCardData.effect_of"] = NoCs("CWCardData.effect_of", "Cards.cs 不带 effect 文案"),
    };

    /// <summary>按名字取一个静态符号的值。名字不在表里 = 当场炸（两侧表的键集合必须逐字相同）。</summary>
    private static object Const(WorldState s, Args a)
    {
        var name = a.Str("name");
        if (!ConstTable.TryGetValue(name, out var fn))
            throw new InvalidOperationException(
                $"常量表里没有「{name}」—— 两侧表的键集合必须逐字相同（Probes.ConstTable ↔ l0_runner.gd:_build_consts）");
        return fn(s, a);
    }

    /// <summary>C# 侧没有对应符号（或只有 <c>private</c>）的：进表占位，调用即抛。</summary>
    private static Func<WorldState, Args, object> NoCs(string gdName, string why)
        => (_, _) => throw new NotSupportedException($"C# 无对应物：{gdName} —— {why}");

    /// <summary>
    /// 分档表**只按下标取值**。GD 那边的 <c>clampi</c> 住在静态函数里，C# 只有裸表 + 调用点内联的 clamp ——
    /// 在靶场里补一个 clamp 就是重写规则（纪律 3 / E-6 规矩 3），所以越界当场抛，
    /// 「越界钳住」那几条断言留 GD（`xcheck/COVERAGE.md` 记空档）。要收进来得先按 §0.6.7 的先例开具名入口。
    /// </summary>
    private static T Row<T>(IReadOnlyList<T> table, int index, string gdName)
        => index >= 0 && index < table.Count
            ? table[index]
            : throw new NotSupportedException(
                $"C# 无对应物：{gdName} 的越界钳住住在 GD 的静态函数里，C# 只有裸表（下标 {index} 越界）");

    public static IReadOnlyCollection<string> Names => Table.Keys;

    /// <summary>调一个探针。参数记账在这里收口 —— 绕过它直接取 <see cref="Table"/> 会丢掉「写错键名当场炸」。</summary>
    public static object Run(string probe, WorldState s, Dictionary<string, string> args)
    {
        if (!Table.TryGetValue(probe, out var fn))
            throw new InvalidOperationException(
                $"不认识的探针：{probe}。已有：{string.Join(" / ", Table.Keys.Order(StringComparer.Ordinal))}");
        var bag = new Args(probe, args);
        var value = fn(s, bag);
        bag.AssertAllUsed();   // 跑完再查：写错键名的用例不许悄悄绿
        return value;
    }

    /// <summary>
    /// 探针 / 契约步的参数（记账机制**同时给 `L0/Steps.cs` 用**，规格 A-6）。
    /// **取过的键要记账、没取过的键当场炸** ——
    /// 写错键名（`form` 打成 `from`）会让那条用例悄悄验了别的东西，
    /// 而它照样绿。这是数据化测试最容易出的那种假绿灯。
    /// </summary>
    public sealed class Args(string probe, Dictionary<string, string> raw)
    {
        private readonly HashSet<string> used = new(StringComparer.Ordinal);

        public int Int(string key)
        {
            var text = Take(key);
            return int.TryParse(text, out var v)
                ? v
                : throw new InvalidOperationException($"{probe} 的参数 {key} 不是整数：{text}");
        }

        public bool Bool(string key) => Int(key) != 0;

        public string Str(string key) => Take(key);

        /// <summary>可选参数：没写就用缺省，写了照样记账。</summary>
        public string Str(string key, string fallback)
        {
            used.Add(key);
            return raw.GetValueOrDefault(key, fallback);
        }

        public HexPosition Pos(string key) => WorldLoader.Pos(Take(key));

        /// <summary>坐标表 `"1,0;2,-1"`；没写就是空表。</summary>
        public IReadOnlyCollection<HexPosition> Positions(string key)
        {
            used.Add(key);
            var text = raw.GetValueOrDefault(key, "");
            return text.Length == 0
                ? []
                : text.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(WorldLoader.Pos).ToArray();
        }

        /// <summary>参数是**席位**号（对拍规格的约定），这里换回细胞。</summary>
        public Cell Cell(WorldState s, string key = "cell") => WorldLoader.CellOfSeat(s, Int(key));

        private string Take(string key)
        {
            used.Add(key);
            return raw.TryGetValue(key, out var v)
                ? v
                : throw new InvalidOperationException($"{probe} 缺参数 {key}");
        }

        /// <summary>跑完之后叫一次：有没有谁写了用不上的参数。</summary>
        public void AssertAllUsed()
        {
            var extra = raw.Keys.Where(k => !used.Contains(k)).Order(StringComparer.Ordinal).ToArray();
            if (extra.Length > 0)
                throw new InvalidOperationException(
                    $"{probe} 用不上这些参数：{string.Join(" / ", extra)} —— 多半是键名写错了，那会让这条用例悄悄验了别的东西");
        }
    }
}
