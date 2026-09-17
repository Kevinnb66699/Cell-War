using System.Text.Json;
using System.Text.Json.Serialization;
using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// **规范化状态**：把 `WorldState` 压成一份跨语言可比的形状，字段名一律用
/// **GDScript 那边的词**（`round_no` / `immune_level` / `tissue` / `solid`…）——
/// 两边要比的是同一份东西，名字先统一，比对报告才落得到字段上。
///
/// 对拍规格定死了这一步的地位：
///
///   > **先跑 `w → Canon → FromCanon → w'` 比 `Save().Json` 全量**，
///   > 拿差异字段清单去补 canon。**这一步不过，后面全是假清单。**
///
/// 为什么是「全量比」而不是「比 canon 覆盖的字段」：只覆盖 canon 自己列的字段，
/// 在**缺失的字段上必然空过、给出虚假通过** —— 原型就是这么漏掉 15 个字段的。
///
/// ⚠ 与 `state_hash` 不是一回事。那边**故意排除**七项（phase / win_reason / win_kind /
/// feed_log / feed_seq / board_radius / play_n）—— 那是「什么会改变下一步结算」的口径。
/// canon 要的是**能把世界重新装回来**，所以一个都不能少。
/// </summary>
public sealed record CanonState
{
    public required CanonBoard Board { get; init; }
    public required List<CanonCell> Cells { get; init; }
    public required CanonGlobal G { get; init; }
    public required List<CanonEffect> Events { get; init; }
    public required Dictionary<string, int> Tune { get; init; }
}

public sealed record CanonBoard(int Radius, List<CanonTile> Tiles);

/// <param name="At">`"q,r"`</param>
/// <param name="Tissue">0 健康 / 1 癌 / 2 固化（与 GD 的 `CWData.Tissue` 同序）</param>
/// <param name="Special">0 无 / 1 核心 / 2 骨髓 / 3 血管（GD `CWData.Special`）</param>
/// <param name="Cell">占据它的细胞**席位**；−1 = 空</param>
public sealed record CanonTile(string At, int Tissue, int Special, int Solid, int Cell,
    int Necrosis, bool Mucus, bool Newborn, int OssifyAt, int SolidLock, int ToxinRound, int Store, int Prod);

/// <param name="Pid">席位（= GD 的 `pid`）</param>
/// <param name="IType">免疫种类；癌细胞 −1（GD `ImmuneType`）</param>
/// <param name="CType">癌细胞种类；免疫 −1（GD `CancerType`）</param>
public sealed record CanonCell(int Pid, string Pos, int Faction, int IType, int CType, int Energy, bool Alive,
    int? DeathRound, int AttacksUsed, int DrawsUsed, int ToxinUsed, bool MutateUsed, int AntibodyUsed,
    bool MetastasisUsed, int JumpUsed, bool ArmorUsed, bool Differentiated, bool EffectorUsed,
    bool Marked, int MarkLeft, int MarkRound, int RespawnRound, int CampRound, string CampPos,
    int HandMax, int PlayN, int NeutralUntil, int ChemoCd, int ChainLeft, int ChainBonus)
{
    public List<string> Hand { get; init; } = [];
    public List<string> Equipped { get; init; } = [];
    /// <summary>装备顺序戳：`名字 → 打出序号`。</summary>
    public Dictionary<string, int> EquipSeq { get; init; } = [];
    /// <summary>「每行动回合前 N 次」闸门的计数。</summary>
    public Dictionary<string, int> FxTurn { get; init; } = [];
    /// <summary>「每世界回合第一次」闸门。</summary>
    public List<string> FxRound { get; init; } = [];
    /// <summary>
    /// 运行期修饰，**逐条九元组**。对拍规格明写不能只导 `{卡名: 剩余次数}` ——
    /// 那样移动费用/伤害这类最该对的数全是拿伪造修饰算出来的。
    /// </summary>
    public List<CanonMod> Mods { get; init; } = [];
}

/// <summary>一条运行期修饰的九元组（对拍规格 §2.2 要求逐条导全）。</summary>
public sealed record CanonMod(string Name, int Target, int Stage, int Layer, int Seq,
    int Value, int? Floor, int Uses, int Until, int Requirement);

public sealed record CanonGlobal(int RoundNo, int Phase, int CurrentPid, int Memory, int ImmuneLevel,
    int StartStep, int? Winner, int CancerAlarmRound, int? PendingDiscardPid,
    int? PendingMutationPid, int? PendingMutationCell, int PendingMutationA, int PendingMutationB,
    int CytokineSeat, int EffectorRound,
    string ChemoAt, int ChemoRounds, int ChemoOwner, int? ChemoCreator,
    int? TrackCell, string TrackFrozenAt, int TrackRounds, int? PendingChainCell,
    int? PendingChemotaxisCell, int ChemotaxisStepsLeft,
    int CardResolveDepth, string PendingCard, int? PendingCardCell)
{
    /// <summary>每个席位的阵营与存活（GD 的 `players` + `order`）。</summary>
    public List<CanonPlayer> Players { get; init; } = [];
}

public sealed record CanonPlayer(int Seat, int Faction, bool Alive, int DrawCount, int Memory, int Level, int? CType);

/// <summary>世界事件 / 卡牌全局修饰容器里的一条。</summary>
public sealed record CanonEffect(string Name, int Left, int Stacks, string Doubled, Dictionary<string, int> Data);
