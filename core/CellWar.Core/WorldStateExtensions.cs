namespace CellWar.Core;

public static class WorldStateExtensions
{
    public static WorldState WithBoard(this WorldState s, Board board) => new() { Board = board, Cells = s.Cells, Turn = s.Turn, Players = s.Players };
    public static WorldState WithTurn(this WorldState s, TurnState turn) => new() { Board = s.Board, Cells = s.Cells, Turn = turn, Players = s.Players };
    public static WorldState UpdateCell(this WorldState s, EntityId id, Cell cell) => new() { Board = s.Board, Cells = s.Cells.SetItem(id, cell), Turn = s.Turn, Players = s.Players };
    public static WorldState AddCell(this WorldState s, Cell cell) => s.UpdateCell(cell.Id, cell);
    public static WorldState RemoveCell(this WorldState s, EntityId id)
    {
        var cells = s.Cells.ToBuilder(); cells.Remove(id);
        return new() { Board = s.Board, Cells = cells, Turn = s.Turn, Players = s.Players };
    }
    public static WorldState UpdatePlayer(this WorldState s, int seat, Player player) => new() { Board = s.Board, Cells = s.Cells, Turn = s.Turn, Players = s.Players.SetItem(seat, player) };
    public static Board UpdateTissue(this Board b, HexPosition pos, Tissue tissue) => new() { Radius = b.Radius, Tissues = b.Tissues.SetItem(pos, tissue) };
    public static Tissue WithState(this Tissue t, TissueState state) => t.CopyTissue(state: state, solid: state == TissueState.Healthy ? 0 : t.SolidificationCount, ossify: state == TissueState.Cancer ? t.OssifyAtRound : 0, newborn: state == TissueState.Cancer ? t.Newborn : false);
    public static Tissue WithType(this Tissue t, TissueType type) => t.CopyTissue(type: type);
    public static Tissue WithOccupyingCell(this Tissue t, EntityId? id) => new() { Position = t.Position, Type = t.Type, State = t.State, SolidificationCount = t.SolidificationCount, OccupyingCell = id, Charge = t.Charge, ProductionCounter = t.ProductionCounter, NecrosisRounds = t.NecrosisRounds, Mucus = t.Mucus, Newborn = t.Newborn, OssifyAtRound = t.OssifyAtRound };
    public static Tissue WithSolidificationCount(this Tissue t, int count) => t.CopyTissue(solid: count);
    public static Tissue WithCharge(this Tissue t, int? charge) => t.CopyTissue(charge: charge);
    public static Tissue WithProductionCounter(this Tissue t, int prod) => t.CopyTissue(prod: prod);
    public static Tissue WithNecrosis(this Tissue t, int rounds) => t.CopyTissue(necrosis: rounds);
    public static Tissue WithMucus(this Tissue t, bool mucus) => t.CopyTissue(mucus: mucus);
    public static Tissue WithNewborn(this Tissue t, bool newborn) => t.CopyTissue(newborn: newborn);
    public static Tissue WithOssifyAt(this Tissue t, int round) => t.CopyTissue(ossify: round);
    public static Tissue WithSolidLockRound(this Tissue t, int round) => t.CopyTissue(solidLock: round);
    public static Tissue WithToxinRound(this Tissue t, int round) => t.CopyTissue(toxinRound: round);

