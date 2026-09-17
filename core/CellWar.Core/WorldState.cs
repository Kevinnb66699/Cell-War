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
    /// 世界事件与卡牌全局修饰的容器（对齐 GD 的 `game.events["active"]`）。
    /// 读它一律走 <see cref="WorldEffects"/> 的 `Stacks` / `Active`，别自己翻这张表。
    /// </summary>
    public IReadOnlyList<ActiveEffect> Effects { get; init; } = [];

    /// <summary>
    /// 规则旋钮（对齐 GD 的 `game.tune`）。**跟着世界走**，不是全局单例 ——
    /// 快照 / 回滚 / 分叉自然带着当时那套旋钮，不会串味。不填就是 PRD 原文。
    /// </summary>
    public RuleTuning Tuning { get; init; } = RuleTuning.Default;
    
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
            Effects = Effects,
            Tuning = Tuning,
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
    public int EndStep { get; init; }   // E 阶段游标：0 = 没开始；1 = 蹲守净化（4.9）做完、等它追出的问答问完再做后半
    public Faction? Winner { get; init; }
    public int CancerAlarmRound { get; init; }
    public int? PendingDiscardSeat { get; init; }  // 手牌超过上限时，强制该席位弃置（PRD §657）
    public EntityId? PendingDiscardCell { get; init; }  // 超限的是哪只细胞：GD `discard_to_limit(cell)` 只问那一只、问到它降到上限为止
    public int? PendingMutationSeat { get; init; }  // 【基因组不稳定】：等待该席位从两次突变判定中选一
    public EntityId? PendingMutationCell { get; init; }
    public int PendingMutationA { get; init; }
    public int PendingMutationB { get; init; }
    public int EffectorRound { get; init; }  // 免疫方本世界回合已发动【效应应答】的世界回合（0=未发动）
    public HexPosition? ChemoAt { get; init; }  // 树突【趋化源】位置
    public int ChemoRounds { get; init; }  // 【趋化源】剩余世界回合
    public int ChemoOwner { get; init; } = -1;  // 建立【趋化源】的**席位**（自身 50% 减免认这个）
    /// <summary>
    /// 建立【趋化源】的那只**细胞**（对齐 GD 的 `chemo["cid"]`）。
    /// 与 `ChemoOwner` 并存不是冗余：减免认席位（PRD 写的是「自身」），
    /// 而**冷却记在细胞上** —— PRD 写的是「技能冷却」，换个树突去立是另一个细胞的技能。
    /// </summary>
    public EntityId? ChemoCreator { get; init; }

    /// <summary>
    /// 【免疫猎杀】附着在某个癌细胞身上的【追踪趋化源】（对齐 GD 的 `chemo_track`）。
    ///
    /// **位置不存在这里** —— 被追的细胞活着时现读它的 `Position`（<see cref="RulePolicies.TrackAt"/>），
    /// 死了才把 <see cref="TrackFrozenAt"/> 冻在死亡格上、把 `TrackCell` 置空
    /// （PRD「癌细胞死亡后趋化源留在死亡格」）。
    /// 否则每一条改位置的路（迁移/转移/紊乱/传送）都得记得同步一次。
    /// </summary>
    public EntityId? TrackCell { get; init; }
    public HexPosition? TrackFrozenAt { get; init; }
    /// <summary>追踪趋化源还剩几个世界回合（E 阶段第 8 步 −1；0 = 场上没有）。</summary>
    public int TrackRounds { get; init; }

    /// <summary>
    /// 【连续吞噬】正在等这只巨噬选下一跳（null = 没在连锁中）。
    /// GD 那边是个 `await` 循环 + `chain_running` 再入闸；C# 的决策模型没有协程，
    /// 每一跳是一个独立决策，所以用挂起态代替 —— 也就不需要那道再入闸。
    /// </summary>
    public EntityId? PendingChainCell { get; init; }
    /// <summary>挂起连锁时的走位栈深。净化抽到【趋化募集】之类会再压一层 —— 那条走位在 GD 里嵌在 draw() 内部、先走完才回到连锁循环，
    /// 所以栈比这个数深的时候连锁先让路（<see cref="CellRules.ChainDeferred"/>）。</summary>
    public int PendingChainWalkDepth { get; init; }

    /// <summary>
    /// 【炎症性趋化】正在等这只细胞选下一步（null = 没在走）。
    /// 不能和 <see cref="PendingChainCell"/> 共用一个字段：巨噬打这张卡、某一步净化又连上
    /// 【连续吞噬】时，两个挂起态**同时存在**，而且连锁要先排干。
    /// </summary>
    public EntityId? PendingChemotaxisCell { get; init; }

    /// <summary>
    /// 【炎症性趋化】还剩几步可走（GD 那个 `for step_no in [2, 3]` 的剩余轮数）。
    /// 静默作废的那一步也照减 —— GD 的 commit 失败不退步数。
    /// </summary>
    public int ChemotaxisStepsLeft { get; init; }
    /// <summary>这段免费连走是哪张卡在走：【炎症性趋化】（付 0.2 一步，最多 3 步）/【趋化募集】（免费，只进健康，2 步）/
    /// 【效应细胞浸润】（免费，健康或普通癌组织，2 步）。候选规则、走法、语义键的 tag 都按它分；null = 没在走。
    /// 后两张是抽到即结算的事件卡（GD `_free_walk`），2026-09-17 之前 C# 把它们做成两条免费移动修饰，没有逐步追问。</summary>
    public string? PendingWalkCard { get; init; }
    /// <summary>嵌套连走时被压在下面的**外层**帧（栈底 → 栈顶−1；栈顶就是上面三个字段）。
    /// GD 的连走是协程栈（cw_card_fx.gd `_free_walk`）：连走的一步踩到存卡的骨髓、抽到【趋化募集】这种抽到即走的卡，
    /// 内层先走完，外层再从新位置把剩下的步问完；「停在这里」只退一层。此前 C# 是单槽，内层把外层整组覆写、外层剩余步数丢掉（2026-09-17 深夜）。</summary>
    public IReadOnlyList<WalkFrame> WalkOuter { get; init; } = Array.Empty<WalkFrame>();
    /// <summary>【骨髓动员】还没收的骨髓（GD `_marrow_mobilization` 的 await 循环：一次抽卡追出问答就停下，答完接着收剩下的）。</summary>
    public IReadOnlyList<HexPosition> PendingMarrow { get; init; } = Array.Empty<HexPosition>();

    /// <summary>
    /// GD 的 `card_resolve_depth`：正在结算一张卡（打出的即时卡 / 抽到的事件卡）时 > 0。
    /// 只挡**净化给的那一份抗原记忆**（Kevin 2026-09-07：卡牌引发的净化不积累记忆；卡本身送记忆的、技能给的照给）。
    /// 结算是同步的，所以在每个决策点上它都是 0 —— 跨决策点的那段由 <see cref="PendingCard"/> 接着挡。
    /// </summary>
    public int CardResolveDepth { get; init; }

    /// <summary>
    /// 结算到一半、等玩家在中途做选择的那张即时卡（今天只有【炎症性趋化】；null = 没有）。
    /// GD 里这段是 `play()` 内的一串 await：卡还在手上、`card_resolve_depth` 还开着；
    /// 中途的挂起摘干净那一刻，`DecisionRouter.Execute` 才给这张卡收尾（离手 + 细胞因子链）。
    /// </summary>
    public string? PendingCard { get; init; }

    public EntityId? PendingCardCell { get; init; }

    /// <summary>
    /// 本世界回合 S 阶段癌方复活问到哪一席了（GD `_ask_each` 的 `flow["i"]`）：席位小于它的这一轮不再问 ——
    /// 放弃了的、已经复活的、轮到时没落点的，都算问过。换回合归零。
    /// 没有它，「放弃」之后 `GetRevivalOptions` 会立刻再问同一个细胞。
    /// </summary>
    public int CancerReviveFrom { get; init; }

    /// <summary>
    /// 【代谢耦联】结算到一半：打出这张卡的细胞、选定的队友、以及方向选定之后的付方（null = 还在问方向）。
    /// GD 里是 `_couple` 内的两次 await；C# 分两个决策点，两问都可「取消」。
    /// </summary>
    public EntityId? PendingCoupleCell { get; init; }

    public EntityId? PendingCoupleAlly { get; init; }

    public EntityId? PendingCouplePayer { get; init; }

    /// <summary>【基质重塑】结算到一半（GD `_remodel` 里的三次 await，cw_card_fx.gd:934-969，零随机）：打出的细胞、已拆的第 1 / 第 2 格、
    /// 当前在问哪一段（0 = 「还可再拆 1 格」，1 / 2 = 「选择要转健康的癌组织」第 1 / 2 格）。
    /// 这四个值**足以从零重算两段候选**（存档恢复后 Runtime 会重跑 Available / Validate）。每段都可「停」，停不是取消：卡照常离手。</summary>
    public EntityId? PendingRemodelCell { get; init; }
    public HexPosition? PendingRemodelFirst { get; init; }
    public HexPosition? PendingRemodelSecond { get; init; }
    public int PendingRemodelStep { get; init; }

    /// <summary>`enter_tile` 的后半截（黏液清除 → collect_special → update_marks）被推迟了：GD 的 `enter_tile` 是一条 await 链，定殖 / 净化里追出来的问答
    /// （净化抽到的连走、撑爆手牌的弃置、【连续吞噬】的连锁、抽到【基因组不稳定】的二选一）**先问完**，才回来收 `dest` 那一格的特殊组织并刷新标记 ——
    /// 连锁把细胞挪走了也仍在 `dest` 收取（cw_actions.gd:1031 显式传 dest）。记「谁、哪一格、推迟时连走栈有多深」，出口等这些问答都摘干净再补做。</summary>
    public EntityId? PendingLandCell { get; init; }
    public HexPosition? PendingLandAt { get; init; }
    public int PendingLandWalkDepth { get; init; }

    public TurnState Clone() => new()
    {
        WorldRound = WorldRound,
        Phase = Phase,
        ActivePlayerSeat = ActivePlayerSeat,
        StartStep = StartStep,
        EndStep = EndStep,
        Winner = Winner,
        CancerAlarmRound = CancerAlarmRound,
        PendingDiscardSeat = PendingDiscardSeat,
        PendingDiscardCell = PendingDiscardCell,
        PendingMutationSeat = PendingMutationSeat,
        PendingMutationCell = PendingMutationCell,
        PendingMutationA = PendingMutationA,
        PendingMutationB = PendingMutationB,
        EffectorRound = EffectorRound,
        ChemoAt = ChemoAt,
        ChemoRounds = ChemoRounds,
        ChemoOwner = ChemoOwner,
        ChemoCreator = ChemoCreator,
        TrackCell = TrackCell,
        TrackFrozenAt = TrackFrozenAt,
        TrackRounds = TrackRounds,
        PendingChainCell = PendingChainCell,
        PendingChainWalkDepth = PendingChainWalkDepth,
        PendingChemotaxisCell = PendingChemotaxisCell,
        ChemotaxisStepsLeft = ChemotaxisStepsLeft,
        PendingWalkCard = PendingWalkCard,
        WalkOuter = WalkOuter,
        PendingMarrow = PendingMarrow,
        CardResolveDepth = CardResolveDepth,
        PendingCard = PendingCard,
        PendingCardCell = PendingCardCell,
        CancerReviveFrom = CancerReviveFrom,
        PendingCoupleCell = PendingCoupleCell,
        PendingCoupleAlly = PendingCoupleAlly,
        PendingCouplePayer = PendingCouplePayer,
        PendingRemodelCell = PendingRemodelCell,
        PendingRemodelFirst = PendingRemodelFirst,
        PendingRemodelSecond = PendingRemodelSecond,
        PendingRemodelStep = PendingRemodelStep,
        PendingLandCell = PendingLandCell,
        PendingLandAt = PendingLandAt,
        PendingLandWalkDepth = PendingLandWalkDepth
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
    // 永久技能装备时盖的戳：技能名 → 装备那一刻的 PlayCounter。
    //
    // 为什么需要它（2026-09-15 补）：PRD:182-184 明写「同一阶段内有多个效果时，
    // 先按**来源层级**，**同层级再按打出/装备的先后顺序**」。
    // 即时卡的先后记在 ActiveModifier.Sequence 里，而永久技能此前是靠
    // `Equipped.Contains("名字")` 现查现用、**没有任何时刻记录** ——
    // 于是两张同阶段的永久技能排不出先后。
    //
    // （PRD:157 那句「与打出的先后无关」说的是**归哪个阶段**，不是同阶段内部怎么排。
    //   我此前在对拍规格里把它读反过一次，已撤销。）
    //
    // 用 ImmutableSortedDictionary 而不是普通 Dictionary：JSON 输出顺序才稳定，
    // 对拍那条「Save().Json 逐字节相同」的自证才有意义。
    private System.Collections.Immutable.ImmutableSortedDictionary<string, int> equipSeq =
        System.Collections.Immutable.ImmutableSortedDictionary<string, int>.Empty.WithComparers(StringComparer.Ordinal);
    public IReadOnlyDictionary<string, int> EquipSeq
    {
        get => equipSeq;
        init => equipSeq = System.Collections.Immutable.ImmutableSortedDictionary
            .CreateRange(StringComparer.Ordinal, value);
    }
    /// <summary>
    /// 巨噬【效应应答·连续吞噬】还能连几次（GD `cell["chain_left"]`）。
    /// 额度是「**本行动回合**」的，`BeginTurn` 清零。
    /// </summary>
    public int ChainLeft { get; init; }

    /// <summary>
    /// 【连续吞噬】连续净化攒下的攻击加成，十分能量（GD `cell["chain_bonus"]`）。
    /// **用掉即清，不按回合过期** —— 「下一次攻击」就是下一次，隔多久都算。
    /// </summary>
    public int ChainBonus { get; init; }

    /// <summary>
    /// 树突【I-趋化源】的技能冷却，还剩几个世界回合（GD `cell["chemo_cd"]`）。
    /// **从效果结束那一刻算起**（PRD「趋化源消失后，技能冷却 1 世界回合才能再次使用」），
    /// E 阶段第 8 步每回合 −1。记在细胞上而不是全局：换个树突去立是另一个细胞的技能。
    /// </summary>
    public int ChemoCooldown { get; init; }

    /// <summary>
    /// 【中和抗体】：该细胞的**种类特殊效果与永久卡牌效果**失效到第几个世界回合末为止（0 = 没被压）。
    ///
    /// 对齐 GD 的 `cell["neutral_until"]`（cw_actions.gd:1613 写、cw_game.gd:580 读）。
    /// 记「到第几回合末为止」而不是倒计时 —— 中途存档读档、快照回滚都不会走样。
    ///
    /// **为什么从 TurnState 上的全局标记改成每胞**：PRD:627 写的是
    /// 「**所有与健康组织相邻的**癌细胞…失效」——是施放那一刻的一批细胞，不是全场。
    /// C# 原来用 `Turn.CancerEffectsDisabledUntil` 一压压全场，连躲在癌组织深处的也压。
    /// </summary>
    public int NeutralUntil { get; init; }

    // 永久技能的「每行动回合前 N 次」闸门（GD 侧 cell["fx_turn"]，begin_turn 清）。
    // 存**用了几次**而不是布尔：多数闸门只问「是不是第一次」，
    // 但【组织驻留】那类「前两次免费」要数得出来。
    //
    // 为什么它必须有自己的家：这四个闸门此前是拿**一条 Value=0 的假 Move 修饰**当标记
    // （「挂着 = 本回合触发过」）。GD 侧它们在 `fx_turn` / `fx_round` 里、**不在 `mods` 里**，
    // 而对拍规格 §2.2 要求 `mods` 逐条导九元组比对 —— 假修饰会在一个**被比对的字段**上
    // 报出一串假差异。这不是洁癖，是 L1 对拍跑不起来。
    private System.Collections.Immutable.ImmutableSortedDictionary<string, int> fxTurn =
        System.Collections.Immutable.ImmutableSortedDictionary<string, int>.Empty.WithComparers(StringComparer.Ordinal);
    public IReadOnlyDictionary<string, int> FxTurn
    {
        get => fxTurn;
        init => fxTurn = System.Collections.Immutable.ImmutableSortedDictionary
            .CreateRange(StringComparer.Ordinal, value);
    }

    /// <summary>
    /// 永久技能的「每世界回合第一次」闸门（GD 侧 cell["fx_round"]，S 阶段清）。
    ///
    /// 语义是**集合**，底层也是 `ImmutableSortedSet`（去重 + 定序）；
    /// 对外露成 `IReadOnlyList` 只为了能被 System.Text.Json 读回来
    /// —— STJ 反序列化不进 `IReadOnlySet<>`（抽象只读集合，它建不出来）。
    /// 写进去重复的名字无妨：init 那一步会去重。
    /// </summary>
    private System.Collections.Immutable.ImmutableSortedSet<string> fxRound =
        System.Collections.Immutable.ImmutableSortedSet<string>.Empty.WithComparer(StringComparer.Ordinal);
    public IReadOnlyList<string> FxRound
    {
        get => fxRound;
        init => fxRound = System.Collections.Immutable.ImmutableSortedSet.CreateRange(StringComparer.Ordinal, value);
    }

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
        EquipSeq = EquipSeq,
        NeutralUntil = NeutralUntil,
        ChemoCooldown = ChemoCooldown,
        ChainLeft = ChainLeft,
        ChainBonus = ChainBonus,
        FxTurn = FxTurn,
        FxRound = FxRound,
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

/// <summary>一段被压在下面的连走：谁在走、还剩几步、走的是哪张卡（与 <see cref="TurnState.PendingChemotaxisCell"/> 三个字段同形）。</summary>
public readonly record struct WalkFrame(EntityId Cell, int StepsLeft, string Card);
