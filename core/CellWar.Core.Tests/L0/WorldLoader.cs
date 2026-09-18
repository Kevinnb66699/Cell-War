using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// 把 <see cref="L0World"/> 装成一个真的 <see cref="WorldState"/>。
///
/// **一条规矩贯穿全文：认不出来的就炸，不许静默跳过。**
/// 迁移计划专门点过这个坑 ——「loader 只走完三分之一」，
/// 而一个只认一半键的 loader 最坏的地方不是装不上，是**装上了但少了东西**：
/// 用例照样绿，绿得毫无意义。
/// </summary>
public static class WorldLoader
{
    public static WorldState Load(L0World spec)
    {
        // **先铺满整块棋盘，再拿用例列的格子覆盖上去。**
        //
        // 不能只铺列到的那几格：GD 那边 `neighbors()` 按 `board_radius` 返回坐标、**不看 tiles 里有没有**，
        // 只铺几格的话取邻居就崩（第一次跑 GD runner 就是这么炸的，而且它带着错误跑完、
        // 结果还碰巧对上，印出一片假 ok）。铺满也更贴近真实对局 —— 棋盘本来就是满的。
        var tiles = new Dictionary<HexPosition, Tissue>();
        foreach (var at in AllCoords(spec.Radius))
            tiles[at] = new Tissue
            {
                // 底板 = 全健康 + 特殊组织按坐标表（GD `build_board` 走 `CWData.special_of`）；用例点名的格再覆盖上去（点名而没写 type 的按 GD 口径归 normal）
                Position = at, Type = MatchSetup.SpecialAt(at), State = TissueState.Healthy,
                SolidificationCount = 0, OccupyingCell = null, Charge = 0,
            };

        var named = new HashSet<HexPosition>();
        foreach (var t in spec.Tiles)
        {
            var at = Pos(t.At);
            if (!tiles.ContainsKey(at)) throw new InvalidOperationException($"这一格在半径 {spec.Radius} 的棋盘外：{t.At}");
            if (!named.Add(at)) throw new InvalidOperationException($"同一格写了两次：{t.At}");
            tiles[at] = new Tissue
                {
                    Position = at,
                    Type = TileType(t.Type),
                    State = TileState(t.State),
                    SolidificationCount = t.Solid,
                    OccupyingCell = null,   // 占位从 cells 段反推（下面），tile.cell 只当校验用
                    Charge = 0,
                    Mucus = t.Mucus,
                    NecrosisRounds = t.Necrosis,
                    OssifyAtRound = t.OssifyAt,
                };
        }

        var cells = new Dictionary<EntityId, Cell>();
        foreach (var c in spec.Cells)
        {
            var at = Pos(c.At);
            if (!tiles.ContainsKey(at)) throw new InvalidOperationException($"细胞站在没铺的格上：{c.At}");
            var type = CellKind(c.Type);
            // id = 在 cells 列表里的序号 + 1：与 GD `make_cell(g.cells.size(), …)` 同口径（闸二 2b 靠这个对得上）；席位不再决定 id
            var id = new EntityId((ulong)(cells.Count + 1));
            if (cells.Values.Any(x => x.OwnerSeat == c.Seat)) throw new InvalidOperationException($"席位 {c.Seat} 写了两只细胞");
            if (tiles[at].OccupyingCell is not null) throw new InvalidOperationException($"两只细胞站在同一格：{c.At}");
            tiles[at] = tiles[at].WithOccupyingCell(id);
            cells[id] = new Cell
            {
                Id = id,
                OwnerSeat = c.Seat,
                Faction = type is CellType.Melanoma or CellType.SignetRing or CellType.Osteosarcoma or CellType.SmallCellLung
                    ? Faction.Cancer : Faction.Immune,
                Type = type,
                Position = at,
                Energy = c.Energy,
                IsAlive = true,
                StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [],
                Equipped = c.Equipped ?? [],
                Marked = c.Marked,
                MarkLeft = c.Marked ? 1 : 0,
                MarkRound = c.Marked ? spec.Round : -1,
                Differentiated = c.Differentiated,
            };
        }

        // 用例若在格上写了 cell（席位），必须与 cells 段一致 —— 两侧各自反推、互相校验
        foreach (var t in spec.Tiles)
        {
            if (t.Cell < 0) continue;
            var occupant = tiles[Pos(t.At)].OccupyingCell is { } oid ? cells[oid] : null;
            if (occupant is null || occupant.OwnerSeat != t.Cell)
                throw new InvalidOperationException($"格 {t.At} 写了 cell={t.Cell}，但 cells 段里没有席位 {t.Cell} 的细胞站在那儿");
        }

        var players = new Dictionary<int, Player>();
        foreach (var p in spec.Players)
        {
            var faction = p.Faction switch
            {
                "immune" => Faction.Immune,
                "cancer" => Faction.Cancer,
                _ => throw new InvalidOperationException($"不认识的阵营：{p.Faction}（只认 immune / cancer）"),
            };
            players[p.Seat] = new Player
            {
                Seat = p.Seat,
                Faction = faction,
                IsAlive = true,
                DrawCount = 0,
                AntigenMemory = p.Memory,
                ImmuneLevel = Level(p.Level),
                // 癌种只从该席的细胞推（GD loader 同口径）；没落子的癌席就是没有 —— 以前静默拿骨肉瘤兜底，闸二 2b 抓出来的
                CancerType = faction == Faction.Cancer ? cells.Values.FirstOrDefault(c => c.OwnerSeat == p.Seat)?.Type : null,
            };
        }

        var world = new WorldState
        {
            Board = new Board { Radius = spec.Radius, Tissues = tiles },
            Cells = cells,
            Players = players,
            Turn = new TurnState { WorldRound = spec.Round, Phase = PhaseOf(spec.Phase), ActivePlayerSeat = spec.Seat },
        };
        return spec.Tuning.Count == 0 ? world : world.WithTuning(Tune(world.Tuning, spec.Tuning));
    }

