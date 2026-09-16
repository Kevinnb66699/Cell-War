namespace CellWar.Core;

/// <summary>
/// 世界状态：包含棋盘、细胞、回合等所有游戏状态
/// 必须可序列化，支持结构共享
/// </summary>
public sealed class WorldState
{
    public required Board Board { get; init; }
    public required PagedMap<EntityId, Cell> Cells { get; init; }
    public required TurnState Turn { get; init; }
    public required PagedMap<int, Player> Players { get; init; }
    
    /// <summary>
    /// 深复制世界状态（用于测试对拍，生产环境使用结构共享）
    /// </summary>
    public WorldState DeepClone()
    {
        return new WorldState
        {
            Board = Board.Clone(),
            Cells = new Dictionary<EntityId, Cell>(Cells.Select(kv => 
                new KeyValuePair<EntityId, Cell>(kv.Key, kv.Value.Clone()))),
            Turn = Turn.Clone(),
            Players = new Dictionary<int, Player>(Players.Select(kv =>
                new KeyValuePair<int, Player>(kv.Key, kv.Value.Clone())))
        };
    }
}

/// <summary>
/// 回合状态
/// </summary>
public sealed class TurnState
{
    public required int WorldRound { get; init; }  // 世界回合数（从1开始）
    public required Phase Phase { get; init; }      // 当前阶段
    public required int ActivePlayerSeat { get; init; }  // 当前行动玩家座位（0-based）
    public int StartStep { get; init; }
    public Faction? Winner { get; init; }
    public int CancerAlarmRound { get; init; }
    public int? PendingDiscardSeat { get; init; }  // 手牌超过上限时，强制该席位弃置（PRD §657）
    public int TgfStacks { get; init; }  // 【TGF-β释放】：下一次有氧结算的 -20% 层数
    public int PausedDecayRound { get; init; }  // 【基质稳定】：该世界回合固化计数不衰减（0=无）
    public int? PendingMutationSeat { get; init; }  // 【基因组不稳定】：等待该席位从两次突变判定中选一
    public EntityId? PendingMutationCell { get; init; }
    public int PendingMutationA { get; init; }
    public int PendingMutationB { get; init; }
    public int CytokineNetworkSeat { get; init; } = -1;  // 【细胞因子网络】：已武装的席位（-1=未武装）
    public int EffectorRound { get; init; }  // 免疫方本世界回合已发动【效应应答】的世界回合（0=未发动）
    public int CancerEffectsDisabledUntil { get; init; }  // 【中和抗体】：癌细胞种类/永久技能效果失效至此世界回合（0=无）
    public HexPosition? ChemoAt { get; init; }  // 树突【趋化源】位置
    public int ChemoRounds { get; init; }  // 【趋化源】剩余世界回合
    public int ChemoOwner { get; init; } = -1;  // 建立【趋化源】的席位

    public TurnState Clone() => new()
    {
        WorldRound = WorldRound,
        Phase = Phase,
        ActivePlayerSeat = ActivePlayerSeat,
        StartStep = StartStep,
        Winner = Winner,
        CancerAlarmRound = CancerAlarmRound,
        PendingDiscardSeat = PendingDiscardSeat,
        TgfStacks = TgfStacks,
        PausedDecayRound = PausedDecayRound,
        PendingMutationSeat = PendingMutationSeat,
        PendingMutationCell = PendingMutationCell,
        PendingMutationA = PendingMutationA,
        PendingMutationB = PendingMutationB,
        CytokineNetworkSeat = CytokineNetworkSeat,
        EffectorRound = EffectorRound,
        CancerEffectsDisabledUntil = CancerEffectsDisabledUntil,
        ChemoAt = ChemoAt,
        ChemoRounds = ChemoRounds,
        ChemoOwner = ChemoOwner
    };
}

/// <summary>
/// 游戏阶段
/// </summary>
public enum Phase
{
    Setup,          // 开局选址：玩家按行动顺序依次放置初始细胞
    S,              // S阶段：资源生产、血管传送、复活、呼吸
    PlayerAction,   // 玩家行动阶段
    E,              // E阶段：压迫、增生、侵蚀、无氧呼吸
    Finished
}

/// <summary>
/// 玩家状态
/// </summary>
public sealed class Player
{
    public required int Seat { get; init; }         // 座位号（0-based）
    public required Faction Faction { get; init; }  // 阵营
    public required bool IsAlive { get; init; }     // 是否存活
    public required int DrawCount { get; init; }    // 可抽卡次数
    public required int AntigenMemory { get; init; } // 抗原记忆（仅免疫方）
    public required ImmuneLevel ImmuneLevel { get; init; } // 免疫等级（仅免疫方）
    public CellType? CancerType { get; init; }      // 癌症方身份（免疫方为 null）
    
    public Player Clone() => new Player
    {
        Seat = Seat,
        Faction = Faction,
        IsAlive = IsAlive,
        DrawCount = DrawCount,
        AntigenMemory = AntigenMemory,
        ImmuneLevel = ImmuneLevel,
        CancerType = CancerType
    };
}

