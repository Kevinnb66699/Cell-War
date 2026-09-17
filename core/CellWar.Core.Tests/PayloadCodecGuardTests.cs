namespace CellWar.Core.Tests;

/// <summary>
/// 存档编解码的白名单要**认得每一种决策**。
///
/// 漏登记不会编译报错、也不会让任何规则测试红 —— 只在 `Runtime` 对待答选项逐条
/// `PayloadCodec.Validate` 的那一刻抛 `Unknown payload type.`，也就是真有人在挂起态存档时才炸。
/// 【连续吞噬】那一对就这么漏了一阵。和 SemanticKeyTests 那条完备性护栏同一个道理：
/// 新加一个 record 忘了回来补一行，这里替人记着。
/// </summary>
public class PayloadCodecGuardTests
{
    /// <summary>与 SemanticKey.DeadCode 同一份名单：有定义、无 Validate/Execute/Available 的死代码，不进存档。</summary>
    private static readonly HashSet<string> NotInSaves = ["AttackDecision", "DivideDecision"];

    [Fact]
    public void 每种决策要么登记进存档白名单要么明确列为不进存档()
    {
        var missing = typeof(IDecision).Assembly.GetTypes()
            .Where(t => t is { IsAbstract: false, IsInterface: false } && typeof(IDecision).IsAssignableFrom(t))
            .Where(t => !PayloadCodec.Types.Contains(t) && !NotInSaves.Contains(t.Name))
            .Select(t => t.Name)
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(missing.Length == 0,
            "下面这些决策没登记进 PayloadCodec.Types —— 挂起态存档会在运行时抛 Unknown payload type："
            + Environment.NewLine + "  " + string.Join(Environment.NewLine + "  ", missing));
    }
}
