namespace CellWar.Core;

/// <summary>
/// 游戏事件基接口
/// 所有游戏事件都是不可变的值对象，用于记录状态变化
/// </summary>
public interface IGameEvent
{
    /// <summary>
    /// 事件发生的世界回合
    /// </summary>
    int WorldRound { get; }
    
    /// <summary>
    /// 事件发生的阶段
    /// </summary>
    Phase Phase { get; }
    
    /// <summary>
    /// 事件类型标识
    /// </summary>
    string EventType { get; }
}

/// <summary>
/// 实体相关事件基接口
/// </summary>
public interface IEntityEvent : IGameEvent
{
    EntityId EntityId { get; }
}

// === 移动事件 ===

public record CellMovedEvent(
    int WorldRound,
    Phase Phase,
    EntityId EntityId,
    HexPosition From,
    HexPosition To,
    double EnergyCost
) : IEntityEvent
{
    public string EventType => "CellMoved";
}

// === 攻击事件 ===

public record CellAttackedEvent(
    int WorldRound,
    Phase Phase,
    EntityId AttackerId,
    EntityId DefenderId,
    double Damage,
    bool IsKill
) : IEntityEvent
{
    public string EventType => "CellAttacked";
    public EntityId EntityId => AttackerId;
}

// === 能量变化事件 ===

public record EnergyChangedEvent(
    int WorldRound,
    Phase Phase,
    EntityId EntityId,
    double OldValue,
    double NewValue,
    string Reason
) : IEntityEvent
{
    public string EventType => "EnergyChanged";
}

// === 细胞死亡事件 ===

public record CellDiedEvent(
    int WorldRound,
    Phase Phase,
    EntityId EntityId,
    string Reason
) : IEntityEvent
{
    public string EventType => "CellDied";
}

// === 回合推进事件 ===

public record PhaseChangedEvent(
    int WorldRound,
    Phase OldPhase,
    Phase NewPhase,
    int ActivePlayerSeat
) : IGameEvent
{
    public Phase Phase => NewPhase;
    public string EventType => "PhaseChanged";
}

public record RoundAdvancedEvent(
    int WorldRound,
    Phase Phase
) : IGameEvent
{
    public string EventType => "RoundAdvanced";
}

// === 组织变化事件 ===

public record TissueStateChangedEvent(
    int WorldRound,
    Phase Phase,
    HexPosition Position,
    TissueState OldState,
    TissueState NewState
) : IGameEvent
{
    public string EventType => "TissueStateChanged";
}

public record TissueSolidifiedEvent(
    int WorldRound,
    Phase Phase,
    HexPosition Position,
    int SolidificationCount
) : IGameEvent
{
    public string EventType => "TissueSolidified";
}
