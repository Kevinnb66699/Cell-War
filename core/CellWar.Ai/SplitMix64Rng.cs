using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// AI 推演用的**独立随机流**（Kevin 10-01：意图 / 搜索档试走不许用真局接下来的骰子）。
///
/// 选 SplitMix64 是因为它在 GDScript 里也写得出来、逐位相同：状态就一个 64 位整数，
/// 只有加、乘、异或、逻辑右移 —— GD 的 int 是有符号 64 位、加乘按二补码回绕（10-01 实测），
/// 逻辑右移用 `(z >> k) & mask` 拼。GD 侧那一份在 `game/scripts/ai/agree_rng.gd`，**两份必须逐位相同**
/// （金值护栏：C# <c>SplitMix64RngTests</c> / GD <c>t_ai_agree_rng</c> 钉同一组数）。
///
/// 取值映射（两边同式）：
/// · 闭区间 [lo, hi] = <c>lo + ((next() &gt;&gt;&gt; 1) % 跨度)</c> —— **只看跨度、与基数无关**：
///   C# 有几处 <c>NextInt(n)</c> 对的是 GD 的 <c>randi_range(1, n)</c>（L1 的 RNG_BASE），偏移必须一样；
/// · **跨度为 1 零消耗**：Godot 的 <c>randi_range(n, n)</c> 不推进状态，两个内核都依赖这条（L1 带子规矩 1）；
/// · [0,1) = 高 53 位。
/// </summary>
public sealed class SplitMix64Rng : IDeterministicRng
{
    public const ulong Golden = 0x9E3779B97F4A7C15UL;

    /// <summary>当前状态。<see cref="RngState.Counter"/> 里放的就是它（<see cref="RngState.Seed"/> 填一个非零标记，免得被 xoshiro 的「全零非法」校验拦下）。</summary>
    public ulong State { get; private set; }

    /// <summary>种子直接当状态（GD 侧 <c>seed = v</c> 同口径）。</summary>
    public SplitMix64Rng(ulong seed) => State = seed;

    public static ulong Mix(ulong z)
    {
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
        return z ^ (z >> 31);
    }

    public ulong NextU64()
    {
        State += Golden;
        return Mix(State);
    }

    /// <summary>闭区间 [from, toInclusive]（GD <c>randi_range</c> 口径）。</summary>
    private int Draw(int from, int toInclusive)
    {
        if (from == toInclusive) return from;
        var span = (ulong)((long)toInclusive - from + 1);
        return from + (int)((NextU64() >> 1) % span);
    }

    public int NextInt(int max)
    {
        if (max <= 0) throw new ArgumentOutOfRangeException(nameof(max));
        return Draw(0, max - 1);
    }

    public int NextIntRange(int min, int max)
    {
        if (min >= max) throw new ArgumentException("Min must be less than max");
        return Draw(min, max - 1);
    }

    public double NextDouble() => (NextU64() >> 11) * (1.0 / (1UL << 53));

    public T Choose<T>(IReadOnlyList<T> items)
    {
        if (items.Count == 0) throw new ArgumentException("Cannot choose from empty list");
        return items[NextInt(items.Count)];
    }

    /// <summary>与 <see cref="Xoshiro256StarStar.PickRandom{T}"/> 同一条 pop-loop（对齐 GD <c>pick_random</c>）。</summary>
    public IReadOnlyList<T> PickRandom<T>(IReadOnlyList<T> items, int count)
    {
        var pool = items.ToList();
        var picked = new List<T>();
        while (picked.Count < count && pool.Count > 0)
        {
            var i = NextIntRange(0, pool.Count);
            picked.Add(pool[i]);
            pool.RemoveAt(i);
        }
        return picked;
    }

    public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items)
    {
        var array = items.ToArray();
        for (var i = array.Length - 1; i > 0; i--)
        {
            var j = NextInt(i + 1);
            (array[i], array[j]) = (array[j], array[i]);
        }
        return array;
    }

    public IDeterministicRng Fork() => new SplitMix64Rng(State);

    /// <summary>Seed 填标记 1（非零），Counter 是状态。</summary>
    public RngState GetState() => new(1, State);

    public void SetState(RngState state) => State = state.Counter;

    /// <summary>
    /// 启发式分化的并列决胜（替 GD 的 <c>hash([rng.state, pid])</c> —— C# 没有 GD 的 hash）：
    /// 同状态同席位同答案，**不消耗**随机数。GD 侧 <c>agree_rng.gd:tie_index</c> 同式。
    /// </summary>
    public static int TieIndex(ulong rngState, int seat, int n)
        => n <= 0 ? 0 : (int)((Mix(rngState + (ulong)(seat + 1) * Golden) >> 1) % (ulong)n);

    /// <summary>从会话种子 + 修订号派生一问的推演种子（sidecar 用；对拍语料里种子是 GD 记下的，不走这里）。</summary>
    public static ulong DecisionSeed(ulong sessionSeed, long revision)
        => Mix(sessionSeed + (ulong)revision * Golden);
}
