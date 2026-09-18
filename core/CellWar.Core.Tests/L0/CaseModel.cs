using System.Text.Json.Serialization;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// 一条 L0「契约靶场」用例（schema `cwxcase/2`，规格 A-1 / §0.6.2）：
/// **装一个盘面 → 调一个纯查询或一个契约步 → 比一个数 / 一棵树 / 一组差分**。
///
/// 这份 JSON 是**两边共用一份**（放在 `game/tests/l0/` 下，GD 走 `res://tests/l0/`，
/// C# 从测试程序集往上找）—— 这是迁移计划里那条闸的全部意义：
/// **同一份数据，GD runner 与 C# runner 都要绿**。
/// GD 绿 = 用例忠实于原断言；C# 绿 = 真的等价。
/// **只做 C# 那一半就是把靶画在自己身上。**
///
/// 为什么不逐条手翻成 xUnit：1013 条 × 原测试密度 ≈ 7000~14000 行新 C# 测试码，
/// 40~70 人天，而且其中 38% 在容器齐备之前根本写不出来。数据化之后，
/// 「再搬一条」= 往 JSON 里加一行。
///
/// **13 键一张表**（§0.6.2 第 1 条）：属性集合 ≡ `game/tests/cw_case_loader.gd:CASE_KEYS`，
/// 由 <see cref="KeyTableTests"/> 逐字钉住。
/// </summary>
public sealed record L0Case
{
    /// <summary>schema 版本。**必填且恒 `cwxcase/2`**（缺或不等 = 硬错，§0.6.2 第 1 条）。</summary>
    public required string Schema { get; init; }

    /// <summary>用例标识，形如 `move_cost/immune_to_cancerous/level_I`。失败报告只报它。</summary>
    public required string Id { get; init; }

    /// <summary>
    /// P 族探针名（见 <see cref="Probes"/>）。不认识的名字**当场炸**，不许静默跳过。
    /// 与 <see cref="Op"/> **二选一**：探针是纯查询（scalar / tree），契约步是会改状态的一步（delta）。
    /// </summary>
    public string? Probe { get; init; }

    /// <summary>S 族契约步名。必须在 `game/tests/contract_ops.json` 里 —— 表外的名字两个 runner 都不分派（规格 A-3 / §0.6.4）。</summary>
    public string? Op { get; init; }

    /// <summary>回指 `game/tests/headless_test.gd` 里的 `check()` 名，形如 `t_pressure::压迫：二期每相邻癌组织`。闸三的分子按它数（A-8）。</summary>
    public List<string> Covers { get; init; } = [];

    /// <summary>OK | NOTIMPL | KNOWN_GAP | UNDEFINED | OUT_OF_SCOPE（规格 §0.2，**没有「未分类」这一档**）。</summary>
    public string Status { get; init; } = "OK";

    /// <summary>PRD 出处三元组（可选）。</summary>
    public L0Prd? Prd { get; init; }

    /// <summary>这条用例出自 PRD / GD 的哪一句 —— 失败时人要去对的就是这个。</summary>
    public string Source { get; init; } = "";

    /// <summary>录制来的才有：`headless_test.gd:t_pressure`（规格 A-4 收割器填）。</summary>
    public string HarvestedFrom { get; init; } = "";

    public required L0World World { get; init; }

    /// <summary>
    /// rng 带子，每条一段（与 `L1/TapeRng.cs` 同一套）。
    /// **`[]` = 断言「这一步不消耗 rng」**（规格 A-7 / §0.6.2 第 1 条）。
    /// </summary>
    public List<List<long>> Rolls { get; init; } = [];

    /// <summary>探针 / 契约步的参数。键由各自认，未知键**当场炸**。</summary>
    public Dictionary<string, string> Args { get; init; } = [];

    /// <summary>期望值：`scalar`（裸整数，单位是十分能量 / 千分率）/ `tree` / `delta` 三类联合体，见 <see cref="L0Expect"/>。</summary>
    public required L0Expect Expect { get; init; }

