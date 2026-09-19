namespace CellWar.Core;

/// <summary>
/// 一条活跃的**全局**修饰。
///
/// 对齐 GDScript 的 `game.events["active"]` 条目（`cw_world_fx.gd` 头注）。
/// 容器里住的只有**卡牌挂的全局修饰** —— 今天真正会动的就这三张：
/// 【基质稳定】【TGF-β释放】【TNF-α局部炎症】。
/// （世界事件整块 2026-09-19 由 Kevin 取消，容器留着 —— 那三张卡的唯一挂接点。）
/// </summary>
/// <param name="Name">效果名，与卡名/事件名同字</param>
/// <param name="Left">
/// 还能存活的**世界回合**数（含本回合）。E 阶段末 −1，归零移除。
/// 「本回合」类事件也占条目（`Left = 1`），查询口径统一。
/// </param>
/// <param name="Stacks">
/// 叠加层数。正常 1。
/// 注意**同名多条**也是合法的（打两张【TGF-β释放】= 两条各 1 层），
/// 所以强度一律用 <see cref="WorldEffects.Stacks"/> 求和，别只看第一条。
/// </param>
public sealed record ActiveEffect(string Name, int Left, int Stacks = 1)
{
    /// <summary>
    /// 条目私有簿记（GD 侧 `data`）。
    /// 键一律用细胞 id 的字符串形式，随快照走、进状态比对。
    /// </summary>
    public IReadOnlyDictionary<string, int> Data { get; init; }
        = System.Collections.Immutable.ImmutableSortedDictionary<string, int>.Empty.WithComparers(StringComparer.Ordinal);

    /// <summary>倒计时一格。</summary>
    public ActiveEffect Tick() => this with { Left = Left - 1 };

    public bool Expired => Left <= 0;
}

/// <summary>
/// 全局修饰容器的读写口子。
///
/// **各结算点读条目一律走 <see cref="Stacks"/> / <see cref="Active"/>**，
/// 别自己去翻 <see cref="WorldState.Effects"/> —— 与 GD 的「一律走 `game.event_stacks()`」同一条规矩。
///
/// 2026-09-16 建立（EV-0）。容器先立起来是因为它是**批 5（卡牌 + 修饰器 + 种类技能，~430 条断言）的三个前置之一**，
/// 而且 C# 侧那三张会动的卡此前各自用一个标量顶着，形状与 GD 对不上。
/// 世界事件整块 2026-09-19 由 Kevin 取消（「我们不加入世界事件了」）：名表与两个判据随之删掉，容器与三张卡照旧。
/// </summary>
public static class WorldEffects
{
    /// <summary>
    /// 这个效果此刻的**总强度**：同名条目的层数求和。
    /// 求和而不是取第一条 —— 打两张【TGF-β释放】是两条各 1 层，逐份 −20%（定案 #63）。
    /// 对齐 GD 的 `CWWorld._tgf_stacks()` 而不是 `CWGame.event_stacks()`
    /// （后者只看第一条，是 GD 侧一个只在「不可能同名多条」的前提下成立的写法）。
    /// </summary>
    public static int Stacks(WorldState s, string name)
        => s.Effects.Where(e => e.Name == name).Sum(e => e.Stacks);

    /// <summary>这个效果此刻在不在场。</summary>
    public static bool Active(WorldState s, string name) => s.Effects.Any(e => e.Name == name);

    /// <summary>【TNF-α局部炎症】冻结名单的键：格坐标 "q,r"（GD `install_event(..., frozen)` 的 data 以 Vector2i 为键）。</summary>
    public static string TileKey(HexPosition p) => $"{p.Q},{p.R}";

    /// <summary>
    /// GD `CWGame.solid_frozen(pos)`：被【TNF-α局部炎症】冻住的格本世界回合不得增加固化计数。
    /// 冻结名单挂在事件容器里（条目 left=1，E 阶段第 8 步随 tick_durations 解冻）—— 此前 C# 用格上的 `SolidLockRound` 顶着，
    /// 规则结果一样但 L1 视图的 `$.g.events` 会少一条（Kevin 2026-09-18 裁：搬进容器）。
    /// </summary>
    public static bool SolidFrozen(WorldState s, HexPosition pos)
    {
        var key = TileKey(pos);
        return s.Effects.Any(e => e.Name == "TNF-α局部炎症" && e.Data.ContainsKey(key));
    }
}
