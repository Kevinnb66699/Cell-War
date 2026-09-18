using CellWar.Core;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// L0 的 **S 族分派表**：契约步名 → 会改状态的一步（测试迁移规格 §0.6.4）。
///
/// **显式白名单，不用反射** —— 反射会在 C# 改名时静默换靶。
/// 表里的名字必须与 `game/tests/contract_ops.json` 里 `kind: "step"` 且
/// `status ∈ {OK, KNOWN_GAP, UNDEFINED}` 的行逐名相同（<see cref="ContractGateTests"/> 盯着），
/// 而那张表才是唯一的 op 白名单：表外的名字代理不覆写、runner 不分派、用例不许引用。
///
/// **26 项全是真转调**（批 4 把 `damage_hit` 换成 <see cref="CellRules.Damage"/>）。不进表的四条：
/// `chaos_return`（NOTIMPL，C# 未实现，`BoardRules.EvolveEndOfRoundB` 里是一行 EV-1 注释）、
/// `check_immune_win` / `check_cancer_win`（OUT_OF_SCOPE，实体在 `OutcomeRules.Evaluate`，
/// 且与规格 §0.2「整局 / 状态机驱动的那一档不进 L0」冲突），
/// 决策类 op 已随批 1 的 C-2 步 1 进表，名字用 GD 入口名 `execute`（§0.6.4 第 1 条）。
///
/// **rng 的约定**：带子由 runner 从用例的 `rolls` 造（`L1/TapeRng.cs`），这里一律念带子、不自己掷。
/// 契约表里 `rng: false` 的步跑完 <see cref="TapeRng.Consumed"/> 必须还是 0 ——
/// 「说好不掷骰的步偷偷掷了」是最难查的那种错位，runner 那头（R1）拿这一条当断言。
/// </summary>
internal static class Steps
{
    /// <summary>一步：吃世界、参数、带子，吐新世界。</summary>
    internal delegate WorldState Step(WorldState s, Args a, TapeRng rng);

