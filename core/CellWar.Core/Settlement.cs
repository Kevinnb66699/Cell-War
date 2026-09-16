namespace CellWar.Core;

/// <summary>
/// 数值修正的语义阶段（PRD「数值修正的结算顺序」§155-179）。
/// </summary>
public enum ModifierStage
{
    Base,       // 基准值（由行动/种类/等级决定，含细胞自带技能）
    Replace,    // 基准值替换：「改为X」「降为X」
    Add,        // 固定增加：「+X」
    Subtract,   // 固定减免：「-X」（可带「最低Y」）
    Multiply,   // 倍增：「×N」
    Divide,     // 倍减：「÷N」「减半」
    Free,       // 免费豁免：「不消耗能量」「费用为0」
    Surcharge   // 不可豁免的附加费
}

/// <summary>
/// 来源层级（PRD「同一阶段内有多个效果时，先按来源层级」§177）。
/// </summary>
public enum SourceLayer
{
    Passive = 0,    // 细胞自带被动
    Card = 1,       // 卡牌
    Skill = 2,      // 技能
    WorldEvent = 3  // 世界事件
}

/// <summary>
/// 一条数值修正。Sequence 为打出/装备的先后序号，用于同层级排序。
/// 单位约定：Add/Subtract/Replace/Surcharge/Floor 用「十分位」整数；Multiply/Divide 用百分比整数（×2=200、÷2=50、×40%=40）。
/// </summary>
public sealed record ValueModifier(
    ModifierStage Stage,
    SourceLayer Layer,
    int Sequence,
    int Value,
    int? Floor = null);

/// <summary>
/// 结算管线（PRD §135-199）。纯整数（十分能量）运算，供技能与卡牌共用。
/// </summary>
public static class Settlement
{
    private static IEnumerable<ValueModifier> Ordered(IEnumerable<ValueModifier> mods, ModifierStage stage)
        => mods.Where(m => m.Stage == stage).OrderBy(m => m.Layer).ThenBy(m => m.Sequence);

    /// <summary>
    /// 数值修正顺序：基准 → 替换 → 固定加 → 固定减 → 倍增 → 倍减 → 免费 → 附加费。
    /// </summary>
    public static int ApplyValue(int baseValue, IEnumerable<ValueModifier> mods)
    {
        var list = mods as IReadOnlyCollection<ValueModifier> ?? mods.ToArray();
        var value = baseValue;
        foreach (var m in Ordered(list, ModifierStage.Replace)) value = m.Value;
        foreach (var m in Ordered(list, ModifierStage.Add)) value += m.Value;
        foreach (var m in Ordered(list, ModifierStage.Subtract))
            value = m.Floor is { } floor ? Math.Max(floor, value - m.Value) : value - m.Value;
        foreach (var m in Ordered(list, ModifierStage.Multiply)) value = value * m.Value / 100;
        foreach (var m in Ordered(list, ModifierStage.Divide)) value = value * 100 / m.Value;
        if (Ordered(list, ModifierStage.Free).Any()) value = 0;
        foreach (var m in Ordered(list, ModifierStage.Surcharge)) value += m.Value;
        return value;
    }

    /// <summary>
    /// 能量损失计算顺序（PRD §137-151，优先级高于数值修正顺序）：
    /// 基础损失 → 固定数值增加 → 倍增 → 倍减 → 固定数值减免。
    /// </summary>
    public static int ApplyEnergyLoss(int baseLoss, IEnumerable<ValueModifier> mods)
    {
        var list = mods as IReadOnlyCollection<ValueModifier> ?? mods.ToArray();
        var loss = baseLoss;
        foreach (var m in Ordered(list, ModifierStage.Add)) loss += m.Value;
        foreach (var m in Ordered(list, ModifierStage.Multiply)) loss = loss * m.Value / 100;
        foreach (var m in Ordered(list, ModifierStage.Divide)) loss = loss * 100 / m.Value;
        foreach (var m in Ordered(list, ModifierStage.Subtract))
            loss = m.Floor is { } floor ? Math.Max(floor, loss - m.Value) : loss - m.Value;
        return Math.Max(0, loss);
    }

    /// <summary>把一个「十分位」的浮点结果四舍五入成整数十分位（PRD 通用规则 1）。</summary>
    public static int RoundTenth(double valueInTenths) => (int)Math.Round(valueInTenths, MidpointRounding.AwayFromZero);

    /// <summary>把整数十分位转成显示用能量（如 25 → 2.5）。</summary>
    public static double ToEnergy(int tenths) => tenths / 10.0;

    /// <summary>
    /// 负担性判定（PRD §181-183）：算出最终数值后判断付不付得起；
    /// 非自毁型技能的费用不能使自身能量降至 ≤0。
    /// </summary>
    public static bool CanPay(int energy, int cost, bool selfDestructive = false)
        => selfDestructive ? energy >= cost : energy > cost;
}
