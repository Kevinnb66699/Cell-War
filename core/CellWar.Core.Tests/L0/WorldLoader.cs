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
        var tiles = new Dictionary<HexPosition, Tissue>();
        foreach (var t in spec.Tiles)
        {
            var at = Pos(t.At);
            if (!tiles.TryAdd(at, new Tissue
                {
                    Position = at,
                    Type = TileType(t.Type),
                    State = TileState(t.State),
                    SolidificationCount = t.Solid,
                    OccupyingCell = t.Cell >= 0 ? Id(t.Cell) : null,
                    Charge = 0,
                    Mucus = t.Mucus,
                    NecrosisRounds = t.Necrosis,
                    OssifyAtRound = t.OssifyAt,
                    SolidLockRound = t.SolidLock,
                }))
                throw new InvalidOperationException($"同一格铺了两次：{t.At}");
        }

        var cells = new Dictionary<EntityId, Cell>();
        foreach (var c in spec.Cells)
        {
            var at = Pos(c.At);
            if (!tiles.ContainsKey(at)) throw new InvalidOperationException($"细胞站在没铺的格上：{c.At}");
            var type = CellKind(c.Type);
            cells[Id(c.Seat)] = new Cell
            {
                Id = Id(c.Seat),
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
                CancerType = faction == Faction.Cancer
                    ? cells.Values.FirstOrDefault(c => c.OwnerSeat == p.Seat)?.Type ?? CellType.Osteosarcoma
                    : null,
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

    /// <summary>坐标 `"q,r"` → 立方坐标（s 由 q、r 定死）。</summary>
    public static HexPosition Pos(string text)
    {
        var parts = text.Split(',');
        if (parts.Length != 2 || !int.TryParse(parts[0].Trim(), out var q) || !int.TryParse(parts[1].Trim(), out var r))
            throw new InvalidOperationException($"坐标要写成 \"q,r\"，拿到的是 \"{text}\"");
        return new HexPosition(q, r, -q - r);
    }

    /// <summary>席位 → 细胞 id：`EntityId = seat + 1`（对拍规格的约定，C# 的 EntityId 0 是 Invalid）。</summary>
    public static EntityId Id(int seat) => new((ulong)(seat + 1));

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

    private static RuleTuning WithKnob(RuleTuning tune, string name, int value) => name switch
    {
        nameof(RuleTuning.CancerMoveCancerous) => tune with { CancerMoveCancerous = value },
        nameof(RuleTuning.CancerMoveHealthy) => tune with { CancerMoveHealthy = value },
        nameof(RuleTuning.SclcMoveHealthy) => tune with { SclcMoveHealthy = value },
        nameof(RuleTuning.PseudopodCost) => tune with { PseudopodCost = value },
        nameof(RuleTuning.MucusMoveSurcharge) => tune with { MucusMoveSurcharge = value },
        nameof(RuleTuning.MetastasisCost) => tune with { MetastasisCost = value },
        nameof(RuleTuning.AnaerobicSolidBonus) => tune with { AnaerobicSolidBonus = value },
        nameof(RuleTuning.AnaerobicFloor) => tune with { AnaerobicFloor = value },
        nameof(RuleTuning.AnaerobicCap) => tune with { AnaerobicCap = value },
        nameof(RuleTuning.AnaerobicSplit) => tune with { AnaerobicSplit = value != 0 },
        nameof(RuleTuning.NewbornProtect) => tune with { NewbornProtect = value != 0 },
        nameof(RuleTuning.CancerUpkeepPercent) => tune with { CancerUpkeepPercent = value },
        nameof(RuleTuning.EnergyCap) => tune with { EnergyCap = value },
        nameof(RuleTuning.OverloadThreshold) => tune with { OverloadThreshold = value },
        nameof(RuleTuning.OverloadDiv) => tune with { OverloadDiv = value },
        nameof(RuleTuning.OverloadExp) => tune with { OverloadExp = value },
        nameof(RuleTuning.OverloadCap) => tune with { OverloadCap = value },
        _ => throw new InvalidOperationException($"旋钮 {name} 还没接进 L0 loader —— 加一行，别绕过去"),
    };
}
