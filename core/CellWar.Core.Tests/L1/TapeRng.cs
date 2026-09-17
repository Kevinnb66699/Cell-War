using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>带子对不上时抛这个：Code 是对拍规格里的那几个词（RNG_SPAN / RNG_OVERRUN / RNG_NO_COUNTERPART）。</summary>
public sealed class TapeException(string code, string detail) : Exception($"{code}：{detail}")
{
    public string Code { get; } = code;
}

/// <summary>
/// **念带子的 rng**：L1 重放时 C# 不自己掷骰，逐条念 GD 录下来的 `[from, to, value]`。
///
/// 对拍规格 §L1 带子的三条硬规矩都在这里落地：
/// 1. **`from==to` 零消耗** —— GD 的 `randi_range(n,n)` 不推进 PCG 状态、带子上没有这条；
///    C# 这边 `NextIntRange(n, n+1)` / `NextInt(1)` 同样不读带子，否则从第一个单选项处就错位。
/// 2. **只比跨度，不比基数** —— `NextInt(max)` 折成 `[0,max-1]`、`NextIntRange(min,max)` 折成 `[min,max-1]`；
///    跨度同、基数不同是口径（记一条 `RNG_BASE`，值按偏移平移）；**跨度不同才是 `RNG_SPAN`**，
///    那是「候选集大小不一样」的免费断言，在结算之前就报警。
/// 3. 带子用完 C# 还要 = `RNG_OVERRUN`；一步走完带子有剩 = `RNG_UNUSED`（调用方看 <see cref="Unused"/>）。
///
/// `NextDouble` 在 GD 侧**没有对应物**（GD 只有 `randi_range`），谁调它就是 `RNG_NO_COUNTERPART`。
/// </summary>
public sealed class TapeRng : IDeterministicRng
{
    private readonly IReadOnlyList<(int From, int To, int Value)> tape;
    private int at;

    /// <summary>跨度同、基数不同的那些调用，按发生顺序记下来（良性，报告里单列）。</summary>
    public List<string> BaseNotes { get; } = [];

    public TapeRng(IEnumerable<IReadOnlyList<long>> records, int cursor = 0)
    {
        tape = records.Select(r => ((int)r[0], (int)r[1], (int)r[2])).ToList();
        at = cursor;
    }

    private TapeRng(IReadOnlyList<(int, int, int)> tape, int at, List<string> notes)
    {
        this.tape = tape;
        this.at = at;
        BaseNotes.AddRange(notes);
    }

    public int Consumed => at;
    public int Unused => tape.Count - at;

    /// <summary>全闭区间 [from, toInclusive]，与 GD `randi_range(from, to)` 同口径。</summary>
    private int Draw(int from, int toInclusive)
    {
        if (from == toInclusive) return from;   // 规矩 1：零消耗
        if (at >= tape.Count)
            throw new TapeException("RNG_OVERRUN", $"C# 还要抽 [{from},{toInclusive}]，带子已经念完（共 {tape.Count} 条）");
        var (f, t, v) = tape[at++];
        if (t - f != toInclusive - from)
            throw new TapeException("RNG_SPAN", $"第 {at} 条：GD 抽的是 [{f},{t}]，C# 要的是 [{from},{toInclusive}]");
        if (f == from) return v;
        BaseNotes.Add($"第 {at} 条：[{f},{t}] → [{from},{toInclusive}]");   // 规矩 2：基数不同只平移
        return v - f + from;
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

    public double NextDouble() => throw new TapeException("RNG_NO_COUNTERPART", "NextDouble 在 GD 侧没有对应物（GD 只有 randi_range）");

    public T Choose<T>(IReadOnlyList<T> items)
    {
        if (items.Count == 0) throw new ArgumentException("Cannot choose from empty list");
        return items[NextInt(items.Count)];
    }

    /// <summary>与 <see cref="Xoshiro256StarStar.PickRandom{T}"/> 同一条 pop-loop（对齐 GD `pick_random`）。</summary>
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

    public IDeterministicRng Fork() => new TapeRng(tape, at, BaseNotes);

    /// <summary>游标塞进 Counter、Seed 填 1 —— `CheckpointCodec` 只校验 Seed|S1|S2|S3 非零（对拍规格 §L1 带子）。</summary>
    public RngState GetState() => new(1, (ulong)at);

    public void SetState(RngState state) => at = (int)state.Counter;
}
