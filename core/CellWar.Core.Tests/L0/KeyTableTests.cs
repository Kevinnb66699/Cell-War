using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// `cwxworld/2` / `cwxcase/2` 的键表护栏（§0.6.1 开头：**仓库里只许有这两份**键表 ——
/// `L0/CaseModel.cs` 与 `game/tests/cw_case_loader.gd`）。
///
/// 做法照 `L1/SemanticKeyTests.GD侧的KEY_FIELDS与CSharp的FieldOrder逐字相同`：正则读 GD 的 `const XXX_KEYS := [...]`，
/// 与这边记录的属性名（经 <see cref="JsonNamingPolicy.SnakeCaseLower"/> 转换后）**逐字比集合**，顺序不比。
/// 不解析对方的逻辑、只读常量 —— 两边同时改才过得去，这正是要的。
///
/// 另有一条：`delta` 的差分与 tree 比法，两侧跑同一份 `game/tests/l0_fixtures/diff_fixture.json` 给出同一组答案。
/// </summary>
public class KeyTableTests
{
    public static TheoryData<string, string> KeyTables() => new()
    {
        { "CASE_KEYS", nameof(L0Case) },
        { "WORLD_KEYS", nameof(L0World) },
        { "PLAYER_KEYS", nameof(L0Player) },
        { "TILE_KEYS", nameof(L0Tile) },
        { "CELL_KEYS", nameof(L0Cell) },
        { "MOD_KEYS", nameof(L0Mod) },
        { "EVENTS_KEYS", nameof(L0Events) },
        { "EFFECT_KEYS", nameof(L0Effect) },
        { "CHEMO_KEYS", nameof(L0Chemo) },
        { "TRACK_KEYS", nameof(L0Track) },
        { "ALARM_KEYS", nameof(L0CancerAlarm) },
    };

