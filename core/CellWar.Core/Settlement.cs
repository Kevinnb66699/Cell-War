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
    int? Floor = null,
    string Name = "");

/// <summary>
/// 结算管线（PRD §135-199）。纯整数（十分能量）运算，供技能与卡牌共用。
/// </summary>
public static class Settlement
{
    private static IEnumerable<ValueModifier> Ordered(IEnumerable<ValueModifier> mods, ModifierStage stage)
        // 排序对齐 GDScript 的 cw_cost.gd:520-530：阶段 → priority → 来源层级 → 打出/装备先后 → **名字**。
        // priority 今天不排：GD 侧全部模板的 priority 都是 0（实测无一非零），是个休眠字段 ——
        // 真用上了再加，别现在替未来立规矩。
        //
        // **名字那一级 2026-09-15 补，它不是装饰**：LINQ 的 OrderBy 是稳定排序，
        // 平局时会退化成**插入顺序** —— 也就是 PhaseRules 那条 if 链的书写顺序。
        // 那等于把「谁先结算」这件事悄悄绑在代码行序上，改一下 if 的位置结果就变，
        // 而且没有任何测试会红。
        => mods.Where(m => m.Stage == stage)
            .OrderBy(m => m.Layer).ThenBy(m => m.Sequence).ThenBy(m => m.Name, StringComparer.Ordinal);

    /// <summary>
    /// 数值修正顺序：基准 → 替换 → 固定加 → 固定减 → 倍增 → 倍减 → 免费 → 附加费。
    /// </summary>
    public static int ApplyValue(int baseValue, IEnumerable<ValueModifier> mods) => ApplyValue(baseValue, mods, null);

    /// <param name="applied">
    /// 给谁**真改了价**记账（GD `quote()` 的 `applied`）：限次修饰只在这时候才消耗（ON_BENEFIT，cw_cost.gd:238），
    /// 免费豁免同一竞争组只选第一条、且费用已经是 0 时谁也不消耗（cw_cost.gd:243-256）。null = 不记。
    /// </param>
    public static int ApplyValue(int baseValue, IEnumerable<ValueModifier> mods, ICollection<ValueModifier>? applied)
    {
        var list = mods as IReadOnlyCollection<ValueModifier> ?? mods.ToArray();
        var value = baseValue;
        void Step(ValueModifier m, int next) { if (next != value && applied != null) applied.Add(m); value = next; }
        foreach (var m in Ordered(list, ModifierStage.Replace)) Step(m, m.Value);
        foreach (var m in Ordered(list, ModifierStage.Add)) Step(m, value + m.Value);
        foreach (var m in Ordered(list, ModifierStage.Subtract))
            Step(m, m.Floor is { } floor ? Math.Max(floor, value - m.Value) : value - m.Value);
        // **费用侧的百分比四舍五入，伤害侧向下取整** —— 这不是笔误，是 GD 侧两条明写的口径：
        //   · 费用：`CWCost._pct` 走 `round_tenth`（PRD 2026-09-08 通用规则 1）
        //   · 伤害：`cw_damage.gd:220` 明写「四个倍率合成一次整数除法…天然向下取整」，
        //     【TGF-β释放】−20%、【刚性屏障】×40% 同样是**卡面写明**向下取整
        // 所以 `ApplyEnergyLoss` 那两行照旧截断，别顺手统一（cw_data.gd:905-908 专门警告过）。
        //
        // 2026-09-15 改：此前这里也是截断，与 GD 差一个十分位 ——
        // 例：健康格 0.5 的迁移费，免疫朝趋化源走 ×70% → GD 0.4、C# 0.3。
        foreach (var m in Ordered(list, ModifierStage.Multiply)) Step(m, RoundDiv(value * m.Value, 100));
        foreach (var m in Ordered(list, ModifierStage.Divide)) Step(m, RoundDiv(value * 100, m.Value));
        // 免费豁免：同一竞争组里**只选第一条**（GD `_free_order`：来源层级 → 打出先后 → 名字，priority 全为 0 不排），
        // 已经是 0 就没有可豁免的东西 —— 谁也不消耗
        var free = Ordered(list, ModifierStage.Free).FirstOrDefault();
        if (free != null) { if (value > 0 && applied != null) applied.Add(free); value = 0; }
        foreach (var m in Ordered(list, ModifierStage.Surcharge)) { applied?.Add(m); value += m.Value; }   // 附加费一律算「用上了」
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

        // **所有倍率合成一次整数除法**，逐位对齐 GDScript 的 cw_damage.gd:218-223。
        //
        // 这里原来是逐条乘除、**每条各截断一次**。GD 那边为此写了一整段警告：
        // 「分开除会各自向下取整一次，『×2 再 ÷2 再 ×40%』就会比『一次算』少掉一两个十分位。
        //   PRD 只要求最后向下取整到十分位，而十分能量的整数除法天然就是这个取整。」
        //
        // 实锤（2026-09-15 变异检验顺出来的）：被【标记】的骨肉瘤立于固化癌组织受 0.7 伤害
        //   GD : 7 × 2 × 40% 合成一次 → 56000 / 10000 = 5  → **0.5**
        //   C#旧: 先 ×40% → 7×40/100 = 2，再 ×200% → 4     → **0.4**
        // 少掉的那 0.1 正是中间那次截断。
        //
        // 截断（而不是四舍五入）在这里是**对的**：【刚性屏障】×40%、【TGF-β释放】−20%、
        // 【抗体】减半都是**卡面写明**向下取整（cw_data.gd:905-908 专门警告别顺手改）。
        // 费用侧的 `ApplyValue` 才是四舍五入，两边不一样是故意的。
        long num = loss, den = 1;
        foreach (var m in Ordered(list, ModifierStage.Multiply)) { num *= m.Value; den *= 100; }
        foreach (var m in Ordered(list, ModifierStage.Divide)) { num *= 100; den *= m.Value; }
        loss = den == 0 ? 0 : (int)(num / den);

        foreach (var m in Ordered(list, ModifierStage.Subtract))
            loss = m.Floor is { } floor ? Math.Max(floor, loss - m.Value) : loss - m.Value;
        return Math.Max(0, loss);
    }

    /// <summary>
    /// 整数四舍五入除法，逐位对齐 GDScript 的 `CWData.round_tenth(num, den)`。
    ///
    /// ⚠ 照抄的包括它的**前提**：`num >= 0 且 den > 0`。
    /// 负数上 C# 与 GDScript 的整数除法都向零截断，`(num + den/2) / den` 会把
    /// −2.4 取成 −1 而不是 −2 —— 两边一样错，所以对拍不会报差异，但仍是个地雷。
    /// 今天所有调用点（费用、有氧收入、压迫）都非负，原样照抄是为了**不引入新的分歧**。
    /// </summary>
    public static int RoundDiv(int num, int den) => den <= 0 ? num : (num + den / 2) / den;

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
