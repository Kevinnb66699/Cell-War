using System.Diagnostics;
using CellWar.Ai;

namespace CellWar.Core.Tests.Ai;

/// <summary>
/// 三档单问耗时基准（换内核 P3 性能节）：每席同一档整局自对弈，只给**顶层行动问答**计时（追问一律回落普通档，几十微秒）。
/// 不进日常套件 —— <c>CW_AI_BENCH=1 dotnet test -c Release --filter AiPerfBench</c>，报告写到测试输出目录 ai_perf.txt。
/// 耗时随机器浮动，不做断言；GD 参照（同机 Godot 4.5）：搜索档 p95 ≈ 0.8 s、最慢 1.4 s（4 人）/ 2.1 s（6 人）。
/// </summary>
public class AiPerfBench
{
    [Fact]
    public void 三档单问耗时()
    {
        if (Environment.GetEnvironmentVariable("CW_AI_BENCH") is null) return;
        var lines = new List<string> { $"# AI 三档单问耗时（{(Debugger.IsAttached ? "调试器下" : "")}{BuildKind()}，每格 2 局整局自对弈，只计顶层行动问答）" };
        foreach (var players in new[] { 4, 6 })
            foreach (var tier in new[] { AiTier.Normal, AiTier.Intent, AiTier.Search })
            {
                var us = new List<long>();
                var rounds = new List<int>();
                foreach (var seed in new ulong[] { 20261001, 20261002 })
                    rounds.Add(Play(players, seed, AiPolicies.Create(AiConfig.For(tier)), us));
                us.Sort();
                long P(double q) => us[Math.Min(us.Count - 1, (int)(us.Count * q))];
                lines.Add($"{players} 人 {tier,-6}：{us.Count} 问，p50 {P(0.5) / 1000.0:F1} ms  p95 {P(0.95) / 1000.0:F1} ms  max {us[^1] / 1000.0:F1} ms（打到第 {string.Join(" / ", rounds)} 回合）");
            }
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "ai_perf.txt"), lines);
    }

    private static string BuildKind()
    {
#if DEBUG
        return "Debug";
#else
        return "Release";
#endif
    }

    /// <summary>一局：真局骰子走 xoshiro（与产品同），每问的推演种子由局种子 + 步数派生（同 sidecar）。返回终局（或封顶）时的回合数。</summary>
    private static int Play(int players, ulong seed, IPolicy policy, List<long> micros)
    {
        var engine = new BasicRulesEngine();
        var s = MatchSetup.Create(players, seed);
        var rng = new Xoshiro256StarStar(seed);
        var step = 0L;
        while (s.Turn.Phase != Phase.Finished && step < 20000)
        {
            var (seat, options) = RolloutCursorProbe.NextAsked(s);
            if (options.Count == 0) { s = engine.AdvancePhase(s, rng).NewState; continue; }
            var timed = AskView.KindOf(s, options) == "action";
            var clock = Stopwatch.StartNew();
            var key = policy.Choose(s, seat, options, new SplitMix64Rng(SplitMix64Rng.DecisionSeed(seed, step++)));
            if (timed) micros.Add(clock.ElapsedTicks * 1_000_000 / Stopwatch.Frequency);
            var d = options.First(o => SemanticKey.Of(s, o) == key);
            s = engine.ExecuteDecision(s, d, rng).NewState;
        }
        return s.Turn.WorldRound;
    }
}
