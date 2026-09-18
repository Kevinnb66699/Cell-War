namespace CellWar.Core;

/// <summary>
/// 把一个决策压成**语义键** —— 两边各在自己的选项表里按这个字符串查回下标。
///
/// 2026-09-18 从测试程序集搬进 CellWar.Core（口径二批 0 步 2）：观测协议 v1 的作答口径「键为准、下标兜底」要在生产代码里查它，
/// 演出通道的方向下标要用 <see cref="GdDirs"/>。文法与 <see cref="FieldOrder"/> 逐字不变；GD 侧那一份在 game/scripts/kernel/cw_semkey.gd（xcheck_bridge.gd 委托它），**不许出现第四份**。
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
    /// <summary>
    /// 字段的**固定顺序**。两边都照这个顺序拼，字符串才比得起来。
    ///
    /// 今天没有哪个键同时带 `cid` 和 `dir`，所以这张表的次序**在现有用例上改了也不红** ——
    /// 正因如此它要被单独钉一条（`字段顺序照 GD 的 13 个 data 键`）：
    /// 它是和 GD 的线上约定，不是某条键的副产物。
    /// </summary>
    public static readonly IReadOnlyList<string> FieldOrder =
        ["act", "card", "type", "to", "cid", "dir", "r", "pay", "get", "from", "to_cid", "stop", "skip"];

    /// <summary>
    /// GD `CWData.DIRS` 的**顺序**（`cw_data.gd:870`）。Excalibur 的 `dir` 是这张表的下标，
    /// 而 C# `HexPosition.GetNeighbors()` 是另一套次序 —— 照自己的枚举序写下标，六个方向全错位。
    /// </summary>
    public static readonly IReadOnlyList<(int Q, int R)> GdDirs =
        [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];

    /// <summary>落点相对起点是 GD `DIRS` 的第几个方向；不是六邻之一就是 -1（GD 侧 dir &lt; 0 不发演出）。</summary>
    public static int DirIndex(HexPosition from, HexPosition to)
    {
        var delta = (to.Q - from.Q, to.R - from.R);
        for (var i = 0; i < GdDirs.Count; i++) if (GdDirs[i] == delta) return i;
        return -1;
    }

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

    /// <summary>一条决策拆成「kind / tag / 有序字段」。键字符串与观测协议的 <c>options[].data</c> 都从这里出（`docs/观测协议_v1.md` §六），别各写一份。</summary>
    public sealed record Parts(string Kind, string? Tag, IReadOnlyList<(string Field, object Value)> Fields)
    {
        public string Key
        {
            get
            {
                var parts = new List<string> { $"k={Kind}" };
                if (Tag != null) parts.Add($"g={Tag}");
                parts.AddRange(Fields.Select(f => $"{f.Field}={Text(f.Value)}"));
                return string.Join("|", parts);
            }
        }
        /// <summary>键文法的值写法：坐标 `q,r`、bool `1/0`、细胞引用用**席位**（规矩 2）。</summary>
        private static string Text(object v) => v switch
        {
            HexPosition p => $"{p.Q},{p.R}",
            EntityId id => ((int)id.Value - 1).ToString(),
            bool b => b ? "1" : "0",
            _ => v.ToString()!,
        };
    }

    public static string Of(WorldState s, IDecision d) => Describe(s, d).Key;

    public static Parts Describe(WorldState s, IDecision d) => d switch
    {
        PlaceDecision p => Key("setup_place", ("to", Pos(p.TargetPosition))),

        // 复活是**两问**：免疫回骨髓（`immune_revive`），癌方靠固化癌组织（`revive`）。
        // 癌方那问 GD 的 data 带 `anchor`，按规矩 1 剔除 —— 所以同一格的多个依托会压成同一个键。
        ReviveDecision r => Key(s.Cells[r.CellId].Faction == Faction.Immune ? "immune_revive" : "revive",
            ("to", Pos(r.TargetPosition))),
        SkipReviveDecision => Key("revive", ("skip", true)),   // GD 下标 0 的「放弃本回合复活」

        EndTurnDecision => Key("action", ("act", "end")),
        PassDecision => Key("action", ("act", "pass")),
        MoveDecision m => Key("action", ("act", "move"), ("to", Pos(m.TargetPosition))),
        DrawDecision => Key("action", ("act", "draw")),
        MutateDecision => Key("action", ("act", "mutate")),
        DifferentiateDecision df => Key("action", ("act", "differentiate"), ("type", (int)df.Type)),

        // 卡牌的细胞目标在 GD 里是 `cid`（`cw_card_fx.gd:150` 起）；`to_cid` 只属于
        // 【代谢耦联】的「转出/转入」那一问（见下面 CoupleDirectionDecision），别顺手挪用。
        PlayCardDecision pc => Key("action", ("act", "play"), ("card", pc.Card),
            ("to", Pos(pc.Target)), ("cid", Seat(pc.TargetCell))),

        // 弃置有**两路**，键也是两个：手牌超限挂起时是 GD 的 `discard_to_limit`（`k=pick`），
        // 没挂起就是行动栏里那条自愿弃置（`k=action|act=discard`）。
        DiscardDecision dc => s.Turn.PendingDiscardSeat is null
            ? Key("action", ("act", "discard"), ("card", dc.Card))
            : Tagged("pick", "手牌上限", ("card", dc.Card)),

        // 【基因组不稳定】：GD 的 data 是**骰面值** `r`，C# 存的是「选第几个」。
        ChooseMutationDecision cm => Tagged("pick", "基因组不稳定",
            ("r", cm.Choice == 0 ? s.Turn.PendingMutationA : s.Turn.PendingMutationB)),

        // 【连续吞噬】的连锁：GD 是一步一问的走位（`kind: "free_move"`, `"连续吞噬"`）
        ChainMoveDecision ch => Tagged("free_move", "连续吞噬", ("to", Pos(ch.Target))),
        StopChainDecision => Tagged("free_move", "连续吞噬", ("stop", true)),

        // 【炎症性趋化】的第 2/3 步：GD 同样是 `kind: "free_move"`，tag 换成卡名。
        // 第 1 步不在这里 —— 它是 `k=action|act=play|card=炎症性趋化|to=…`。
        // 2026-09-17 起三张卡共用这两条决策：tag 从挂起态里读（【趋化募集】【效应细胞浸润】是抽到即走的事件卡）
        ChemotaxisStepDecision cx => Tagged("free_move", s.Turn.PendingWalkCard ?? "炎症性趋化", ("to", Pos(cx.Target))),
        StopChemotaxisDecision => Tagged("free_move", s.Turn.PendingWalkCard ?? "炎症性趋化", ("stop", true)),

        // 【代谢耦联】的两次追问（GD kind pick / tag 代谢耦联）：方向 {from, to_cid}、档位 {pay, get}、取消 {stop}
        CoupleDirectionDecision cd => Tagged("pick", "代谢耦联", ("from", Seat(cd.Payer)), ("to_cid", Seat(cd.Getter))),
        CoupleTierDecision ct => Tagged("pick", "代谢耦联", ("pay", ct.Pay), ("get", ct.Get)),
        CancelCoupleDecision => Tagged("pick", "代谢耦联", ("stop", true)),

        // 【基质重塑】的三次追问（GD kind pick_tile / tag 基质重塑）：再拆 / 转健康都是 {to}，停是 {stop} —— 三问同形，重放器靠 asks 里的位置区分
        RemodelPickDecision rp => Tagged("pick_tile", "基质重塑", ("to", Pos(rp.Target))),
        StopRemodelDecision => Tagged("pick_tile", "基质重塑", ("stop", true)),

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
    private static Parts TypeSkill(WorldState s, TypeSkillDecision t) => t.Skill switch
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
    private static Parts Key(string kind, params (string Field, object? Value)[] fields) => Tagged(kind, null, fields);

    private static Parts Tagged(string kind, string? tag, params (string Field, object? Value)[] fields)
    {
        var bag = fields.Where(f => f.Value != null).ToDictionary(f => f.Field, f => f.Value!, StringComparer.Ordinal);
        var unknown = bag.Keys.Where(k => !FieldOrder.Contains(k)).ToArray();
        if (unknown.Length > 0)
            throw new InvalidOperationException($"语义键里出现了文法外的字段：{string.Join(" / ", unknown)}");

        return new Parts(kind, tag, FieldOrder.Where(bag.ContainsKey).Select(f => (f, bag[f])).ToArray());
    }

    private static object? Pos(HexPosition? p) => p;

    /// <summary>细胞 id → **席位**（规矩 2：C# 的 `EntityId = seat + 1`）。</summary>
    private static object? Seat(EntityId? id) => id;

    /// <summary>落点 → GD `DIRS` 的下标。不是六邻之一就没有方向可言。</summary>
    private static object? Dir(HexPosition from, HexPosition? to)
    {
        if (to is not { } t) return null;
        var i = DirIndex(from, t);
        return i < 0 ? null : i;
    }
}
