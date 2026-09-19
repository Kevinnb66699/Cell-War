using System.Collections.Immutable;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests;

/// <summary>
/// 口径二 · 批 0 步 6 的验收闸（规格 C-1 步 6）：三条 L1 夹具各重放 200 步，GD 桥的各条演出通道都至少出现过一次；
/// 骰点在面数之内、过场方向是 DIRS 下标、判词三档之一。顺带把每类条目的次数写到 bin 目录，文档引用。
/// `beam`（Excalibur）夹具里没有，不在必到名单里；`world_event` 通道 2026-09-19 已删。
/// </summary>
public class PresentationCoverageGuardTests
{
    private static readonly string[] MustAppear = ["roll", "result", "attack", "card_played", "card_drawn", "event_drawn", "erosion", "fx"];

    [Fact]
    public void 三条夹具重放完_各条演出通道至少出现一次_数值都在值域内()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "game", "tests", "l1");
        var staged = new List<IPresentationEvent>();
        foreach (var name in new[] { "trace_4p_4242.jsonl", "trace_2p_2222.jsonl", "trace_6p_6666.jsonl" })
        {
            var path = Path.Combine(dir, name);
            Assert.True(File.Exists(path), $"找不到夹具：{path}");
            var report = L1Replay.Run(path, 200, onResult: r => staged.AddRange(r.Events.OfType<IPresentationEvent>()));
            Assert.True(report.Agreed >= 100, $"{name} 夹具本身要先大体一致：{report.Agreed}");
        }

        var counts = staged.GroupBy(e => e.EventType).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal);
        var fxKinds = staged.OfType<SkillFx>().GroupBy(f => f.Kind).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal);
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "presentation_coverage.txt"),
            counts.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => $"{kv.Key}	{kv.Value}")
                .Concat(fxKinds.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => $"fx:{kv.Key}	{kv.Value}")));

        var missing = MustAppear.Where(k => !counts.ContainsKey(k)).ToArray();
        Assert.True(missing.Length == 0, $"这些通道一次都没出现：{string.Join(" / ", missing)}；出现过的：{string.Join(" / ", counts.Keys)}");

        Assert.All(staged.OfType<DiceRolled>(), d => Assert.InRange(d.Value, 1, d.Sides));
        Assert.All(staged.OfType<TissueConverted>(), t => Assert.InRange(t.Dir, 0, 5));
        Assert.All(staged.OfType<AttackResolved>(), a => Assert.Contains(a.Outcome, new[] { "fail", "success", "crit" }));
        Assert.All(staged.OfType<CardDrawn>(), d => Assert.NotEqual("", d.Source));
        Assert.All(staged.OfType<SkillFx>(), f => Assert.All(f.Data.Values, v => Assert.True(v is int or bool or HexPosition or HexPosition[] or EntityId, $"fx {f.Kind} 的 data 装了 {v.GetType().Name}")));
    }
}
