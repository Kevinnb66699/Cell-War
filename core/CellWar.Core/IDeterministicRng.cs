namespace CellWar.Core;

/// <summary>
/// 确定性随机数生成器：作为可分支、可回溯的状态。
/// 必须支持 fork、序列化和完全确定的输出。
/// </summary>
public interface IDeterministicRng
{
    /// <summary>
    /// 生成 [0, 1) 范围内的随机浮点数。
    /// </summary>
    double NextDouble();

    /// <summary>
    /// 生成 [0, max) 范围内的随机整数。
    /// </summary>
    int NextInt(int max);

    /// <summary>
    /// 生成 [min, max) 范围内的随机整数。
    /// </summary>
    int NextIntRange(int min, int max);

    /// <summary>
    /// 从列表中随机选择一个元素。
    /// </summary>
    T Choose<T>(IReadOnlyList<T> items);

    /// <summary>
    /// 随机洗牌（返回新列表，不修改原列表）。
    /// </summary>
    IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items);

    /// <summary>
    /// 从 `items` 里随机挑 `count` 个（不放回），**逐位对齐 GDScript 的 `CWGame.pick_random`**：
    /// 每次 `randi_range(0, 剩余−1)` 抽一个、从池子里拿掉，池子空了就提前结束。
    ///
    /// ⚠ **不能用 `Shuffle(...).Take(n)` 代替。** 两者抽取的**次数与区间都不一样**：
    ///   · `pick_random(m 选 n)`：抽 **n** 次，区间 [0,m−1]、[0,m−2]…[0,m−n]
    ///   · Fisher-Yates 洗完再取：抽 **m−1** 次，区间 [0,m−1]、[0,m−2]…[0,1]
    /// 而双内核对拍的随机数带子是**逐笔**比对的 —— 次数对不上，那一步之后整段作废。
    /// 这是对拍规格点名的「RNG 口径改造」之一。
    /// </summary>
    IReadOnlyList<T> PickRandom<T>(IReadOnlyList<T> items, int count);

    /// <summary>
    /// 创建当前状态的结构共享副本（用于分支）。
    /// </summary>
    IDeterministicRng Fork();

    /// <summary>
    /// 序列化当前状态。
    /// </summary>
    RngState GetState();

    /// <summary>
    /// 从状态恢复。
    /// </summary>
    void SetState(RngState state);
}

/// <summary>
/// RNG 状态：可序列化、可比较（用于验证确定性）。
/// </summary>
public readonly record struct RngState(ulong Seed, ulong Counter, ulong S1 = 0, ulong S2 = 0, ulong S3 = 0)
{
    public override string ToString() => $"RngState(seed={Seed:X16}, counter={Counter})";
}

/// <summary>
/// xoshiro256** 实现：高质量、快速、可分支的确定性 RNG。
/// 参考：https://prng.di.unimi.it/
/// </summary>
public sealed class Xoshiro256StarStar : IDeterministicRng
{
    private ulong s0, s1, s2, s3;
    private ulong callCount; // 用于验证确定性和调试

    public Xoshiro256StarStar(ulong seed)
    {
        // SplitMix64 初始化，避免低质量种子
        s0 = SplitMix64(ref seed);
        s1 = SplitMix64(ref seed);
        s2 = SplitMix64(ref seed);
        s3 = SplitMix64(ref seed);
        callCount = 0;
    }

    private Xoshiro256StarStar(ulong s0, ulong s1, ulong s2, ulong s3, ulong callCount)
    {
        this.s0 = s0;
        this.s1 = s1;
        this.s2 = s2;
        this.s3 = s3;
        this.callCount = callCount;
    }

    private static ulong SplitMix64(ref ulong x)
    {
        ulong z = (x += 0x9e3779b97f4a7c15UL);
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
        z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
        return z ^ (z >> 31);
    }

    private ulong Next()
    {
        ulong result = RotateLeft(s1 * 5, 7) * 9;
        ulong t = s1 << 17;

        s2 ^= s0;
        s3 ^= s1;
        s1 ^= s2;
        s0 ^= s3;

        s2 ^= t;
        s3 = RotateLeft(s3, 45);

        callCount++;
        return result;
    }

    private static ulong RotateLeft(ulong x, int k) => (x << k) | (x >> (64 - k));

    public double NextDouble()
    {
        // 生成 [0, 1) 范围，使用高 53 位
        return (Next() >> 11) * (1.0 / (1UL << 53));
    }

    public int NextInt(int max)
    {
        if (max <= 0) throw new ArgumentOutOfRangeException(nameof(max), "Max must be positive");
        // 使用简单但正确的拒绝采样方法
        ulong range = (ulong)max;
        ulong limit = ulong.MaxValue - (ulong.MaxValue % range);
        
        ulong value;
        do
        {
            value = Next();
        } while (value >= limit);
        
        return (int)(value % range);
    }

    public int NextIntRange(int min, int max)
    {
        if (min >= max) throw new ArgumentException("Min must be less than max");
        return min + NextInt(max - min);
    }

    public T Choose<T>(IReadOnlyList<T> items)
    {
        if (items.Count == 0) throw new ArgumentException("Cannot choose from empty list");
        return items[NextInt(items.Count)];
    }

    public IReadOnlyList<T> PickRandom<T>(IReadOnlyList<T> items, int count)
    {
        var pool = items.ToList();
        var picked = new List<T>();
        while (picked.Count < count && pool.Count > 0)
        {
            var i = NextIntRange(0, pool.Count);   // 半开 [0, size) ≡ GD 的 randi_range(0, size−1)
            picked.Add(pool[i]);
            pool.RemoveAt(i);
        }
        return picked;
    }

    public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items)
    {
        var array = items.ToArray();
        for (int i = array.Length - 1; i > 0; i--)
        {
            int j = NextInt(i + 1);
            (array[i], array[j]) = (array[j], array[i]);
        }
        return array;
    }

    public IDeterministicRng Fork()
    {
        // 结构共享：复制当前状态
        return new Xoshiro256StarStar(s0, s1, s2, s3, callCount);
    }

    public RngState GetState()
    {
        return new RngState(s0, callCount, s1, s2, s3);
    }

    public void SetState(RngState state)
    {
        if ((state.Seed | state.S1 | state.S2 | state.S3) == 0)
            throw new ArgumentException("The all-zero xoshiro state is invalid.", nameof(state));
        (s0, s1, s2, s3, callCount) = (state.Seed, state.S1, state.S2, state.S3, state.Counter);
    }
}
