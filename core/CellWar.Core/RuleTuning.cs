namespace CellWar.Core;

/// <summary>
/// 规则旋钮：**默认值 = PRD**，改它就能不动引擎扫平衡。
///
/// 对齐 GDScript 的 `CWTuning`（`game/scripts/core/cw_tuning.gd`）——
/// 那边 67 项都挂在 `game.tune` 上，`RULE_FIELDS` 这张表决定哪些进存档/联机签名。
/// 那边的默认值一律指向 `CWData` 的常量，所以这里的默认值也必须**逐条等于同名常量**，
/// 由 `GdScriptParityTests` 直接读 `cw_data.gd` 钉住。
///
/// **本文件只搬「移动费用」那一片（TU-2）。** 其余旋钮（呼吸、E 阶段、攻击、胜负…）
/// 各有自己的工单，一次搬一片、每片都要有对得上 GD 的判据 ——
/// 一口气抄 67 个字面量进来只会得到 67 个没人验的数。
///
/// 为什么是 `init` 而不是可变字段：世界状态不可变，旋钮跟着世界走
/// （`WorldState.Tuning`），快照/回滚/分叉自然带着当时那套旋钮，不会串味。
/// </summary>
public sealed record RuleTuning
{
    /// <summary>默认值 = PRD 规则原文。</summary>
    public static readonly RuleTuning Default = new();

    // ---- 移动费用（十分能量）----

    /// <summary>免疫【迁移】→健康组织，按等级 I/II/III/X（GD `IMMUNE_MOVE_HEALTHY`）。</summary>
    public IReadOnlyList<int> ImmuneMoveHealthy { get; init; } = [5, 5, 5, 5];

    /// <summary>免疫【迁移】→癌性组织，按等级 I/II/III/X（GD `IMMUNE_MOVE_CANCEROUS`）。</summary>
    public IReadOnlyList<int> ImmuneMoveCancerous { get; init; } = [10, 8, 8, 8];

    /// <summary>癌细胞移动到癌性组织（GD `CANCER_MOVE_CANCEROUS`）。</summary>
    public int CancerMoveCancerous { get; init; } = 2;

    /// <summary>癌细胞移动到健康组织，即「占地单价」（GD `CANCER_MOVE_HEALTHY`）。</summary>
    public int CancerMoveHealthy { get; init; } = 12;

    /// <summary>小细胞肺癌【极简胞浆】移动到健康组织的永久折后价（GD `SCLC_MOVE_HEALTHY`）。</summary>
    public int SclcMoveHealthy { get; init; } = 7;

    /// <summary>黑色素瘤【伪足穿透】达门槛时的基础费（GD `PSEUDOPOD_COST`）。</summary>
    public int PseudopodCost { get; init; } = 5;

    /// <summary>免疫踏进「黏液侵染」格的迁移附加费；≤0 视为关闭（GD `MUCUS_MOVE_SURCHARGE`）。</summary>
    public int MucusMoveSurcharge { get; init; } = 2;

    /// <summary>小细胞肺癌【转移】的费用（GD `METASTASIS_COST`）。</summary>
    public int MetastasisCost { get; init; } = 10;
    /// <summary>免疫细胞死亡后罚停几个世界回合（GD `CWData.IMMUNE_RESPAWN_DELAY` / `cw_tuning.gd immune_respawn_delay`）：
    /// 死于第 N 回合 → 第 N+1+delay 回合的 S 阶段可复活；-1 = 不再复活。</summary>
    public int ImmuneRespawnDelay { get; init; } = 1;
    /// <summary>小细胞肺癌【转移】每世界回合最多几次（GD `cw_tuning.gd metastasis_max_per_round`，0 = 不限）。</summary>
    public int MetastasisMaxPerRound { get; init; } = 2;
    /// <summary>巨噬【I-吞噬】每次由【迁移】触发的净化回多少（GD `cw_tuning.gd macro_heal_purify` = `CWData.MACRO_HEAL_PURIFY` = 0.2；0 = 不回能，平衡扫描的 `mheal=`）。</summary>
    public int MacroHealPurify { get; init; } = 2;
    /// <summary>攻击无效时攻击者被反弹的损失（GD `cw_tuning.gd counter_dmg_on_fail` = `CWData.COUNTER_DMG_ON_FAIL` = 0.5；0 = 不反弹）。</summary>
    public int CounterDamageOnFail { get; init; } = 5;

