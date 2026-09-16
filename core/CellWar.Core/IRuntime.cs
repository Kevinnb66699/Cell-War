namespace CellWar.Core;

/// <summary>
/// 模拟运行时接口：管理世界执行、事件调度和时间推进
/// Runtime 是单个世界的写执行者，保证串行执行规则处理器
/// </summary>
public interface IRuntime
{
    /// <summary>
    /// 当前世界时刻（Tick）
    /// 时刻是离散的单调递增整数，每次处理事件队列时推进
    /// </summary>
    long CurrentTick { get; }

    /// <summary>
    /// 是否处于活跃状态（未终止、未暂停）
    /// </summary>
    bool IsActive { get; }

    /// <summary>
    /// 推进模拟到下一个事件时刻
    /// 从优先队列取出最早事件，更新 CurrentTick，调用对应规则处理器
    /// </summary>
    /// <returns>成功执行的事件数，若队列为空返回 0</returns>
    StepResult Step();

    /// <summary>
    /// 推进模拟直到指定时刻（包含该时刻）
    /// 处理所有 Tick &lt;= targetTick 的事件
    /// </summary>
    /// <param name="targetTick">目标时刻</param>
    /// <returns>执行的总事件数</returns>
    int StepUntil(long targetTick);

    /// <summary>
    /// 调度一个新事件到指定时刻
    /// 当前时刻使用 LIFO；未来独立事件按时刻、显式顺序与稳定序号升序。
    /// </summary>
    /// <param name="tick">触发时刻，必须 >= CurrentTick</param>
    /// <param name="eventType">事件类型标识</param>
    /// <param name="payload">事件负载数据</param>
    void Schedule(long tick, string eventType, object? payload = null);

    /// <summary>
    /// 取消未来的某些事件
    /// 用于单位死亡时清理延迟伤害、移除持续效果等
    /// </summary>
    /// <param name="predicate">取消条件谓词</param>
    /// <returns>被取消的事件数</returns>
    int CancelEvents(Func<ScheduledEvent, bool> predicate);

    /// <summary>
    /// 暂停模拟（保持状态，阻止 Step 推进）
    /// </summary>
    void Pause();

    /// <summary>
    /// 恢复模拟
    /// </summary>
    void Resume();

    /// <summary>
    /// 创建当前状态的分支（fork）
    /// 新 Runtime 共享历史状态，拥有独立的事件队列和时刻
    /// 用于 MCTS 探索、回滚重放
    /// </summary>
    /// <returns>新的 Runtime 实例</returns>
    IRuntime Fork();
    int Run(int eventBudget = 256);
    ValidationResult Answer(InputAnswer answer);
}

/// <summary>
/// 单步执行结果
/// </summary>
public readonly record struct StepResult(
    int EventsProcessed,
    long NewTick,
    bool QueueEmpty
);

/// <summary>
/// 已调度事件的不可变描述
/// </summary>
public readonly record struct ScheduledEvent(
    long Tick,
    string EventType,
    object? Payload,
    int SequenceId  // 用于 LIFO 排序
);

/// <summary>
/// 世界句柄：不可变的世界标识符
/// 隔离不同世界状态，禁止全局 current_world
/// </summary>
public readonly record struct WorldHandle(
    Guid Id,
    long CreatedAtTick
)
{
    public static WorldHandle NewWorld() => new(Guid.NewGuid(), 0L);
}
