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

    // ---- E 阶段：无氧呼吸 ----
    //
    // 单位一律照 GD：**十分能量**。公式（PRD 2026-09-14 issue #43）：
    //   max{floor, k × (块内普通癌组织数^指数 × 系数 + **全图**固化数 × 每格加成) ÷ 块内癌细胞数}

    /// <summary>指数项系数，十分能量，按人数分档（GD `ANAEROBIC_BLOCK_COEF_BY_PLAYERS`）。表里没有的人数退回缺省。</summary>
    public IReadOnlyDictionary<int, int> AnaerobicBlockCoefByPlayers { get; init; }
        = new Dictionary<int, int> { [2] = 28, [4] = 20, [6] = 28 };

    /// <summary>指数项系数的缺省值（GD `ANAEROBIC_BLOCK_COEF`）。</summary>
    public int AnaerobicBlockCoef { get; init; } = 28;

    /// <summary>连通块癌组织个数的指数，百分数，按人数分档（GD `ANAEROBIC_BLOCK_EXP_BY_PLAYERS`）。</summary>
    public IReadOnlyDictionary<int, int> AnaerobicBlockExpByPlayers { get; init; }
        = new Dictionary<int, int> { [2] = 30, [4] = 30, [6] = 30 };

    /// <summary>指数缺省值（GD `ANAEROBIC_BLOCK_EXP`）。</summary>
    public int AnaerobicBlockExp { get; init; } = 30;

    /// <summary>**全图**每格固化癌组织给的加成，十分能量（GD `ANAEROBIC_SOLID_BONUS`）。</summary>
    public int AnaerobicSolidBonus { get; init; } = 10;

    /// <summary>
    /// 块内存活 1/2/3 个癌细胞时整条分式外面乘的**人数系数**，百分数（GD `ANAEROBIC_CELLS_K`）。
    /// PRD 2026-09-14（issue #43）加的，净效果是**罚独占、奖抱团**。**兜底排在它之后**。
    /// </summary>
    public IReadOnlyList<int> AnaerobicCellsK { get; init; } = [80, 100, 120];

    /// <summary>池子是否按块内癌细胞数均分（GD `anaerobic_split`，默认开）。</summary>
    public bool AnaerobicSplit { get; init; } = true;

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

    /// <summary>按免疫等级取一档（等级枚举 I=1…X=4，数组是 0 基）。</summary>
    public static int ByLevel(IReadOnlyList<int> table, ImmuneLevel level) => table[(int)level - 1];

    /// <summary>按肿瘤分期取一档（C# 的 `Stage()` 出 1/2/3，GD 的 `tumor_stage()` 出 0/1/2，数组是 0 基）。</summary>
    public static int ByStage(IReadOnlyList<int> table, int stage) => table[Math.Clamp(stage, 1, table.Count) - 1];

    /// <summary>按肿瘤分期取一档（元组表，如【E-侵蚀】的转化格数）。</summary>
    public static T ByStage<T>(IReadOnlyList<T> table, int stage) => table[Math.Clamp(stage, 1, table.Count) - 1];
}
