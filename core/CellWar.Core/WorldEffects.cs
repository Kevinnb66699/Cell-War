namespace CellWar.Core;

/// <summary>
/// 一条活跃的**全局**修饰。
///
/// 对齐 GDScript 的 `game.events["active"]` 条目（`cw_world_fx.gd` 头注）。
/// 容器里住两类东西，**共用同一套挂接点**，这也是先做它的理由：
///   · 世界事件（15 个，按 3/6/10/14 世界回合抽取）
///   · **卡牌挂的全局修饰** —— 今天真正会动的就这三张：
///     【基质稳定】【TGF-β释放】【TNF-α局部炎症】
///
/// 想区分「这条是世界事件还是卡牌挂的」用 <see cref="WorldEffects.IsWorldEvent"/>，
/// 别拿持续时间表当判据（GD 那边踩过，见 `cw_world_fx.gd` 的「审查问题 3」）。
/// </summary>
/// <param name="Name">效果名，与卡名/事件名同字</param>
/// <param name="Left">
/// 还能存活的**世界回合**数（含本回合）。E 阶段末 −1，归零移除。
/// 「本回合」类事件也占条目（`Left = 1`），查询口径统一。
/// </param>
/// <param name="Stacks">
/// 叠加层数。正常 1；【双重触发】加倍「持续·数量类」时为 2。
/// 注意**同名多条**也是合法的（打两张【TGF-β释放】= 两条各 1 层），
/// 所以强度一律用 <see cref="WorldEffects.Stacks"/> 求和，别只看第一条。
/// </param>
/// <param name="Doubled">
/// 被【双重触发】加倍时记下是哪一档（"stacks" / "rounds" / "repeat"），没被加倍就是空串。
/// **只为让界面说得出「这条被双重触发了」** —— 光看 Left/Stacks 反推不出来。
/// </param>
public sealed record ActiveEffect(string Name, int Left, int Stacks = 1, string Doubled = "")
{
    /// <summary>
    /// 事件私有簿记（GD 侧 `data`：紊乱=原位 / 营养输送=已领 / 迁移激活=已用）。
    /// 键一律用细胞 id 的字符串形式，随快照走、进状态比对。
    /// </summary>
    public IReadOnlyDictionary<string, int> Data { get; init; }
        = System.Collections.Immutable.ImmutableSortedDictionary<string, int>.Empty.WithComparers(StringComparer.Ordinal);

    /// <summary>倒计时一格。</summary>
    public ActiveEffect Tick() => this with { Left = Left - 1 };

    public bool Expired => Left <= 0;
}

/// <summary>
/// 世界事件与全局修饰容器的读写口子。
///
/// **各结算点读事件一律走 <see cref="Stacks"/> / <see cref="Active"/>**，
/// 别自己去翻 <see cref="WorldState.Effects"/> —— 与 GD 的「一律走 `game.event_stacks()`」同一条规矩。
///
/// 2026-09-16 建立（EV-0）。这一版**只有容器与接口，不含 15 个世界事件的内容**：
/// 抽取表、触发结算、【双重触发】的三档加倍都还没搬。
/// 容器先立起来是因为它是**批 5（卡牌 + 修饰器 + 种类技能，~430 条断言）的三个前置之一**，
/// 而且 C# 侧那三张会动的卡此前各自用一个标量顶着，形状与 GD 对不上。
/// </summary>
public static class WorldEffects
{
    /// <summary>
    /// 15 个世界事件，按 PRD「世界事件」节的出场顺序（GD `CWWorldFx.EVENTS`）。
    /// **这里只是名字表，C# 还没有实现它们的效果** —— 放着是为了接入时有个对齐的锚点。
    /// </summary>
    public static readonly IReadOnlyList<string> WorldEventNames =
    [
        "营养输送", "异常增殖", "代谢加速", "紊乱", "抗原引导", "免疫伪装",
        "抗原变异", "抗原暴露", "增殖抑制",
        "营养缺乏", "双重触发", "细胞应激", "基质阻隔", "迁移激活", "信号放大",
    ];

    /// <summary>
    /// 世界事件的触发回合（GD `CWData.is_world_event_round`）：第 3 / 6 / 10 / 14 世界回合。
    /// 14 而非 15 —— 终局那回合不再插事件（2026-09-07 随 15 回合制改）。
    /// </summary>
    public static bool IsWorldEventRound(int round) => round is 3 or 6 or 10 or 14;

    /// <summary>这条是世界事件，还是卡牌挂上来的全局修饰。</summary>
    public static bool IsWorldEvent(string name) => WorldEventNames.Contains(name);

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
}
