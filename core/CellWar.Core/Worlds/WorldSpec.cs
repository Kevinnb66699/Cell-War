using System.Text.Json;
using System.Text.Json.Serialization;

namespace CellWar.Core.Worlds;

// 2026-10-01 换内核 P5：从测试工程 `CellWar.Core.Tests/L0/CaseModel.cs` 上提进产品程序集（新手教程的关卡世界也是 cwxworld/3），
// 改名去掉 L0 前缀；测试工程用 global using 别名照旧叫 L0World / L0Cell …（见 CellWar.Core.Tests/L0/WorldAliases.cs）。

/// <summary>
/// 盘面装载规格 `cwxworld/3`（规格 A-2 / §0.6.1）。**刻意只认列出来的键**：多打一个字、少填一个字段都要当场报错，
/// 不许「认识的就读、不认识的就忽略」—— 那样写错的用例会变成静默绿灯。
///
/// 键表在仓库里只许有两份、且逐键相同：这里与 GD 的 `game/scripts/kernel/cw_world_loader.gd`（<see cref="KeyTableTests"/> 钉住）。
///
/// **顶层 15 键**。不收的五样（写了硬错，§0.6.1 第 1 条）：
/// `win_reason`（文案，由 `win_kind` 现算）、`feed_seq`（演出流水号，不是规则量）、
/// `chain_cell`（派生：`cells[].chain_running`）、`differentiated`（派生：免疫分化种类由 cells 现算）、
/// `cancer_alarm.hold_rounds`（旋钮 `cancer_win_hold_rounds` 的转写，走 `tuning`）。
/// </summary>
public sealed record WorldSpec
{
    public int Radius { get; init; } = 6;
    public int Round { get; init; } = 1;

    /// <summary>阶段名，与 <see cref="Phase"/> 同字（Setup / S / PlayerAction / E / Finished）。</summary>
    public string Phase { get; init; } = "PlayerAction";

    /// <summary>当前行动席位。</summary>
    public int Seat { get; init; }

    public required List<SpecPlayer> Players { get; init; }

    /// <summary>点名的格；没点名的保留底板（全健康 + 特殊组织按坐标表）。</summary>
    public List<SpecTile> Tiles { get; init; } = [];

    public List<SpecCell> Cells { get; init; } = [];

    // ---- 全局六样（§0.6.1 第 1 条把 A-2 的「10 个」改成这六个）----

    /// <summary>"" / immune / cancer。</summary>
    public string Winner { get; init; } = "";

    /// <summary>"" / immune_clear / cancer_weighted / limit_cancer / limit_immune。</summary>
    public string WinKind { get; init; } = "";

    /// <summary>免疫方已发动【效应应答】的世界回合号；**−1 = 从没发动过**（协议口径，C# 内部记 0）。</summary>
    public int EffectorRound { get; init; } = -1;

    /// <summary>树突【I-趋化源】；不写 = 场上没有。</summary>
    public SpecChemo? Chemo { get; init; }

    /// <summary>【免疫猎杀】的追踪趋化源；不写 = 场上没有。</summary>
    public SpecTrack? ChemoTrack { get; init; }

    /// <summary>癌症胜利警报；不写 = 连胜计数 0。</summary>
    public SpecCancerAlarm? CancerAlarm { get; init; }

    /// <summary>全局修饰容器。⚠ 装载时**覆盖**引擎自己填的池子，不是追加（A-2）。</summary>
    public SpecEvents? Events { get; init; }

    /// <summary>要拧的旋钮；不填就是 PRD 原文。键名按**GD 的名字**（snake_case），四档白名单在 `game/data/contract_tune.json`。分档表写下标：`proliferate_per_adjacent[1]`（1 基）。</summary>
    public Dictionary<string, int> Tuning { get; init; } = [];
}