    /// <summary>这条用例走探针还是走契约步 —— 两个都写或都不写都是硬错（§0.6.2 第 1 条）。</summary>
    [JsonIgnore]
    public string Entry => (Probe, Op) switch
    {
        (null or "", null or "") => throw new InvalidOperationException($"{Id}：probe 与 op 一个都没写"),
        (not (null or ""), not (null or "")) => throw new InvalidOperationException($"{Id}：probe 与 op 只能写一个（P 族纯查询 / S 族契约步）"),
        (not (null or ""), _) => Probe!,
        _ => Op!,
    };

    /// <summary>P 族 = 写了 <see cref="Probe"/>；S 族 = 写了 <see cref="Op"/>。</summary>
    [JsonIgnore]
    public bool IsProbe => Probe is not (null or "");
}

/// <param name="Sha">PRD 文件的 sha</param>
/// <param name="Line">行号（会漂，只当线索）</param>
/// <param name="Text">那一句的原文</param>
public sealed record L0Prd(string Sha, int Line, string Text);

/// <summary>
/// 盘面装载规格 `cwxworld/2`（规格 A-2 / §0.6.1）。**刻意只认列出来的键**：多打一个字、少填一个字段都要当场报错，
/// 不许「认识的就读、不认识的就忽略」—— 那样写错的用例会变成静默绿灯。
///
/// 键表在仓库里只许有两份、且逐键相同：这里与 GD 的 `game/tests/cw_case_loader.gd`（<see cref="KeyTableTests"/> 钉住）。
///
/// **顶层 15 键**。不收的五样（写了硬错，§0.6.1 第 1 条）：
/// `win_reason`（文案，由 `win_kind` 现算）、`feed_seq`（演出流水号，不是规则量）、
/// `chain_cell`（派生：`cells[].chain_running`）、`differentiated`（派生：免疫分化种类由 cells 现算）、
/// `cancer_alarm.hold_rounds`（旋钮 `cancer_win_hold_rounds` 的转写，走 `tuning`）。
/// </summary>
public sealed record L0World
{
    public int Radius { get; init; } = 6;
    public int Round { get; init; } = 1;

    /// <summary>阶段名，与 <see cref="Phase"/> 同字（Setup / S / PlayerAction / E / Finished）。</summary>
    public string Phase { get; init; } = "PlayerAction";

    /// <summary>当前行动席位。</summary>
    public int Seat { get; init; }

    public required List<L0Player> Players { get; init; }

    /// <summary>点名的格；没点名的保留底板（全健康 + 特殊组织按坐标表）。</summary>
    public List<L0Tile> Tiles { get; init; } = [];

    public List<L0Cell> Cells { get; init; } = [];

    // ---- 全局六样（§0.6.1 第 1 条把 A-2 的「10 个」改成这六个）----

    /// <summary>"" / immune / cancer。</summary>
    public string Winner { get; init; } = "";

    /// <summary>"" / immune_clear / cancer_weighted / limit_cancer / limit_immune。</summary>
    public string WinKind { get; init; } = "";

    /// <summary>免疫方已发动【效应应答】的世界回合号；**−1 = 从没发动过**（协议口径，C# 内部记 0）。</summary>
    public int EffectorRound { get; init; } = -1;

    /// <summary>树突【I-趋化源】；不写 = 场上没有。</summary>
    public L0Chemo? Chemo { get; init; }

    /// <summary>【免疫猎杀】的追踪趋化源；不写 = 场上没有。</summary>
    public L0Track? ChemoTrack { get; init; }

    /// <summary>癌症胜利警报；不写 = 连胜计数 0。</summary>
    public L0CancerAlarm? CancerAlarm { get; init; }

    /// <summary>世界事件 / 全局修饰容器。⚠ 装载时**覆盖**引擎自己填的池子，不是追加（A-2）。</summary>
    public L0Events? Events { get; init; }

