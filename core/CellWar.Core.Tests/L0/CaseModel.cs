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
/// **13 键一张表**（§0.6.2 第 1 条）：属性集合 ≡ `game/scripts/kernel/cw_world_loader.gd:CASE_KEYS`，
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
