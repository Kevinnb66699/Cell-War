namespace CellWar.Core;

/// <summary>
/// 产品版的**脚本骰子**（换内核 P5，新手教程用；GD 侧是 `game/scripts/kernel/cw_roll_tape.gd`）：先按带子 `[[from, to, value], …]` 一条条念，
/// 念完回落到一条按种子生成的随机流。与测试工程里 L1 那份 TapeRng 的区别：那份念完就抛异常（对拍要当场红），这份要让教程「自由游玩」接着跑。
///
/// 口径照 GD `cw_roll_tape.gd`：
///   · 退化区间（from == to）零消耗、不碰带子；
///   · 带子上的区间与这次要的不一样：记一笔 `BadRange`，照样用带子上的值；
///     只有**宽度相同、基数不同**时平移（C# 掷 d6 用 0..5、GD 用 1..6，同一条带子两边都要念得出同一颗骰子 —— 与 L1 TapeRng 的规矩 2 同）；
///   · 念完：记一笔 `Overrun`，改从回落流抽。
///
/// **回落流 = Godot 4 的 `RandomNumberGenerator`（PCG32）逐位照抄**（换内核 P5（三），2026-10-01）：GD 的带子念完回落到
/// `inner.randi_range`（`seed` = 装载器的种子 1），而且**念带子的时候也照样推一步** inner（「有人会偷看 rng.state」）。
/// 第五关自由游玩、第六关（`rolls: []`）的骰子全是回落流掷的（第五关 15 颗、第六关 15 颗）。回落流不一样的话，
/// 同一条带子在两个内核上演出来的就不是同一局（10-01 实测：第五关第一只骨肉瘤 6 下变 5 下、第六关多掷一颗）；照抄之后
/// 只要两个内核要骰子的次序与区间宽度一样（L1 四条整局轨迹钉着），每一颗都相同。区间宽度相同、基数不同（0..5 ↔ 1..6）
/// 时 PCG 用的界是一样的（`bound = 宽度`），抽出来的偏移量也一样。金值两侧各钉一份（C# `ScriptedRngResumeTests`、GD `t_tutor_sidecar_rng`）。
///
/// 状态要装进 <see cref="RngState"/> 的五个字段（Runtime 每个事件都 Fork + SetState，见 Runtime.cs）：
/// `Seed` = 回落流的种子、`Counter` = PCG 的 64 位状态（增量恒为 Godot 的缺省值，不用存）、`S1` = 带子游标、`S2` / `S3` = Overrun / BadRange 计数。
/// </summary>
public sealed class ScriptedRng : IDeterministicRng
{
    private readonly IReadOnlyList<(int From, int To, int Value)> tape;
    private ulong seed;
    private ulong pcg;
    private int at;

    public int Overrun { get; private set; }
    public int BadRange { get; private set; }
    public int Consumed => at;
    public int Unused => Math.Max(tape.Count - at, 0);

    /// <param name="records">GD 关卡数据里的 `rolls`：每条 `[from, to, value]`。</param>
    /// <param name="fallbackSeed">念完之后的回落流种子（GD 装载器恒为 1）。</param>
    public ScriptedRng(IEnumerable<IReadOnlyList<long>> records, ulong fallbackSeed = 1)
        : this(records.Select(r => ((int)r[0], (int)r[1], (int)r[2])).ToList(), fallbackSeed, Seeded(fallbackSeed), 0, 0, 0) { }

    private ScriptedRng(IReadOnlyList<(int, int, int)> tape, ulong seed, ulong pcg, int at, int overrun, int badRange)
    {
        this.tape = tape;
        this.seed = seed;
        this.pcg = pcg;
        this.at = at;
        Overrun = overrun;
        BadRange = badRange;
    }

    // ---- Godot 4 `RandomPCG`（thirdparty/misc/pcg.cpp + core/math/random_pcg.h）----

    private const ulong PcgMultiplier = 6364136223846793005UL;
    /// <summary>Godot 的 `PCG_DEFAULT_INC_64`；`RandomNumberGenerator.seed = s` 走 `pcg32_srandom_r(s, 它)`，所以增量 = (它 &lt;&lt; 1) | 1。</summary>
    private const ulong PcgIncrement = (1442695040888963407UL << 1) | 1UL;

    /// <summary>`pcg32_srandom_r(seed, PCG_DEFAULT_INC_64)` 之后的状态（= GD `rng.seed = seed`）。</summary>
    private static ulong Seeded(ulong s)
    {
        var state = 0UL;
        Step(ref state);
        state += s;
        Step(ref state);
        return state;
    }

    /// <summary>`pcg32_random_r`：推一步、出一个 32 位数（XSH RR）。</summary>
    private static uint Step(ref ulong state)
    {
        var old = state;
        state = unchecked(old * PcgMultiplier + PcgIncrement);
        var xorShifted = (uint)(((old >> 18) ^ old) >> 27);
        var rot = (int)(old >> 59);
        return (xorShifted >> rot) | (xorShifted << ((-rot) & 31));
    }

    /// <summary>`pcg32_boundedrand_r`：拒绝采样到 `[0, bound)`（GD `randi_range(a, b)` = a + 它(b − a + 1)）。</summary>
    private uint Bounded(uint bound)
    {
        var threshold = unchecked(0u - bound) % bound;
        while (true)
        {
            var r = Step(ref pcg);
            if (r >= threshold) return r % bound;
        }
    }

    private int Draw(int from, int toInclusive)
    {
        if (from == toInclusive) return from;
        var width = (uint)(toInclusive - from + 1);
        if (at >= tape.Count)
        {
            Overrun++;
            return from + (int)Bounded(width);
        }
        var (f, t, v) = tape[at++];
        Bounded(width);   // 念带子也照样推一步回落流（同 GD：inner.randi_range 照调）—— 带子念完时两边的回落流才站在同一处
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

    /// <summary>GD 侧只有 randi_range，没有浮点抽法；带子不管它，直接从回落流拼 53 位（教程关卡里没有用到浮点抽取的规则）。</summary>
    public double NextDouble()
    {
        var hi = (ulong)Step(ref pcg);
        var lo = (ulong)Step(ref pcg);
        return (((hi << 32) | lo) >> 11) * (1.0 / (1UL << 53));
    }

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

    public IDeterministicRng Fork() => new ScriptedRng(tape, seed, pcg, at, Overrun, BadRange);

    public RngState GetState() => new(seed, pcg, (ulong)at, (ulong)Overrun, (ulong)BadRange);

    public void SetState(RngState state)
    {
        seed = state.Seed;
        pcg = state.Counter;
        at = (int)state.S1;
        Overrun = (int)state.S2;
        BadRange = (int)state.S3;
    }
}
