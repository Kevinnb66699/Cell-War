using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// 把一个决策压成**语义键** —— 两边各在自己的选项表里按这个字符串查回下标。
///
/// 为什么不用下标运输：C# 的 `DecisionRouter.Available` 走 `PagedMap` 的迭代序，
/// GD 的选项表是另一套顺序。拿下标对，第一步就错位。
///
/// 文法（对拍规格定的，两侧同一套，纯字符串比较）：
/// <code>
///   k=&lt;kind&gt;[|g=&lt;tag&gt;]|&lt;field&gt;=&lt;v&gt;|...
///   field 固定顺序，取自 GD data 的 13 个键：
///     act, card, type, to, cid, dir, r, pay, get, from, to_cid, stop, skip
///   Vector2i → "q,r"；bool → 1/0
/// </code>
/// 真实样例：`k=action|act=move|to=-2,0`、`k=action|act=play|card=癌症转移|to=-3,3`。
///
/// **三条硬规矩**（规格原文）：
/// 1. **剔除 `cost` 与 `anchor`** —— 那是引擎算出来的报价与依托，不是玩家意图。
///    留在键里，「C# 算费不同」会伪装成「动作不同」，而算费差异本该由 L0 的探针单独报一条。
/// 2. **`cid` 用席位不用 id** —— GD 的 `cells` 下标从 0 起，C# 的 `EntityId` 0 是 Invalid、从 1 起。
/// 3. **合并键**：GD 两问 ↔ C# 一决策的三处走组键（`k=action+chemo_target|…`）。
///
/// 为什么要传 `WorldState`：三处键**只看决策本身写不出来** ——
/// 复活要分阵营（`immune_revive` / `revive`）、Excalibur 要算方向下标、
/// 【基因组不稳定】的 `r` 是骰面值而 C# 存的是下标。
/// </summary>
public static class SemanticKey
{
    /// <summary>字段的**固定顺序**。两边都照这个顺序拼，字符串才比得起来。</summary>
    private static readonly string[] FieldOrder =
        ["act", "card", "type", "to", "cid", "dir", "r", "pay", "get", "from", "to_cid", "stop", "skip"];

    /// <summary>
    /// GD `CWData.DIRS` 的**顺序**（`cw_data.gd:870`）。Excalibur 的 `dir` 是这张表的下标，
    /// 而 C# `HexPosition.GetNeighbors()` 是另一套次序 —— 照自己的枚举序写下标，六个方向全错位。
    /// </summary>
    private static readonly (int Q, int R)[] GdDirs =
        [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];

    /// <summary>
    /// 这些决策类型**故意不映射**：`IRulesEngine.cs` 里有定义但没有 Validate / Execute / Available，
    /// 是死代码。列出来是为了让完备性护栏区分「还没搬」与「本来就不该有」。
    /// </summary>
    public static readonly IReadOnlySet<string> DeadCode =
        new HashSet<string>(StringComparer.Ordinal) { "Attack", "Divide" };

    /// <summary>
    /// GD 那边没有的选项。`PassDecision` 是 C# 每个行动问答固定多出来的一条，
    /// 比集合差的时候要先减掉它，不然每一步都报一条 `OPTION_EXTRA`。
    /// </summary>
    public const string PassKey = "k=action|act=pass";

    public static string Of(WorldState s, IDecision d) => d switch
    {
        PlaceDecision p => Key("setup_place", ("to", Pos(p.TargetPosition))),

        // 复活是**两问**：免疫回骨髓（`immune_revive`），癌方靠固化癌组织（`revive`）。
        // 癌方那问 GD 的 data 带 `anchor`，按规矩 1 剔除 —— 所以同一格的多个依托会压成同一个键。
        ReviveDecision r => Key(s.Cells[r.CellId].Faction == Faction.Immune ? "immune_revive" : "revive",
            ("to", Pos(r.TargetPosition))),

        EndTurnDecision => Key("action", ("act", "end")),
        PassDecision => Key("action", ("act", "pass")),
        MoveDecision m => Key("action", ("act", "move"), ("to", Pos(m.TargetPosition))),
        DrawDecision => Key("action", ("act", "draw")),
        MutateDecision => Key("action", ("act", "mutate")),
        DifferentiateDecision df => Key("action", ("act", "differentiate"), ("type", ((int)df.Type).ToString())),

        // 卡牌的细胞目标在 GD 里是 `cid`（`cw_card_fx.gd:150` 起）；`to_cid` 只属于
        // 【代谢耦联】的「转出/转入」二问，C# 没有那一问，别顺手挪用。
        PlayCardDecision pc => Key("action", ("act", "play"), ("card", pc.Card),
            ("to", Pos(pc.Target)), ("cid", Seat(pc.TargetCell))),

        // C# 的弃置只有**强制**那一路（`Turn.PendingDiscardSeat` 挂起时才给选项），
        // 对应 GD 的 `discard_to_limit`；行动栏里那条自愿弃置 C# 还没有，见 KnownGaps。
        DiscardDecision dc => Tagged("pick", "手牌上限", ("card", dc.Card)),

        // 【基因组不稳定】：GD 的 data 是**骰面值** `r`，C# 存的是「选第几个」。
        ChooseMutationDecision cm => Tagged("pick", "基因组不稳定",
            ("r", (cm.Choice == 0 ? s.Turn.PendingMutationA : s.Turn.PendingMutationB).ToString())),

        // 【连续吞噬】的连锁：GD 是一步一问的走位（`kind: "free_move"`, `"连续吞噬"`）
        ChainMoveDecision ch => Tagged("free_move", "连续吞噬", ("to", Pos(ch.Target))),
        StopChainDecision => Tagged("free_move", "连续吞噬", ("stop", "1")),

        TypeSkillDecision ts => TypeSkill(s, ts),

        _ => throw new InvalidOperationException(
            $"决策 {d.DecisionType}（{d.GetType().Name}）还没有语义键 —— 加一条，别让它静默缺席"),
    };

