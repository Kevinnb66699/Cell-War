namespace CellWar.Core.Tests.L1;

/// <summary>
/// 跨生产者 envelope 对拍的**同一套裁剪**（docs/观测协议_v1.md §八 六条例外 + 比法三条），两处共用：
/// `EnvelopeParityTests`（三条 L1 夹具逐步）与 `L0/PreParityTests`（L0 用例装载自证，闸二 2b）。
/// 把不比的东西删掉 / 抹平，剩下的逐字段 `DeepDiff`。输入是 `L1View.Plain` 出来的字典 / 列表 / 标量树，**原地改**。
/// </summary>
internal static class EnvelopeNormalize
{
    /// <summary>tier B 键表（与 GD `cw_obs_proto.gd` 的 *_B 同一份；C# 批 0 不产出，对拍时从 GD 侧剥掉）。</summary>
    public static readonly string[] TileB = ["prod_left", "store_max", "solid_frozen", "store_pending"];
    public static readonly string[] CellB = ["action_kinds", "status_rows", "pressure_lethal", "neutralized", "type_ability_on", "antibody_cost",
        "metastasis_cost_real", "ossify_cost_real", "attack_cap_left", "draw_cap_left", "homing_cost_real"];
    public static readonly string[] GlobalB = ["count_healthy", "count_cancer", "count_solid", "count_necrosis", "cancer_weighted", "level_thresholds", "memory_next_at", "next_event_round"];

    private static readonly HashSet<string> TileBSet = new(TileB, StringComparer.Ordinal);
    private static readonly HashSet<string> CellBSet = new(CellB, StringComparer.Ordinal);
    private static readonly HashSet<string> GlobalBSet = new(GlobalB, StringComparer.Ordinal);

    public static Dictionary<string, object?> Normalize(object? tree, bool gdSide)
    {
        var e = (Dictionary<string, object?>)tree!;
        foreach (var k in new[] { "p", "ruleset", "rev", "obs_seq", "viewer", "open_hands", "produced_tiers", "full", "base" }) e.Remove(k);
        var state = (Dictionary<string, object?>)e["state"]!;
        foreach (var t in ((List<object?>)((Dictionary<string, object?>)state["board"]!)["tiles"]!).Cast<Dictionary<string, object?>>())
            foreach (var k in TileBSet) ((Dictionary<string, object?>)t["d"]!).Remove(k);
        foreach (var c in ((List<object?>)state["cells"]!).Cast<Dictionary<string, object?>>())
        {
            foreach (var k in new[] { "hand", "equipped", "fx_round" }) c[k] = Sorted(c[k]);   // #1
            foreach (var k in CellBSet) ((Dictionary<string, object?>)c["d"]!).Remove(k);     // #4
        }
        var g = (Dictionary<string, object?>)state["g"]!;
        ((Dictionary<string, object?>)g["cancer_alarm"]!).Remove("streak");   // #3
        foreach (var k in GlobalBSet) ((Dictionary<string, object?>)g["d"]!).Remove(k);
        ((Dictionary<string, object?>)g["d"]!)["phase_text"] = "";   // #6 文案
        g["win_reason"] = "";
        g["differentiated"] = Sorted(g["differentiated"]);
        foreach (var p in ((List<object?>)g["players"]!).Cast<Dictionary<string, object?>>()) p.Remove("name");   // #5
        // #6：日志内容不比；行数 GD 每步多行、C# 一事一行，也不比 —— 只留「有没有」
        e["logs"] = ((Dictionary<string, object?>)e["logs"]!)["lines"] is List<object?> ? "present" : null;
        if (e["ask"] is Dictionary<string, object?> ask)
        {
            ask.Remove("ask_id"); ask.Remove("rev"); ask["prompt"] = "";
            var kind = (string)ask["kind"]!;
            var byKey = new Dictionary<string, object?>(StringComparer.Ordinal);
            string? stopKey = null;
            foreach (var o in ((List<object?>)ask["options"]!).Cast<Dictionary<string, object?>>())
            {
                var key = (string)o["key"]!;
                if (!gdSide && key == SemanticKey.PassKey) continue;   // C# 固定多出的一条
                var collapsed = L1Replay.Collapse(kind, key);
                if ((bool)o["is_stop"]!) stopKey ??= collapsed;
                if (collapsed != key) { byKey[collapsed] = "组键"; continue; }   // GD 一问 ↔ C# 按目标展开的一决策：只比存在
                o.Remove("index"); o["label"] = ""; o["blocked"] = null;
                byKey[collapsed] = o;
            }
            ask["options"] = byKey;
            ask.Remove("stop_index"); ask["stop_key"] = stopKey;   // 两侧选项序不同：比「停止项是哪条」而不是下标
        }
        return e;
    }

    private static List<object?> Sorted(object? xs) => ((List<object?>)xs!).OrderBy(x => (string)x!, StringComparer.Ordinal).ToList();
}
