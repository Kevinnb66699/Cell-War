using System.Text.Json;
using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// **L1 视图**：两个内核都能算出来的那部分状态，压成同一形状的普通字典/列表/标量，
/// 与 GD 侧 `game/tests/xcheck_export.gd` 的 `view(g)` **逐键相同**（字段名用 GD 的词、值用 GD 的枚举）。
///
/// 它不是 canon：canon（`CanonCodec`）是 C# 自己能装回来的全量，视图只导两边共有的部分 ——
/// 所以这里**只在这一处和 GD 的 view() 里各写一份**，改一边就得改另一边。
///
/// 有意不进视图的（与 GD 侧文件头同一份口径）：`mods` 只带 {name, uses, until, seq}；
/// 挂起态（弃置 / 二选一 / 连锁 / 趋化）GD 没有字段、以问答的 kind 出现；`CancerAlarmRound` 与 GD `cancer_win_streak` 语义不同。
/// </summary>
public static class L1View
{
    private const int CancerTypeBase = (int)CellType.Melanoma;   // C# 把癌种排在免疫种类之后；GD 的 CancerType 从 0 起

    // ---------------- 导出 ----------------

    public static Dictionary<string, object?> Of(WorldState s)
    {
        var tiles = s.Board.Tissues.Values
            .OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R)
            .Select(t => (object?)new Dictionary<string, object?>
            {
                ["at"] = Pos(t.Position), ["tissue"] = (long)t.State, ["special"] = (long)t.Type,
                ["solid"] = (long)t.SolidificationCount,
                ["cell"] = t.OccupyingCell is { } id ? (long)Seat(id) : -1L,
                ["necrosis"] = (long)t.NecrosisRounds, ["mucus"] = t.Mucus, ["newborn"] = t.Newborn,
                ["ossify_at"] = (long)t.OssifyAtRound, ["toxin_round"] = (long)t.ToxinRound,
                ["store"] = (long)(t.Charge ?? 0), ["prod"] = (long)t.ProductionCounter,
            }).ToList();

        var cells = s.Cells.Values.OrderBy(c => c.OwnerSeat).Select(c => (object?)new Dictionary<string, object?>
        {
            ["pid"] = (long)c.OwnerSeat, ["pos"] = Pos(c.Position), ["faction"] = (long)c.Faction,
            ["itype"] = c.Faction == Faction.Immune ? (long)c.Type : -1L,
            ["ctype"] = c.Faction == Faction.Cancer ? (long)c.Type - CancerTypeBase : -1L,
            ["energy"] = (long)c.Energy, ["alive"] = c.IsAlive,
            ["attacks_used"] = (long)c.AttacksThisTurn, ["draws_used"] = (long)c.DrawsThisTurn,
            ["toxin_used"] = (long)c.ToxinThisRound, ["mutate_used"] = c.MutateUsedThisRound,
            ["antibody_used"] = (long)c.AntibodyThisRound, ["metastasis_used"] = c.MetastasisUsedThisRound,
            ["jump_used"] = (long)c.JumpUsedThisRound, ["armor_used"] = c.ArmorUsedThisRound,
            ["differentiated"] = c.Differentiated, ["effector_used"] = c.EffectorUsed,
            ["marked"] = c.Marked, ["mark_left"] = (long)c.MarkLeft, ["mark_round"] = (long)c.MarkRound,
            ["respawn_round"] = (long)c.RespawnRound,
            ["camp_round"] = (long)c.CampRound,
            ["camp_pos"] = c.CampRound >= 0 && c.CampPosition is { } cp ? Pos(cp) : "",
            ["play_n"] = (long)c.PlayCounter,
            // 「从没被中和过」GD 记 -1、C# 记 0，意思相同、值不同 —— 视图上统一成 -1
            ["neutral_until"] = c.NeutralUntil <= 0 ? -1L : c.NeutralUntil, ["chemo_cd"] = (long)c.ChemoCooldown,
            ["chain_left"] = (long)c.ChainLeft, ["chain_bonus"] = (long)c.ChainBonus,
            ["hand"] = Sorted(c.Hand), ["equipped"] = Sorted(c.Equipped),
            ["equip_seq"] = c.EquipSeq.ToDictionary(kv => kv.Key, kv => (object?)(long)kv.Value),
            ["fx_turn"] = c.FxTurn.ToDictionary(kv => kv.Key, kv => (object?)(long)kv.Value),
            ["fx_round"] = Sorted(c.FxRound),
            ["mods"] = c.Modifiers
                .OrderBy(m => m.Sequence).ThenBy(m => m.Card, StringComparer.Ordinal)
                .Select(m => (object?)new Dictionary<string, object?>
                {
                    ["name"] = m.Card, ["uses"] = (long)m.Uses, ["until"] = Until(m.Duration), ["seq"] = (long)m.Sequence,
                }).ToList(),
        }).ToList();