/// <summary>
/// 阵营
/// </summary>
public enum Faction
{
    Immune,  // 免疫细胞
    Cancer   // 癌细胞
}

/// <summary>
/// 免疫等级（PRD §345-365）：I / II / III / X。
/// </summary>
public enum ImmuneLevel
{
    I = 1,
    II = 2,
    III = 3,
    X = 4
}

/// <summary>
/// 棋盘：六边形网格
/// </summary>
public sealed class Board
{
    public required int Radius { get; init; }  // 棋盘半径（环数）
    public required PagedMap<HexPosition, Tissue> Tissues { get; init; }
    
    public Board Clone() => new Board
    {
        Radius = Radius,
        Tissues = new Dictionary<HexPosition, Tissue>(Tissues.Select(kv =>
            new KeyValuePair<HexPosition, Tissue>(kv.Key, kv.Value.Clone())))
    };
}

/// <summary>
/// 组织格
/// </summary>
public sealed class Tissue
{
    public required HexPosition Position { get; init; }
    public required TissueType Type { get; init; }
    public required TissueState State { get; init; }  // 健康/癌组织
    public required int SolidificationCount { get; init; }  // 固化计数（十分位，仅癌组织）
    public required EntityId? OccupyingCell { get; init; }  // 占据的细胞ID

    // 特殊组织属性
    public required int? Charge { get; init; }  // 充能（代谢核心能量/骨髓卡数，十分位）
    public int ProductionCounter { get; init; }  // 产出周期计数器（旧实现 prod：每世界回合 +1，达周期清零）
    public int NecrosisRounds { get; init; }  // 「坏死」还剩几个世界回合（>0 时不为免疫【有氧呼吸】供能）
    public bool Mucus { get; init; }  // 「黏液侵染」：免疫细胞进入即消失，迁入耗能 +0.2
    public bool Newborn { get; init; }  // 本世界回合新转化的癌组织
    public int OssifyAtRound { get; init; }  // 骨肉瘤【骨样硬化】标记：到第几世界回合的 E 阶段转固化（0=无）
    public int SolidLockRound { get; init; }  // 【TNF-α局部炎症】：该世界回合内不得增加固化计数（0=无）
    public int ToxinRound { get; init; }  // 上一次在该格发动【细胞毒素】的世界回合（0=从未）

    public Tissue Clone() => new()
    {
        Position = Position,
        Type = Type,
        State = State,
        SolidificationCount = SolidificationCount,
        OccupyingCell = OccupyingCell,
        Charge = Charge,
        ProductionCounter = ProductionCounter,
        NecrosisRounds = NecrosisRounds,
        Mucus = Mucus,
        Newborn = Newborn,
        OssifyAtRound = OssifyAtRound,
        SolidLockRound = SolidLockRound,
        ToxinRound = ToxinRound
    };
}

/// <summary>
/// 组织类型
/// </summary>
public enum TissueType
{
    Normal,           // 普通组织
    MetabolicCore,    // 代谢核心
    BoneMarrow,       // 骨髓
    BloodVessel       // 血管
}

/// <summary>
/// 组织状态
/// </summary>
public enum TissueState
{
    Healthy,  // 健康组织
    Cancer,   // 癌组织
    SolidifiedCancer
}

/// <summary>
/// 细胞种类：免疫方分化前为基础免疫细胞，分化后四种；癌方按四种真实癌症。
/// 当前切片不实现分化/种类技能，但种类是玩家身份与表现（贴图/UI）的必要数据。
/// </summary>
public enum CellType
{
    ImmuneBasic,     // 免疫细胞
    BCell,           // B细胞
    TCell,           // T细胞
    Macrophage,      // 巨噬细胞
    Dendritic,       // 树突状细胞
    Melanoma,        // 恶性黑色素瘤
    SignetRing,      // 印戒细胞癌
    Osteosarcoma,    // 骨肉瘤
    SmallCellLung    // 小细胞肺癌
}

/// <summary>
/// 细胞
/// </summary>
public sealed class Cell
{
    public required EntityId Id { get; init; }
    public required int OwnerSeat { get; init; }  // 所属玩家座位
    public required Faction Faction { get; init; }
    public required CellType Type { get; init; }
    public required HexPosition Position { get; init; }
    public required int Energy { get; init; }  // 能量（整数十分能量，如 3.0 = 30）
    public required bool IsAlive { get; init; }
    
    // 状态效果（暂时简化）
    private IReadOnlyList<StatusEffect> statusEffects = Array.Empty<StatusEffect>();
    public required IReadOnlyList<StatusEffect> StatusEffects
    {
        get => statusEffects;
        init => statusEffects = System.Collections.Immutable.ImmutableArray.CreateRange(value);
    }
    public int? DeathRound { get; init; }
    public int AttacksThisTurn { get; init; }
    public int CampRound { get; init; } = -1;  // 免疫细胞踏进【骨样硬化】标记格的世界回合（-1=未蹲）
    public HexPosition? CampPosition { get; init; }  // 蹲的是哪一格（挪窝即作废）

