using static CellWar.Core.CellRules;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 开局选址与免疫分化所有权域（对应三层设计的 PlacementRules / CellRules 开局部分）：
/// 落子验证/落子、下一未落子席位、进入第 1 世界回合，以及免疫细胞【分化】验证与执行。
/// </summary>
internal static class PlacementRules
{
    internal static readonly CellType[] ImmuneTypes =
        [CellType.BCell, CellType.TCell, CellType.Macrophage, CellType.Dendritic];

    public static ValidationResult ValidatePlacement(WorldState s, PlaceDecision place)
    {
        if (s.Turn.Phase != Phase.Setup) return new(false, "不在开局选址阶段");
        if (place.PlayerSeat != s.Turn.ActivePlayerSeat) return new(false, "不是该玩家的落子顺序");
        if (!s.Players.TryGetValue(place.PlayerSeat, out var player)) return new(false, "玩家不存在");
        if (Cells(s).Any(c => c.OwnerSeat == place.PlayerSeat)) return new(false, "该玩家已落子");
        if (!s.Board.Tissues.TryGetValue(place.TargetPosition, out var tile)) return new(false, "目标位置不在棋盘内");
        var want = player.Faction == Faction.Cancer ? TissueState.Cancer : TissueState.Healthy;
        if (tile.State != want) return new(false, player.Faction == Faction.Cancer ? "癌细胞只能放置在癌组织" : "免疫细胞只能放置在健康组织");
        if (tile.OccupyingCell != null) return new(false, "同一组织格仅能放置一个细胞");
        return new(true);
    }

    public static ValidationResult ValidateDifferentiate(WorldState s, DifferentiateDecision d)
    {
        if (s.Turn.Phase != Phase.PlayerAction) return new(false, "当前阶段不允许玩家操作");
        if (d.PlayerSeat != s.Turn.ActivePlayerSeat) return new(false, "不是该玩家的回合");
        if (!s.Players.TryGetValue(d.PlayerSeat, out var player) || player.Faction != Faction.Immune)
            return new(false, "只有免疫方可以分化");
        if (!s.Cells.TryGetValue(d.CellId, out var cell) || !cell.IsAlive || cell.OwnerSeat != d.PlayerSeat)
            return new(false, "细胞不存在或不可控制");
        if (cell.Differentiated) return new(false, "该细胞每局只能分化一次");
        if (player.ImmuneLevel < ImmuneLevel.III) return new(false, "免疫等级未达 III 级");
        if (!ImmuneTypes.Contains(d.Type)) return new(false, "无效的免疫细胞种类");
        if (Cells(s).Any(x => x.OwnerSeat == d.PlayerSeat && x.IsAlive && x.Type == d.Type))
            return new(false, "该免疫细胞种类本局已存在");
        return new(true);
    }

    public static RulesResult Differentiate(WorldState s, DifferentiateDecision d)
    {
        var cell = s.Cells[d.CellId];
        s = s.UpdateCell(cell.Id, cell.Copy(type: d.Type, differentiated: true));
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    public static RulesResult PlaceCell(WorldState s, PlaceDecision place)
    {
        var player = s.Players[place.PlayerSeat];
        var type = player.Faction == Faction.Cancer ? player.CancerType ?? CellType.Melanoma : CellType.ImmuneBasic;
        var id = new EntityId(s.Cells.Count == 0 ? 1UL : s.Cells.Keys.Max(k => k.Value) + 1);
        var cell = new Cell
        {
            Id = id, OwnerSeat = place.PlayerSeat, Faction = player.Faction, Type = type,
            Position = place.TargetPosition, Energy = player.Faction == Faction.Immune ? 30 : 60,
            IsAlive = true, StatusEffects = Array.Empty<StatusEffect>()
        };
        s = s.UpdateCell(id, cell);
        s = s.UpdateTissueOccupant(place.TargetPosition, id);
        var next = NextUnplacedSeat(s, place.PlayerSeat + 1);
        s = next is { } seat ? s.WithTurn(s.Turn.Copy(seat: seat)) : BeginWorldRound(s);
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    public static int? NextUnplacedSeat(WorldState s, int fromInclusive)
    {
        foreach (var seat in s.Players.Keys.OrderBy(x => x).Where(x => x >= fromInclusive))
            if (!Cells(s).Any(c => c.OwnerSeat == seat)) return seat;
        return null;
    }

    public static WorldState BeginWorldRound(WorldState s)
    {
        var first = s.Players.Keys.OrderBy(x => x).First();
        return s.WithTurn(s.Turn.Copy(phase: Phase.S, seat: first, startStep: 0));
    }
}
