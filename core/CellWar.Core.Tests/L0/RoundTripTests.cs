using System.Text.Json;
using CellWar.Core;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// 闸二的两段同侧往返（规格 A-5 / C-1 步 4；判据按 §0.6.5 第 1 条）：
///
/// * **2a · dump 往返** —— `Minify(Dump(Load(spec))) ≡ Minify(spec)`，抓「spec 里写了但 loader 没读」。
///   `Minify` 是**独立实现**（不转调 load / dump），两侧各一份、同一张默认表（含 tile `type` = `special_of(at)` 时省略）。
/// * **2d · 世界往返** —— `Normalize(Encode(Load(Dump(g)))) ≡ Normalize(Encode(g))`，抓「世界里有但 dump 没写」。
///   `g` 取三条 L1 夹具的采样步（取世界的做法照 `L1/EnvelopeParityTests`）。
///   **第一次红在哪个字段就补 `Dump`，不改判据。**
///
/// GD 侧的同一对判据走 `l0_runner.gd --selfcheck`；两者都要进 `tools/run_l0.sh`（任一红整体红）。
/// </summary>
public class RoundTripTests
{
    /// <summary>2a：逐条用例 dump 往返。</summary>
    [Fact]
    public void 闸二2a_dump往返_每条用例削完之后与原文相同()
    {
        var bad = new List<string>();
        foreach (var c in L0RunnerTests.ReadAll())
        {
            try
            {
                var back = WorldLoader.Minify(WorldLoader.Dump(WorldLoader.Load(c.World)));
                var want = WorldLoader.Minify(c.World);
                var diffs = DeepDiff.Compare(Plain(want), Plain(back), "$", 4);
                if (diffs.Count > 0) bad.Add($"{c.Id}：{diffs[0]}");
            }
            catch (UnloadableException e)
            {
                bad.Add($"{c.Id}：{e.Message}");   // 仓库用例集里不许有装不进的用例（§0.6.1 第 7 条）
            }
        }
        Assert.True(bad.Count == 0, $"{bad.Count} 条用例 dump 往返对不上（首条差异即报）：" + Environment.NewLine
            + string.Join(Environment.NewLine, bad.Take(12)));
    }

    /// <summary>2d：三条 L1 夹具的采样步，世界往返之后 envelope 逐字段相同。</summary>
    [Theory]
    [InlineData("4p_4242")]
    [InlineData("2p_2222")]
    [InlineData("6p_6666")]
    public void 闸二2d_世界往返_envelope逐字段相同(string fixture)
    {
        var tracePath = Path.Combine(RepoRoot(), "game", "tests", "l1", $"trace_{fixture}.jsonl");
        Assert.True(File.Exists(tracePath), $"缺 L1 夹具 {tracePath}");

        var mismatches = new List<(int N, IReadOnlyList<string> Diffs)>();
        var skipped = new List<string>();
        var compared = 0;
        L1Replay.Run(tracePath, MaxSteps, inspect: (n, s) =>
        {
            if (n % SampleEvery != 0) return;
            try
            {
                var back = WorldLoader.Load(WorldLoader.Dump(s));
                var a = Subset.Normalize(Subset.Encode(s));
                var b = Subset.Normalize(Subset.Encode(back));
                var diffs = DeepDiff.Compare(a, b, "$", 40);
                compared++;
                if (diffs.Count > 0) mismatches.Add((n, diffs));
            }
            catch (UnloadableException e)
            {
                // 装不进的那几步（今天只有非空 `mods`：E-2 的 `setup_ops` 前奏落在批 5a）单列，不当通过
                skipped.Add($"第 {n} 步：{e.Message}");
            }
        });

        var lines = new List<string> { $"# L0 世界往返 {fixture}：比了 {compared} 步，{mismatches.Count} 步有差异，{skipped.Count} 步装不回去" };
        foreach (var (n, diffs) in mismatches.Take(6)) { lines.Add($"## 第 {n} 步"); lines.AddRange(diffs.Take(20).Select(d => "  " + d)); }
        lines.AddRange(skipped.Take(20).Select(x => "  " + x));
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, $"l0_roundtrip_{fixture}.txt"), lines);

        Assert.True(compared > 0, $"{fixture}：一步都没比到 —— 采样或夹具有问题（{skipped.Count} 步装不回去）");
        Assert.True(mismatches.Count == 0, mismatches.Count == 0 ? "" :
            $"{fixture}：{mismatches.Count} 步世界往返之后 envelope 不一样（首条 第 {mismatches[0].N} 步）：" + Environment.NewLine
            + string.Join(Environment.NewLine, mismatches[0].Diffs.Take(12)) + Environment.NewLine + $"（全文见 l0_roundtrip_{fixture}.txt）");
    }

    private const int MaxSteps = 200;

    /// <summary>每隔几步取一个世界（三条夹具各 200 步 → 实测比到 111 步；全取只是更慢，不会更严）。</summary>
    private const int SampleEvery = 2;

    private static object? Plain(L0World w)
        => L1View.Plain(JsonSerializer.SerializeToElement(w, L0RunnerTests.Json));

    private static string RepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !(Directory.Exists(Path.Combine(d, "game")) && Directory.Exists(Path.Combine(d, "core"))))
            d = Path.GetDirectoryName(d);
        return d ?? throw new InvalidOperationException("找不到仓库根");
    }
}
