namespace CellWar.Core;

/// <summary>
/// 产品版的**脚本骰子**（换内核 P5，新手教程用；GD 侧是 `game/scripts/kernel/cw_roll_tape.gd`）：先按带子 `[[from, to, value], …]` 一条条念，
/// 念完回落到一条按种子生成的随机流。与测试工程里 L1 那份 TapeRng 的区别：那份念完就抛异常（对拍要当场红），这份要让教程「自由游玩」接着跑。
///
/// 口径照 GD `cw_roll_tape.gd`：
///   · 退化区间（from == to）零消耗、不碰带子；
///   · 带子上的区间与这次要的不一样：记一笔 `BadRange`，照样用带子上的值；
///     只有**宽度相同、基数不同**时平移（C# 掷 d6 用 0..5、GD 用 1..6，同一条带子两边都要念得出同一颗骰子 —— 与 L1 TapeRng 的规矩 2 同）；
///   · 念完：记一笔 `Overrun`，改从回落流抽（GD 回落 PCG(seed=1)，C# 回落 SplitMix；回落序列两边不同，教程只在带子之后的自由游玩里用到它）。
///
/// 状态要装进 <see cref="RngState"/> 的五个字段（Runtime 每个事件都 Fork + SetState，见 Runtime.cs）：
/// `Seed` = 回落流的种子、`Counter` = 回落流已抽次数、`S1` = 带子游标、`S2` / `S3` = Overrun / BadRange 计数。
/// 回落流是**按计数直接算**的 SplitMix64（第 n 次 = SplitMix64(seed + n·γ)），所以两个字段就够、不用存内部状态。
/// </summary>
public sealed class ScriptedRng : IDeterministicRng
{
    private readonly IReadOnlyList<(int From, int To, int Value)> tape;
    private ulong seed;
    private ulong counter;
    private int at;

    public int Overrun { get; private set; }
    public int BadRange { get; private set; }
    public int Consumed => at;
    public int Unused => Math.Max(tape.Count - at, 0);

    /// <param name="records">GD 关卡数据里的 `rolls`：每条 `[from, to, value]`。</param>
    /// <param name="fallbackSeed">念完之后的回落流种子。</param>
    public ScriptedRng(IEnumerable<IReadOnlyList<long>> records, ulong fallbackSeed = 1)
        : this(records.Select(r => ((int)r[0], (int)r[1], (int)r[2])).ToList(), fallbackSeed, 0, 0, 0, 0) { }

    private ScriptedRng(IReadOnlyList<(int, int, int)> tape, ulong seed, ulong counter, int at, int overrun, int badRange)
    {
        this.tape = tape;
        this.seed = seed;
        this.counter = counter;
        this.at = at;
        Overrun = overrun;
        BadRange = badRange;
    }

    private const ulong Gamma = 0x9e3779b97f4a7c15UL;

    private ulong NextFallback()
    {
        var z = seed + (++counter) * Gamma;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
        z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
        return z ^ (z >> 31);
    }

    private int Draw(int from, int toInclusive)
    {
        if (from == toInclusive) return from;
        if (at >= tape.Count)
        {
            Overrun++;
            return from + (int)(NextFallback() % (ulong)(toInclusive - from + 1));
        }
        var (f, t, v) = tape[at++];
        if (t - f == toInclusive - from) return v - f + from;   // 宽度相同：只平移基数
        BadRange++;
        return Math.Clamp(v, from, toInclusive);
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

    /// <summary>GD 侧只有 randi_range，没有浮点抽法；带子不管它，直接走回落流（教程关卡里没有用到浮点抽取的规则）。</summary>
    public double NextDouble() => (NextFallback() >> 11) * (1.0 / (1UL << 53));

    public T Choose<T>(IReadOnlyList<T> items)
    {
        if (items.Count == 0) throw new ArgumentException("Cannot choose from empty list");
        return items[NextInt(items.Count)];
    }

    /// <summary>与 L1 TapeRng / Xoshiro 同一种抽法（逐个抽下标、抽出即移走），带子才念得对。</summary>
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
        var list = items.ToList();
        for (var i = list.Count - 1; i > 0; i--)
        {
            var j = NextInt(i + 1);   // 与 Xoshiro / L1 TapeRng 逐字同一种抽法
            (list[i], list[j]) = (list[j], list[i]);
        }
        return list;
    }

    public IDeterministicRng Fork() => new ScriptedRng(tape, seed, counter, at, Overrun, BadRange);

    public RngState GetState() => new(seed, counter, (ulong)at, (ulong)Overrun, (ulong)BadRange);

    public void SetState(RngState state)
    {
        seed = state.Seed;
        counter = state.Counter;
        at = (int)state.S1;
        Overrun = (int)state.S2;
        BadRange = (int)state.S3;
    }
}
