using CellWar.Core.Tests.L1;
using System.Text.Json;
using System.Text.Json.Serialization;
using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// L0「契约靶场」的 **C# runner**：读 `game/tests/l0/*.json`，逐条装盘面、按 kind 分派、比结果。
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
    internal static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,   // 用例键名与 GD 侧一致（ossify_at 这类多词键）
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        // 测试迁移规格 A-5 闸 2c：写错键名的用例（"newbron"）不许悄悄绿 —— 以前是静默忽略
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    /// <summary>
    /// `game/tests/l0/` 下**不是用例表**的 json —— 两侧 runner 要跳过同一份名单，
    /// 否则一边把夹具当用例读、一边不读，闸一就散了。
    /// </summary>
    internal static readonly string[] NotCaseFiles = ["diff_fixture.json"];

    public static TheoryData<string, string> Cases()
    {
        var data = new TheoryData<string, string>();
        foreach (var file in CaseFiles())
            foreach (var c in Read(file))
                data.Add(Path.GetRelativePath(CaseDir(), file), c.Id);
        return data;
    }

    private static IEnumerable<string> CaseFiles()
        => Directory.EnumerateFiles(CaseDir(), "*.json", SearchOption.AllDirectories)   // C-2 的批次目录 l0/batch{n}/ 也要跑到（与 GD `_case_files`、契约门同口径）
            .Where(f => !NotCaseFiles.Contains(Path.GetFileName(f), StringComparer.Ordinal))
            .OrderBy(f => f, StringComparer.Ordinal);

    [Theory]
    [MemberData(nameof(Cases))]
    public void 靶场用例(string file, string id)
    {
        var c = Read(Path.Combine(CaseDir(), file)).Single(x => x.Id == id);
        var where = c.Source == "" ? "" : $"\n  出处：{c.Source}";

        // UNLOADABLE 单列一档（§0.6.1 第 7 条）：**仓库用例集里不许有装不进的用例** —— 只有收割器拿它跳条目
        WorldState world;
        try
        {
            world = WorldLoader.Load(c.World);
        }
        catch (UnloadableException e)
        {
            Assert.Fail($"{c.Id}：{e.Message}{where}");
            return;
        }

        if (!c.IsProbe)
        {
            // S 族：Load → Encode → Subset.Normalize → Steps.Run → 再 encode / normalize → Subset.Diff → Subset.ApplyIgnore
            //        → 与 expect.changed **整集合比**（A-1：整集合比不是包含比，多改一个字段红、少改一个也红）。
            // GD `l0_runner.gd:_case_delta` 是同一条路；rng 走带子（`rolls: []` = 断言这一步不掷骰，掷了 TapeRng 当场抛）。
            Assert.True(c.Expect.Kind == ExpectKind.Delta, $"{c.Id}：S 族契约步的 expect 只能是 delta{where}");
            var grammar = Subset.CheckGrammar(c.Expect.Changed.Keys.Concat(c.Expect.Ignore));
            Assert.True(grammar.Count == 0, $"{c.Id}：{string.Join("；", grammar)}{where}");
            var pre = Subset.Normalize(Subset.Encode(world));
            var rng = new TapeRng(c.Rolls);
            WorldState after;
            IReadOnlyList<IPresentationEvent> staged;
            // 契约步在一个 Stage 作用域里跑：发出的演出条目按 Runtime 同一条路过一遍 SimulationState.Emit，
            // 出牌 / 抽事件才会像 GD note_feed 那样落进 g.feed_log（card-play-feed-log，2026-09-19）
            using (var scope = new Stage.Scope())
            {
                after = Steps.Run(c.Op!, world, c.Args, rng);
                staged = scope.Drain();
            }
            Assert.True(rng.Unused == 0, $"{c.Id}：带子有剩 {rng.Unused} 段 —— rolls 写多了，或这一步没掷那么多次{where}");
            var sim = new SimulationState();
            foreach (var ev in staged) sim = sim.Emit(ev);
            var post = Subset.Normalize(Subset.Encode(after, sim));
            var got = Subset.ApplyIgnore(Subset.Diff(pre, post), c.Expect.Ignore);
            // 一条手写的 changed 路径命中零个字段 = 硬错（A-1）：写歪的路径不能靠整集合比顺带报成「多一条」
            var known = Subset.Paths(pre);
            known.UnionWith(Subset.Paths(post));
            foreach (var path in c.Expect.Changed.Keys)
                Assert.True(Subset.Hits(known, path), $"{c.Id}：changed 里的 {path} 在 pre / post 上一个字段都命不中（路径写错了？）{where}");
            var want = c.Expect.Changed.ToDictionary(kv => kv.Key, kv => Subset.Text(L1View.Plain(JsonSerializer.SerializeToElement(kv.Value))), StringComparer.Ordinal);
            var bad = new List<string>();
            foreach (var (path, v) in got.OrderBy(x => x.Key, StringComparer.Ordinal))
            {
                if (!want.TryGetValue(path, out var w)) { bad.Add($"多出一条差分 {path} = {Subset.Text(v)}"); continue; }
                if (w != Subset.Text(v)) bad.Add($"{path} 期望 {w}，算出 {Subset.Text(v)}");
            }
            foreach (var path in want.Keys.Where(k => !got.ContainsKey(k)).Order(StringComparer.Ordinal))
                bad.Add($"少一条差分 {path}（期望 {want[path]}）");
            Assert.True(bad.Count == 0, $"{c.Id}（契约步 {c.Op}）：{Environment.NewLine}  {string.Join(Environment.NewLine + "  ", bad)}{where}");
            return;
        }

        // P 族是纯查询：不推进流程、不掷骰、不改状态 —— 所以带子必须是空的，`delta` 也无从谈起
        Assert.True(c.Rolls.Count == 0, $"{c.Id}：P 族探针是纯查询，`rolls` 必须是 []（拿到 {c.Rolls.Count} 段）{where}");
        Assert.True(c.Expect.Kind != ExpectKind.Delta, $"{c.Id}：`delta` 要 pre / post 两份 envelope，只有 S 族契约步产得出来{where}");

        var actual = Probes.Run(c.Probe!, world, c.Args);
        var note = L0Expect.Judge(actual, c.Expect);
        Assert.True(note is null, $"{c.Id}（探针 {c.Probe}）：{note}{where}");
    }

    /// <summary>
    /// 用例本身的体检：schema 必填且恒 `cwxcase/2`、id 不许重复、probe / op 二选一、名字必须认识。
    ///
    /// 重复 id 会让 `Cases()` 里两条撞在一起、`Single` 直接抛；
    /// 但那时报的是「序列里不止一个元素」，人得找半天。这里先报清楚。
    ///
    /// **「每个分派名至少一条用例」的反向闸搬走了**：它现在按 `game/tests/contract_ops.json` 的
    /// `cases`（required / deferred / none）判（§0.6.4 第 3 条），两侧共用一份判定，落在 `ContractGateTests`。
    /// 留在这里会把 4 个 deferred 空壳当场判红。
    /// </summary>
    [Fact]
    public void 用例表本身是好的()
    {
        var all = ReadAll();
        Assert.True(all.Count > 0, $"{CaseDir()} 下一条用例都没有 —— runner 空转就是假绿灯");

        var badSchema = all.Where(c => c.Schema != "cwxcase/2").Select(c => $"{c.Id}（{c.Schema}）").ToArray();
        Assert.True(badSchema.Length == 0, $"这些用例的 schema 不是 cwxcase/2：{string.Join(" / ", badSchema)}");

        var dup = all.GroupBy(c => c.Id, StringComparer.Ordinal).Where(g => g.Count() > 1).Select(g => g.Key).ToArray();
        Assert.True(dup.Length == 0, $"用例 id 撞车：{string.Join(" / ", dup)}");

        // Entry 自己就管「probe 与 op 二选一」：都写 / 都不写当场抛
        var entries = all.Select(c => (c.Id, Entry: c.Entry, c.IsProbe)).ToArray();

        var unknown = entries.Where(x => x.IsProbe).Select(x => x.Entry).Distinct(StringComparer.Ordinal)
            .Where(p => !Probes.Names.Contains(p)).Order(StringComparer.Ordinal).ToArray();
        Assert.True(unknown.Length == 0,
            $"用例用了不存在的探针：{string.Join(" / ", unknown)}。已有：{string.Join(" / ", Probes.Names.Order(StringComparer.Ordinal))}");

        var badStatus = all.Where(c => c.Status is not ("OK" or "NOTIMPL" or "KNOWN_GAP" or "UNDEFINED" or "OUT_OF_SCOPE"))
            .Select(c => $"{c.Id}（{c.Status}）").ToArray();
        Assert.True(badStatus.Length == 0, $"这些用例的 status 不在五档里：{string.Join(" / ", badStatus)}（规格 §0.2，没有「未分类」这一档）");

        // delta 的路径文法（只查文法，不查命中 —— 「命中零个字段 = 硬错」要 envelope，随 S 族分派一起落地）
        var badPath = all.Where(c => c.Expect.Kind == ExpectKind.Delta)
            .SelectMany(c => Subset.CheckGrammar(c.Expect.Changed.Keys.Concat(c.Expect.Ignore)).Select(x => $"{c.Id}：{x}")).ToArray();
        Assert.True(badPath.Length == 0, $"{badPath.Length} 条 delta 路径不合文法：" + Environment.NewLine + string.Join(Environment.NewLine, badPath.Take(12)));
    }

    [Fact]
    public void 写错键名的用例当场红()
    {
        var json = "[{\"schema\":\"cwxcase/2\",\"id\":\"x\",\"probe\":\"solidify_threshold\",\"world\":{\"players\":[{\"seat\":0,\"faction\":\"immune\"}],\"tiles\":[{\"at\":\"0,0\",\"newbron\":true}]},\"expect\":30}]";
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<List<L0Case>>(json, Json));
    }

    /// <summary>`{"kind":"scalar"}` 这种写法两侧都不接受（§0.6.2 第 2 条）—— 一侧收一侧不收就会分叉。</summary>
    [Fact]
    public void expect写成kind_scalar当场红()
    {
        var json = "[{\"schema\":\"cwxcase/2\",\"id\":\"x\",\"probe\":\"solidify_threshold\",\"world\":{\"players\":[{\"seat\":0,\"faction\":\"immune\"}]},\"expect\":{\"kind\":\"scalar\",\"value\":30}}]";
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<List<L0Case>>(json, Json));
    }

    internal static IReadOnlyList<L0Case> ReadAll() => CaseFiles().SelectMany(Read).ToList();

    private static IReadOnlyList<L0Case> Read(string path)
        => JsonSerializer.Deserialize<List<L0Case>>(File.ReadAllText(path), Json)
           ?? throw new InvalidOperationException($"{path} 解不出用例");

    /// <summary>从测试程序集往上找 `game/tests/l0`。</summary>
    internal static string CaseDir()
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

    /// <summary>`game/tests`：两侧共用的契约文件（`contract_tune.json` / `contract_ops.json`）与 GD 护栏文件都在这儿。</summary>
    internal static string GameTestsDir() => Path.GetDirectoryName(CaseDir())!;
}