/// <param name="At">坐标 `"q,r"`</param>
/// <param name="Left">还剩几个世界回合</param>
/// <param name="By">建立者**席位**（loader 解析成「该席唯一的活细胞」）</param>
/// <param name="Cid">建立者的**席位**；−1 = 那只细胞已死</param>
public sealed record SpecChemo(string At, int Left, int By = -1, int Cid = -1);

/// <param name="Cid">被追细胞的**席位**；−1 = 已死、冻在 <paramref name="At"/></param>
public sealed record SpecTrack(int Cid, string At, int Left);

/// <summary>癌症胜利警报。**只有 `streak`** —— `hold_rounds` 是旋钮 `cancer_win_hold_rounds` 的转写，走 `tuning`（§0.6.1 第 1 条）。</summary>
/// <param name="Streak">连续达标的世界回合数</param>
public sealed record SpecCancerAlarm(int Streak);

/// <param name="Active">挂着的条目</param>
public sealed record SpecEvents(List<SpecEffect>? Active = null);

/// <summary>`cw_obs_proto.gd:EFFECT` 去掉 `d`。`stacks: n` 装成**一条** `stacks = n`（§0.6.1 第 5 条）。</summary>
public sealed record SpecEffect(string Name, int Left, int Stacks = 1, Dictionary<string, int>? Data = null);

/// <summary>`cw_obs_proto.gd:MOD` 的四元组（E-2）。`data` 不在 envelope 白名单里，不进 spec。</summary>
/// <param name="Until">"" / turn / round</param>
public sealed record SpecMod(string Name, int Uses, string Until, int Seq);

/// <param name="Seat">席位号</param>
/// <param name="Faction">immune / cancer</param>
/// <param name="Level">免疫等级 I / II / III / X；癌方填什么都不看</param>
/// <param name="Memory">抗原记忆</param>
/// <param name="CancerType">癌种，**癌席必填**；免疫席**不许写**；不设 `"none"` 哨兵（§0.6.1 第 2 条）</param>
public sealed record SpecPlayer(int Seat, string Faction, string Level = "I", int Memory = 0, string? CancerType = null);

/// <summary>
/// 一格。键 = `at` + `cw_setup.gd:make_tile` 的 11 键 = **12 键**（§0.6.1 第 3 条）。
/// **不收 `cell`**：两侧口径相反过（C# 拿它当权威、GD 整个忽略），占位一律从 `cells[].at` 反推。
/// `state` / `type` **不改名**成 `tissue` / `special`。
/// </summary>
/// <param name="At">坐标 `"q,r"`（与对拍规格的运输格式同一套）</param>
/// <param name="State">healthy / cancer / solid</param>
/// <param name="Type">normal / core / marrow / vessel；**不写 = 棋盘本来的特殊组织**（`CWData.special_of` / <see cref="MatchSetup"/> 同一张表），所以缺省是 null 不是 `"normal"`</param>
/// <param name="Solid">固化计数（十分位）</param>
/// <param name="Store">代谢核心存的十分能量；**骨髓格写 cards**（两个键在 C# 侧同住 `Tissue.Charge`）</param>
/// <param name="Cards">骨髓存的卡数</param>
/// <param name="Prod">特殊组织产出周期计数器</param>
/// <param name="ToxinRound">上一次在这一格发动【细胞毒素】的世界回合；0 = 从没有过</param>
public sealed record SpecTile(string At, string State = "healthy", string? Type = null,
    int Solid = 0, bool Mucus = false, int Necrosis = 0, int OssifyAt = 0, bool Newborn = false,
    int Store = 0, int Cards = 0, int Prod = 0, int ToxinRound = 0);

/// <summary>
/// 一只细胞。**33 键 = 构造三键 `seat` / `type` / `at` + 30 个可写状态键**（§0.6.1 第 4 条）：
/// `cw_obs_proto.gd:CELL` 去掉 `d` 是 36 键，减去 6 个派生键（`id` / `pid` / `faction` / `pos` / `itype` / `ctype`）。
/// 细胞 id 由**列表序**定（与 GD `make_cell(g.cells.size(), …)` 同口径，闸二 2b 靠这个对得上）。
/// </summary>
public sealed record SpecCell
{
    /// <summary>席位号（协议里的 `pid`）。</summary>
    public required int Seat { get; init; }