    /// <summary>要拧的旋钮；不填就是 PRD 原文。键名按**GD 的名字**（snake_case），四档白名单在 `game/tests/contract_tune.json`。分档表写下标：`proliferate_per_adjacent[1]`（1 基）。</summary>
    public Dictionary<string, int> Tuning { get; init; } = [];
}

/// <param name="At">坐标 `"q,r"`</param>
/// <param name="Left">还剩几个世界回合</param>
/// <param name="By">建立者**席位**（loader 解析成「该席唯一的活细胞」）</param>
/// <param name="Cid">建立者的**席位**；−1 = 那只细胞已死</param>
public sealed record L0Chemo(string At, int Left, int By = -1, int Cid = -1);

/// <param name="Cid">被追细胞的**席位**；−1 = 已死、冻在 <paramref name="At"/></param>
public sealed record L0Track(int Cid, string At, int Left);

/// <summary>癌症胜利警报。**只有 `streak`** —— `hold_rounds` 是旋钮 `cancer_win_hold_rounds` 的转写，走 `tuning`（§0.6.1 第 1 条）。</summary>
/// <param name="Streak">连续达标的世界回合数</param>
public sealed record L0CancerAlarm(int Streak);

/// <param name="Pool">事件池。C# 侧是写死的全表（世界事件整块未迁），写了就必须一字不差，否则 UNLOADABLE</param>
/// <param name="Active">挂着的条目</param>
/// <param name="DoubleNext">下一次事件翻倍。C# 侧没有落点，写 true = UNLOADABLE</param>
public sealed record L0Events(List<string>? Pool = null, List<L0Effect>? Active = null, bool DoubleNext = false);

/// <summary>`cw_obs_proto.gd:EFFECT` 去掉 `d`。`stacks: n` 装成**一条** `stacks = n`（§0.6.1 第 5 条）。</summary>
public sealed record L0Effect(string Name, int Left, int Stacks = 1, string Doubled = "", Dictionary<string, int>? Data = null);

/// <summary>`cw_obs_proto.gd:MOD` 的四元组（E-2）。`data` 不在 envelope 白名单里，不进 spec。</summary>
/// <param name="Until">"" / turn / round</param>
public sealed record L0Mod(string Name, int Uses, string Until, int Seq);

/// <param name="Seat">席位号</param>
/// <param name="Faction">immune / cancer</param>
/// <param name="Level">免疫等级 I / II / III / X；癌方填什么都不看</param>
/// <param name="Memory">抗原记忆</param>
/// <param name="CancerType">癌种，**癌席必填**；免疫席**不许写**；不设 `"none"` 哨兵（§0.6.1 第 2 条）</param>
public sealed record L0Player(int Seat, string Faction, string Level = "I", int Memory = 0, string? CancerType = null);

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
public sealed record L0Tile(string At, string State = "healthy", string? Type = null,
    int Solid = 0, bool Mucus = false, int Necrosis = 0, int OssifyAt = 0, bool Newborn = false,
    int Store = 0, int Cards = 0, int Prod = 0, int ToxinRound = 0);

/// <summary>
/// 一只细胞。**33 键 = 构造三键 `seat` / `type` / `at` + 30 个可写状态键**（§0.6.1 第 4 条）：
/// `cw_obs_proto.gd:CELL` 去掉 `d` 是 36 键，减去 6 个派生键（`id` / `pid` / `faction` / `pos` / `itype` / `ctype`）。
/// 细胞 id 由**列表序**定（与 GD `make_cell(g.cells.size(), …)` 同口径，闸二 2b 靠这个对得上）。
/// </summary>
public sealed record L0Cell
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

    /// <summary>修饰条目四元组。**C# 侧非空 = UNLOADABLE**，直到 `setup_ops` 前奏落地（批 5a 的 C-2 步 2，§0.6.1 第 4 条）。</summary>
    public List<L0Mod> Mods { get; init; } = [];

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
