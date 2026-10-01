using CellWar.Ai;
using CellWar.Core.Tests.L0;

namespace CellWar.Core.Tests.Ai;

/// <summary>
/// AI 三档对拍（换内核 P3 验收，docs/内核替换_重启计划.md §四 P3：**不扫胜率**，逐决策比答案）。
///
/// 语料 = game/tests/ai_agree/*.jsonl.gz（GD 无头自对弈录的，ai_agree_export.gd；规则或 AI 改了就重录）。判据：
/// · 普通档：每一问答案键 100% 一致；
/// · 意图档：全部候选的读数逐字段相等、分在 1e-9 内，最终键一致；
/// · 搜索档：根候选读数 / 根集合 / 对手节点排序 / 叶值序列（1e-9）/ 最终键一致；
/// · 零分叉（谁被问、规范选项表、执行）、GD 形状字段（含报价 cost）零差、段界世界与随机流状态零差。
/// 不一致**一条都不许靠放宽阈值放过** —— 先归因（规则差 / 浮点 / 并列次序），再改该改的那一侧。
/// 三份语料各占一个测试类：xUnit 按类并行，墙钟 ≈ 最慢的那一份。
/// </summary>
public static class AgreementTests
{
    internal static string CorpusDir() => Path.Combine(L0RunnerTests.GameTestsDir(), "ai_agree");

    internal static string Corpus(string file) => Path.Combine(CorpusDir(), file);

    /// <summary>跑一份语料、三档全比，报告写到测试输出目录（ai_agree_&lt;语料&gt;.txt）。</summary>
    internal static void AssertCorpus(string file)
    {
        var report = AgreeReplay.Run(Corpus(file), ["normal", "intent", "search"]);
        var lines = report.Lines(file).ToList();
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, $"ai_agree_{file}.txt"), lines);
        var why = string.Join(Environment.NewLine, lines.Take(40));
        Assert.True(report.Compared > 100, why);
        Assert.True(report.Divergences.Count == 0, why);
        Assert.True(report.DataDiffs.Count == 0, why);
        Assert.True(report.BoundaryDiffs.Count == 0, why);
        foreach (var tier in report.Total.Keys)
            Assert.True(report.Agree[tier] == report.Total[tier] && report.Total[tier] == report.Compared, why);
        Assert.True(report.IntentTraced > 50 && report.IntentTraceEqual == report.IntentTraced, why);
        Assert.True(report.SearchTraced > 50 && report.SearchTraceEqual == report.SearchTraced, why);
    }
}

public class Agreement2pTests
{
    [Fact] public void 二人整局三档逐问一致() => AgreementTests.AssertCorpus("agree_2p.jsonl.gz");
}

public class Agreement4pTests
{
    [Fact] public void 四人局三档逐问一致() => AgreementTests.AssertCorpus("agree_4p.jsonl.gz");
}

public class Agreement6pTests
{
    [Fact] public void 六人局三档逐问一致() => AgreementTests.AssertCorpus("agree_6p.jsonl.gz");
}

/// <summary>
/// 变异检验：把被测策略的**一个**参数 / 权重拨歪，对拍必须红。否则对拍就是在自己比自己（读数没进比较、比较器恒真……）。
/// 每条只跑到第一处不一致就停（<see cref="AgreeReplay.Run"/> 的 stopAtFirst），不拖慢套件。
/// </summary>
public class AgreementMutationTests
{
    private static AgreeReplay.Report RunMutated(string tier, IPolicy mutated)
        => AgreeReplay.Run(AgreementTests.Corpus("agree_4p.jsonl.gz"), [tier], _ => mutated, stopAtFirst: true);

    /// <summary>分化改成永远拿第一种（GD v1 行为）：四人局里免疫升到 II 级必分化，答案必变 ——
    /// 顺带钉住分化的并列决胜（tie_index）真进了比较。（「关掉惜命」在这份语料里一问都改不了，不能当变异用。）</summary>
    [Fact]
    public void 普通档分化拿第一种必红()
    {
        var r = RunMutated("normal", new NormalPolicy(new AiConfig { FixedLineup = true }));
        Assert.True(r.Agree["normal"] < r.Total["normal"], "分化改成拿第一种之后普通档仍与 GD 全同 —— 对拍没在比答案");
    }

    [Fact]
    public void 意图档威胁权重改一档必红()
    {
        var r = RunMutated("intent", new IntentPolicy(new AiConfig { Tier = AiTier.Intent, ThreatWeight = 14.0 }));
        Assert.True(r.IntentTraceEqual < r.IntentTraced, "W_THREAT 15 → 14 之后意图档读数仍全同 —— 分没进比较");
    }

    [Fact]
    public void 意图档二步展开少一格必红()
    {
        var r = RunMutated("intent", new IntentPolicy(new AiConfig { Tier = AiTier.Intent, SecondStepMax = 2 }));
        Assert.True(r.IntentTraceEqual < r.IntentTraced, "二步只展开 2 格之后候选表仍全同 —— 候选没进比较");
    }

