using CellWar.Core;

namespace CellWar.Core.Tests;

/// <summary>
/// 记录型 rng：**不改变任何取值**，只把每一笔抽取**请求的区间**记下来。
///
/// 值域断言靠它才能落在**调用点**上，而不是落在 RNG 助手上 ——
/// 2026-09-15 那个「攻击暴击永远掷不出来」的 bug 能活下来，
/// 正是因为第一版测试把靶画在了助手身上。
///
/// 2026-09-16 从 RegressionGuardTests 里抽出来：`GdScriptParityTests` 也要用它
/// 验【E-侵蚀】掷的是 d3（1..3）而不是 `NextInt(3)`（0..2）。
/// </summary>
internal sealed class RecordingRng(IDeterministicRng inner) : IDeterministicRng
{
    public List<(int Min, int Max)> Ranges { get; } = [];
    public int DoubleDraws { get; private set; }

    public double NextDouble() { DoubleDraws++; return inner.NextDouble(); }
    public int NextInt(int max) { Ranges.Add((0, max)); return inner.NextInt(max); }
    public int NextIntRange(int min, int max) { Ranges.Add((min, max)); return inner.NextIntRange(min, max); }
    public T Choose<T>(IReadOnlyList<T> items) { Ranges.Add((0, items.Count)); return inner.Choose(items); }
    public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items) => inner.Shuffle(items);
    public IDeterministicRng Fork() => new RecordingRng(inner.Fork());
    public RngState GetState() => inner.GetState();
    public void SetState(RngState state) => inner.SetState(state);
}

/// <summary>只数抽取次数，不改任何取值。</summary>
internal sealed class CountingRng(IDeterministicRng inner, Action onDraw) : IDeterministicRng
{
    public double NextDouble() { onDraw(); return inner.NextDouble(); }
    public int NextInt(int max) { onDraw(); return inner.NextInt(max); }
    public int NextIntRange(int min, int max) { onDraw(); return inner.NextIntRange(min, max); }
    public T Choose<T>(IReadOnlyList<T> items) { onDraw(); return inner.Choose(items); }
    public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items) { onDraw(); return inner.Shuffle(items); }
    public IDeterministicRng Fork() => new CountingRng(inner.Fork(), onDraw);
    public RngState GetState() => inner.GetState();
    public void SetState(RngState state) => inner.SetState(state);
}