        var immune = s.Players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat).FirstOrDefault();
        var events = s.Effects
            .OrderBy(e => e.Name, StringComparer.Ordinal).ThenBy(e => e.Left)
            .Select(e => (object?)new Dictionary<string, object?> { ["name"] = e.Name, ["left"] = (long)e.Left, ["stacks"] = (long)e.Stacks })
            .ToList();
        var phase = PhaseWord(s.Turn.Phase);

        return new Dictionary<string, object?>
        {
            ["board"] = new Dictionary<string, object?> { ["radius"] = (long)s.Board.Radius, ["tiles"] = tiles },
            ["cells"] = cells,
            ["g"] = new Dictionary<string, object?>
            {
                ["round_no"] = (long)s.Turn.WorldRound, ["phase"] = phase,
                // GD 的 current_pid 换回合不清零，只在玩家回合里两边才是同一个意思
                ["current_pid"] = phase == "turn" ? (long)s.Turn.ActivePlayerSeat : -1L,
                ["memory"] = (long)(immune?.AntigenMemory ?? 0),
                // GD 的 immune_level 从 0 起（I=0…X=3），C# 的枚举从 1 起 —— 视图用 GD 的数
                ["immune_level"] = (long)(immune?.ImmuneLevel ?? ImmuneLevel.I) - 1,
                ["winner"] = s.Turn.Winner is { } w ? (long)w : -1L, ["effector_round"] = (long)s.Turn.EffectorRound,
                ["chemo_at"] = s.Turn.ChemoAt is { } ca ? Pos(ca) : "",
                ["chemo_left"] = s.Turn.ChemoAt is null ? 0L : s.Turn.ChemoRounds,
                ["chemo_by"] = s.Turn.ChemoAt is null ? -1L : s.Turn.ChemoOwner,
                ["track_cid"] = s.Turn.TrackCell is { } tc ? (long)Seat(tc) : -1L,
                ["track_at"] = s.Turn.TrackFrozenAt is { } ta ? Pos(ta) : "",
                ["track_left"] = (long)s.Turn.TrackRounds,
                ["events"] = events,
            },
            ["players"] = s.Players.Values.OrderBy(p => p.Seat).Select(p => (object?)new Dictionary<string, object?>
            {
                ["pid"] = (long)p.Seat, ["faction"] = (long)p.Faction, ["alive"] = p.IsAlive,
                // 癌种记在席位上（GD player["cancer_type"]）：落子之前细胞还不存在，装载时靠它定种
                ["ctype"] = p.CancerType is { } ct ? (long)ct - CancerTypeBase : -1L,
            }).ToList(),
            ["tune"] = Tune(s.Tuning),
        };
    }

    // ---------------- 装载（只用于轨迹开头：那时没有修饰、没人死） ----------------

    /// <summary>
    /// 从 GD 的视图装出一个 C# 世界。走 canon：视图是 canon 的子集，缺的字段填默认值再交给 <see cref="CanonCodec.From"/>。
    /// **只接受没有修饰条目的视图** —— GD 的修饰条目没有效果元组，装不回 C# 的 `ActiveModifier`。
    /// </summary>
    public static WorldState Load(JsonElement v, int activeSeat)
    {
        var g = v.GetProperty("g");
        var phase = g.GetProperty("phase").GetString()!;
        var (phaseInt, startStep) = phase switch
        {
            "setup" => ((int)Phase.Setup, 0), "s" => ((int)Phase.S, 1), "turn" => ((int)Phase.PlayerAction, 2),
            "e" => ((int)Phase.E, 2), "finished" => ((int)Phase.Finished, 2),
            _ => throw new InvalidOperationException($"BADFIXTURE：不认识的 phase「{phase}」"),
        };
        var currentPid = g.GetProperty("current_pid").GetInt32();

        var tiles = v.GetProperty("board").GetProperty("tiles").EnumerateArray().Select(t => new CanonTile(
            S(t, "at"), I(t, "tissue"), I(t, "special"), I(t, "solid"), I(t, "cell"),
            I(t, "necrosis"), B(t, "mucus"), B(t, "newborn"), I(t, "ossify_at"), 0, I(t, "toxin_round"),
            I(t, "store"), I(t, "prod"))).ToList();

        var cells = v.GetProperty("cells").EnumerateArray().Select(c =>
        {
            if (c.GetProperty("mods").GetArrayLength() > 0)
                throw new InvalidOperationException("BADFIXTURE：视图装不回带修饰的细胞（GD 的条目没有效果元组）");
            var faction = I(c, "faction");
            return new CanonCell(I(c, "pid"), S(c, "pos"), faction,
                I(c, "itype"), faction == (int)Faction.Cancer ? I(c, "ctype") + CancerTypeBase : -1,
                I(c, "energy"), B(c, "alive"), null,
                I(c, "attacks_used"), I(c, "draws_used"), I(c, "toxin_used"), B(c, "mutate_used"), I(c, "antibody_used"),
                B(c, "metastasis_used"), I(c, "jump_used"), B(c, "armor_used"), B(c, "differentiated"), B(c, "effector_used"),
                B(c, "marked"), I(c, "mark_left"), I(c, "mark_round"), I(c, "respawn_round"), I(c, "camp_round"), S(c, "camp_pos"),
                HandMax, I(c, "play_n"), Math.Max(0, I(c, "neutral_until")), I(c, "chemo_cd"), I(c, "chain_left"), I(c, "chain_bonus"))
            {
                Hand = Strings(c, "hand"), Equipped = Strings(c, "equipped"),
                EquipSeq = IntMap(c, "equip_seq"), FxTurn = IntMap(c, "fx_turn"), FxRound = Strings(c, "fx_round"),
            };
        }).ToList();

        var players = v.GetProperty("players").EnumerateArray().Select(p =>
        {
            var faction = I(p, "faction");
            return new CanonPlayer(I(p, "pid"), faction, B(p, "alive"), 0,
                faction == (int)Faction.Immune ? I(g, "memory") : 0,
                faction == (int)Faction.Immune ? I(g, "immune_level") + 1 : (int)ImmuneLevel.I,   // GD 0 基 → C# 1 基
                I(p, "ctype") >= 0 ? I(p, "ctype") + CancerTypeBase : null);
        }).ToList();

        var events = g.GetProperty("events").EnumerateArray()
            .Select(e => new CanonEffect(S(e, "name"), I(e, "left"), I(e, "stacks"), "", []))
            .ToList();

        var canon = new CanonState
        {
            Board = new CanonBoard(I(v.GetProperty("board"), "radius"), tiles),
            Cells = cells,
            G = new CanonGlobal(I(g, "round_no"), phaseInt, currentPid >= 0 ? currentPid : activeSeat,
                I(g, "memory"), I(g, "immune_level") + 1, startStep,
                I(g, "winner") is var w && w >= 0 ? w : null, CancerAlarmDefault,
                null, null, null, 0, 0, -1, I(g, "effector_round"),
                S(g, "chemo_at"), I(g, "chemo_left"), S(g, "chemo_at") == "" ? 0 : I(g, "chemo_by"), null,
                I(g, "track_cid") is var tc && tc >= 0 ? tc : null, S(g, "track_at"), I(g, "track_left"),
                null, null, 0, 0, "", null, 0, null, null, null)
            { Players = players },
            Events = events,
            Tune = v.GetProperty("tune").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetInt32()),
        };
        return CanonCodec.From(canon);
    }

    /// <summary>PRD 手牌上限 8；视图里没有这个字段（GD 是常量）。</summary>
    private const int HandMax = 8;
    /// <summary>C# `TurnState.CancerAlarmRound` 的默认值（视图不导它）。</summary>
    private const int CancerAlarmDefault = 0;

    // ---------------- 工具 ----------------

    /// <summary>把 JSON 树压成与 <see cref="Of"/> 同一套普通对象（字典 / 列表 / long / bool / string），好让 DeepDiff 两边同型。</summary>
    public static object? Plain(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Object => e.EnumerateObject().ToDictionary(p => p.Name, p => Plain(p.Value)),
        JsonValueKind.Array => e.EnumerateArray().Select(Plain).ToList(),
        JsonValueKind.String => e.GetString(),
        // ⚠ 三目里 long 与 double 会被提升成 double，整数就全成了 Double —— 先装箱再说
        JsonValueKind.Number => e.TryGetInt64(out var l) ? (object)l : e.GetDouble(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null,
    };

    public static string Pos(HexPosition p) => $"{p.Q},{p.R}";
    private static int Seat(EntityId id) => (int)id.Value - 1;
    private static List<object?> Sorted(IEnumerable<string> xs) => xs.OrderBy(x => x, StringComparer.Ordinal).Select(x => (object?)x).ToList();
    private static string Until(ModifierDuration d) => d switch { ModifierDuration.Turn => "turn", ModifierDuration.Round => "round", _ => "" };
    private static string PhaseWord(Phase p) => p switch
    {
        Phase.Setup => "setup", Phase.S => "s", Phase.PlayerAction => "turn", Phase.E => "e", _ => "finished",
    };

    /// <summary>与 GD 侧 `TUNE_KEYS` 同一份 17 个键（`CanonCodec.TuneToCanon` 的那张表）。</summary>
    private static Dictionary<string, object?> Tune(RuleTuning t) => new()
    {
        ["cancer_move_cancerous"] = (long)t.CancerMoveCancerous, ["cancer_move_healthy"] = (long)t.CancerMoveHealthy,
        ["sclc_move_healthy"] = (long)t.SclcMoveHealthy, ["pseudopod_cost"] = (long)t.PseudopodCost,
        ["mucus_move_surcharge"] = (long)t.MucusMoveSurcharge, ["metastasis_cost"] = (long)t.MetastasisCost,
        ["attack_max_per_turn"] = (long)t.AttackMaxPerTurn,
        ["anaerobic_solid_bonus"] = (long)t.AnaerobicSolidBonus, ["anaerobic_floor"] = (long)t.AnaerobicFloor,
        ["anaerobic_cap"] = (long)t.AnaerobicCap, ["anaerobic_split"] = t.AnaerobicSplit ? 1L : 0L,
        ["newborn_protect"] = t.NewbornProtect ? 1L : 0L, ["cancer_upkeep_pct"] = (long)t.CancerUpkeepPercent,
        ["energy_cap"] = (long)t.EnergyCap, ["overload_threshold"] = (long)t.OverloadThreshold,
        ["overload_div"] = (long)t.OverloadDiv, ["overload_exp"] = (long)t.OverloadExp, ["overload_cap"] = (long)t.OverloadCap,
    };

    private static int I(JsonElement e, string k) => e.GetProperty(k).GetInt32();
    private static bool B(JsonElement e, string k) => e.GetProperty(k).GetBoolean();
    private static string S(JsonElement e, string k) => e.GetProperty(k).GetString() ?? "";
    private static List<string> Strings(JsonElement e, string k) => e.GetProperty(k).EnumerateArray().Select(x => x.GetString()!).ToList();
    private static Dictionary<string, int> IntMap(JsonElement e, string k) => e.GetProperty(k).EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetInt32());
}