    private static Tissue CopyTissue(this Tissue t, TissueState? state = null, TissueType? type = null, int? solid = null, int? charge = null,
        int? prod = null, int? necrosis = null, bool? mucus = null, bool? newborn = null, int? ossify = null, int? solidLock = null, int? toxinRound = null)
        => new()
        {
            Position = t.Position, Type = type ?? t.Type, State = state ?? t.State,
            SolidificationCount = solid ?? t.SolidificationCount, OccupyingCell = t.OccupyingCell,
            Charge = charge ?? t.Charge, ProductionCounter = prod ?? t.ProductionCounter,
            NecrosisRounds = necrosis ?? t.NecrosisRounds, Mucus = mucus ?? t.Mucus,
            Newborn = newborn ?? t.Newborn, OssifyAtRound = ossify ?? t.OssifyAtRound,
            SolidLockRound = solidLock ?? t.SolidLockRound, ToxinRound = toxinRound ?? t.ToxinRound
        };
    public static Cell Copy(this Cell c, int? energy = null, HexPosition? position = null, bool? alive = null, int? attacks = null, int? deathRound = null, int? campRound = null, HexPosition? campPosition = null,
        int? draws = null, int? toxin = null, bool? mutateUsed = null, bool? differentiated = null, bool? effectorUsed = null, bool? marked = null, int? markLeft = null, int? markRound = null, int? respawnRound = null,
        IReadOnlyList<string>? hand = null, IReadOnlyList<string>? equipped = null, CellType? type = null, int? playCounter = null, IReadOnlyList<ActiveModifier>? modifiers = null,
        int? antibody = null, bool? metastasis = null, int? jump = null, bool? armor = null)
        => new() { Id = c.Id, OwnerSeat = c.OwnerSeat, Faction = c.Faction, Type = type ?? c.Type, Position = position ?? c.Position, Energy = energy ?? c.Energy,
            IsAlive = alive ?? c.IsAlive, StatusEffects = c.StatusEffects, AttacksThisTurn = attacks ?? c.AttacksThisTurn, DeathRound = deathRound ?? c.DeathRound,
            CampRound = campRound ?? c.CampRound, CampPosition = campPosition ?? c.CampPosition,
            DrawsThisTurn = draws ?? c.DrawsThisTurn, ToxinThisRound = toxin ?? c.ToxinThisRound, MutateUsedThisRound = mutateUsed ?? c.MutateUsedThisRound,
            AntibodyThisRound = antibody ?? c.AntibodyThisRound, MetastasisUsedThisRound = metastasis ?? c.MetastasisUsedThisRound, JumpUsedThisRound = jump ?? c.JumpUsedThisRound,
            ArmorUsedThisRound = armor ?? c.ArmorUsedThisRound,
            Differentiated = differentiated ?? c.Differentiated, EffectorUsed = effectorUsed ?? c.EffectorUsed, Marked = marked ?? c.Marked,
            MarkLeft = markLeft ?? c.MarkLeft, MarkRound = markRound ?? c.MarkRound, RespawnRound = respawnRound ?? c.RespawnRound,
            HandMax = c.HandMax, Hand = hand ?? c.Hand, Equipped = equipped ?? c.Equipped,
            PlayCounter = playCounter ?? c.PlayCounter, Modifiers = modifiers ?? c.Modifiers };
    public static Cell WithEnergy(this Cell c, int energy) => c.Copy(energy: energy);
    public static Cell WithPosition(this Cell c, HexPosition pos) => c.Copy(position: pos);
    public static Cell WithIsAlive(this Cell c, bool alive) => c.Copy(alive: alive);
    public static Player WithIsAlive(this Player p, bool alive) => new() { Seat = p.Seat, Faction = p.Faction, IsAlive = alive, DrawCount = p.DrawCount, AntigenMemory = p.AntigenMemory, ImmuneLevel = p.ImmuneLevel, CancerType = p.CancerType };
    public static Player WithAntigenMemory(this Player p, int memory) => new() { Seat = p.Seat, Faction = p.Faction, IsAlive = p.IsAlive, DrawCount = p.DrawCount, AntigenMemory = memory, ImmuneLevel = p.ImmuneLevel, CancerType = p.CancerType };
    public static Player WithImmuneLevel(this Player p, ImmuneLevel level) => new() { Seat = p.Seat, Faction = p.Faction, IsAlive = p.IsAlive, DrawCount = p.DrawCount, AntigenMemory = p.AntigenMemory, ImmuneLevel = level, CancerType = p.CancerType };
    public static Player WithDrawCount(this Player p, int count) => new() { Seat = p.Seat, Faction = p.Faction, IsAlive = p.IsAlive, DrawCount = count, AntigenMemory = p.AntigenMemory, ImmuneLevel = p.ImmuneLevel, CancerType = p.CancerType };
    public static Player WithCancerType(this Player p, CellType type) => new() { Seat = p.Seat, Faction = p.Faction, IsAlive = p.IsAlive, DrawCount = p.DrawCount, AntigenMemory = p.AntigenMemory, ImmuneLevel = p.ImmuneLevel, CancerType = type };
    public static TurnState Copy(this TurnState t, Phase? phase = null, int? seat = null, int? round = null, int? startStep = null, Faction? winner = null, int? alarm = null, int? pendingDiscard = null, int? tgf = null, int? pausedDecay = null,
        int? pendingMutationSeat = null, EntityId? pendingMutationCell = null, int? pendingMutationA = null, int? pendingMutationB = null, int? cytokineSeat = null, int? effectorRound = null, int? cancerDisabledUntil = null,
        HexPosition? chemoAt = null, int? chemoRounds = null, int? chemoOwner = null)
        => new() { WorldRound = round ?? t.WorldRound, Phase = phase ?? t.Phase, ActivePlayerSeat = seat ?? t.ActivePlayerSeat,
            StartStep = startStep ?? t.StartStep, Winner = winner ?? t.Winner, CancerAlarmRound = alarm ?? t.CancerAlarmRound,
            PendingDiscardSeat = pendingDiscard ?? t.PendingDiscardSeat, TgfStacks = tgf ?? t.TgfStacks, PausedDecayRound = pausedDecay ?? t.PausedDecayRound,
            PendingMutationSeat = pendingMutationSeat ?? t.PendingMutationSeat, PendingMutationCell = pendingMutationCell ?? t.PendingMutationCell,
            PendingMutationA = pendingMutationA ?? t.PendingMutationA, PendingMutationB = pendingMutationB ?? t.PendingMutationB,
            CytokineNetworkSeat = cytokineSeat ?? t.CytokineNetworkSeat,
            EffectorRound = effectorRound ?? t.EffectorRound, CancerEffectsDisabledUntil = cancerDisabledUntil ?? t.CancerEffectsDisabledUntil,
            ChemoAt = chemoAt ?? t.ChemoAt, ChemoRounds = chemoRounds ?? t.ChemoRounds, ChemoOwner = chemoOwner ?? t.ChemoOwner };
    public static TurnState WithPhase(this TurnState t, Phase p) => t.Copy(phase: p);
    public static TurnState WithActivePlayer(this TurnState t, int seat) => t.Copy(seat: seat);
    public static TurnState WithWorldRound(this TurnState t, int round) => t.Copy(round: round);
    public static TurnState WithPendingDiscard(this TurnState t, int? seat) => new()
    {
        WorldRound = t.WorldRound, Phase = t.Phase, ActivePlayerSeat = t.ActivePlayerSeat,
        StartStep = t.StartStep, Winner = t.Winner, CancerAlarmRound = t.CancerAlarmRound, PendingDiscardSeat = seat,
        TgfStacks = t.TgfStacks, PausedDecayRound = t.PausedDecayRound,
        PendingMutationSeat = t.PendingMutationSeat, PendingMutationCell = t.PendingMutationCell,
        PendingMutationA = t.PendingMutationA, PendingMutationB = t.PendingMutationB, CytokineNetworkSeat = t.CytokineNetworkSeat,
        EffectorRound = t.EffectorRound, CancerEffectsDisabledUntil = t.CancerEffectsDisabledUntil,
        ChemoAt = t.ChemoAt, ChemoRounds = t.ChemoRounds, ChemoOwner = t.ChemoOwner
    };
    public static TurnState WithPendingMutation(this TurnState t, int seat, EntityId cell, int a, int b) => new()
    {
        WorldRound = t.WorldRound, Phase = t.Phase, ActivePlayerSeat = t.ActivePlayerSeat, StartStep = t.StartStep,
        Winner = t.Winner, CancerAlarmRound = t.CancerAlarmRound, PendingDiscardSeat = t.PendingDiscardSeat,
        TgfStacks = t.TgfStacks, PausedDecayRound = t.PausedDecayRound,
        PendingMutationSeat = seat, PendingMutationCell = cell, PendingMutationA = a, PendingMutationB = b,
        CytokineNetworkSeat = t.CytokineNetworkSeat, EffectorRound = t.EffectorRound, CancerEffectsDisabledUntil = t.CancerEffectsDisabledUntil,
        ChemoAt = t.ChemoAt, ChemoRounds = t.ChemoRounds, ChemoOwner = t.ChemoOwner
    };
    public static TurnState ClearPendingMutation(this TurnState t) => new()
    {
        WorldRound = t.WorldRound, Phase = t.Phase, ActivePlayerSeat = t.ActivePlayerSeat, StartStep = t.StartStep,
        Winner = t.Winner, CancerAlarmRound = t.CancerAlarmRound, PendingDiscardSeat = t.PendingDiscardSeat,
        TgfStacks = t.TgfStacks, PausedDecayRound = t.PausedDecayRound,
        PendingMutationSeat = null, PendingMutationCell = null, PendingMutationA = 0, PendingMutationB = 0,
        CytokineNetworkSeat = t.CytokineNetworkSeat, EffectorRound = t.EffectorRound, CancerEffectsDisabledUntil = t.CancerEffectsDisabledUntil,
        ChemoAt = t.ChemoAt, ChemoRounds = t.ChemoRounds, ChemoOwner = t.ChemoOwner
    };
    public static TurnState WithCytokineNetwork(this TurnState t, int seat) => new()
    {
        WorldRound = t.WorldRound, Phase = t.Phase, ActivePlayerSeat = t.ActivePlayerSeat, StartStep = t.StartStep,
        Winner = t.Winner, CancerAlarmRound = t.CancerAlarmRound, PendingDiscardSeat = t.PendingDiscardSeat,
        TgfStacks = t.TgfStacks, PausedDecayRound = t.PausedDecayRound,
        PendingMutationSeat = t.PendingMutationSeat, PendingMutationCell = t.PendingMutationCell,
        PendingMutationA = t.PendingMutationA, PendingMutationB = t.PendingMutationB, CytokineNetworkSeat = seat,
        EffectorRound = t.EffectorRound, CancerEffectsDisabledUntil = t.CancerEffectsDisabledUntil,
        ChemoAt = t.ChemoAt, ChemoRounds = t.ChemoRounds, ChemoOwner = t.ChemoOwner
    };
    public static TurnState WithChemo(this TurnState t, HexPosition? at, int rounds, int owner) => new()
    {
        WorldRound = t.WorldRound, Phase = t.Phase, ActivePlayerSeat = t.ActivePlayerSeat, StartStep = t.StartStep,
        Winner = t.Winner, CancerAlarmRound = t.CancerAlarmRound, PendingDiscardSeat = t.PendingDiscardSeat,
        TgfStacks = t.TgfStacks, PausedDecayRound = t.PausedDecayRound,
        PendingMutationSeat = t.PendingMutationSeat, PendingMutationCell = t.PendingMutationCell,
        PendingMutationA = t.PendingMutationA, PendingMutationB = t.PendingMutationB, CytokineNetworkSeat = t.CytokineNetworkSeat,
        EffectorRound = t.EffectorRound, CancerEffectsDisabledUntil = t.CancerEffectsDisabledUntil,
        ChemoAt = at, ChemoRounds = rounds, ChemoOwner = owner
    };
    public static WorldState UpdateTissueState(this WorldState s, HexPosition pos, TissueState type) => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithState(type)));
    public static WorldState UpdateTissueOccupant(this WorldState s, HexPosition pos, EntityId? id) => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithOccupyingCell(id)));
    public static WorldState UpdateTissueSolidification(this WorldState s, HexPosition pos, int count) => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithSolidificationCount(count)));
    public static Cell? GetCell(this WorldState s, EntityId id) => s.Cells.TryGetValue(id, out var cell) ? cell : null;
    public static Cell? GetCellAt(this WorldState s, HexPosition pos) => s.Board.Tissues.TryGetValue(pos, out var tissue) && tissue.OccupyingCell is { } id ? s.GetCell(id) : null;
    public static IEnumerable<Cell> GetAliveCells(this WorldState s, Faction? faction = null) => s.Cells.Values.Where(c => c.IsAlive && (faction == null || c.Faction == faction));
    public static IEnumerable<HexPosition> GetAdjacentPositions(this Board b, HexPosition p) => p.GetNeighbors().Where(b.Tissues.ContainsKey);
}