    /// <summary>
    /// 种类技能按 Skill 串分派。
    ///
    /// 【效应应答】四种分化共用 GD 的一个入口 `act=effector`（`CWData.EFFECTOR_NAMES`）：
    /// B【中和抗体】与巨噬【连续吞噬】问完就结，树突【免疫猎杀】与 T【Excalibur】
    /// 还要再问一次目标 —— 后两个走**组键**，比对边界落在组的末尾。
    /// </summary>
    private static string TypeSkill(WorldState s, TypeSkillDecision t) => t.Skill switch
    {
        "抗体" => Key("action", ("act", "antibody")),
        "细胞毒素" => Key("action", ("act", "toxin")),
        "骨样硬化" => Key("action", ("act", "ossify")),
        "黏液破裂" => Key("action", ("act", "mucus")),
        "中和抗体" => Key("action", ("act", "effector")),
        "连续吞噬" => Key("action", ("act", "effector")),
        "裂解" => Key("action", ("act", "lyse"), ("to", Pos(t.Target))),
        "转移" => Key("action", ("act", "jump"), ("to", Pos(t.Target))),
        "早期血行转移" => Key("action", ("act", "homing"), ("to", Pos(t.Target))),
        // ---- 组键：GD 两问 ↔ C# 一决策 ----
        "趋化源" => Key("action+chemo_target", ("act", "chemo"), ("to", Pos(t.Target))),
        "免疫猎杀" => Key("action+effector_target", ("act", "effector"), ("cid", Seat(t.TargetCell))),
        "Excalibur" => Key("action+effector_target", ("act", "effector"),
            ("to", Pos(t.Target)), ("dir", Dir(s.Cells[t.CellId].Position, t.Target))),
        _ => throw new InvalidOperationException($"种类技能【{t.Skill}】还没有语义键"),
    };

    /// <summary>按固定顺序拼；值为 null 的字段**不出现**（GD 那边也不会有那个键）。</summary>
    private static string Key(string kind, params (string Field, string? Value)[] fields) => Tagged(kind, null, fields);

    private static string Tagged(string kind, string? tag, params (string Field, string? Value)[] fields)
    {
        var bag = fields.Where(f => f.Value != null).ToDictionary(f => f.Field, f => f.Value!, StringComparer.Ordinal);
        var unknown = bag.Keys.Where(k => !FieldOrder.Contains(k)).ToArray();
        if (unknown.Length > 0)
            throw new InvalidOperationException($"语义键里出现了文法外的字段：{string.Join(" / ", unknown)}");

        var parts = new List<string> { $"k={kind}" };
        if (tag != null) parts.Add($"g={tag}");
        parts.AddRange(FieldOrder.Where(bag.ContainsKey).Select(f => $"{f}={bag[f]}"));
        return string.Join("|", parts);
    }

    private static string? Pos(HexPosition? p) => p is { } v ? $"{v.Q},{v.R}" : null;

    /// <summary>细胞 id → **席位**（规矩 2：C# 的 `EntityId = seat + 1`）。</summary>
    private static string? Seat(EntityId? id) => id is { } v ? ((int)v.Value - 1).ToString() : null;

    /// <summary>落点 → GD `DIRS` 的下标。不是六邻之一就没有方向可言。</summary>
    private static string? Dir(HexPosition from, HexPosition? to)
    {
        if (to is not { } t) return null;
        var delta = (t.Q - from.Q, t.R - from.R);
        var i = Array.IndexOf(GdDirs, delta);
        return i < 0 ? null : i.ToString();
    }
}