    private static readonly Dictionary<string, Step> Table = new(StringComparer.Ordinal)
    {
        // ---- S 阶段（5）----
        ["reset_round_flags"] = (s, _, _) => CellRules.ResetRoundFlags(s),
        // ⚠ 不是 `BoardRules.Produce`：它头一行就是 ResetRoundFlags、末尾还 CollectSpecial，
        //    录 GD `_tissue_production` 的差分、重放 Produce 会多出一整轮标志位重置（规格 §0.4(b) 18）
        ["tissue_production"] = (s, _, rng) => BoardRules.TissueProduction(s, rng),
        ["vessel_teleport"] = (s, _, rng) => BoardRules.Transport(s, rng),
        // GD 侧钉的是 `cw_world.gd:_aerobic` / `_overload`（下划线那层）—— 薄壳 `aerobic()` 不是契约步（§0.6.4 第 2 条）
        ["aerobic"] = (s, _, _) => PhaseRules.Aerobic(s),
        ["overload"] = (s, _, _) => PhaseRules.Overload(s),

        // ---- E 阶段（18）----
        ["anaerobic"] = (s, _, _) => BoardRules.Anaerobic(s),
        ["cancer_upkeep"] = (s, _, _) => BoardRules.CancerUpkeep(s),
        ["pressure"] = (s, _, _) => BoardRules.Pressure(s),
        // C# 把这一轮新造的格子从 out 参数交出来，GD 是返回值交给 `_erosion(fresh)` —— 同一件事两种写法
        ["proliferate"] = (s, _, rng) => { BoardRules.Proliferate(s, rng, out var next); return next; },
        ["erosion"] = (s, a, rng) => BoardRules.Erosion(s, rng, a.Positions("fresh")),
        ["resolve_camping"] = (s, _, rng) => BoardRules.ResolveCamping(s, rng),
        ["solidify"] = (s, _, _) => BoardRules.Solidify(s),
        ["rooted"] = (s, _, rng) => BoardRules.Rooted(s, rng),
        ["ossify"] = (s, _, _) => BoardRules.Ossify(s),
        ["decay"] = (s, _, _) => BoardRules.Decay(s),
        ["mark_adhesion"] = (s, _, _) => BoardRules.MarkAdhesion(s),
        ["tick_durations"] = (s, _, _) => BoardRules.TickDurations(s),
        ["tick_necrosis"] = (s, _, _) => BoardRules.TickNecrosis(s),
        ["tick_chemo_cd"] = (s, _, _) => BoardRules.TickChemoCooldown(s),
        ["tick_chemo_track"] = (s, _, _) => BoardRules.TickChemoTrack(s),
        ["expire_marks"] = (s, _, _) => BoardRules.ExpireMarks(s),
        ["clear_newborn"] = (s, _, _) => BoardRules.ClearNewborn(s),
        ["cap_energy"] = (s, _, _) => BoardRules.CapEnergy(s),

        // ---- 动作（3）----
        // ⚠ GD `enter_tile(cell, dest, paid := -1)` 有第三个参数 `paid`，C# `EnterTile(s, id, dest, rng)` 没有。
        //    本批 `cases: "deferred"`（零用例），先按名字转调 C# 已有的唯一入口、**不写转换层**（E-6 规矩 3）；
        //    真要写 enter_tile 的用例之前先核这一处（写了 `paid` 的用例会被 AssertAllUsed 当场打红，不会假绿）
        ["enter_tile"] = (s, a, rng) => CellRules.EnterTile(s, a.Cell(s).Id, a.Pos("dest"), rng),
        // 决策类 op：**两侧不是同一个签名** —— GD `execute(cell, data)` 收一个自带 `cost` 的 data 字典
        // （调用方先报价），这边收一个已经生成好的 IDecision、费用由它自己 `QuoteMove`。
        // 所以 args 只能是**席位 + 语义键**，两侧各自从自己的选项表里按键找回那一条
        // （GD `build_options` + `CWSemKey.key`，这边 `GetAvailableDecisions` + `SemanticKey.Of`）。
        // 语义键的规矩 1 已经把 `cost` 剔出键外 —— 所以「C# 算费不同」不会伪装成「动作不同」，
        // 它会原样落在 delta 的 energy 上。批 1 只用 `act=move` 且落点为**空格**的那一支（不掷骰）；
        // 批 4 追加攻击（**同一个键形** `act=move`，落点上有活癌细胞才成为攻击，掷骰走带子）与 `act=antibody`。
        ["execute"] = Execute,
        // 伤害管线的单点入口（批 4 换真）。两端签名已按 C-2 步 1 逐参数核过，args 四个键由硬约定定死：
        // `target`（**席位**，名字跟 GD 的形参 —— GD 边界权威）/ `base`（十分能量）/
        // `source`（四个字面词 → LossSource）/ `ability`（GD 伤害事件的 ability 字段）。
        // **不收 `attacker`**：这边的 `Damage` 没有这个形参 —— 吸血（巨噬【吞噬】）与斩杀（【吞噬体成熟】）
        // 住在 `CellRules.Move` 的攻击流程里，GD 那边住在 `CWDamage` 的伤后触发队列里，
        // 所以 GD 侧探针一律传 `{}`（两条触发都不发生），要验它们走 `execute` 的攻击分支。
        // **不收 `add`**（GD 在 `_calculate` 第一步就加进 base，用例折进 `base`）、
        // **不收 `direct`**（GD 那边是同批第二条事件，两侧形状不同 —— 那一刀也走 `execute`）。
        ["damage_hit"] = (s, a, _) => CellRules.Damage(
            s, a.Cell(s, "target").Id, a.Int("base"), Source(a.Str("source"), a.Str("ability")), a.Str("ability")),
    };

    /// <summary>
    /// `damage_hit` 的 `source` 四个字面词 → <see cref="LossSource"/>。
    ///
    /// 顺带把 `ability` 那条硬约定钉住：GD `immune_hit` 的 ability 是**硬编码**的
    /// （`attack=true` 恒「攻击」、`attack=false` 恒「技能」），用例写别的词两侧的 ability 就不是同一个值了
    /// （【缺氧适应】挡「微环境压迫」、【耗竭抵抗】结算它时额外 −0.5，两处判的都是这个字段）——
    /// 当场抛，不让它悄悄绿。GD 侧 `l0_runner.gd:_step` 的 `damage_hit` 分支是同两句话。
    /// </summary>
    private static LossSource Source(string source, string ability)
    {
        switch (source)
        {
            case "immune_attack" when ability != "攻击":
            case "immune_effect" when ability != "技能":
                throw new InvalidOperationException(
                    $"damage_hit：source={source} 的 ability 是 GD immune_hit 写死的（immune_attack → 攻击 / immune_effect → 技能），拿到「{ability}」");
            case "immune_attack": return LossSource.ImmuneAttack;
            case "immune_effect": return LossSource.ImmuneEffect;
            case "cancer_skill": return LossSource.CancerSkill;
            case "world": return LossSource.World;
            default:
                throw new InvalidOperationException(
                    $"damage_hit 的 source 只认四个字面词（immune_attack / immune_effect / cancer_skill / world），拿到「{source}」");
        }
    }

