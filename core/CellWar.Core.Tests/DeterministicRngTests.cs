using Xunit;

namespace CellWar.Core.Tests;

/// <summary>
/// 确定性 RNG 测试：验证可重现性、分支一致性。
/// </summary>
public class DeterministicRngTests
{
    [Fact]
    public void SameSeed_ProducesSameSequence()
    {
        var rng1 = new Xoshiro256StarStar(12345);
        var rng2 = new Xoshiro256StarStar(12345);

        for (int i = 0; i < 100; i++)
        {
            Assert.Equal(rng1.NextDouble(), rng2.NextDouble());
        }
    }

    [Fact]
    public void DifferentSeed_ProducesDifferentSequence()
    {
        var rng1 = new Xoshiro256StarStar(12345);
        var rng2 = new Xoshiro256StarStar(54321);

        bool foundDifference = false;
        for (int i = 0; i < 10; i++)
        {
            if (rng1.NextDouble() != rng2.NextDouble())
            {
                foundDifference = true;
                break;
            }
        }

        Assert.True(foundDifference, "不同种子应产生不同序列");
    }

    [Fact]
    public void Fork_ProducesSameSubsequentValues()
    {
        var rng = new Xoshiro256StarStar(9999);
        
        // 消耗几个值
        rng.NextDouble();
        rng.NextDouble();

        var forked = rng.Fork();

        // 验证分支后两者产生相同序列
        for (int i = 0; i < 50; i++)
        {
            Assert.Equal(rng.NextDouble(), forked.NextDouble());
        }
    }

    [Fact]
    public void NextInt_RespectsMax()
    {
        var rng = new Xoshiro256StarStar(7777);

        for (int i = 0; i < 1000; i++)
        {
            int value = rng.NextInt(10);
            Assert.InRange(value, 0, 9);
        }
    }

    [Fact]
    public void NextIntRange_RespectsRange()
    {
        var rng = new Xoshiro256StarStar(8888);

        for (int i = 0; i < 1000; i++)
        {
            int value = rng.NextIntRange(5, 15);
            Assert.InRange(value, 5, 14);
        }
    }

    [Fact]
    public void Choose_ReturnsItemFromList()
    {
        var rng = new Xoshiro256StarStar(6666);
        var items = new[] { "A", "B", "C", "D" };

        for (int i = 0; i < 100; i++)
        {
            string chosen = rng.Choose(items);
            Assert.Contains(chosen, items);
        }
    }

    [Fact]
    public void Shuffle_ContainsAllOriginalElements()
    {
        var rng = new Xoshiro256StarStar(5555);
        var original = new[] { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

        var shuffled = rng.Shuffle(original);

        Assert.Equal(original.Length, shuffled.Count);
        foreach (var item in original)
        {
            Assert.Contains(item, shuffled);
        }
    }

    [Fact]
    public void Shuffle_ProducesDifferentOrderEventually()
    {
        var rng = new Xoshiro256StarStar(4444);
        var original = new[] { 1, 2, 3, 4, 5 };

        bool foundDifference = false;
        for (int attempt = 0; attempt < 20; attempt++)
        {
            var shuffled = rng.Shuffle(original);
            if (!shuffled.SequenceEqual(original))
            {
                foundDifference = true;
                break;
            }
        }

        Assert.True(foundDifference, "洗牌应最终产生不同顺序");
    }

    [Fact]
    public void DeterministicBehavior_AcrossOperations()
    {
        // 验证混合操作的确定性
        var rng1 = new Xoshiro256StarStar(11111);
        var rng2 = new Xoshiro256StarStar(11111);

        Assert.Equal(rng1.NextInt(100), rng2.NextInt(100));
        Assert.Equal(rng1.NextDouble(), rng2.NextDouble());
        Assert.Equal(rng1.NextIntRange(10, 20), rng2.NextIntRange(10, 20));
    }
}
