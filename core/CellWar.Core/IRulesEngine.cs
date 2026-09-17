namespace CellWar.Core;

/// <summary>
/// 规则引擎接口
/// 负责执行所有游戏规则，保持纯函数特性，不依赖任何外部状态
/// </summary>
public interface IRulesEngine
{
    /// <summary>
    /// 执行玩家决策，返回新状态和产生的事件
    /// </summary>
    /// <param name="state">当前世界状态（不可变）</param>
    /// <param name="decision">玩家决策</param>
    /// <param name="rng">确定性随机数生成器</param>
    /// <returns>新状态和事件列表</returns>
    RulesResult ExecuteDecision(WorldState state, IDecision decision, IDeterministicRng rng);
    
    /// <summary>
    /// 执行阶段推进逻辑
    /// </summary>
    RulesResult AdvancePhase(WorldState state, IDeterministicRng rng);
    
    /// <summary>
    /// 验证决策是否合法
    /// </summary>
    ValidationResult ValidateDecision(WorldState state, IDecision decision);
    
    /// <summary>
    /// 获取当前可用的决策列表（用于AI）
    /// </summary>
    IReadOnlyList<IDecision> GetAvailableDecisions(WorldState state, int playerSeat);
}

/// <summary>
/// 规则执行结果
/// </summary>
public record RulesResult(
    WorldState NewState,
    IReadOnlyList<IGameEvent> Events,
    bool Success,
    string? ErrorMessage = null
);

/// <summary>
/// 决策验证结果
/// </summary>
public record ValidationResult(
    bool IsValid,
    string? ErrorMessage = null
);

/// <summary>
/// 玩家决策基接口
/// </summary>
public interface IDecision
{
    int PlayerSeat { get; }
    string DecisionType { get; }
}

public sealed record ReviveDecision(int PlayerSeat, EntityId CellId, HexPosition TargetPosition,
    HexPosition? SourcePosition = null) : IDecision
{
    public string DecisionType => "Revive";
}

/// <summary>癌方「放弃本回合复活」（GD 复活问答下标 0 的 `{skip: true}`）。免疫复活没有这一项。</summary>
public sealed record SkipReviveDecision(int PlayerSeat, EntityId CellId) : IDecision
{
    public string DecisionType => "SkipRevive";
}

/// <summary>
/// 开局选址：在 Setup 阶段把初始细胞放到目标格。
/// </summary>
public sealed record PlaceDecision(
    int PlayerSeat,
    HexPosition TargetPosition
) : IDecision
{
    public string DecisionType => "Place";
}

/// <summary>
/// 移动决策
/// </summary>
public record MoveDecision(
    int PlayerSeat,
    EntityId CellId,
    HexPosition TargetPosition
) : IDecision
{
    public string DecisionType => "Move";
}

/// <summary>
/// 攻击决策
/// </summary>
public record AttackDecision(
    int PlayerSeat,
    EntityId AttackerId,
    EntityId TargetId
) : IDecision
{
    public string DecisionType => "Attack";
}

/// <summary>
/// 【分化】决策：免疫细胞分化为 B/T/巨噬/树突状细胞（每细胞每局一次，每种最多一个）。
/// </summary>
public sealed record DifferentiateDecision(
    int PlayerSeat,
    EntityId CellId,
    CellType Type
) : IDecision
{
    public string DecisionType => "Differentiate";
}

/// <summary>
/// 【基因表达】决策：消耗能量抽卡（每行动回合最多 3 次）。
/// </summary>
public sealed record DrawDecision(
    int PlayerSeat,
    EntityId CellId
) : IDecision
{
    public string DecisionType => "Draw";
}

/// <summary>
/// 手牌超过上限时的弃置决策（PRD §657：最多 8 张，超过需弃置到 8 张）。
/// </summary>
public sealed record DiscardDecision(
    int PlayerSeat,
    EntityId CellId,
    string Card
) : IDecision
{
    public string DecisionType => "Discard";
}

/// <summary>
/// 【突变】决策：消耗 0.5 能量，每个癌细胞每世界回合最多 1 次。
/// </summary>
public sealed record MutateDecision(
    int PlayerSeat,
    EntityId CellId
) : IDecision
{
    public string DecisionType => "Mutate";
}

/// <summary>
/// 打出手牌决策（即时技能结算后弃置；永久技能装备后持续生效）。
/// </summary>
public sealed record PlayCardDecision(
    int PlayerSeat,
    EntityId CellId,
    string Card,
    HexPosition? Target = null,
    EntityId? TargetCell = null
) : IDecision
{
    public string DecisionType => "PlayCard";
}