    /// <summary>见 <c>execute</c> 表项上的注释：按**席位 + 语义键**找回那一条决策，然后照常执行。</summary>
    private static WorldState Execute(WorldState s, Args a, TapeRng rng)
    {
        var seat = a.Int("seat");
        var want = a.Str("key");
        var engine = new BasicRulesEngine();
        var options = engine.GetAvailableDecisions(s, seat);
        var chosen = options.FirstOrDefault(d => SemanticKey.Of(s, d) == want)
            ?? throw new InvalidOperationException(
                $"席位 {seat} 的选项表里没有语义键「{want}」。已有："
                + string.Join(" / ", options.Select(d => SemanticKey.Of(s, d)).Order(StringComparer.Ordinal)));
        var result = engine.ExecuteDecision(s, chosen, rng);
        return result.Success
            ? result.NewState
            : throw new InvalidOperationException($"{want} 执行失败：{result.ErrorMessage}");
    }

    internal static IReadOnlyCollection<string> Names => Table.Keys;

    internal static WorldState Run(string op, WorldState s, Dictionary<string, string> args, TapeRng rng)
    {
        if (!Table.TryGetValue(op, out var fn))
            throw new InvalidOperationException(
                $"不认识的契约步：{op}。已有：{string.Join(" / ", Table.Keys.Order(StringComparer.Ordinal))}");
        var bag = new Args(op, args);
        var next = fn(s, bag, rng);
        bag.AssertAllUsed();   // 跑完再查：写错键名的用例不许悄悄绿
        return next;
    }

    /// <summary>
    /// S 族的参数袋。记账机制与探针共用 —— 里头包着一个 <see cref="Probes.Args"/>，
    /// `Int` / `Pos` / `Cell` / `AssertAllUsed` 全部转调它，只多一个**列表参数**的读法。
    ///
    /// 为什么包一层而不是给 `Probes.Args` 加方法：`Probes.cs` 这一批归 C# 侧那组改，
    /// 两组同时改一个文件必撞。等两边都落地了，这一层该并回 `Probes.Args` 去。
    /// </summary>
    internal sealed class Args
    {
        /// <summary>本批唯一的列表参数（`erosion` 的 `fresh`）。</summary>
        private const string ListKey = "fresh";

        private readonly Dictionary<string, string> raw;
        private readonly Probes.Args bag;

        internal Args(string op, Dictionary<string, string> args)
        {
            raw = args;
            // `Probes.Args` 只认标量，列表参数先摘出去自己解析；其余键原样交给它记账（写错键名照样当场炸）
            bag = new Probes.Args(op, args.Where(kv => kv.Key != ListKey)
                .ToDictionary(kv => kv.Key, kv => kv.Value, StringComparer.Ordinal));
        }

        internal int Int(string key) => bag.Int(key);

        internal string Str(string key) => bag.Str(key);

        internal HexPosition Pos(string key) => bag.Pos(key);

        /// <summary>
        /// 席位参数的**键名**跟 GD 的形参走（GD 边界权威）：多数步写 `cell`，`damage_hit` 写 `target`。
        /// 与 <see cref="Probes.Args.Cell"/> 同形 —— 这一层只转发，别在这儿另立一套缺省。
        /// </summary>
        internal Cell Cell(WorldState s, string key = "cell") => bag.Cell(s, key);

        internal void AssertAllUsed() => bag.AssertAllUsed();

        /// <summary>
        /// 列表参数：`"q,r;q,r"`。不写 = 空表 —— 这不是靶场自己编的默认值，
        /// 是生产代码本来的那个（GD `cw_world.gd:_erosion(fresh: Array[Vector2i] = [])`）。
        /// </summary>
        internal IReadOnlyCollection<HexPosition> Positions(string key)
            => !raw.TryGetValue(key, out var text) || text.Length == 0
                ? []
                : text.Split(';').Select(WorldLoader.Pos).ToArray();
    }
}
