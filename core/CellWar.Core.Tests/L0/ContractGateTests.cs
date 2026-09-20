using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// 契约面的**启动闸**，C# 半边（测试迁移规格 §0.6.4 第 4 条）。
/// GD 半边在 `game/tests/l0_contract_gate.gd`，两侧读的是**同一份** `game/tests/contract_ops.json` ——
/// A-6 原来写的「两边各一条护栏读对方的表」已按 §0.6.6 改成「两侧都与契约表双射，相等经表传递」，
/// 谁也不解析对方的源码。子集规则与 GD 门逐字相同：
///
///   ① 双射：`Probes.Names ∪ Steps.Names` ≡ 表里 `status ∈ {OK, KNOWN_GAP, UNDEFINED}` 的 `op` 集合；
///   ② 用例面：`required` 行 ≥1 条用例且每档 `boundaries` 正则 ≥1 条命中；`deferred` 行零用例（§0.6.4 第 5 条）；`none` 行零用例；
///      用例引的 `probe` / `op` 都在表里且族对得上；
///   ③ 表本身：`kind` 只许 probe / step（T 族不进契约面）、`op` 名不重复、`status` 五档之一、`cases` 三值之一。
///
/// 外加第四条：`contract_tune.json` 与 `RuleTuning` 对得上（§0.6.3）。
/// </summary>
public class ContractGateTests
{
    private static readonly string[] DispatchStatus = ["OK", "KNOWN_GAP", "UNDEFINED"];
    private static readonly string[] AllStatus = ["OK", "KNOWN_GAP", "UNDEFINED", "NOTIMPL", "OUT_OF_SCOPE"];
    private static readonly string[] AllCases = ["required", "deferred", "none"];
    private static readonly string[] AllKind = ["probe", "step"];

    [Fact]
    public void 契约门一_分派表与契约表双射()
    {
        var listed = Ops().Where(o => DispatchStatus.Contains(Text(o, "status")))
            .Select(o => Text(o, "op")).ToHashSet(StringComparer.Ordinal);
        var mine = Probes.Names.Concat(Steps.Names).ToHashSet(StringComparer.Ordinal);

        var missing = listed.Except(mine).Order(StringComparer.Ordinal).ToArray();
        var extra = mine.Except(listed).Order(StringComparer.Ordinal).ToArray();
        Assert.True(missing.Length + extra.Length == 0,
            $"分派表与 contract_ops.json 对不上：C# 缺 [{string.Join(" ", missing)}]；"
            + $"C# 多 [{string.Join(" ", extra)}]（NOTIMPL / OUT_OF_SCOPE 不进分派，deferred 进分派但放空壳）");

        // 族也要对得上：探针表里的名字在契约表里必须是 probe 行，S 族同理
        var kinds = Ops().ToDictionary(o => Text(o, "op"), o => Text(o, "kind"), StringComparer.Ordinal);
        var wrong = Probes.Names.Where(n => kinds.GetValueOrDefault(n) == "step")
            .Concat(Steps.Names.Where(n => kinds.GetValueOrDefault(n) == "probe"))
            .Order(StringComparer.Ordinal).ToArray();
        Assert.True(wrong.Length == 0, $"这些 op 进错了族（P 表 / S 表与契约表的 kind 不一致）：{string.Join(" ", wrong)}");
    }

