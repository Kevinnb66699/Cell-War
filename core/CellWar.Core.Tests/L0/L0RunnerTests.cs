using System.Text.Json;
using System.Text.Json.Serialization;
using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// L0「契约靶场」的 **C# runner**：读 `game/tests/l0/*.json`，逐条装盘面、调探针、比数。
///
/// **这只是两个 runner 里的一个。** 迁移计划的闸一写死了：同一份 JSON，
/// **GD runner 与 C# runner 都要绿** —— GD 绿说明用例忠实于原断言，C# 绿说明真的等价。
/// 只做 C# 这一半就是把靶画在自己身上（今天已经栽过好几次的那个形状）。
/// GD 侧的 runner 见 `game/tests/l0_runner.gd`。
///
/// 用例放在 `game/` 下而不是 `core/` 下，是为了**只有一份**：
/// Godot 读 `res://tests/l0/`，C# 从测试程序集往上找同一个目录。复制两份就迟早会分叉。
/// </summary>
public class L0RunnerTests
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,   // 用例键名与 GD 侧一致（ossify_at 这类多词键）
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        // 测试迁移规格 A-5 闸 2c：写错键名的用例（"newbron"）不许悄悄绿 —— 以前是静默忽略
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static TheoryData<string, string> Cases()
    {
        var data = new TheoryData<string, string>();
        foreach (var file in Directory.EnumerateFiles(CaseDir(), "*.json").OrderBy(f => f, StringComparer.Ordinal))
            foreach (var c in Read(file))
                data.Add(Path.GetFileName(file), c.Id);
        return data;
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void 靶场用例(string file, string id)
    {
        var c = Read(Path.Combine(CaseDir(), file)).Single(x => x.Id == id);
        var world = WorldLoader.Load(c.World);
        var actual = Probes.Run(c.Probe, world, c.Args);

        Assert.True(actual == c.Expect,
            $"{c.Id}（探针 {c.Probe}）：期望 {c.Expect}，C# 算出 {actual}" +
            (c.Source == "" ? "" : $"\n  出处：{c.Source}"));
    }

    /// <summary>
    /// 用例本身的体检：id 不许重复、探针名必须认识。
    ///
    /// 重复 id 会让 `Cases()` 里两条撞在一起、`Single` 直接抛；
    /// 但那时报的是「序列里不止一个元素」，人得找半天。这里先报清楚。
    /// </summary>
    [Fact]
    public void 用例表本身是好的()
    {
        var all = Directory.EnumerateFiles(CaseDir(), "*.json").SelectMany(Read).ToArray();
        Assert.True(all.Length > 0, $"{CaseDir()} 下一条用例都没有 —— runner 空转就是假绿灯");

        var dup = all.GroupBy(c => c.Id, StringComparer.Ordinal).Where(g => g.Count() > 1).Select(g => g.Key).ToArray();
        Assert.True(dup.Length == 0, $"用例 id 撞车：{string.Join(" / ", dup)}");

        var unknown = all.Select(c => c.Probe).Distinct(StringComparer.Ordinal)
            .Where(p => !Probes.Names.Contains(p)).Order(StringComparer.Ordinal).ToArray();
        Assert.True(unknown.Length == 0,
            $"用例用了不存在的探针：{string.Join(" / ", unknown)}。已有：{string.Join(" / ", Probes.Names.Order(StringComparer.Ordinal))}");

        // 反向：探针表里每个探针至少一条用例 —— 只查「用例引了不存在的探针」抓不到「探针没人用」，那也是假绿灯（测试迁移规格 C-1 步 1）
        var used = all.Select(c => c.Probe).ToHashSet(StringComparer.Ordinal);
        var idle = Probes.Names.Where(p => !used.Contains(p)).Order(StringComparer.Ordinal).ToArray();
        Assert.True(idle.Length == 0, $"这些探针一条用例都没有：{string.Join(" / ", idle)}");
    }

    [Fact]
    public void 写错键名的用例当场红()
    {
        var json = "[{\"id\":\"x\",\"probe\":\"solidify_threshold\",\"world\":{\"players\":[{\"seat\":0,\"faction\":\"immune\"}],\"tiles\":[{\"at\":\"0,0\",\"newbron\":true}]},\"expect\":30}]";
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<List<L0Case>>(json, Json));
    }

    private static IReadOnlyList<L0Case> Read(string path)
        => JsonSerializer.Deserialize<List<L0Case>>(File.ReadAllText(path), Json)
           ?? throw new InvalidOperationException($"{path} 解不出用例");

    /// <summary>从测试程序集往上找 `game/tests/l0`。</summary>
    private static string CaseDir()
    {
        var dir = AppContext.BaseDirectory;
        for (var i = 0; i < 12 && dir != null; i++)
        {
            var candidate = Path.Combine(dir, "game", "tests", "l0");
            if (Directory.Exists(candidate)) return candidate;
            dir = Path.GetDirectoryName(dir);
        }
        throw new DirectoryNotFoundException("找不到 game/tests/l0 —— 两边共用的那份用例表在那儿");
    }
}
