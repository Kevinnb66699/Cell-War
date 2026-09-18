using System.IO.Compression;
using System.Text.Json;
using CellWar.Core.Observation;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// 闸二 2b「装载自证」（docs/口径二_测试迁移规格.md A-5 / C-1 步 5）：同一份 L0 用例，GD `cw_case_loader.gd` 装出的世界经
/// `cw_obs_codec.gd` 编成 envelope（`l0_pre_dump.gd` 导出、gzip 进 `game/tests/l0/pre_envelopes.jsonl.gz`），
/// 与 C# `WorldLoader.Load` + `ObservationV1Codec.Encode` 产的那份逐字段 diff。非零 = 两侧装出来的不是同一个世界，
/// 探针再对也是假绿灯。裁剪与 `EnvelopeParityTests` 同一套（`EnvelopeNormalize`）。
/// </summary>
public class PreParityTests
{
    [Fact]
    public void 装载自证_同一份用例两侧装出的世界逐字段相同()
    {
        var caseDir = L0RunnerTests.CaseDir();
        var gzPath = Path.Combine(caseDir, "pre_envelopes.jsonl.gz");
        Assert.True(File.Exists(gzPath),
            $"缺 GD 侧的装载 envelope {gzPath} —— 录法：godot --headless --path game --script res://tests/l0_pre_dump.gd -- out=<临时>.jsonl，再 gzip -9 进那个位置（用例一动就重录）");
        var gd = ReadGz(gzPath).Where(l => l.Length > 0).Select(l => JsonDocument.Parse(l).RootElement)
            .ToDictionary(e => e.GetProperty("id").GetString()!, e => e.GetProperty("env"), StringComparer.Ordinal);

        var cases = L0RunnerTests.ReadAll();
        var missing = new List<string>();
        var mismatches = new List<(string Id, IReadOnlyList<string> Diffs)>();
        foreach (var c in cases)
        {
            if (!gd.TryGetValue(c.Id, out var gdEnv)) { missing.Add(c.Id); continue; }
            var image = new WorldImage(WorldLoader.Load(c.World));
            var csJson = ObservationV1Codec.Serialize(ObservationV1Codec.Encode(image, new Revision(0)));
            var a = EnvelopeNormalize.Normalize(L1View.Plain(gdEnv), gdSide: true);
            var b = EnvelopeNormalize.Normalize(L1View.Plain(JsonDocument.Parse(csJson).RootElement), gdSide: false);
            var diffs = DeepDiff.Compare(a, b, "$", 200);
            if (diffs.Count > 0) mismatches.Add((c.Id, diffs));
        }

        var lines = new List<string> { $"# L0 装载自证：{cases.Count} 条用例，{mismatches.Count} 条两侧装得不一样，{missing.Count} 条缺 GD 侧 envelope" };
        var patterns = mismatches.SelectMany(m => m.Diffs).Select(d => System.Text.RegularExpressions.Regex.Replace(d.Split('：')[0], @"\[\d+\]", "[*]"))
            .GroupBy(x => x).OrderByDescending(g => g.Count()).Select(g => $"  {g.Count(),6} × {g.Key}").ToList();
        lines.Add($"# 差异模式（{patterns.Count} 种）"); lines.AddRange(patterns.Take(40));
        foreach (var (id, diffs) in mismatches.Take(8)) { lines.Add($"## {id}"); lines.AddRange(diffs.Take(30).Select(d => "  " + d)); }
        if (missing.Count > 0) { lines.Add("## 缺 GD 侧 envelope 的用例（重录 pre_envelopes.jsonl.gz）"); lines.AddRange(missing.Select(m => "  " + m)); }
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "l0_pre_parity.txt"), lines);

        Assert.True(missing.Count == 0, $"{missing.Count} 条用例缺 GD 侧 envelope（重录 pre_envelopes.jsonl.gz）：{string.Join(" / ", missing.Take(5))}");
        Assert.True(mismatches.Count == 0, mismatches.Count == 0 ? "" :
            $"{mismatches.Count} 条用例两侧装出的世界不一样（首条 {mismatches[0].Id}）：" + Environment.NewLine
            + string.Join(Environment.NewLine, mismatches[0].Diffs.Take(12)) + Environment.NewLine + "（全文见 l0_pre_parity.txt）");
    }

    private static IEnumerable<string> ReadGz(string path)
    {
        using var file = File.OpenRead(path);
        using var gz = new GZipStream(file, CompressionMode.Decompress);
        using var reader = new StreamReader(gz);
        while (reader.ReadLine() is { } line) yield return line;
    }
}
