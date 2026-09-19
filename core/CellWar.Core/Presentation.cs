using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>
/// 结构化演出通道（口径二 · 批 0，规格 docs/口径二_批0_底座规格.md A-4）。
///
/// 为什么要另开一条：<see cref="SimulationState.Outbox"/> 只装字符串，装不下骰点 / 光束 / 侵蚀方向；
/// GD 侧最宽的一条演出是 `fx: immune_attack` 的 10 个键（cw_actions.gd:945-949）。
/// 这里的记录**逐字照** GD 桥的十条通道（cw_bridge.gd:31-92 / cw_net_bridge.gd:34-80 的报文键），一个键都不改 ——
/// 批 1 接线时客户端拿到的形状要和今天联机报文一样，`match.gd` 的播放代码才能原样复用。
///
/// 事件从规则函数**既有的** <c>result.Events</c> 通道流出来（实现 <see cref="IPresentationEvent"/> 的就是演出，其余照旧进日志），
/// 规则函数签名一个不改；<see cref="IEventContext.Emit"/> 把它们按单调 <see cref="StagedEvent.Seq"/> 排进
/// <see cref="SimulationState.Presentation"/>。溢出丢最旧、抬水位线，**永不重编号**（客户端一比就知道自己漏了，而不是静默错播）。
/// AI 推演（<c>Runtime.Fork</c>）静音，对齐 GD 的 `sim_quiet`。
/// </summary>
public interface IPresentationEvent : IGameEvent { }

/// <summary>排好序号的演出条目。</summary>
public sealed record StagedEvent(long Seq, IPresentationEvent Event);

/// <summary>`show_roll(reason, value, sides, pid, at)`：掷骰。带 barrier —— 消费者播完才 ack（批 0 不反转 await 语义）。</summary>
public sealed record DiceRolled(int WorldRound, Phase Phase, string Reason, int Value, int Sides, int Seat, HexPosition At) : IPresentationEvent
{
    public string EventType => "roll";
}

/// <summary>攻击判定的结果：骰点、是否重掷、判词（由引擎给，UI 不许照点数再判一遍 —— cw_bridge.gd:36-38）、实际造成、是否被挡。</summary>
public sealed record AttackResolved(int WorldRound, Phase Phase, EntityId Attacker, EntityId Defender, int Roll, bool Rerolled,
    string Outcome, int Dealt, bool Shielded, bool IsKill) : IPresentationEvent
{
    public string EventType => "attack";
}

/// <summary>`show_result(text, at, linger)`：格上冒一行结果文案。</summary>
public sealed record ResultAnnounced(int WorldRound, Phase Phase, string Text, HexPosition At, bool Linger = false) : IPresentationEvent
{
    public string EventType => "result";
}

/// <summary>`show_notice(text)`：全局提示。</summary>
public sealed record NoticeAnnounced(int WorldRound, Phase Phase, string Text) : IPresentationEvent
{
    public string EventType => "notice";
}

/// <summary>`show_card_played(pid, text, {cell_id, pos, faction, card})`。</summary>
public sealed record CardPlayed(int WorldRound, Phase Phase, int Seat, string Text, EntityId CellId, HexPosition Pos, Faction Faction, string Card) : IPresentationEvent
{
    public string EventType => "card_played";
}

/// <summary>`show_event_drawn(pid, {cell_id, pos, faction, card})`：抽到即结算的事件卡。</summary>
public sealed record EventCardDrawn(int WorldRound, Phase Phase, int Seat, EntityId CellId, HexPosition Pos, Faction Faction, string Card) : IPresentationEvent
{
    public string EventType => "event_drawn";
}

/// <summary>`show_card_drawn(pid, {cell_id, pos, source})`：**刻意不带牌名**（cw_game.gd:785），观众 / 对手不该看见。</summary>
public sealed record CardDrawn(int WorldRound, Phase Phase, int Seat, EntityId CellId, HexPosition Pos, string Source) : IPresentationEvent
{
    public string EventType => "card_drawn";
}

/// <summary>`show_erosion(at, dir)`：组织翻面的演出（侵蚀 / 增生 / 定殖共用）。<paramref name="Dir"/> 是 GD `CWData.DIRS` 的下标（<see cref="SemanticKey.DirIndex"/>），-1 = 无方向（GD 侧 dir &lt; 0 不发）。</summary>
public sealed record TissueConverted(int WorldRound, Phase Phase, HexPosition At, int Dir, string Cause) : IPresentationEvent
{
    public string EventType => "erosion";
}

/// <summary>`show_beam(from, to, splash)`。</summary>
public sealed record BeamFired(int WorldRound, Phase Phase, HexPosition From, HexPosition To, ImmutableArray<HexPosition> Splash) : IPresentationEvent
{
    public string EventType => "beam";
}

/// <summary>`show_fx(kind, data)`：技能 / 卡牌粒子。<paramref name="Kind"/> 照 skill_fx.gd:14-45 的名单；
/// <paramref name="Data"/> 只装 int / bool / 坐标 / 坐标数组（cw_game.gd:819-821），像素换算留在 GD 侧。</summary>
public sealed record SkillFx(int WorldRound, Phase Phase, string Kind, ImmutableDictionary<string, object> Data) : IPresentationEvent
{
    public string EventType => "fx";
}

/// <summary>行动边界（观测协议 p=2 附录 B；Kevin 2026-09-19 拍「演出播放形态选 2」）：一问答下之后 <c>step_begin{ask_id, seat}</c>。
/// 客户端拿它把一步的演出当一个包顺序播完、再落地这一步的 sync；引擎 / 服务器照旧不等演出。GD 侧同口径：<c>cw_kernel_inproc.gd:_open_step</c>。</summary>
public sealed record StepBegin(int WorldRound, Phase Phase, long AskId, int Seat) : IPresentationEvent
{
    public string EventType => "step_begin";
}

/// <summary>一步收尾 <c>step_end{rev}</c>：下一问挂起之前（<see cref="Runtime.AwaitInput"/>）。<paramref name="Rev"/> = 这一步提交后的修订号，与紧随其后的 envelope.rev 同一个数。</summary>
public sealed record StepEnd(int WorldRound, Phase Phase, long Rev) : IPresentationEvent
{
    public string EventType => "step_end";
}
