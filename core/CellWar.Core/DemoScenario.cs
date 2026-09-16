namespace CellWar.Core;

/// <summary>Fixed four-seat integration fixture, not the full pre-game placement workflow.</summary>
public static class DemoScenario
{
    public static WorldState Create()
    {
        var tissues = new Dictionary<HexPosition, Tissue>();
        for (var q = -6; q <= 6; q++)
            for (var r = -6; r <= 6; r++)
                if (Math.Abs(q + r) <= 6)
                {
                    var p = new HexPosition(q, r, -q - r);
                    tissues[p] = new Tissue { Position = p, Type = TissueType.Normal, State = TissueState.Healthy,
                        SolidificationCount = 0, OccupyingCell = null, Charge = 0 };
                }
        foreach (var p in tissues.Keys.OrderBy(p => p.DistanceTo(new(0, 0, 0))).ThenBy(p => p.Q).ThenBy(p => p.R).Take(15).ToArray())
            tissues[p] = tissues[p].WithState(TissueState.Cancer);
        var positions = new[] { new HexPosition(-4, 0, 4), new HexPosition(-1, 0, 1), new HexPosition(4, 0, -4), new HexPosition(1, 0, -1) };
        var types = new[] { CellType.ImmuneBasic, CellType.Melanoma, CellType.ImmuneBasic, CellType.SignetRing };
        var cells = new Dictionary<EntityId, Cell>();
        var players = new Dictionary<int, Player>();
        for (var seat = 0; seat < 4; seat++)
        {
            var faction = seat % 2 == 0 ? Faction.Immune : Faction.Cancer;
            var id = new EntityId((ulong)seat + 1);
            cells[id] = new Cell { Id = id, OwnerSeat = seat, Faction = faction, Type = types[seat], Position = positions[seat],
                Energy = faction == Faction.Immune ? 30 : 60, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>() };
            tissues[positions[seat]] = tissues[positions[seat]].WithOccupyingCell(id);
            players[seat] = new Player { Seat = seat, Faction = faction, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };
        }
        return new() { Board = new Board { Radius = 6, Tissues = tissues }, Cells = cells, Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.S, ActivePlayerSeat = 0 } };
    }
}