    // ---- 行动 ----

    /// <summary>每行动回合攻击次数上限（GD `attack_max_per_turn`，默认 `CWData.ATTACK_MAX_PER_TURN` = 3）；**0 = 不限**。</summary>
    public int AttackMaxPerTurn { get; init; } = 3;

    /// <summary>攻击**成功**的伤害基数，十分能量（GD `attack_dmg_success` = `CWData.ATTACK_DMG_SUCCESS` = 1.0）。K3 接进伤害管线。</summary>
    public int AttackDmgSuccess { get; init; } = 10;

    /// <summary>【抗体】同一世界回合内每多放一次伤害减半（GD `antibody_halve`，团队 2026-09-04 定案保留，默认开；`abhalf=0` 跑「每次打满」对照档）。K3 接。</summary>
    public bool AntibodyHalve { get; init; } = true;

    /// <summary>B 细胞【抗体】每世界回合最多几次（GD `antibody_max_per_round` = `CWData.ANTIBODY_MAX_PER_ROUND` = 0）；**0 = 不限**（现行 PRD）。K3 接。</summary>
    public int AntibodyMaxPerRound { get; init; }

    /// <summary>骨肉瘤【骨样硬化】的费用，十分能量（GD `osteo_ossify_cost` = `CWData.OSTEO_OSSIFY_COST` = 2.0）。K3 接费用点，K2 接观测编码器。</summary>
    public int OsteoOssifyCost { get; init; } = 20;

    // ---- E 阶段 ----

    /// <summary>
    /// 【E-固化】的计数门槛，按肿瘤分期三档（GD `SOLIDIFY_THRESHOLD_BY_STAGE`）。
    /// II 期就降到 2.0 是 PRD 2026-09-12 把它从 III 期提前来的。
    /// </summary>
    public IReadOnlyList<int> SolidifyThreshold { get; init; } = [30, 20, 20];

    /// <summary>【E-增生】每个相邻癌性组织的基数，千分率，按分期三档（GD `PROLIFERATE_BASE_BY_STAGE`）。</summary>
    public IReadOnlyList<int> ProliferatePerAdjacent { get; init; } = [30, 35, 40];

    /// <summary>【E-增生】块内每格固化癌组织的加成，千分率，按分期三档（GD `PROLIFERATE_SOLID_BY_STAGE`）。</summary>
    public IReadOnlyList<int> ProliferatePerSolid { get; init; } = [5, 10, 10];

    /// <summary>
    /// 【E-侵蚀】每个封闭健康块转几格，按分期三档的 (常见值, 少见值)。
    /// 掷 d3：≤2 取前者（2/3 概率），否则取后者（GD `EROSION_TILES_BY_STAGE`）。
    /// </summary>
    public IReadOnlyList<(int Common, int Rare)> ErosionTiles { get; init; } = [(2, 3), (2, 3), (3, 5)];

    // ---- S 阶段：有氧呼吸 ----
    //
    // 单位照 GD：**十分能量**。现行公式 = 按抗原记忆等级查 AerobicByLevel 那张表，与盘面无关
    // （GD `CWWorld._aerobic_base` / `_split_aerobic` / `necrosis_cut`，cw_world.gd:557 / 542 / 440）。

    /// <summary>【S-有氧呼吸】按免疫等级查表，十分能量，下标 = GD 的 `immune_level`（0 起 = I/II/III/X）
    /// （GD `aerobic_by_level` = `CWData.AEROBIC_BY_LEVEL` = 2.0 / 3.0 / 4.5 / 5.0，issue #13）。
    /// **非空时它说了算**，下面那条线性式退成对照档；置空（`abylv=0`）即回到线性 / 盘面式。</summary>
    public IReadOnlyList<int> AerobicByLevel { get; init; } = [20, 30, 45, 50];

