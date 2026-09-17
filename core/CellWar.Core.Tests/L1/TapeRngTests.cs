namespace CellWar.Core.Tests.L1;

/// <summary>
/// 念带子的三条硬规矩（对拍规格 §L1 带子），一条一个判据。
/// 整局重放里这三条不一定每条都被踩到（28 步里未必有退化区间、未必有基数差），
/// 所以单独钉：靠重放「顺便」覆盖是运气。
/// </summary>
public class TapeRngTests
{
    private static TapeRng Tape(params (int From, int To, int Value)[] records)
        => new(records.Select(r => (IReadOnlyList<long>)new List<long> { r.From, r.To, r.Value }));

    [Fact]
    public void 退化区间零消耗_不念带子()
    {
        var rng = Tape((1, 6, 4));
        Assert.Equal(3, rng.NextIntRange(3, 4));   // C# 半开 [3,4) = GD randi_range(3,3)
        Assert.Equal(0, rng.NextInt(1));
        Assert.Equal(0, rng.Consumed);
        Assert.Equal(4, rng.NextIntRange(1, 7));   // 这才念第一条
        Assert.Equal(1, rng.Consumed);
    }

    [Fact]
    public void 跨度同基数不同只平移并记一条()
    {
        var rng = Tape((1, 35, 6));
        Assert.Equal(5, rng.NextInt(35));          // GD [1,35] 抽到 6 → C# [0,34] 就是 5
        Assert.Single(rng.BaseNotes);
        Assert.Equal(0, rng.Unused);
    }

    [Fact]
    public void 跨度不同报RNG_SPAN()
    {
        var rng = Tape((1, 6, 4));
        var e = Assert.Throws<TapeException>(() => rng.NextInt(3));
        Assert.Equal("RNG_SPAN", e.Code);
    }

    [Fact]
    public void 带子念完还要报RNG_OVERRUN()
    {
        var rng = Tape((1, 6, 4));
        rng.NextIntRange(1, 7);
        var e = Assert.Throws<TapeException>(() => rng.NextIntRange(1, 7));
        Assert.Equal("RNG_OVERRUN", e.Code);
    }

    [Fact]
    public void NextDouble在GD侧没有对应物()
    {
        var e = Assert.Throws<TapeException>(() => Tape((0, 999, 3)).NextDouble());
        Assert.Equal("RNG_NO_COUNTERPART", e.Code);
    }

    [Fact]
    public void PickRandom照GD的pop_loop逐次念()
    {
        // GD pick_random：每取一个 randi_range(0, size-1)，取走后 size 减一
        var rng = Tape((0, 3, 2), (0, 2, 0));
        var picked = rng.PickRandom(new[] { "a", "b", "c", "d" }, 2);
        Assert.Equal(new[] { "c", "a" }, picked);
        Assert.Equal(0, rng.Unused);
    }
}