    [Fact]
    public void 搜索档根少取一个必红()
    {
        var r = RunMutated("search", new SearchPolicy(new AiConfig { Tier = AiTier.Search, TopK = 5 }));
        Assert.True(r.SearchTraceEqual < r.SearchTraced, "TopK 6 → 5 之后搜索读数仍全同 —— 根集合没进比较");
    }

    /// <summary>推演随机流换一条（种子 +1）：叶值必须跟着变 —— 证明试走真在用 Choose 收到的那条流，而不是别处的骰子。</summary>
    [Fact]
    public void 搜索档换一条推演流必红()
    {
        var r = RunMutated("search", new ShiftedStream(new SearchPolicy(AiConfig.For(AiTier.Search))));
        Assert.True(r.SearchTraceEqual < r.SearchTraced, "推演种子 +1 之后叶值仍全同 —— 试走没用独立随机流");
    }

    private sealed class ShiftedStream(IPolicy inner) : IPolicy
    {
        public string Choose(WorldState state, int seat, IReadOnlyList<IDecision> options, IDeterministicRng rng,
            CancellationToken cancellation = default, AiTrace? trace = null)
            => inner.Choose(state, seat, options, new SplitMix64Rng(((SplitMix64Rng)rng).State + 1), cancellation, trace);
    }
}

/// <summary>开发 / 排查工具：环境变量不给就什么也不做（日常套件里空跑）。</summary>
public class AgreementDevTools
{
    /// <summary>
    /// <c>CW_AGREE_CORPUS=/abs/path.jsonl[.gz] CW_AGREE_TIERS=normal,intent</c> 跑任意一份语料，
    /// 报告（含每问耗时分位）写到测试输出目录的 ai_agree_dev.txt。
    /// </summary>
    [Fact]
    public void 开发语料()
    {
        var path = Environment.GetEnvironmentVariable("CW_AGREE_CORPUS");
        if (string.IsNullOrEmpty(path)) return;
        var tiers = (Environment.GetEnvironmentVariable("CW_AGREE_TIERS") ?? "normal,intent,search").Split(',');
        var report = AgreeReplay.Run(path, tiers);
        var lines = report.Lines(Path.GetFileName(path)).ToList();
        foreach (var t in tiers)
        {
            var us = report.Micros[t].OrderBy(x => x).ToList();
            if (us.Count > 0) lines.Add($"  {t} 每问耗时 µs：p50 {us[us.Count / 2]} p95 {us[(int)(us.Count * 0.95)]} max {us[^1]}");
        }
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "ai_agree_dev.txt"), lines);
    }

    /// <summary>
    /// <c>CW_AGREE_CORPUS=… CW_AGREE_DEBUG_ROW=91 CW_AGREE_TIERS=search</c>：把第 N 问那一档的试走逐步记到
    /// ai_agree_steps.jsonl（[席位, 键, 作答时 rng 状态, 局面摘要]），与 GD 侧 ai_agree_export.gd 的 debug= 输出逐行比，
    /// 第一处不同的那一行就是分叉点（10-01 那四处内核时序差都是这么定位的）。
    /// </summary>
    [Fact]
    public void 开发试走逐步()
    {
        var path = Environment.GetEnvironmentVariable("CW_AGREE_CORPUS");
        var rowText = Environment.GetEnvironmentVariable("CW_AGREE_DEBUG_ROW");
        if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(rowText)) return;
        var target = int.Parse(rowText);
        var tier = (Environment.GetEnvironmentVariable("CW_AGREE_TIERS") ?? "search").Split(',')[0];
        var lines = new List<string>();
        AgreeReplay.Run(path, [], null, onAsk: (n, s, seat, options, seed) =>
        {
            if (n != target) return;
            RolloutCursor.DebugStep = (who, key, rng, st) => lines.Add($"[{who},\"{key}\",{(long)rng},\"{Digest(st)}\"]");
            try { AiPolicies.Create(AiConfig.For(AiConfig.ParseTier(tier))).Choose(s, seat, options, new SplitMix64Rng(seed)); }
            finally { RolloutCursor.DebugStep = null; }
        });
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "ai_agree_steps.jsonl"), lines);
    }

    /// <summary>与 GD agree_rng.gd:_digest 同式的局面摘要（记忆 / 等级 / 癌组织与固化数 / 每只细胞的能量、位置、标记）。</summary>
    private static string Digest(WorldState s)
    {
        var parts = new List<string>
        {
            $"m{s.FactionMemory(Faction.Immune)}", $"l{(int)s.FactionImmuneLevel(Faction.Immune) - 1}",
            $"c{s.Board.Tissues.Values.Count(t => t.State == TissueState.Cancer)}",
            $"s{s.Board.Tissues.Values.Count(t => t.State == TissueState.SolidifiedCancer)}",
        };
        foreach (var c in s.Cells.Values.OrderBy(c => c.OwnerSeat))
            parts.Add($"{c.OwnerSeat}:{c.Energy}@{c.Position.Q},{c.Position.R}{(c.IsAlive ? "" : "x")}{(c.Marked ? $"M{c.MarkLeft}/{c.MarkRound}" : "")}");
        return string.Join(" ", parts);
    }
}
