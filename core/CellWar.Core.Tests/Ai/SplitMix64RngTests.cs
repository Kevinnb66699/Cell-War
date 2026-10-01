using CellWar.Ai;

namespace CellWar.Core.Tests.Ai;

/// <summary>
/// 推演随机流的金值：**与 GD 侧 headless_test 的 t_ai_agree_rng 钉的是同一组数**（金值用 Python 按 SplitMix64 原式算出）。
/// 两边任何一处移位 / 回绕 / 取值映射写歪，这里或那边先红 —— 对拍语料里所有试走的骰子都从这条流出来。
/// </summary>
public class SplitMix64RngTests
{
    [Fact]
    public void 原始输出与GD同()
    {
        var r = new SplitMix64Rng(20261001);
        Assert.Equal([2091738599621355213L, 4067228912806564614L, -2320869810489835059L],
            new[] { (long)r.NextU64(), (long)r.NextU64(), (long)r.NextU64() });
    }

    [Fact]
    public void 闭区间映射只看跨度()
    {
        var r = new SplitMix64Rng(42);
        var faces = Enumerable.Range(0, 8).Select(_ => r.NextIntRange(1, 7)).ToArray();   // GD randi_range(1, 6)
        Assert.Equal([1, 4, 4, 1, 6, 4, 1, 5], faces);
        Assert.Equal(-1028001813962170158L, (long)r.State);
        // 基数不同、跨度相同 → 偏移相同（C# NextInt(n) 对 GD randi_range(1, n)，L1 的 RNG_BASE）
        var a = new SplitMix64Rng(7);
        var b = new SplitMix64Rng(7);
        Assert.Equal(a.NextInt(6) + 1, b.NextIntRange(1, 7));
    }

    [Fact]
    public void 退化区间零消耗()
    {
        var r = new SplitMix64Rng(42);
        Assert.Equal(3, r.NextIntRange(3, 4));
        Assert.Equal(0, r.NextInt(1));
        Assert.Equal(42UL, r.State);
    }

    [Fact]
    public void 负数状态的闭区间与GD同()
    {
        var r = new SplitMix64Rng(ulong.MaxValue);   // GD 的 -1
        Assert.Equal([968, 484, 500, 921], Enumerable.Range(0, 4).Select(_ => r.NextIntRange(0, 1000)).ToArray());
        Assert.Equal(8709371129873690707L, (long)r.State);
    }

    [Fact]
    public void 并列决胜与GD同()
    {
        Assert.Equal(2, SplitMix64Rng.TieIndex(12345, 2, 4));
        Assert.Equal(6, SplitMix64Rng.TieIndex(unchecked((ulong)-5L), 0, 7));
    }
}