    // 行动/世界回合额度（旧实现 make_cell 的对应字段）
    public int DrawsThisTurn { get; init; }  // 【基因表达】每行动回合最多 3 次
    public int ToxinThisRound { get; init; }  // T【细胞毒素】每世界回合最多 3 次
    public int AntibodyThisRound { get; init; }  // B【抗体】每世界回合使用次数（抗体伤害逐次减半）
    public bool MetastasisUsedThisRound { get; init; }  // 黑色素瘤【早期血行转移】每世界回合 1 次
    public int JumpUsedThisRound { get; init; }  // 小细胞肺癌【转移】本世界回合次数
    public bool MutateUsedThisRound { get; init; }  // 【突变】每世界回合 1 次
    public bool ArmorUsedThisRound { get; init; }  // 印戒【囊性护甲】每世界回合减免 1 次
    public bool Differentiated { get; init; }  // 每细胞每局仅能【分化】一次
    public bool EffectorUsed { get; init; }  // 【效应应答】每细胞每局 1 次（死亡复活后保留）
    public bool Marked { get; init; }  // 树突【标记】
    public int MarkLeft { get; init; }  // 【标记】还能翻倍几次
    public int MarkRound { get; init; } = -1;  // 上一次获得【标记】的世界回合（同回合只能得一次）
    public int RespawnRound { get; init; } = -1;  // 免疫细胞可复活的世界回合（-1=未死亡/不复活）
    public int HandMax { get; init; } = 8;  // 手牌上限（旧实现 HAND_MAX）
    private System.Collections.Immutable.ImmutableArray<string> hand = System.Collections.Immutable.ImmutableArray<string>.Empty;
    public IReadOnlyList<string> Hand { get => hand; init => hand = System.Collections.Immutable.ImmutableArray.CreateRange(value); }
    private System.Collections.Immutable.ImmutableArray<string> equipped = System.Collections.Immutable.ImmutableArray<string>.Empty;
    public IReadOnlyList<string> Equipped { get => equipped; init => equipped = System.Collections.Immutable.ImmutableArray.CreateRange(value); }
    public int PlayCounter { get; init; }  // 每细胞打出/装备卡的单调序号（用于修饰结算先后）
    private System.Collections.Immutable.ImmutableArray<ActiveModifier> modifiers = System.Collections.Immutable.ImmutableArray<ActiveModifier>.Empty;
    public IReadOnlyList<ActiveModifier> Modifiers { get => modifiers; init => modifiers = System.Collections.Immutable.ImmutableArray.CreateRange(value); }

    public Cell Clone() => new()
    {
        Id = Id,
        OwnerSeat = OwnerSeat,
        Faction = Faction,
        Type = Type,
        Position = Position,
        Energy = Energy,
        IsAlive = IsAlive,
        StatusEffects = StatusEffects,
        DeathRound = DeathRound,
        AttacksThisTurn = AttacksThisTurn,
        CampRound = CampRound,
        CampPosition = CampPosition,
        DrawsThisTurn = DrawsThisTurn,
        ToxinThisRound = ToxinThisRound,
        AntibodyThisRound = AntibodyThisRound,
        MetastasisUsedThisRound = MetastasisUsedThisRound,
        JumpUsedThisRound = JumpUsedThisRound,
        MutateUsedThisRound = MutateUsedThisRound,
        ArmorUsedThisRound = ArmorUsedThisRound,
        Differentiated = Differentiated,
        EffectorUsed = EffectorUsed,
        Marked = Marked,
        MarkLeft = MarkLeft,
        MarkRound = MarkRound,
        RespawnRound = RespawnRound,
        HandMax = HandMax,
        Hand = Hand,
        Equipped = Equipped,
        PlayCounter = PlayCounter,
        Modifiers = Modifiers
    };
}

/// <summary>
/// 状态效果（暂时简化）
/// </summary>
public sealed class StatusEffect
{
    public required string EffectType { get; init; }
    public required int Duration { get; init; }  // 持续回合数
    private IReadOnlyDictionary<string, object> parameters = System.Collections.Immutable.ImmutableDictionary<string, object>.Empty;
    public required IReadOnlyDictionary<string, object> Parameters
    {
        get => parameters;
        init
        {
            foreach (var item in value.Values)
                if (item is not (string or bool or int or long or double or decimal))
                    throw new ArgumentException("Status parameters must be immutable scalar values.");
            parameters = System.Collections.Immutable.ImmutableDictionary.ToImmutableDictionary(value);
        }
    }
    
    public StatusEffect Clone() => new StatusEffect
    {
        EffectType = EffectType,
        Duration = Duration,
        Parameters = new Dictionary<string, object>(Parameters)
    };
}
