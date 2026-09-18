using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using CellWar.Core;
using CellWar.Core.Observation;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// `delta` 的载体与路径文法（规格 E-1：**envelope 子集，不是 canon 子集**；§0.6.2 第 3 条）。
///
/// 为什么是 envelope：两侧都产得出来（`cw_obs_codec.gd` ↔ <see cref="ObservationV1Codec"/>），
/// 而且已经在 `EnvelopeParityTests` 上跑出三夹具 573 步 0 差异；canon 只有 C# 产得出来，
/// GD 半边**结构上产不出**（`CanonMod` 的 Stage/Layer/Value/Floor/Requirement 住在 `cw_cost.gd:TEMPLATES` 的静态表里）。
///
/// **路径文法**（与 GD `game/tests/cw_case_diff.gd` 逐字相同，仓库里就这两份）：
/// * 根 `$` = `{board, cells, g, ask}`（envelope 的 `state` 三件 + 兄弟 `ask`）。
///   envelope 元数据（`p` / `rev` / `obs_seq` / `ruleset` / `produced_tiers` / `logs`）构造时就进不来。
/// * 语义键下标、**禁用序号**：`$.board.tiles@&lt;q&gt;,&lt;r&gt;.&lt;键&gt;`、`$.cells[&lt;席位&gt;].&lt;键&gt;`、
///   `$.cells[&lt;席位&gt;].mods[&lt;卡名&gt;].&lt;键&gt;`、`$.g.&lt;键&gt;`、`$.g.events.active[&lt;事件名&gt;].&lt;键&gt;`、
///   `$.ask.kind` / `$.ask.tag` / `$.ask.seat`。
///   理由：`xcheck_export.gd:view` 的 `tile.cell` 写 pid、`cw_obs_codec.gd:_board` 写 id，今天等价、一席多细胞就静默换靶。
/// * 其余数组（`hand` / `equipped` / `fx_round` / `g.players` / `g.order` / …）整条当叶子比。
/// * 通配 `*` 只许出现在**倒数第二段**；禁止 `**`。
/// * **一条路径命中零个字段 = 硬错**，不是空集通过；**同席多细胞取 `cells[&lt;席位&gt;]` = 硬错**。
/// * tier B 已被 <see cref="EnvelopeNormalize"/> 剥掉，选了自然命中零个字段。
/// * **本批禁选 `$.ask.options` 及其子路径**（C# 侧 normalize 折叠 options，GD 不移植折叠）。
///
/// **全局豁免表只有一份 = <see cref="EnvelopeNormalize"/> 今天剥的那一套**，一个字不多 ——
/// 特别是**不另剥 `$.g.feed_log`**（`docs/观测协议_v1.md` §八 末行：`feed_log` 进对拍），
/// 要豁免就由单条用例自己写 `ignore: ["$.g.feed_log"]`。
/// </summary>
internal static class Subset
{
    private static readonly JsonSerializerOptions Show = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>本批禁选的子树（§0.6.2 第 3 条）。</summary>
    public const string BannedPrefix = "$.ask.options";

    /// <summary>
    /// 世界 → plain envelope（照 `L0/PreParityTests.cs` 今天的做法，别另起一套）：
    /// <see cref="WorldLoader.Load"/> 装出来的世界 → <see cref="ObservationV1Codec.Encode"/> 的全知 envelope。
    /// </summary>
    public static Dictionary<string, object?> Encode(WorldState s)
    {
        var json = ObservationV1Codec.Serialize(ObservationV1Codec.Encode(new WorldImage(s), new Revision(0)));
        return (Dictionary<string, object?>)L1View.Plain(JsonDocument.Parse(json).RootElement)!;
    }

