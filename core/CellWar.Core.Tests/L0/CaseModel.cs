using System.Text.Json.Serialization;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// 一条 L0「契约靶场」用例：**装一个盘面 → 调一个纯查询 → 比一个数**。
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
/// </summary>
public sealed record L0Case
{
    /// <summary>用例标识，形如 `move_cost/immune_to_cancerous/level_I`。失败报告只报它。</summary>
    public required string Id { get; init; }

    /// <summary>探针名（见 <see cref="Probes"/>）。不认识的名字**当场炸**，不许静默跳过。</summary>
    public required string Probe { get; init; }

    /// <summary>这条用例出自 PRD / GD 的哪一句 —— 失败时人要去对的就是这个。</summary>
    public string Source { get; init; } = "";

    public required L0World World { get; init; }

    /// <summary>探针参数。键由各探针自己认，未知键**当场炸**。</summary>
    public Dictionary<string, string> Args { get; init; } = [];

    /// <summary>期望值。单位一律是**十分能量 / 千分率**的整数 —— 与内核内部同一套单位。</summary>
    public required int Expect { get; init; }
}

/// <summary>
/// 盘面装载规格。**刻意只认列出来的键**：多打一个字、少填一个字段都要当场报错，
/// 不许「认识的就读、不认识的就忽略」—— 那样写错的用例会变成静默绿灯。
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
    public required List<L0Tile> Tiles { get; init; }
    public List<L0Cell> Cells { get; init; } = [];

    /// <summary>要拧的旋钮；不填就是 PRD 原文。键名与 <see cref="RuleTuning"/> 的属性同名。</summary>
    public Dictionary<string, int> Tuning { get; init; } = [];
}

/// <param name="Seat">席位号</param>
/// <param name="Faction">immune / cancer</param>
/// <param name="Level">免疫等级 I / II / III / X；癌方填什么都不看</param>
/// <param name="Memory">抗原记忆</param>
public sealed record L0Player(int Seat, string Faction, string Level = "I", int Memory = 0);

/// <param name="At">坐标 `"q,r"`（与对拍规格的运输格式同一套）</param>
/// <param name="State">healthy / cancer / solid</param>
/// <param name="Type">normal / core / marrow / vessel</param>
/// <param name="Solid">固化计数（十分位）</param>
/// <param name="Cell">占据它的细胞**席位**号；−1 = 空。用席位不用 id —— 见对拍规格「cid 用席位不用 id」</param>
public sealed record L0Tile(string At, string State = "healthy", string Type = "normal",
    int Solid = 0, int Cell = -1, bool Mucus = false, int Necrosis = 0, int OssifyAt = 0, int SolidLock = 0);

/// <param name="Seat">席位号；细胞 id = 席位 + 1（对拍规格的约定）</param>
/// <param name="Type">ImmuneBasic / BCell / TCell / Macrophage / Dendritic / Melanoma / SignetRing / Osteosarcoma / SmallCellLung</param>
/// <param name="At">坐标 `"q,r"`</param>
/// <param name="Energy">能量（十分位）</param>
public sealed record L0Cell(int Seat, string Type, string At, int Energy = 300,
    List<string>? Equipped = null, bool Marked = false, bool Differentiated = false);