    /// <summary>线性档的基数，十分能量（GD `aerobic_level_base` = `CWData.AEROBIC_LEVEL_BASE` = 2.0）。
    /// 只在 <see cref="AerobicByLevel"/> 置空时生效：`base + step × 等级`。
    /// GD 的 `-1`（按人数分档 `AEROBIC_LEVEL_BASE_BY_PLAYERS`）与 `0`（退回盘面式）两档 **C# 未迁**，
    /// `RulePolicies.AerobicBase` 会抛 —— 静默取默认就等于给扫描一个不是 GD 结果的数（口径二 E-3）。</summary>
    public int AerobicLevelBase { get; init; } = 20;

    /// <summary>线性档每级的增量，十分能量（GD `aerobic_level_step` = `CWData.AEROBIC_LEVEL_STEP` = 1.5）。
    /// **不在 12 个旋钮的表里**，是 <see cref="AerobicLevelBase"/> 的必要配件 —— 少了它那条线性式没法逐字对 GD。</summary>
    public int AerobicLevelStep { get; init; } = 15;

    /// <summary>有氧是否再按**存活免疫细胞数**均分（GD `aerobic_split`，2026-09-05 方案 f 定为**不**均分；`asplit=1` 扫回均分档）。</summary>
    public bool AerobicSplit { get; init; }

    /// <summary>均分按几个免疫细胞的量标定（GD `aerobic_split_ref` = `CWData.AEROBIC_SPLIT_REF` = 2）：
    /// n ≤ ref 每人全额，n > ref 把 ref 份均分；**0 = 纯「基数 ÷ 人数」**（数据上已排除的甲读法）。</summary>
    public int AerobicSplitRef { get; init; } = 2;

    /// <summary>站在坏死格上的免疫细胞这一回合的有氧拿几成，**百分数**
    /// （GD `necrosis_aerobic_pct` = `CWData.NECROSIS_AEROBIC_PCT` = 50 = 减半，线上版 PRD）；
    /// 0 = 一份不给（09-05~09-07 的旧行为，`necro=0` 扫回），100 = 坏死对有氧没有影响。</summary>
    public int NecrosisAerobicPct { get; init; } = 50;

    /// <summary>**旧盘面式**的乘数，十分能量（GD `aerobic_mult` = `CWData.AEROBIC_MULT` = 3.0）：
    /// 每份 = (健康 − 坏死) × 本值 ÷ <see cref="RulePolicies.TotalTiles"/>。
    /// 只在 <see cref="AerobicByLevel"/> 置空**且** <see cref="AerobicLevelBase"/> = 0 时生效（09-04 之前的扫描数据靠它复现）。
    /// GD 那边还有一个 `aerobic_mult_growth`（系数随世界回合线性增长）—— 那个是 E-3 **判死**的旋钮
    /// （`contract_tune.json` 的 B 档、`docs/临时下架清单.md`），C# 没有它，所以这里的系数不随回合变。</summary>
    public int AerobicMult { get; init; } = 30;

    /// <summary>有氧**基准**的低保，十分能量（GD `aerobic_floor` = `CWData.AEROBIC_FLOOR` = 0）：**0 = 关**（恒等）。
    /// 夹在基准上、**排在均分之前** —— 顺序反过来 2.0 的低保会把 2.5÷3=0.8 顶回 2.0、均分等于没开
    /// （GD `cw_world.gd:aerobic_share` 2026-09-05 当场抓到的那条）。</summary>
    public int AerobicFloor { get; init; }

    /// <summary>有氧**基准**的封顶，十分能量（GD `aerobic_cap` = 0）：**0 = 不封顶**。与 <see cref="AerobicFloor"/> 同一次夹钳，排在低保之后。</summary>
    public int AerobicCap { get; init; }

    // ---- E 阶段：无氧呼吸 ----
    //
    // 单位一律照 GD：**十分能量**。公式（PRD 2026-09-14 issue #43）：
    //   max{floor, k × (块内普通癌组织数^指数 × 系数 + **全图**固化数 × 每格加成) ÷ 块内癌细胞数}

