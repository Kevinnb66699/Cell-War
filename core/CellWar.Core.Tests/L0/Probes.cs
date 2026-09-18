using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// L0 探针表：**名字 → 一个纯查询**。
///
/// 只收纯查询 —— 不推进流程、不掷骰、不改状态。L0 的全部价值就在这条约束上：
/// 每条用例互相独立，C# 少一条规则**只污染那一行**，不会顺着流程污染一整局。
/// 要验流程编排与修饰器叠加顺序得靠 L1，那是另一件事（L0 全绿不是出口条件，只是必要条件）。
///
/// 加探针的规矩：**名字与 GDScript 那边的入口同名**，
/// 否则「两边跑同一份 JSON」这件事在名字这一层就先散了。
/// </summary>
public static class Probes
{
    public delegate int Probe(WorldState s, Args args);

    private static readonly Dictionary<string, Probe> Table = new(StringComparer.Ordinal)
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
        // 判词是字符串，这里编码成 0/1/2 —— L0 的 expect 统一是整数，
        // 多加一种 expect 形状不如把值域压成整数：两边都好比，也好在 JSON 里读
        ["attack_outcome"] = (s, a) => RulePolicies.AttackOutcome(s, a.Int("roll"), a.Cell(s)) switch
        {
            "fail" => 0,
            "success" => 1,
            "crit" => 2,
            var other => throw new InvalidOperationException($"不认识的攻击判词：{other}"),
        },
        // 【抗体】的伤害暂不进探针表：GD 的 `antibody_damage(cell)` 收的是**细胞**
        // （自己从细胞身上读用过几次、装没装【抗体亲和力成熟】），C# 的是 `(used, matured)` 两个标量。
        // 签名不一样就没法「两边跑同一份参数」——要么先把其中一边的边界挪齐，要么它不该进 L0。
        // 硬凑一个转换层是最坏的选择：那等于在靶场里再写一遍规则。
    };

    public static IReadOnlyCollection<string> Names => Table.Keys;

    public static int Run(string probe, WorldState s, Dictionary<string, string> args)
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
    /// 探针参数。**取过的键要记账、没取过的键当场炸** ——
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

        public HexPosition Pos(string key) => WorldLoader.Pos(Take(key));

        /// <summary>参数 `cell` 是**席位**号（对拍规格的约定），这里换回细胞。</summary>
        public Cell Cell(WorldState s) => WorldLoader.CellOfSeat(s, Int("cell"));

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
