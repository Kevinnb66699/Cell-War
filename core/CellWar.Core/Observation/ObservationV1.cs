using System.Text.Json.Serialization;

namespace CellWar.Core.Observation;

/// <summary>
/// 观测协议 v1 的 C# 形状（规格正本 docs/观测协议_v1.md；口径二 · 批 0 步 4）。
///
/// * 属性名经 <c>JsonNamingPolicy.SnakeCaseLower</c> 就是协议键名，所以**改属性名 = 改协议**，先改文档再改这里、再升 <see cref="ObservationV1Codec.Protocol"/>。
/// * 全 int / bool / string / null：零浮点（十分位整数、百分点、千分点）、零 rng（规矩 1、2）。
/// * 解码时未知键 = 硬错（<see cref="ObservationV1Codec.Json"/> 的 <c>UnmappedMemberHandling.Disallow</c>，规矩 3）。
/// * tier B（C# 批 0 不产出，GD 生产者填）一律可空 + <c>WhenWritingNull</c>：缺席合法；tier A 与状态键缺了就是硬错。
/// </summary>
public sealed record ObsPos(int Q, int R);

public sealed record ObsRuleset(int HostAbi, string RulesBuild, string Digest);

public sealed record ObsEnvelope(int P, ObsRuleset Ruleset, long Rev, long ObsSeq, int Viewer, bool OpenHands,
    string[] ProducedTiers, bool Full, ObsEnvelope? Base, ObsState State, ObsAsk? Ask, ObsLogs Logs);

public sealed record ObsState(ObsBoard Board, ObsCell[] Cells, ObsGlobal G);

public sealed record ObsBoard(int Radius, ObsTile[] Tiles);

/// <summary>§二 · 14 键。`store` 与 `cards` 语义分离：骨髓格只填 `cards`、其余只填 `store`。</summary>
public sealed record ObsTile(ObsPos At, int Tissue, int Special, int Solid, int Necrosis, bool Mucus, bool Newborn,
    int OssifyAt, int ToxinRound, int Prod, int Store, int Cards, int Cell, ObsTileD D);

public sealed record ObsTileD(int Pressure, int SolidFraction, int StoreFraction, int ProliferateChance,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? ProdLeft,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? StoreMax,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? SolidFrozen,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? StorePending);   // p=2

public sealed record ObsMod(string Name, int Uses, string Until, int Seq);

/// <summary>§三 · 36 键（make_cell 32 + 动态 4）。数组下标 = `id`，含死者。</summary>
public sealed record ObsCell(int Id, int Pid, int Faction, ObsPos Pos, int Itype, int Ctype, int Energy, bool Alive,
    bool Marked, int MarkLeft, int MarkRound, bool EffectorUsed, string[] Hand, string[] Equipped, ObsMod[] Mods, int PlayN,
    Dictionary<string, int> EquipSeq, Dictionary<string, int> FxTurn, string[] FxRound, bool Differentiated, int ChemoCd,
    bool ArmorUsed, bool MutateUsed, int ToxinUsed, int AntibodyUsed, bool MetastasisUsed, int JumpUsed, int DrawsUsed, int AttacksUsed,
    int RespawnRound, int CampRound, ObsPos? CampPos, int ChainLeft, int ChainBonus, int NeutralUntil, bool ChainRunning, ObsCellD D);

public sealed record ObsStatusRow(string Kind, string Name, string Detail);

public sealed record ObsCellD(int Income, int AntibodyDamage, int OverloadLoss,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string[]? ActionKinds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] ObsStatusRow[]? StatusRows,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? PressureLethal,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Neutralized,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? TypeAbilityOn,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? AntibodyCost,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? MetastasisCostReal,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? OssifyCostReal,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? AttackCapLeft,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? DrawCapLeft,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? HomingCostReal);   // p=2

public sealed record ObsPlayer(int Id, string Name, int Faction, int CellId, int CancerType, ObsPlayerD D);

public sealed record ObsPlayerD(int Income);

public sealed record ObsCancerAlarm(int Streak, int HoldRounds);

public sealed record ObsChemo(ObsPos At, int Left, int By, int Cid);

public sealed record ObsTrack(int Cid, ObsPos At, int Left);

public sealed record ObsEffect(string Name, int Left, int Stacks, Dictionary<string, int> Data);

public sealed record ObsEvents(ObsEffect[] Active);

public sealed record ObsFeed(long Seq, string Kind, int Pid, int Faction, string Card, int Left);

/// <summary>UI 真读的 8 个旋钮；`solidify_threshold` 是按分期的三档原值（GD 的 tune 就是数组），分期后的当前值在 `g.d.solid_threshold`。</summary>
public sealed record ObsTune(int CancerWinWeighted, int CancerWinHoldRounds, int LimitRound, int LimitCancerous,
    int MucusMoveSurcharge, int MetastasisCost, int OsteoOssifyCost, int[] SolidifyThreshold);

public sealed record ObsGlobalD(int SolidThreshold, int TumorStage, int CancerPhase, string PhaseText,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? CountHealthy,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? CountCancer,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? CountSolid,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? CountNecrosis,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? CancerWeighted,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int[]? LevelThresholds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? MemoryNextAt);

/// <summary>§四 · 顶层。</summary>
public sealed record ObsGlobal(int RoundNo, string Phase, int CurrentPid, int AskingPid, int Memory, int ImmuneLevel, int EffectorRound,
    int[] Differentiated, int Winner, string WinReason, string WinKind, ObsCancerAlarm CancerAlarm, ObsChemo? Chemo, ObsTrack? ChemoTrack,
    ObsEvents Events, ObsFeed[] FeedLog, long FeedSeq, int ChainCell, bool Aborted, bool IsOver, int[] Order, ObsPlayer[] Players,
    ObsTune Tune, ObsGlobalD D);

public sealed record ObsCostRow(string Name, int Before, int After, string Note);

/// <summary>§6.2。`data` 保留 GD 今天的形状（键名取自语义键的 13 个字段 + 迁移的 `cost`），值是协议编码（坐标 `{q,r}`、细胞引用是 cell id）。</summary>
public sealed record ObsOption(int Index, string Key, string Label, Dictionary<string, System.Text.Json.JsonElement> Data, int? Cost,
    ObsCostRow[] CostRows, ObsPos? Anchor, bool IsStop, bool IsAttack, string? Blocked);

public sealed record ObsAsk(long AskId, long Rev, string Kind, string? Tag, int Seat, string Prompt, bool Mine, int StopIndex, ObsOption[] Options);

public sealed record ObsLogs(long From, string[] Lines);

/// <summary>`kernel.query("quote_path")` 的返回（§5.3）。`mid` = 借道的第一跳（`RulePolicies.PassThroughMid`，与 GD `pass_through_mid` 同口径）；走得到的相邻格为 null。</summary>
public sealed record ObsPathStep(ObsPos To, int Cost, ObsPos? Mid, bool Legal, bool Afford, string Blocked, int Gain);

public sealed record ObsPathQuote(ObsPathStep[] Steps, int Total, int Gained, bool Ok, int Left, int Stop);

/// <summary>`kernel.version()`：三个字段必须分开（迁移计划 §三 硬不变量③）—— `host_abi` 是握手闸，其余只上报。</summary>
public sealed record ObsVersion(int HostAbi, string RulesBuild, string Digest);