    /// <summary>指数项系数，十分能量，按人数分档（GD `ANAEROBIC_BLOCK_COEF_BY_PLAYERS`）。表里没有的人数退回缺省。</summary>
    public IReadOnlyDictionary<int, int> AnaerobicBlockCoefByPlayers { get; init; }
        = new Dictionary<int, int> { [2] = 28, [4] = 20, [6] = 28 };

    /// <summary>指数项系数的缺省值（GD `ANAEROBIC_BLOCK_COEF`）：分档表里没有的人数退回它。</summary>
    public int AnaerobicBlockCoef { get; init; } = 28;

    /// <summary>GD `tune.anaerobic_block_coef`（旋钮，不是常量）：**-1 = 按人数取**（<see cref="AnaerobicBlockCoefByPlayers"/>，表里没有的退回 <see cref="AnaerobicBlockCoef"/>）；
    /// &gt;0 = 所有人数统一成这个值；**0 = 退回 09-04 之前的线性求和**（对照档：每癌组织 <see cref="AnaerobicPerCancer"/>、每固化 <see cref="AnaerobicPerSolid"/>）。
    /// 此前 C# 先查分档表、这条旋钮永远够不着，`anaerobic_block_coef = 0` 的对照档算出来仍是默认档（批 3 KG-1，2026-09-19）。</summary>
    public int AnaerobicBlockCoefOverride { get; init; } = -1;

    /// <summary>线性对照档（`AnaerobicBlockCoefOverride == 0`）每格普通癌组织的供能，十分能量（GD `ANAEROBIC_PER_CANCER`）。</summary>
    public int AnaerobicPerCancer { get; init; } = 4;

    /// <summary>线性对照档每格固化癌组织的供能，十分能量（GD `ANAEROBIC_PER_SOLID`）。</summary>
    public int AnaerobicPerSolid { get; init; } = 10;

    /// <summary>连通块癌组织个数的指数，百分数，按人数分档（GD `ANAEROBIC_BLOCK_EXP_BY_PLAYERS`）。</summary>
    public IReadOnlyDictionary<int, int> AnaerobicBlockExpByPlayers { get; init; }
        = new Dictionary<int, int> { [2] = 30, [4] = 30, [6] = 30 };

    /// <summary>指数缺省值（GD `ANAEROBIC_BLOCK_EXP`）：分档表里没有的人数退回它。</summary>
    public int AnaerobicBlockExp { get; init; } = 30;

    /// <summary>GD `tune.anaerobic_block_exp`（旋钮）：**-1 = 按人数取**（<see cref="AnaerobicBlockExpByPlayers"/>，表里没有的退回 <see cref="AnaerobicBlockExp"/>）；&gt;0 = 所有人数统一成这个百分数。</summary>
    public int AnaerobicBlockExpOverride { get; init; } = -1;

    /// <summary>**全图**每格固化癌组织给的加成，十分能量（GD `ANAEROBIC_SOLID_BONUS`）。</summary>
    public int AnaerobicSolidBonus { get; init; } = 10;

    /// <summary>
    /// 块内存活 1/2/3 个癌细胞时整条分式外面乘的**人数系数**，百分数（GD `ANAEROBIC_CELLS_K`）。
    /// PRD 2026-09-14（issue #43）加的，净效果是**罚独占、奖抱团**。**兜底排在它之后**。
    /// </summary>
    public IReadOnlyList<int> AnaerobicCellsK { get; init; } = [80, 100, 120];

    /// <summary>池子是否按块内癌细胞数均分（GD `anaerobic_split`，默认开）。</summary>
    public bool AnaerobicSplit { get; init; } = true;

    /// <summary>【E-无氧呼吸】改在**各癌细胞自己的行动回合末**各算各的（GD `anaerobic_on_turn_end`，`eturn=1` 对照档）；
    /// 默认 false = Kevin 2026-09-06 改回的「世界回合 E 阶段统一结算」。K2 接时机。</summary>
    public bool AnaerobicOnTurnEnd { get; init; }

