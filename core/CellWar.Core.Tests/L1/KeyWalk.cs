using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// 按**语义键**驱动一整局的走子器 —— L1 对拍的 C# 半边。
///
/// 规矩只有一条，但它是整个 L1 的地基：**挑选项要与引擎的 rng 彻底无关**。
/// 用引擎的 rng 挑，两边的带子从第一次分叉起就再也对不上，而且看起来像是规则不同。
/// 所以这里自带一条 LCG，和 GD 侧 `xcheck_bridge.ask()` 用同一组常数、
/// 同样**先把键排序再挑** —— 这样哪怕我们改了选项的生成次序，整串也不会错位。
///
/// GD 侧要照抄的三行（常数别改）：
/// <code>
///   _lcg = (_lcg * 1103515245 + 12345) &amp; 0x7FFFFFFF
///   keys.sort()
///   idx = _lcg % keys.size()
/// </code>
/// </summary>
public static class KeyWalk
{
    public sealed record Trace(WorldState Final, IReadOnlyList<string> Picked, IReadOnlySet<string> Seen, int Steps);

    /// <summary>
    /// 推着世界往前走 <paramref name="steps"/> 步：有人能动就按键挑一个执行，
    /// 没人能动就推一格阶段。返回挑过的键（带子）与见过的全部键（覆盖率）。
    /// </summary>
    /// <param name="onStep">每推进一步（执行一个决策或推一格阶段）之后调一次 —— 全盘不变量护栏挂在这里。</param>
    public static Trace Walk(WorldState s, int steps, ulong seed, Action<WorldState>? onStep = null)
    {
        var engine = new BasicRulesEngine();
        var rng = new Xoshiro256StarStar(seed);
        var lcg = seed & 0x7FFFFFFF;
        var picked = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var done = 0;

        for (; done < steps && s.Turn.Phase != Phase.Finished; done++)
        {
            var (seat, options) = NextAsked(s);
            if (options.Count == 0) { s = engine.AdvancePhase(s, rng).NewState; onStep?.Invoke(s); continue; }

            var byKey = new SortedDictionary<string, IDecision>(StringComparer.Ordinal);
            foreach (var d in options) byKey.TryAdd(SemanticKey.Of(s, d), d);
            seen.UnionWith(byKey.Keys);

            lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
            var key = byKey.Keys.ElementAt((int)(lcg % (ulong)byKey.Count));
            picked.Add(key);

            var result = engine.ExecuteDecision(s, byKey[key], rng);
            // 执行失败不该发生（键是从合法选项里挑的）—— 真发生了就是 Validate 与 Available 不自洽，
            // 卡在这里比静默跳过强：跳过的话带子会悄悄比 GD 短一截。
            Assert.True(result.Success, $"选项表给出的 {key} 执行失败了：{result.ErrorMessage}");
            s = result.NewState;
            onStep?.Invoke(s);
        }
        return new Trace(s, picked, seen, done);
    }

    /// <summary>此刻轮到谁、他有哪些选项。四席挨个问一遍，谁有选项就是谁。</summary>
    private static (int Seat, IReadOnlyList<IDecision> Options) NextAsked(WorldState s)
    {
        var engine = new BasicRulesEngine();
        foreach (var seat in s.Players.Keys.OrderBy(x => x))
        {
            var options = engine.GetAvailableDecisions(s, seat);
            if (options.Count > 0) return (seat, options);
        }
        return (-1, Array.Empty<IDecision>());
    }
}
