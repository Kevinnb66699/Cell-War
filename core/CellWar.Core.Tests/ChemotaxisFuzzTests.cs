using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests;

/// <summary>
/// 【炎症性趋化】的**不变量**走子：整局随机走、每只免疫细胞手里一直有这张牌，只看挂起态的形状。
///
/// 这条测试来自一次没跑完的对抗复核 —— 它第一次真跑就在第 1 个种子上撞出
/// `CommitLegal` 少了树突那条检查导致的 `QuoteMove(...)!.Value` 崩溃。
/// 逐条钉形状的测试（ChemotaxisTests）覆盖的是**想到的**局面，这条覆盖的是**没想到的**：
/// 两个挂起态相互作用、死亡、能量见底、别人占了落点 —— 都只靠五条不变量兜着。
/// </summary>
public class ChemotaxisFuzzTests
{
    private const string Card = "炎症性趋化";

    [Theory]
    [InlineData(1UL)] [InlineData(2UL)] [InlineData(3UL)] [InlineData(5UL)] [InlineData(8UL)]
    [InlineData(13UL)] [InlineData(21UL)] [InlineData(34UL)] [InlineData(55UL)] [InlineData(89UL)]
    [InlineData(144UL)] [InlineData(233UL)] [InlineData(377UL)] [InlineData(610UL)] [InlineData(987UL)]
    public void 整局走子_挂起态不变量(ulong seed)
    {
        var engine = new BasicRulesEngine();
        var rng = new Xoshiro256StarStar(seed);
        var lcg = seed & 0x7FFFFFFF;
        var s = DemoScenario.Create();
        // 每只免疫细胞手里塞三张，保证这张牌被反复打出
        foreach (var c in s.Cells.Values.Where(c => c.Faction == Faction.Immune).ToArray())
            s = s.UpdateCell(c.Id, c.Copy(hand: [Card, Card, Card], energy: 200));

        for (var i = 0; i < 1200 && s.Turn.Phase != Phase.Finished; i++)
        {
            var seat = -1;
            IReadOnlyList<IDecision> options = Array.Empty<IDecision>();
            foreach (var x in s.Players.Keys.OrderBy(v => v))
            {
                var o = engine.GetAvailableDecisions(s, x);
                if (o.Count > 0) { seat = x; options = o; break; }
            }
            if (seat < 0)
            {
                Assert.True(s.Turn.PendingChemotaxisCell is null,
                    $"[seed {seed} step {i}] 没人能动、却还挂着趋化 —— 挂起态要被 AdvancePhase 带过回合边界");
                s = engine.AdvancePhase(s, rng).NewState;
                continue;
            }
            if (s.Turn.PendingChemotaxisCell is { } pend && s.Turn.PendingChainCell is null)
            {
                Assert.True(options.Count >= 2,
                    $"[seed {seed} step {i}] 挂起时只剩 {options.Count} 个选项（{string.Join(",", options.Select(o => o.DecisionType))}）—— GD 里没有「只能停」的决策点");
                Assert.True(s.Cells[pend].IsAlive, $"[seed {seed} step {i}] 死细胞还在被问趋化的下一步");
            }
            // 挑选项照 KeyWalk 的规矩：与引擎 rng 无关的 LCG、先按语义键排序再挑
            var byKey = new SortedDictionary<string, IDecision>(StringComparer.Ordinal);
            foreach (var d in options) byKey.TryAdd(SemanticKey.Of(s, d), d);
            lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
            var key = byKey.Keys.ElementAt((int)(lcg % (ulong)byKey.Count));
            var r = engine.ExecuteDecision(s, byKey[key], rng);
            Assert.True(r.Success, $"[seed {seed} step {i}] 合法选项 {key} 执行失败：{r.ErrorMessage}");
            s = r.NewState;
            // 补牌，让这张卡一直有得打
            foreach (var c in s.Cells.Values.Where(c => c.Faction == Faction.Immune && c.IsAlive && c.Hand.Count == 0).ToArray())
                s = s.UpdateCell(c.Id, c.Copy(hand: [Card, Card]));
            Assert.True(s.Turn.ChemotaxisStepsLeft >= 0, $"[seed {seed} step {i}] 剩余步数跑成了负数 {s.Turn.ChemotaxisStepsLeft}");
        }
    }
}
