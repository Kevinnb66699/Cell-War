namespace CellWar.Core.Tests.L1;

/// <summary>
/// **L1 的正式对拍**：按 GD 录的轨迹（`game/tests/l1/*.jsonl`，`xcheck_export.gd` 录的）教师强制重放。
///
/// 判据是一条**水位线**：第一处分叉之前一致的步数不得低于各夹具自己的 ratchet。
/// 每修掉一处分叉就把水位线往上拧；**只许往上，不许往下** —— 往下放等于把刚发现的偏离又盖回去。
/// 完整的逐步报告写在测试输出目录的 `l1_report_&lt;夹具&gt;.txt`，断言信息里也带着第一处分叉。
///
/// 三条夹具（2026-09-17 起 2p / 6p 各一条，Kevin 要的）：人数不同，席位表、复活、无氧的人数系数、E 阶段的盘面规模都不同，
/// 4p 一条走通不代表另外两档也通。重录夹具：
/// <code>
///   Godot_v4.5-stable_win64_console.exe --headless --path game --script res://tests/xcheck_export.gd -- \
///       players=4 seed=4242 out=&lt;仓库&gt;/game/tests/l1/trace_4p_4242.jsonl steps=200
///   （2p：players=2 seed=2222 → trace_2p_2222.jsonl；6p：players=6 seed=6666 → trace_6p_6666.jsonl；
///    树突建源局：players=4 seed=4242 steps=400 policy=chemo → trace_4p_chemo_4242.jsonl，exporter 在源消散 + 冷却归零后 12 步自动收尾）
/// </code>
/// 录完要 grep `SCRIPT ERROR`（GDScript 运行时错误不中断执行），并跑两遍比逐字节相同。
/// 2p 那条 173 步就分出胜负，录到终局为止。
/// </summary>
public class L1ReplayTests
{
    /// <summary>4p seed 4242 的水位线（2026-09-17：200 步整条一致）。往上拧，别往下放。</summary>
    public const int Ratchet = 200;
    /// <summary>2p seed 2222（终局 173 步，2026-09-17 晚整条一致）。</summary>
    public const int Ratchet2p = 173;
    /// <summary>6p seed 6666（200 步，2026-09-17 晚整条一致）。</summary>
    public const int Ratchet6p = 200;
    /// <summary>
    /// 4p seed 4242 · `policy=chemo`（2026-09-19，Kevin 要一条树突建源的夹具）：脚本偏好把免疫攒到 III 级（第 235 步）、
    /// 分化树突（236）、建源（237，落 0,2）、源消散 + 冷却归零、再建一次（268，落 1,1），源活着的 28 步里免疫 / 癌各走了 8 步；
    /// 279 步收尾。前三条夹具里趋化源动作是 0 次，这条专门补它。
    /// 首跑抓到两处：① C# 建源写死 2 完整回合（GD 1）—— 已修，钉在 `ChemoFullTurns`；② 第 238 步抽到事件卡【炎症风暴】，GD 问 `pick_cell`
    /// 选一个免疫细胞，C# 没有这个挂起态、效果被静默跳过（KNOWN_GAP，见拍板记录 §九）。水位线先钉在 237，pick_cell 落地后往上拧到 279。
    /// </summary>
    public const int RatchetChemo = 237;

    [Theory]
    [InlineData("trace_4p_4242.jsonl", Ratchet)]
    [InlineData("trace_2p_2222.jsonl", Ratchet2p)]
    [InlineData("trace_6p_6666.jsonl", Ratchet6p)]
    [InlineData("trace_4p_chemo_4242.jsonl", RatchetChemo)]
    public void 按GD轨迹重放_分叉之前的步数不低于水位线(string fixture, int ratchet)
    {
        var path = Path.Combine(RepoRoot(), "game", "tests", "l1", fixture);
        Assert.True(File.Exists(path), $"轨迹夹具不存在：{path}（用 xcheck_export.gd 重录，见本文件头注）");

        var report = L1Replay.Run(path);
        var text = string.Join(Environment.NewLine, report.Lines());
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, $"l1_report_{Path.GetFileNameWithoutExtension(fixture)}.txt"), text);

        Assert.True(report.Agreed >= ratchet,
            $"{fixture}：分叉早于水位线 {ratchet}（一致 {report.Agreed} 步）：" + Environment.NewLine + text);
    }

    private static string RepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !(Directory.Exists(Path.Combine(d, "game")) && Directory.Exists(Path.Combine(d, "core"))))
            d = Path.GetDirectoryName(d);
        return d ?? throw new InvalidOperationException("从测试目录往上找不到仓库根（要同时有 game/ 与 core/）");
    }
}