    /// <summary>每个癌细胞每次至少拿多少，十分能量；≤0 = 不兜底（GD `ANAEROBIC_FLOOR`）。</summary>
    public int AnaerobicFloor { get; init; } = 20;

    /// <summary>无氧收入上限，十分能量；≤0 = 不封顶（GD `ANAEROBIC_CAP`，团队 2026-09-04 定案不封）。</summary>
    public int AnaerobicCap { get; init; }

    /// <summary>「新生」的当回合固化保护（GD `newborn_protect`，Kevin 2026-09-04 拍板取消，默认关）。</summary>
    public bool NewbornProtect { get; init; }

    /// <summary>
    /// 【代谢消耗】：每个癌细胞在 E 阶段按**当前能量的百分比**自动损能；≤0 = 关闭
    /// （GD `cancer_upkeep_pct`，PRD 之外的平衡候选③，默认关）。
    /// </summary>
    public int CancerUpkeepPercent { get; init; }

    /// <summary>
    /// 【E-能量上限】每个世界回合结算末，所有存活细胞的能量削到这个数；0 = 不启用
    /// （GD `energy_cap` / `ENERGY_CAP_PER_ROUND`，默认 0）。
    /// 管的是**存量不是流量** —— 与无氧/有氧那几个「这一回合进多少」的低保/封顶不是一回事。
    /// </summary>
    public int EnergyCap { get; init; }

    // ---- S 阶段第 6 步【过载】（PRD 2026-09-15 新增）----
    //
    //   能量损失 = min{上限, max{0, ((x − 门槛) ÷ 分母)^指数}}
    //
    // 门槛与上限是**十分能量**，指数是百分数。

    /// <summary>低于这个能量不扣（GD `OVERLOAD_THRESHOLD`，十分能量）。</summary>
    public int OverloadThreshold { get; init; } = 100;

    /// <summary>分母：(x − 门槛) ÷ 它；**≤0 = 关闭整条规则**（GD `OVERLOAD_DIV`，顺带兜住除零）。</summary>
    public int OverloadDiv { get; init; } = 2;

    /// <summary>指数，百分数（GD `OVERLOAD_EXP`，1.18）。</summary>
    public int OverloadExp { get; init; } = 118;

    /// <summary>单次损失上限，十分能量；0 = 不封顶（GD `OVERLOAD_CAP`，Kevin 2026-09-15 晚加）。</summary>
    public int OverloadCap { get; init; } = 150;

    // ---- 全局开关与胜负 ----

    /// <summary>世界事件总开关（GD `world_events_on`，Kevin 2026-09-08 要的；**2026-09-10 起默认关** ——
    /// 云端 PRD 给整节加了「暂时停止维护」的标题）。关掉后 GD `CWWorldFx.trigger()` 直接返回：不抽、不挂、不通报。K2 接。</summary>
    public bool WorldEventsOn { get; init; }

    /// <summary>癌方占地胜利要**连续几个世界回合末**都达标才判定
    /// （GD `cancer_win_hold_rounds` = `CWData.CANCER_WIN_HOLD_ROUNDS` = 2，团队 2026-09-01 定案 B：首次达标只拉警报）；
    /// 1 = 达标即胜的旧规则。K2 接 `OutcomeRules.Evaluate`。</summary>
    public int CancerWinHoldRounds { get; init; } = 2;

    /// <summary>按免疫等级取一档（等级枚举 I=1…X=4，数组是 0 基）。</summary>
    public static int ByLevel(IReadOnlyList<int> table, ImmuneLevel level) => table[(int)level - 1];

    /// <summary>按肿瘤分期取一档（C# 的 `Stage()` 出 1/2/3，GD 的 `tumor_stage()` 出 0/1/2，数组是 0 基）。</summary>
    public static int ByStage(IReadOnlyList<int> table, int stage) => table[Math.Clamp(stage, 1, table.Count) - 1];

    /// <summary>按肿瘤分期取一档（元组表，如【E-侵蚀】的转化格数）。</summary>
    public static T ByStage<T>(IReadOnlyList<T> table, int stage) => table[Math.Clamp(stage, 1, table.Count) - 1];
}