    /// <summary>ImmuneBasic / BCell / TCell / Macrophage / Dendritic / Melanoma / SignetRing / Osteosarcoma / SmallCellLung（协议里的 `itype` + `ctype` + `faction`）。</summary>
    public required string Type { get; init; }

    /// <summary>坐标 `"q,r"`（协议里的 `pos`）。</summary>
    public required string At { get; init; }

    /// <summary>能量（十分位）。缺省 300 —— **不要**改成 `CWData.INIT_ENERGY`（§0.6.1 第 4 条）。</summary>
    public int Energy { get; init; } = 300;

    public bool Alive { get; init; } = true;

    // ---- 【标记】三件套：写了 marked 就必须三个都写，loader 一个都不许自己补（A-2 规矩 3 / §0.6.1 第 4 条）。
    //      用可空区分「没写」与「写了 0 / −1」。
    public bool? Marked { get; init; }
    public int? MarkLeft { get; init; }
    public int? MarkRound { get; init; }

    public bool EffectorUsed { get; init; }
    public List<string> Hand { get; init; } = [];
    public List<string> Equipped { get; init; } = [];

    /// <summary>
    /// 修饰条目四元组。装载走 <see cref="WorldLoader"/> 的 `setup_ops` 前奏（E-2）：缺的六项由生产代码现挂，
    /// loader 里没有 `name → ActiveModifier` 工厂（纪律 3）。**路由表认不出的名字 / 没按 `(seq, 名)` 升序写 ⇒ UNLOADABLE。**
    /// </summary>
    public List<SpecMod> Mods { get; init; } = [];

    public int PlayN { get; init; }
    public Dictionary<string, int> EquipSeq { get; init; } = [];
    public Dictionary<string, int> FxTurn { get; init; } = [];
    public List<string> FxRound { get; init; } = [];
    public bool Differentiated { get; init; }
    public int ChemoCd { get; init; }
    public bool ArmorUsed { get; init; }
    public bool MutateUsed { get; init; }
    public int ToxinUsed { get; init; }
    public int AntibodyUsed { get; init; }
    public bool MetastasisUsed { get; init; }
    public int JumpUsed { get; init; }
    public int DrawsUsed { get; init; }
    public int AttacksUsed { get; init; }
    public int RespawnRound { get; init; } = -1;

    /// <summary>已结算过几次【复活】：PRD【S-复活】死亡惩罚 X = 旋钮初始值 + 这个数（issue #63）。不在观测协议里。</summary>
    public int Revives { get; init; }
    public int CampRound { get; init; } = -1;

    /// <summary>蹲的是哪一格 `"q,r"`；没在蹲就不写。</summary>
    public string? CampPos { get; init; }

    public int ChainLeft { get; init; }
    public int ChainBonus { get; init; }

    /// <summary>【中和抗体】压到第几个世界回合末；**−1 = 从没被压过**（协议口径，C# 内部记 0）。</summary>
    public int NeutralUntil { get; init; } = -1;

    /// <summary>正在连续吞噬。C# 侧它住在全局 `Turn.PendingChainCell` 上 —— 世界段的 `chain_cell` 因此是派生量、不进 spec。</summary>
    public bool ChainRunning { get; init; }
}

/// <summary>cwxworld/3 的 JSON 读法：键名 snake_case、**不认识的键当场报错**（与 L0 靶场读用例同一套，GD 侧 `cw_world_loader.gd` 同口径）。</summary>
public static class WorldJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static WorldSpec Parse(string json)
        => JsonSerializer.Deserialize<WorldSpec>(json, Options) ?? throw new InvalidOperationException("世界规格是 null");
}
