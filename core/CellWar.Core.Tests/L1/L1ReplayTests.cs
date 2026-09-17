namespace CellWar.Core.Tests.L1;

/// <summary>
/// **L1 的正式对拍**：按 GD 录的轨迹（`game/tests/l1/*.jsonl`，`xcheck_export.gd` 录的）教师强制重放。
///
/// 判据是一条**水位线**：第一处分叉之前一致的步数不得低于 <see cref="Ratchet"/>。
/// 每修掉一处分叉就把水位线往上拧；**只许往上，不许往下** —— 往下放等于把刚发现的偏离又盖回去。
/// 完整的逐步报告写在测试输出目录的 `l1_report.txt`，断言信息里也带着第一处分叉。
///
/// 重录夹具：
/// <code>
///   Godot_v4.5-stable_win64_console.exe --headless --path game --script res://tests/xcheck_export.gd -- \
///       players=4 seed=4242 out=&lt;仓库&gt;/game/tests/l1/trace_4p_4242.jsonl steps=80
/// </code>
/// 录完要 grep `SCRIPT ERROR`（GDScript 运行时错误不中断执行），并跑两遍比逐字节相同。
/// </summary>
public class L1ReplayTests
{
    /// <summary>水位线：分叉之前至少一致这么多步。往上拧，别往下放。</summary>
    public const int Ratchet = 32;   // 2026-09-16：【代谢耦联】跟上 GD 后到 32；第 33 步分叉在「需要选格的卡逐格摊开」（【基质硬化】），见对拍规格 KNOWN_GAP

    [Fact]
    public void 按GD轨迹重放_分叉之前的步数不低于水位线()
    {
        var path = Path.Combine(RepoRoot(), "game", "tests", "l1", "trace_4p_4242.jsonl");
        Assert.True(File.Exists(path), $"轨迹夹具不存在：{path}（用 xcheck_export.gd 重录，见本文件头注）");

        var report = L1Replay.Run(path);
        var text = string.Join(Environment.NewLine, report.Lines());
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "l1_report.txt"), text);

        Assert.True(report.Agreed >= Ratchet,
            $"分叉早于水位线 {Ratchet}（一致 {report.Agreed} 步）：" + Environment.NewLine + text);
    }

    private static string RepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !(Directory.Exists(Path.Combine(d, "game")) && Directory.Exists(Path.Combine(d, "core"))))
            d = Path.GetDirectoryName(d);
        return d ?? throw new InvalidOperationException("从测试目录往上找不到仓库根（要同时有 game/ 与 core/）");
    }
}
