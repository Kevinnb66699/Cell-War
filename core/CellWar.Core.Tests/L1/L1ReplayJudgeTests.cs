using System.Text.Json;
using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// 重放器的**判官本身**要有人盯：真轨迹的前 28 步里 C# 从没多出过选项、带子从没剩过，
/// 所以「C# 多出来的选项不报」「带子有剩不报」两条变异在水位线上活得下来（2026-09-16 变异检验抓出来的）。
/// 这里用手搓的最小轨迹把这两道判据各自钉死 —— 判官漏判比被测方出错更贵，那是整套对拍的假绿灯。
/// </summary>
public class L1ReplayJudgeTests
{
    [Fact]
    public void CSharp多出一条选项要报OPTION_DIFF()
    {
        var (world, keys) = SetupWorldAndKeys();
        // GD 那一问「少列」一条 —— 也就是 C# 多出来一条
        var report = Run(world, gdOpts: keys.Skip(1).ToList(), pick: keys[1], rng: []);

        var first = Assert.Single(report.Steps);
        Assert.Equal("OPTION_DIFF", first.Code);
        Assert.Contains("C# 多 1", first.Detail);
        Assert.Equal(0, report.Agreed);
    }

    [Fact]
    public void 这一步的带子没念完要报RNG_UNUSED()
    {
        var (world, keys) = SetupWorldAndKeys();
        // 落子不掷骰，而 GD 这一步「录了」一条：C# 少掷了就该报出来
        var report = Run(world, gdOpts: keys, pick: keys[0], rng: [[1, 6, 3]]);

        var first = Assert.Single(report.Steps);
        Assert.Equal("RNG_UNUSED", first.Code);
    }

    /// <summary>开局落子那一问：C# 在这个世界上给出的全部语义键（排好序、去重）。</summary>
    private static (WorldState World, List<string> Keys) SetupWorldAndKeys()
    {
        var world = MatchSetup.Create(4, 20260916);
        var keys = new BasicRulesEngine().GetAvailableDecisions(world, 0)
            .Select(d => SemanticKey.Of(world, d)).Distinct().OrderBy(k => k, StringComparer.Ordinal).ToList();
        Assert.True(keys.Count > 10);
        return (world, keys);
    }

    /// <summary>手搓一条单步轨迹（header + step + footer）写进临时文件，交给真正的重放器。</summary>
    private static ReplayReport Run(WorldState world, List<string> gdOpts, string pick, List<long[]> rng)
    {
        var view = L1View.Of(world);
        var header = new Dictionary<string, object?> { ["t"] = "header", ["proto"] = 2, ["pre"] = view };
        var step = new Dictionary<string, object?>
        {
            ["t"] = "step", ["n"] = 1,
            ["asks"] = new List<object?>
            {
                new Dictionary<string, object?> { ["kind"] = "setup_place", ["pid"] = 0, ["tag"] = "", ["n"] = gdOpts.Count, ["pick"] = pick, ["idx"] = 0, ["opts"] = gdOpts },
            },
            ["rng"] = rng,
            ["post"] = view,   // 走不到比状态那一步，随便放一份
        };
        var footer = new Dictionary<string, object?> { ["t"] = "footer", ["steps"] = 1 };
        var path = Path.Combine(Path.GetTempPath(), $"l1_judge_{Guid.NewGuid():N}.jsonl");
        File.WriteAllLines(path, new[] { header, step, footer }.Select(x => JsonSerializer.Serialize(x)));
        try { return L1Replay.Run(path); }
        finally { File.Delete(path); }
    }
}
