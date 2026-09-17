namespace CellWar.Core.Tests.L1;

/// <summary>
/// M4 批扫（对拍规格 §7）：把一个目录里的全部 GD 轨迹逐条教师强制重放，汇总每条的第一处分叉，写成 `l1_scan_summary.txt`。
/// 目录由环境变量 `CWX_SCAN_DIR` 给（没设就跳过，不进日常套件）；轨迹**不进 git**，只是找分叉用的一次性素材。
/// 用法：
/// <code>
///   CWX_SCAN_DIR=&lt;目录&gt; dotnet test core/CellWar.Core.Tests --filter FullyQualifiedName~L1ScanTests
///   → core/CellWar.Core.Tests/bin/Debug/net10.0/l1_scan_summary.txt（按「分叉步数」升序，最先撞的排最前）
/// </code>
/// 这条测试**不断言一致** —— 它是发现器，判据在 L1ReplayTests 的三条正式夹具上。
/// </summary>
public class L1ScanTests
{
    [Fact]
    public void 批扫目录里的每条轨迹_汇总第一处分叉()
    {
        var dir = Environment.GetEnvironmentVariable("CWX_SCAN_DIR");
        if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;

        var rows = new List<(string File, int Agreed, int Steps, string First)>();
        foreach (var path in Directory.GetFiles(dir, "*.jsonl").OrderBy(p => p, StringComparer.Ordinal))
        {
            try
            {
                var report = L1Replay.Run(path);
                var d = report.FirstDivergence;
                rows.Add((Path.GetFileName(path), report.Agreed, report.Steps.Count, d is null ? "（整条一致）" : $"#{d.N} {d.Code} {d.Detail}"));
            }
            catch (Exception e)
            {
                rows.Add((Path.GetFileName(path), -1, 0, "EXCEPTION " + e.GetType().Name + ": " + e.Message.Split('\n')[0]));
            }
        }
        var text = string.Join(Environment.NewLine,
            new[] { $"批扫 {rows.Count} 条轨迹（{dir}）", "" }
            .Concat(rows.OrderBy(r => r.Agreed).Select(r => $"{r.File,-28} 一致 {r.Agreed,4} / {r.Steps,4}   {r.First}")));
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "l1_scan_summary.txt"), text);
    }
}
