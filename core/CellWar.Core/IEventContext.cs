namespace CellWar.Core;

/// <summary>
/// 事件处理上下文：规则处理器的环境接口
/// 提供状态读写、随机数、调度新事件的能力
/// 确保规则处理器同步执行，不直接访问全局状态
/// </summary>
public interface IEventContext
{
    /// <summary>
    /// 当前事件的时刻
    /// </summary>
    long CurrentTick { get; }

    /// <summary>
    /// 当前正在处理的事件
    /// </summary>
    ScheduledEvent CurrentEvent { get; }

    /// <summary>
    /// 确定性随机数生成器
    /// 事务内连续消费世界 RNG，失败时不提交随机状态。
    /// </summary>
    IDeterministicRng Rng { get; }

    /// <summary>
    /// 获取当前世界状态（只读视图）
    /// </summary>
    WorldState GetWorldState();

    /// <summary>
    /// 更新世界状态（调用者负责创建新状态）
    /// </summary>
    void SetWorldState(WorldState newState);

    /// <summary>
    /// 调度未来事件
    /// </summary>
    void Schedule(long tick, string eventType, object? payload = null);

    /// <summary>
    /// 取消未来事件
    /// </summary>
    int CancelEvents(Func<ScheduledEvent, bool> predicate);

    /// <summary>
    /// 记录日志（用于调试和回放验证）
    /// </summary>
    void Log(string message);
    void AwaitInput(int playerSeat, IReadOnlyList<IDecision> options);
}

/// <summary>
/// 实体标识符：不可变的全局唯一 ID
/// </summary>
public readonly record struct EntityId(ulong Value)
{
    public static EntityId Invalid => new(0);
    public bool IsValid => Value != 0;
}

/// <summary>
/// 规则处理器接口：处理特定类型的事件
/// 每个规则处理器是无状态的纯函数，通过 IEventContext 访问世界状态
/// </summary>
public interface IRuleHandler
{
    /// <summary>
    /// 处理器负责的事件类型
    /// </summary>
    string EventType { get; }

    /// <summary>
    /// 同步执行事件处理逻辑
    /// </summary>
    /// <param name="context">事件上下文</param>
    void Handle(IEventContext context);
}

/// <summary>
/// 规则模块：一组相关的规则处理器
/// 例如：战斗模块、移动模块、经济模块
/// </summary>
public interface IRuleModule
{
    /// <summary>
    /// 模块名称
    /// </summary>
    string Name { get; }

    /// <summary>
    /// 注册该模块的所有规则处理器
    /// </summary>
    IEnumerable<IRuleHandler> GetHandlers();
}