    [Fact]
    public void 契约门二_required的每一档都有用例()
    {
        var kinds = Ops().ToDictionary(o => Text(o, "op"), o => Text(o, "kind"), StringComparer.Ordinal);
        var used = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var errors = new List<string>();

        foreach (var (id, name, want) in ReadCaseHeads())
        {
            if (name is null) { errors.Add($"用例 {id} 的 probe / op 要二选一（都写或都不写 = 硬错）"); continue; }
            if (!kinds.TryGetValue(name, out var kind)) { errors.Add($"用例 {id} 引用了契约表里没有的 {want}「{name}」"); continue; }
            if (kind != want) { errors.Add($"用例 {id} 写的是 {want}「{name}」，可它在契约表里是 kind={kind}"); continue; }
            if (!used.TryGetValue(name, out var list)) used[name] = list = [];
            list.Add(id);
        }

        foreach (var op in Ops())
        {
            var name = Text(op, "op");
            var mine = used.GetValueOrDefault(name, []);
            switch (Text(op, "cases"))
            {
                case "required":
                    if (mine.Count == 0) errors.Add($"required 的 {name} 一条用例都没有");
                    foreach (var b in Boundaries(op))
                    {
                        var pattern = Text(b, "cases");
                        if (!mine.Any(id => Regex.IsMatch(id, pattern)))
                            errors.Add($"required 的 {name} 档「{Text(b, "tag")}」（{pattern}）零条用例命中");
                    }
                    break;
                case "deferred":
                    // 规格 §0.6.4 第 5 条：deferred = 零用例。悄悄带用例的 deferred 行以前抓不到（批 1 F15）
                    if (mine.Count > 0) errors.Add($"deferred 的 {name} 偷偷带了 {mine.Count} 条用例（要么转 required 并写 boundaries，要么用例不进仓库）：{string.Join(" / ", mine)}");
                    break;
                case "none":
                    if (mine.Count > 0) errors.Add($"挂档 {name}（cases: none）却有 {mine.Count} 条用例：{string.Join(" / ", mine)}");
                    break;
            }
        }

        Assert.True(errors.Count == 0, string.Join(Environment.NewLine, errors));
    }