    /// <summary>半径内的所有格（与 GD 的 `CWData.all_coords` 同一套：|q|、|r|、|s| 都 ≤ radius）。</summary>
    private static IEnumerable<HexPosition> AllCoords(int radius)
    {
        for (var q = -radius; q <= radius; q++)
            for (var r = Math.Max(-radius, -q - radius); r <= Math.Min(radius, -q + radius); r++)
                yield return new HexPosition(q, r, -q - r);
    }

    /// <summary>坐标 `"q,r"` → 立方坐标（s 由 q、r 定死）。</summary>
    public static HexPosition Pos(string text)
    {
        var parts = text.Split(',');
        if (parts.Length != 2 || !int.TryParse(parts[0].Trim(), out var q) || !int.TryParse(parts[1].Trim(), out var r))
            throw new InvalidOperationException($"坐标要写成 \"q,r\"，拿到的是 \"{text}\"");
        return new HexPosition(q, r, -q - r);
    }

    /// <summary>席位 → 细胞 id：`EntityId = seat + 1`（对拍规格的约定，C# 的 EntityId 0 是 Invalid）。</summary>
    /// <summary>按席位找细胞（id 不再等于席位 + 1）。</summary>
    public static Cell CellOfSeat(WorldState s, int seat)
        => s.Cells.Values.FirstOrDefault(c => c.OwnerSeat == seat) ?? throw new InvalidOperationException($"要的细胞（席位 {seat}）不在这个盘面上");

    private static TissueState TileState(string s) => s switch
    {
        "healthy" => TissueState.Healthy,
        "cancer" => TissueState.Cancer,
        "solid" => TissueState.SolidifiedCancer,
        _ => throw new InvalidOperationException($"不认识的组织状态：{s}（只认 healthy / cancer / solid）"),
    };

    private static TissueType TileType(string s) => s switch
    {
        "normal" => TissueType.Normal,
        "core" => TissueType.MetabolicCore,
        "marrow" => TissueType.BoneMarrow,
        "vessel" => TissueType.BloodVessel,
        _ => throw new InvalidOperationException($"不认识的组织类型：{s}（只认 normal / core / marrow / vessel）"),
    };

    private static CellType CellKind(string s) => Enum.TryParse<CellType>(s, out var t)
        ? t
        : throw new InvalidOperationException($"不认识的细胞种类：{s}");

    private static ImmuneLevel Level(string s) => s switch
    {
        "I" => ImmuneLevel.I,
        "II" => ImmuneLevel.II,
        "III" => ImmuneLevel.III,
        "X" => ImmuneLevel.X,
        _ => throw new InvalidOperationException($"不认识的免疫等级：{s}（只认 I / II / III / X）"),
    };

    private static Phase PhaseOf(string s) => Enum.TryParse<Phase>(s, out var p)
        ? p
        : throw new InvalidOperationException($"不认识的阶段：{s}");

    /// <summary>
    /// 拧旋钮。只支持**标量**旋钮 —— 数组型（分档表）要拧的话另加语法，
    /// 现在写了数组名就报错，免得「拧了个寂寞」。
    /// </summary>
    private static RuleTuning Tune(RuleTuning tune, Dictionary<string, int> knobs)
    {
        foreach (var (key, value) in knobs) tune = WithKnob(tune, key, value);
        return tune;
    }

    /// <summary>
    /// 旋钮按**GD 的名字**（snake_case）认 —— 用例说的是权威那边的话，
    /// 不是 C# 的属性名。GD runner 那头直接 `g.tune.set(key, value)` 就用得上同一个键。
    /// 没接上线的旋钮**当场炸**，别绕过去。
    /// </summary>
    private static RuleTuning WithKnob(RuleTuning tune, string name, int value) => name switch
    {
        "cancer_move_cancerous" => tune with { CancerMoveCancerous = value },
        "cancer_move_healthy" => tune with { CancerMoveHealthy = value },
        "sclc_move_healthy" => tune with { SclcMoveHealthy = value },
        "pseudopod_cost" => tune with { PseudopodCost = value },
        "mucus_move_surcharge" => tune with { MucusMoveSurcharge = value },
        "metastasis_cost" => tune with { MetastasisCost = value },
        "metastasis_max_per_round" => tune with { MetastasisMaxPerRound = value },
        "immune_respawn_delay" => tune with { ImmuneRespawnDelay = value },
        "macro_heal_purify" => tune with { MacroHealPurify = value },
        "counter_dmg_on_fail" => tune with { CounterDamageOnFail = value },
        "attack_max_per_turn" => tune with { AttackMaxPerTurn = value },
        "anaerobic_solid_bonus" => tune with { AnaerobicSolidBonus = value },
        "anaerobic_floor" => tune with { AnaerobicFloor = value },
        "anaerobic_cap" => tune with { AnaerobicCap = value },
        "anaerobic_split" => tune with { AnaerobicSplit = value != 0 },
        "newborn_protect" => tune with { NewbornProtect = value != 0 },
        "cancer_upkeep_pct" => tune with { CancerUpkeepPercent = value },
        "energy_cap" => tune with { EnergyCap = value },
        "overload_threshold" => tune with { OverloadThreshold = value },
        "overload_div" => tune with { OverloadDiv = value },
        "overload_exp" => tune with { OverloadExp = value },
        "overload_cap" => tune with { OverloadCap = value },
        _ => throw new InvalidOperationException($"旋钮 {name} 还没接进 L0 loader —— 加一行，别绕过去"),
    };
}