    /// <summary>
    /// 整份 envelope → `$` 根 `{board, cells, g, ask}`（先过全局豁免表）。
    /// `ask` 只留 kind / tag / seat 这一类标量：`options`（C# 折叠、GD 不折叠）、`stop_key` / `stop_index`（两侧串不同）
    /// 在这一层**整个摘掉**，与 GD `cw_case_diff.gd:normalize` 逐字同 —— 于是 S 族步产生询问时两侧的差分形状一样，
    /// 而手写路径选到它们会因「命中零个字段」当场硬错（§0.6.2：本批只许 $.ask.kind / tag / seat）。
    /// </summary>
    public static Dictionary<string, object?> Normalize(Dictionary<string, object?> envelope)
    {
        var e = EnvelopeNormalize.Normalize(envelope, gdSide: false);
        if (e.GetValueOrDefault("ask") is Dictionary<string, object?> ask)
            foreach (var k in new[] { "options", "stop_key", "stop_index" }) ask.Remove(k);
        var state = (Dictionary<string, object?>)e["state"]!;
        return new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["board"] = state["board"],
            ["cells"] = state["cells"],
            ["g"] = state["g"],
            ["ask"] = e.GetValueOrDefault("ask"),
        };
    }

    /// <summary>
    /// pre → post 的差分集合（**叶子级**，与 GD `cw_case_diff.gd:diff` 同一算法：两棵树各压成「叶子路径 → 值」再做集合差）：
    /// post 有而 pre 没有或值变了 → 路径 → post 的值；pre 有而 post 没有 → 路径 → `null`（整条消失就是它的每片叶子各记一条 null）。
    /// 差分命中 `$.ask.options` 及其子路径 = 硬错（本批禁选；正常路上 <see cref="Normalize"/> 已把它摘掉，这条只在裸树上起作用）。
    /// </summary>
    public static Dictionary<string, object?> Diff(Dictionary<string, object?> pre, Dictionary<string, object?> post)
    {
        var a = Flatten(pre);
        var b = Flatten(post);
        var outp = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var (path, v) in b.OrderBy(x => x.Key, StringComparer.Ordinal))
            if (!a.TryGetValue(path, out var av) || Text(av) != Text(v)) outp[path] = v;
        foreach (var path in a.Keys.Where(k => !b.ContainsKey(k)).Order(StringComparer.Ordinal))
            outp[path] = null;
        foreach (var path in outp.Keys)
            if (Banned(path))
                throw new InvalidOperationException($"差分命中 {path} —— 本批禁选 {BannedPrefix} 及其子路径（§0.6.2），只许 $.ask.kind / $.ask.tag / $.ask.seat");
        return outp;
    }

    /// <summary>`$` 根 → {叶子路径: 值}（GD `cw_case_diff.gd:flatten` 的逐字版；语义键重复 = 硬错）。</summary>
    public static Dictionary<string, object?> Flatten(Dictionary<string, object?> root)
    {
        var outp = new Dictionary<string, object?>(StringComparer.Ordinal);
        Rec(root, "$", outp);
        return outp;
    }

    /// <summary>按 `ignore` 里的路径（可带倒数第二段的 `*`）从差分集合里摘条目。**一条 ignore 一个字段都没命中 = 硬错**（GD 同）。</summary>
    public static Dictionary<string, object?> ApplyIgnore(Dictionary<string, object?> d, IReadOnlyList<string> ignore)
    {
        var outp = new Dictionary<string, object?>(d, StringComparer.Ordinal);
        foreach (var pattern in ignore)
        {
            var hits = outp.Keys.Where(p => Match(pattern, p)).ToList();
            if (hits.Count == 0)
                throw new InvalidOperationException($"ignore 里的 {pattern} 一个字段都没命中 —— 空豁免是硬错，不是通过");
            foreach (var hit in hits) outp.Remove(hit);
        }
        return outp;
    }

    /// <summary>这棵树上的**叶子**路径（差分与 ignore 都在叶子上）—— 用来判「一条手写 changed 路径命中零个字段」。</summary>
    public static HashSet<string> Paths(Dictionary<string, object?> root)
        => new(Flatten(root).Keys, StringComparer.Ordinal);

    /// <summary>这条路径（可带 `*`）在这棵树上命中了吗。**命中零个字段 = 硬错**，由调用点报。</summary>
    public static bool Hits(HashSet<string> known, string pattern)
        => pattern.Contains('*') ? known.Any(p => Match(pattern, p)) : known.Contains(pattern);

    /// <summary>
    /// 只查文法、不查命中（不需要 envelope）：根必须是 `$`、`*` 只许在倒数第二段、禁止 `**`、
    /// **本批禁选 `$.ask.options` 及其子路径**。返回不合文法的原因，空 = 过。
    /// </summary>
    public static IReadOnlyList<string> CheckGrammar(IEnumerable<string> paths)
    {
        var bad = new List<string>();
        foreach (var p in paths)
        {
            if (!p.StartsWith("$.", StringComparison.Ordinal))
            { bad.Add($"`{p}`：根必须是 `$`（四件套 board / cells / g / ask）"); continue; }
            if (Banned(p) || (p.StartsWith("$.ask.", StringComparison.Ordinal) && p is not ("$.ask.kind" or "$.ask.tag" or "$.ask.seat")))
            { bad.Add($"`{p}`：本批 ask 下只许选 $.ask.kind / $.ask.tag / $.ask.seat（options / stop_key 两侧形状不同，§0.6.2）"); continue; }
            try { Match(p, p); }
            catch (InvalidOperationException e) { bad.Add(e.Message); }
        }
        return bad;
    }

    /// <summary>把值印成一行（报告与「相等吗」都用它 —— 两侧比的是同一套字面量）。
    /// 字典先按键名（Ordinal）排序再印：没语义键的数组整条当叶子比，叶子里若有对象，键序不该算差异
    ///（GD `cw_case_diff.gd:compare` 是结构比、键序无关；此前这里按 JSON 原序印，手写 `changed` 得照 C# 的键序抄 —— 批 1 F13）。</summary>
    public static string Text(object? v) => v is null ? "null" : JsonSerializer.Serialize(Canon(v), Show);

    /// <summary>键名 Ordinal 升序的等价结构（递归进数组）；标量原样。</summary>
    private static object? Canon(object? v) => v switch
    {
        Dictionary<string, object?> d => d.Keys.Order(StringComparer.Ordinal).ToDictionary(k => k, k => Canon(d[k])),
        List<object?> l => l.Select(Canon).ToList(),
        _ => v,
    };

    // ---------------- 递归 ----------------

    private static bool Banned(string path)
        => path == BannedPrefix || path.StartsWith(BannedPrefix + ".", StringComparison.Ordinal) || path.StartsWith(BannedPrefix + "[", StringComparison.Ordinal);

    /// <summary>GD `_walk`：字典逐键下钻（空字典是一片叶子）、有语义键的数组按键下钻、其余一律叶子（没语义键的数组整条当叶子）。</summary>
    private static void Rec(object? node, string path, IDictionary<string, object?> outp)
    {
        switch (node)
        {
            case Dictionary<string, object?> d when d.Count > 0:
                foreach (var key in d.Keys.Order(StringComparer.Ordinal)) Rec(d[key], $"{path}.{key}", outp);
                return;
            case List<object?> l when Keyed(path):
                foreach (var (key, x) in Index(path, l)) Rec(x, Segment(path, key), outp);
                return;
            default:
                outp[path] = node;
                return;
        }
    }

    /// <summary>这一层的数组按语义键下标吗（文法只认这四处）。</summary>
    private static bool Keyed(string path)
        => path is "$.cells" or "$.board.tiles" or "$.g.events.active" || path.EndsWith(".mods", StringComparison.Ordinal);

    private static Dictionary<string, object?> Index(string path, List<object?> xs)
    {
        var outp = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var x in xs)
        {
            var e = (Dictionary<string, object?>)x!;
            var key = path switch
            {
                "$.cells" => Text(e["pid"]),
                "$.board.tiles" => $"{Text(((Dictionary<string, object?>)e["at"]!)["q"])},{Text(((Dictionary<string, object?>)e["at"]!)["r"])}",
                _ => (string)e["name"]!,   // mods / events.active
            };
            if (!outp.TryAdd(key, e))
                throw new InvalidOperationException($"{path} 里语义键 `{key}` 出现了两次 —— 路径文法要求它唯一（同席多细胞取 cells[席位] 是硬错）");
        }
        return outp;
    }

    /// <summary>语义键拼成路径段：`tiles@q,r` 用 @，其余用 `[]`。</summary>
    private static string Segment(string path, string key)
        => path == "$.board.tiles" ? $"{path}@{key}" : $"{path}[{key}]";

    /// <summary>
    /// 通配 `*` 只许出现在**倒数第二段**、只许一个、禁止 `**`。`*` 是**段内**通配（GD `_compile` 把它编成 `[^.]*`）：
    /// `$.cells[*].energy` 命中 `$.cells[0].energy`，`$.board.tiles@*.tissue` 命中每一格。
    /// </summary>
    private static bool Match(string pattern, string path)
    {
        if (pattern.Contains("**", StringComparison.Ordinal))
            throw new InvalidOperationException($"路径 `{pattern}` 用了 `**` —— 文法禁止");
        if (pattern.Count(ch => ch == '*') > 1)
            throw new InvalidOperationException($"路径 `{pattern}` 里有 {pattern.Count(ch => ch == '*')} 个 `*` —— 只许一个");
        var a = Split(pattern);
        var b = Split(path);
        for (var i = 0; i < a.Count; i++)
            if (a[i].Contains('*') && i != a.Count - 2)
                throw new InvalidOperationException($"路径 `{pattern}` 的通配 `*` 只许出现在倒数第二段");
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (!a[i].Contains('*')) { if (a[i] != b[i]) return false; continue; }
            var rx = "^" + Regex.Escape(a[i]).Replace(@"\*", "[^.]*") + "$";
            if (!Regex.IsMatch(b[i], rx)) return false;
        }
        return true;
    }

    /// <summary>按 `.` 切段，但不切进 `[]` 里的语义键（卡名 / 事件名里可能有点）。</summary>
    private static List<string> Split(string path)
    {
        var segs = new List<string>();
        var depth = 0;
        var start = 0;
        for (var i = 0; i < path.Length; i++)
        {
            if (path[i] == '[') depth++;
            else if (path[i] == ']') depth--;
            else if (path[i] == '.' && depth == 0) { segs.Add(path[start..i]); start = i + 1; }
        }
        segs.Add(path[start..]);
        return segs;
    }
}