    [Fact]
    public void 契约门三_契约表本身是好的()
    {
        var errors = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var op in Ops())
        {
            var name = Text(op, "op");
            if (!seen.Add(name)) errors.Add($"op 名重复「{name}」");
            var kind = Text(op, "kind");
            if (!AllKind.Contains(kind))
                errors.Add($"{name} 的 kind 只许 probe / step，拿到「{kind}」—— T 族不进契约面（规格 §0.3）");
            var status = Text(op, "status");
            if (!AllStatus.Contains(status)) errors.Add($"{name} 的 status「{status}」不是五档之一（{string.Join(" / ", AllStatus)}）");
            var cases = Text(op, "cases");
            if (!AllCases.Contains(cases)) errors.Add($"{name} 的 cases「{cases}」不是 required / deferred / none 之一");
        }
        Assert.True(errors.Count == 0, string.Join(Environment.NewLine, errors));
    }

    /// <summary>
    /// 第四条（§0.6.3）：`cs` 非空 ↔ `RuleTuning` 真有该属性；B 档 18 个都没有属性；
    /// A / A′ 的 25 个逐个过 `WorldLoader.WithKnob` 不抛。
    ///
    /// `WithKnob` 今天是 private，所以走反射拿 —— 签名钉死 `(RuleTuning, string, int)`（规格 §0.6.3）。
    /// </summary>
    [Fact]
    public void 旋钮表_与RuleTuning对得上()
    {
        var withKnob = typeof(WorldLoader).GetMethod("WithKnob",
                           BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic,
                           null, [typeof(RuleTuning), typeof(string), typeof(int)], null)
                       ?? throw new InvalidOperationException(
                           "WorldLoader 里找不到 WithKnob(RuleTuning, string, int) —— 签名是 §0.6.3 钉死的，改它就把这条护栏一起改");
        var props = typeof(RuleTuning).GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .ToDictionary(p => p.Name, StringComparer.Ordinal);
        var errors = new List<string>();

        foreach (var knob in Knobs())
        {
            var name = Text(knob, "name");
            var tier = Text(knob, "tier");
            var cs = Text(knob, "cs");
            var prop = cs.Length == 0 ? null : props.GetValueOrDefault(cs.Split('.')[^1]);
            if (cs.Length > 0 && prop is null) errors.Add($"旋钮 {name} 的 cs 写着「{cs}」，可 RuleTuning 上没有这个属性");

            if (tier == "B")
            {
                if (cs.Length > 0) errors.Add($"B 档的 {name} 不该有 cs（B = C# 无对应物，E-3）");
                var pascal = string.Concat(name.Split('_').Select(w => w.Length == 0 ? w : char.ToUpperInvariant(w[0]) + w[1..]));
                if (props.ContainsKey(pascal)) errors.Add($"B 档的 {name} 在 RuleTuning 上其实有 {pascal} —— 归错档了（E-3）");
            }

            if (tier is not ("A" or "A'")) continue;
            if (prop is null) { errors.Add($"{tier} 档的 {name} 必须有 cs 并指到 RuleTuning 的属性"); continue; }
            // 分档表用下标语法 name[i]（1 基，§0.6.1 第 6 条）；标量直接写名字
            var indexed = prop.PropertyType.IsGenericType
                          && prop.PropertyType.GetGenericTypeDefinition() == typeof(IReadOnlyList<>);
            var key = indexed ? $"{name}[1]" : name;
            try
            {
                withKnob.Invoke(null, [RuleTuning.Default, key, 1]);
            }
            catch (TargetInvocationException e)
            {
                errors.Add($"{tier} 档的旋钮「{key}」过不了 WorldLoader.WithKnob：{e.InnerException?.Message}");
            }
        }

        Assert.True(errors.Count == 0, string.Join(Environment.NewLine, errors));
    }

    // ---- 小工具 ----

    /// <summary>`game/tests`：`CaseDir()` 是 `game/tests/l0`，往上一层就是（照 `PreParityTests` 找仓库的做法）。</summary>
    private static string TestsDir() => Path.GetDirectoryName(L0RunnerTests.CaseDir())!;

    private static JsonElement[] Ops() => ReadArray(Path.Combine(TestsDir(), "contract_ops.json"));

    private static JsonElement[] Knobs()
    {
        var path = Path.Combine(TestsDir(), "..", "data", "contract_tune.json");   // 2026-09-19 搬到 game/data/（导出版要读）
        Assert.True(File.Exists(path), $"缺旋钮表 {path}（规格 §0.6.3）");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.GetProperty("knobs").EnumerateArray().Select(e => e.Clone()).ToArray();
    }

    private static JsonElement[] ReadArray(string path)
    {
        Assert.True(File.Exists(path), $"缺契约表 {path} —— 它是唯一的 op 白名单（规格 §0.6.4）");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.EnumerateArray().Select(e => e.Clone()).ToArray();
    }

    private static IEnumerable<JsonElement> Boundaries(JsonElement op)
        => op.TryGetProperty("boundaries", out var b) ? b.EnumerateArray() : [];

    private static string Text(JsonElement e, string key)
        => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";

    /// <summary>
    /// 每条用例的 (id, op 名, 族)：**只读 id / probe / op 三个键**，不经 `L0Case` ——
    /// 这条护栏要在键表变动时照样跑得起来。`op` 名为 null = probe / op 没有二选一。
    /// 同目录下根是对象且带 `schema` 的（`diff_fixture.json` 的 `cwxdiff/1`）是数据夹具，不是用例表。
    /// </summary>
    private static IEnumerable<(string Id, string? Name, string Want)> ReadCaseHeads()
    {
        foreach (var file in Directory.EnumerateFiles(L0RunnerTests.CaseDir(), "*.json", SearchOption.AllDirectories).OrderBy(f => f, StringComparer.Ordinal))
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(file));
            if (doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("schema", out _)) continue;
            Assert.True(doc.RootElement.ValueKind == JsonValueKind.Array, $"{file} 解不出用例数组");
            foreach (var c in doc.RootElement.EnumerateArray())
            {
                var id = Text(c, "id");
                var hasProbe = c.TryGetProperty("probe", out _);
                var hasOp = c.TryGetProperty("op", out _);
                yield return hasProbe == hasOp
                    ? (id, null, "")
                    : hasProbe ? (id, Text(c, "probe"), "probe") : (id, Text(c, "op"), "step");
            }
        }
    }
}
