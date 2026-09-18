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
/// 表里 `status ∈ {OK, KNOWN_GAP, UNDEFINED}` 的 P 族行 ≡ <see cref="Names"/>，**12 条**。
/// 其中 4 条是**空壳**（`deferred`：本批未开工，调用即抛）。
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
        ["const"] = Deferred("const"),                           // 两侧常量表随批 0 建

        // 【抗体】的伤害暂不进探针表：GD 的 `antibody_damage(cell)` 收的是**细胞**
        // （自己从细胞身上读用过几次、装没装【抗体亲和力成熟】），C# 的是 `(used, matured)` 两个标量。
        // 按上面 E-6 的规矩 1，要么 C# 挪齐边界，要么它登记 OUT_OF_SCOPE 不进 L0。
    };

    private static Probe Deferred(string name)
        => (_, _) => throw new NotImplementedException($"本批未开工：探针 {name} 在 contract_ops.json 里是 deferred（空壳）");

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
