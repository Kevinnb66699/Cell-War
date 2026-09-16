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

    /// <summary>按免疫等级取一档（等级枚举 I=1…X=4，数组是 0 基）。</summary>
    public static int ByLevel(IReadOnlyList<int> table, ImmuneLevel level) => table[(int)level - 1];
}