/// <summary>
/// 巨噬【连续吞噬】的一跳：免费迁移到相邻的癌组织（不进费用管线，所以是真免费）。
/// </summary>
public sealed record ChainMoveDecision(int PlayerSeat, EntityId CellId, HexPosition Target) : IDecision
{
    public string DecisionType => "ChainMove";
}

/// <summary>巨噬【连续吞噬】：不再连了。</summary>
public sealed record StopChainDecision(int PlayerSeat, EntityId CellId) : IDecision
{
    public string DecisionType => "StopChain";
}

/// <summary>
/// 【炎症性趋化】的第 2/3 步：起价 0.2 的一次**正常**迁移（照跑费用管线，不是免费）。
/// 第 1 步不在这里 —— 它的落点烤在打出这张卡的选项里。
/// </summary>
public sealed record ChemotaxisStepDecision(int PlayerSeat, EntityId CellId, HexPosition Target) : IDecision
{
    public string DecisionType => "ChemotaxisStep";
}

/// <summary>【炎症性趋化】：停在这里。</summary>
public sealed record StopChemotaxisDecision(int PlayerSeat, EntityId CellId) : IDecision
{
    public string DecisionType => "StopChemotaxis";
}

/// <summary>【代谢耦联】第一问：转移方向 —— 谁付（Payer）给谁（Getter）。GD data `{from, to_cid}`。</summary>
public sealed record CoupleDirectionDecision(int PlayerSeat, EntityId CellId, EntityId Payer, EntityId Getter) : IDecision
{
    public string DecisionType => "CoupleDirection";
}

/// <summary>【代谢耦联】第二问：档位 —— 转出 Pay、接收方得 Get（十分能量）。GD data `{pay, get}`。</summary>
public sealed record CoupleTierDecision(int PlayerSeat, EntityId CellId, int Pay, int Get) : IDecision
{
    public string DecisionType => "CoupleTier";
}

/// <summary>【代谢耦联】两问里的「取消」（Kevin 2026-09-16）：无效果、**卡不弃置**。GD data `{stop: true}`，下标 0。</summary>
public sealed record CancelCoupleDecision(int PlayerSeat, EntityId CellId) : IDecision
{
    public string DecisionType => "CancelCouple";
}

/// <summary>【基质重塑】的追问里选一格：Step 0 = 「再拆这一格」，Step 1/2 = 「转化这一格」。GD 三问的 data 都是 `{to}`，键形只有一种，所以合成一条决策。</summary>
public sealed record RemodelPickDecision(int PlayerSeat, EntityId CellId, HexPosition Target) : IDecision
{
    public string DecisionType => "RemodelPick";
}

/// <summary>【基质重塑】的「只拆这一格」/「到此为止」（GD data `{stop: true}`，下标 0）。**不是取消**：第 1 格已经拆了，卡照常离手 —— 别照抄 <see cref="CancelCoupleDecision"/>。</summary>
public sealed record StopRemodelDecision(int PlayerSeat, EntityId CellId) : IDecision
{
    public string DecisionType => "StopRemodel";
}

/// <summary>
/// 【基因组不稳定】：从本次突变的两次判定中选择一个结果结算。
/// </summary>
public sealed record ChooseMutationDecision(
    int PlayerSeat,
    EntityId CellId,
    int Choice
) : IDecision
{
    public string DecisionType => "ChooseMutation";
}

/// <summary>
/// 细胞种类主动技能（B【抗体】、T【细胞毒素】/【裂解】、癌细胞种类技能等）。
/// </summary>
public sealed record TypeSkillDecision(
    int PlayerSeat,
    EntityId CellId,
    string Skill,
    HexPosition? Target = null,
    EntityId? TargetCell = null
) : IDecision
{
    public string DecisionType => "TypeSkill";
}

/// <summary>
/// 分裂决策
/// </summary>
public record DivideDecision(
    int PlayerSeat,
    EntityId CellId,
    HexPosition TargetPosition
) : IDecision
{
    public string DecisionType => "Divide";
}

/// <summary>
/// 结束回合决策
/// </summary>
public record EndTurnDecision(
    int PlayerSeat
) : IDecision
{
    public string DecisionType => "EndTurn";
}

/// <summary>
/// 跳过决策（不执行任何操作）
/// </summary>
public record PassDecision(
    int PlayerSeat
) : IDecision
{
    public string DecisionType => "Pass";
}