    [Theory]
    [MemberData(nameof(KeyTables))]
    public void 键表与GD的cw_case_loader逐字相同(string constName, string typeName)
    {
        var gd = GdConst(constName);
        var cs = JsonNames(typeName);
        var onlyGd = gd.Except(cs, StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
        var onlyCs = cs.Except(gd, StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
        Assert.True(onlyGd.Length == 0 && onlyCs.Length == 0,
            $"`cw_case_loader.gd:{constName}`（{gd.Count} 个）与 `L0/CaseModel.cs:{typeName}`（{cs.Count} 个）对不上："
            + (onlyGd.Length > 0 ? $"\n  只有 GD 有：{string.Join(" / ", onlyGd)}" : "")
            + (onlyCs.Length > 0 ? $"\n  只有 C# 有：{string.Join(" / ", onlyCs)}" : ""));
    }

    /// <summary>
    /// 两侧的 `diff` 与 tree 比法跑同一份夹具给出同一组答案（§0.6.2 第 3 条）。
    /// GD 半边是 `game/tests/cw_case_diff.gd` 的同名测试，读的是同一个文件。
    /// </summary>
    [Fact]
    public void diff夹具_两侧同答案()
    {
        var path = Path.Combine(L0RunnerTests.GameTestsDir(), "l0_fixtures", "diff_fixture.json");   // 用例目录只装用例，夹具单放
        Assert.True(File.Exists(path), $"缺 {path} —— 两侧 diff / tree 比法的共享夹具（§0.6.2 第 3 条，GD 侧建）");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        Assert.Equal("cwxdiff/1", root.GetProperty("schema").GetString());

        var bad = new List<string>();
        foreach (var row in root.GetProperty("diff").EnumerateArray())
        {
            var name = row.GetProperty("name").GetString()!;
            var pre = Tree(row.GetProperty("pre"));
            var post = Tree(row.GetProperty("post"));
            var wantsError = row.TryGetProperty("error", out var err) && err.GetBoolean();
            try
            {
                var ignore = row.TryGetProperty("ignore", out var ig) ? ig.EnumerateArray().Select(x => x.GetString()!).ToList() : [];
                var got = Subset.ApplyIgnore(Subset.Diff(pre, post), ignore);   // 夹具的 changed = apply_ignore(diff(pre, post), ignore) 的整集合（GD 同）
                if (wantsError) { bad.Add($"{name}：期望硬错，却算出了 {got.Count} 条差分"); continue; }
                var want = row.GetProperty("changed").EnumerateObject()
                    .ToDictionary(p => p.Name, p => Subset.Text(L1View.Plain(p.Value)), StringComparer.Ordinal);
                foreach (var (p, v) in got.OrderBy(x => x.Key, StringComparer.Ordinal))
                {
                    if (!want.TryGetValue(p, out var w)) { bad.Add($"{name}：多出一条差分 {p} = {Subset.Text(v)}"); continue; }
                    if (w != Subset.Text(v)) bad.Add($"{name}：{p} 期望 {w}，算出 {Subset.Text(v)}");
                }
                foreach (var p in want.Keys.Where(k => !got.ContainsKey(k)).Order(StringComparer.Ordinal))
                    bad.Add($"{name}：少一条差分 {p}（期望 {want[p]}）");
            }
            catch (InvalidOperationException e) when (wantsError)
            {
                _ = e;   // 期望硬错的条目：抛了就是对的
            }
        }

        foreach (var row in root.GetProperty("compare").EnumerateArray())
        {
            var name = row.GetProperty("name").GetString()!;
            var got = DeepDiff.Compare(L1View.Plain(row.GetProperty("a")), L1View.Plain(row.GetProperty("b")), "$", 200)
                .Select(d => d.Split('：')[0]).Order(StringComparer.Ordinal).ToArray();
            var want = row.GetProperty("paths").EnumerateArray().Select(x => x.GetString()!).Order(StringComparer.Ordinal).ToArray();
            if (!got.SequenceEqual(want, StringComparer.Ordinal))
                bad.Add($"{name}：tree 比法给出 [{string.Join(" / ", got)}]，夹具写的是 [{string.Join(" / ", want)}]");
        }

        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "l0_diff_fixture.txt"),
            new[] { $"# diff 夹具：{bad.Count} 处对不上" }.Concat(bad));
        Assert.True(bad.Count == 0, $"{bad.Count} 处对不上（全文见 l0_diff_fixture.txt）："
            + Environment.NewLine + string.Join(Environment.NewLine, bad.Take(20)));
    }

    private static Dictionary<string, object?> Tree(JsonElement e) => (Dictionary<string, object?>)L1View.Plain(e)!;

    /// <summary>正则读 `game/tests/cw_case_loader.gd` 里的 `const XXX_KEYS := ["a", "b", …]`（每个元素都是字符串字面量）。</summary>
    private static IReadOnlyCollection<string> GdConst(string name)
    {
        var path = Path.Combine(L0RunnerTests.GameTestsDir(), "cw_case_loader.gd");
        Assert.True(File.Exists(path), $"找不到 {path}");
        var m = Regex.Match(File.ReadAllText(path), $@"const\s+{name}\s*:=\s*\[(.*?)\]", RegexOptions.Singleline);
        Assert.True(m.Success, $"cw_case_loader.gd 里找不到 {name}");
        return m.Groups[1].Value.Split(',').Select(x => x.Trim().Trim('"')).Where(x => x.Length > 0).ToArray();
    }

    /// <summary>这个记录的 JSON 键名（与 `L0RunnerTests.Json` 同一套命名策略；`[JsonIgnore]` 的派生属性不算）。</summary>
    private static IReadOnlyCollection<string> JsonNames(string typeName)
    {
        var type = typeof(L0Case).Assembly.GetType($"CellWar.Core.Tests.L0.{typeName}")
            ?? throw new InvalidOperationException($"找不到类型 {typeName}");
        return type.GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance)
            .Where(p => p.GetCustomAttributes(typeof(JsonIgnoreAttribute), inherit: true).Length == 0)
            .Select(p => JsonNamingPolicy.SnakeCaseLower.ConvertName(p.Name))
            .ToArray();
    }
}
