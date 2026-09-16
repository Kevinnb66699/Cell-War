namespace CellWar.Core;

public static class WorldStateExtensions
{
    /// <summary>
    /// **世界状态的唯一一份字段清单。** 下面所有 `With*` / `Update*` 都走它。
    ///
    /// 2026-09-15：这里原来是**五份手写的初始化器**，加 `Tuning` 时五份一份都没跟上 ——
    /// 于是第一次改棋盘，旋钮就悄悄回默认值（门槛旋钮的测试当场撞上，靠探针才查出来）。
    /// Tissue / Cell / TurnState 的清单早就收口了，唯独漏了 `WorldState` 自己。
    /// </summary>
    public static WorldState Copy(this WorldState s, Board? board = null, PagedMap<EntityId, Cell>? cells = null,
        TurnState? turn = null, PagedMap<int, Player>? players = null, RuleTuning? tuning = null,
        IReadOnlyList<ActiveEffect>? effects = null)
        => new()
        {
            Board = board ?? s.Board,
            Cells = cells ?? s.Cells,
            Turn = turn ?? s.Turn,
            Players = players ?? s.Players,
            Effects = effects ?? s.Effects,
            Tuning = tuning ?? s.Tuning,
        };

    /// <summary>
    /// 往全局修饰容器里挂一条（卡牌的全局修饰用；世界事件将来走自己的 trigger）。
    /// `left` 按**世界回合**倒计时，E 阶段末 −1、归零移除 —— 与世界事件同一套时钟。
    /// 对齐 GD 的 `CWGame.install_event()`。
    ///
    /// **同名可以挂多条**（打两张【TGF-β释放】就是两条），强度靠 `WorldEffects.Stacks` 求和。
    /// </summary>
    public static WorldState InstallEffect(this WorldState s, string name, int left, int stacks = 1,
        IReadOnlyDictionary<string, int>? data = null)
    {
        var entry = new ActiveEffect(name, left, stacks);
        if (data != null) entry = entry with { Data = data };
        return s.Copy(effects: [.. s.Effects, entry]);
    }

    /// <summary>把同名的条目**整批**摘掉（【TGF-β释放】结算后就是这样一次清空）。</summary>
    public static WorldState RemoveEffects(this WorldState s, string name)
        => s.Copy(effects: s.Effects.Where(e => e.Name != name).ToList());

    public static WorldState WithBoard(this WorldState s, Board board) => s.Copy(board: board);
    public static WorldState WithTurn(this WorldState s, TurnState turn) => s.Copy(turn: turn);
    public static WorldState WithTuning(this WorldState s, RuleTuning tuning) => s.Copy(tuning: tuning);
    public static WorldState UpdateCell(this WorldState s, EntityId id, Cell cell) => s.Copy(cells: s.Cells.SetItem(id, cell));
    public static WorldState AddCell(this WorldState s, Cell cell) => s.UpdateCell(cell.Id, cell);
    public static WorldState RemoveCell(this WorldState s, EntityId id)
    {
        var cells = s.Cells.ToBuilder(); cells.Remove(id);
        return s.Copy(cells: cells);
    }
    public static WorldState UpdatePlayer(this WorldState s, int seat, Player player) => s.Copy(players: s.Players.SetItem(seat, player));
    public static Board UpdateTissue(this Board b, HexPosition pos, Tissue tissue) => new() { Radius = b.Radius, Tissues = b.Tissues.SetItem(pos, tissue) };
    public static Tissue WithState(this Tissue t, TissueState state) => t.CopyTissue(state: state, solid: state == TissueState.Healthy ? 0 : t.SolidificationCount, ossify: state == TissueState.Cancer ? t.OssifyAtRound : 0, newborn: state == TissueState.Cancer ? t.Newborn : false);
    public static Tissue WithType(this Tissue t, TissueType type) => t.CopyTissue(type: type);
    // 2026-09-15 修：这里原来自己手写了一份初始化器，**漏掉 SolidLockRound 与 ToxinRound**。
    // 实测一格 Toxin=7 SolidLock=3，放进一个细胞之后变成 0/0 ——
    // 而「格上有细胞」恰恰是这两个字段唯一起作用的场合（TNF-α 冻结固化、细胞毒素的格记录）。
    //
    // 病根不是漏了两个字段，是**同一份字段清单被手写了三遍**（Clone / CopyTissue / 这里）。
    // 所以改法是让它也走 CopyTissue，字段清单从此只有一份。
    // `setOccupying` 那个开关是必须的：EntityId? 分不出「不改」和「改成 null」。
    public static Tissue WithOccupyingCell(this Tissue t, EntityId? id)
        => t.CopyTissue(setOccupying: true, occupying: id);
    public static Tissue WithSolidificationCount(this Tissue t, int count) => t.CopyTissue(solid: count);
    public static Tissue WithCharge(this Tissue t, int? charge) => t.CopyTissue(charge: charge);
    public static Tissue WithProductionCounter(this Tissue t, int prod) => t.CopyTissue(prod: prod);
    public static Tissue WithNecrosis(this Tissue t, int rounds) => t.CopyTissue(necrosis: rounds);
    public static Tissue WithMucus(this Tissue t, bool mucus) => t.CopyTissue(mucus: mucus);
    public static Tissue WithNewborn(this Tissue t, bool newborn) => t.CopyTissue(newborn: newborn);
    public static Tissue WithOssifyAt(this Tissue t, int round) => t.CopyTissue(ossify: round);
    public static Tissue WithSolidLockRound(this Tissue t, int round) => t.CopyTissue(solidLock: round);
    public static Tissue WithToxinRound(this Tissue t, int round) => t.CopyTissue(toxinRound: round);

    /// <summary>
    /// Tissue 的**唯一**一份字段清单。所有 With* 都从这里出去 ——
    /// 新加字段只要往这里加一行，就不会有某个 With* 悄悄把它清零。
    /// （2026-09-15 之前 WithOccupyingCell 自己手写了一份，漏了两个字段、静默清零。）
    /// </summary>
    private static Tissue CopyTissue(this Tissue t, TissueState? state = null, TissueType? type = null, int? solid = null, int? charge = null,
        int? prod = null, int? necrosis = null, bool? mucus = null, bool? newborn = null, int? ossify = null, int? solidLock = null, int? toxinRound = null,
        bool setOccupying = false, EntityId? occupying = null)
        => new()
        {
            Position = t.Position, Type = type ?? t.Type, State = state ?? t.State,
            SolidificationCount = solid ?? t.SolidificationCount,
            OccupyingCell = setOccupying ? occupying : t.OccupyingCell,
            Charge = charge ?? t.Charge, ProductionCounter = prod ?? t.ProductionCounter,
            NecrosisRounds = necrosis ?? t.NecrosisRounds, Mucus = mucus ?? t.Mucus,
            Newborn = newborn ?? t.Newborn, OssifyAtRound = ossify ?? t.OssifyAtRound,
            SolidLockRound = solidLock ?? t.SolidLockRound, ToxinRound = toxinRound ?? t.ToxinRound
        };
    public static Cell Copy(this Cell c, int? energy = null, HexPosition? position = null, bool? alive = null, int? attacks = null, int? deathRound = null, int? campRound = null, HexPosition? campPosition = null,
        int? draws = null, int? toxin = null, bool? mutateUsed = null, bool? differentiated = null, bool? effectorUsed = null, bool? marked = null, int? markLeft = null, int? markRound = null, int? respawnRound = null,
        IReadOnlyList<string>? hand = null, IReadOnlyList<string>? equipped = null, CellType? type = null, int? playCounter = null, IReadOnlyList<ActiveModifier>? modifiers = null,
        int? antibody = null, bool? metastasis = null, int? jump = null, bool? armor = null,
        IReadOnlyDictionary<string, int>? equipSeq = null,
        IReadOnlyDictionary<string, int>? fxTurn = null, IReadOnlyList<string>? fxRound = null, int? neutralUntil = null)
        => new() { Id = c.Id, OwnerSeat = c.OwnerSeat, Faction = c.Faction, Type = type ?? c.Type, Position = position ?? c.Position, Energy = energy ?? c.Energy,
            IsAlive = alive ?? c.IsAlive, StatusEffects = c.StatusEffects, AttacksThisTurn = attacks ?? c.AttacksThisTurn, DeathRound = deathRound ?? c.DeathRound,
            CampRound = campRound ?? c.CampRound, CampPosition = campPosition ?? c.CampPosition,
            DrawsThisTurn = draws ?? c.DrawsThisTurn, ToxinThisRound = toxin ?? c.ToxinThisRound, MutateUsedThisRound = mutateUsed ?? c.MutateUsedThisRound,
            AntibodyThisRound = antibody ?? c.AntibodyThisRound, MetastasisUsedThisRound = metastasis ?? c.MetastasisUsedThisRound, JumpUsedThisRound = jump ?? c.JumpUsedThisRound,
            ArmorUsedThisRound = armor ?? c.ArmorUsedThisRound,
            Differentiated = differentiated ?? c.Differentiated, EffectorUsed = effectorUsed ?? c.EffectorUsed, Marked = marked ?? c.Marked,
            MarkLeft = markLeft ?? c.MarkLeft, MarkRound = markRound ?? c.MarkRound, RespawnRound = respawnRound ?? c.RespawnRound,
            HandMax = c.HandMax, Hand = hand ?? c.Hand, Equipped = equipped ?? c.Equipped,
            PlayCounter = playCounter ?? c.PlayCounter, EquipSeq = equipSeq ?? c.EquipSeq,
            FxTurn = fxTurn ?? c.FxTurn, FxRound = fxRound ?? c.FxRound,
            NeutralUntil = neutralUntil ?? c.NeutralUntil, Modifiers = modifiers ?? c.Modifiers };
    public static Cell WithEnergy(this Cell c, int energy) => c.Copy(energy: energy);
    public static Cell WithPosition(this Cell c, HexPosition pos) => c.Copy(position: pos);
    public static Cell WithIsAlive(this Cell c, bool alive) => c.Copy(alive: alive);
    /// <summary>Player 的**唯一**一份字段清单（2026-09-15 收口：此前 5 个 With* 各手写了一份 7 字段）。</summary>
    private static Player CopyPlayer(this Player p, bool? alive = null, int? memory = null,
        ImmuneLevel? level = null, int? drawCount = null, CellType? cancerType = null)
        => new()
        {
            Seat = p.Seat, Faction = p.Faction,
            IsAlive = alive ?? p.IsAlive, DrawCount = drawCount ?? p.DrawCount,
            AntigenMemory = memory ?? p.AntigenMemory, ImmuneLevel = level ?? p.ImmuneLevel,
            CancerType = cancerType ?? p.CancerType
        };
    public static Player WithIsAlive(this Player p, bool alive) => p.CopyPlayer(alive: alive);
    public static Player WithAntigenMemory(this Player p, int memory) => p.CopyPlayer(memory: memory);
    public static Player WithImmuneLevel(this Player p, ImmuneLevel level) => p.CopyPlayer(level: level);
    public static Player WithDrawCount(this Player p, int count) => p.CopyPlayer(drawCount: count);
    public static Player WithCancerType(this Player p, CellType type) => p.CopyPlayer(cancerType: type);
    /// <summary>
    /// TurnState 的**唯一**一份字段清单。所有 With* 都从这里出去。
    ///
    /// 2026-09-15 收口：此前 `WithPendingDiscard` / `WithPendingMutation` / `ClearPendingMutation` /
    /// `WithCytokineNetwork` / `WithChemo` 各自手写了一份 19 字段的初始化器 —— 连同这里的 `Copy`
    /// 与 `TurnState.Clone()` 共 **7 份**。七份今天都还是全的，但 `Tissue.WithOccupyingCell`
    /// 当初也是「全的」，直到有人加了两个字段，它就静默清零了 `SolidLockRound` 与 `ToxinRound`。
    ///
    /// 那 5 份之所以存在，是因为 `?? t.X` **表达不了「改成 null」**。
    /// 解法照 `CopyTissue` 的 `setOccupying` 先例：给会被清空的那三处各加一个开关。
    /// 只加真正用到的三个 —— 将来要清 `Winner` 时再加第四个，别现在替未来立规矩。
    /// </summary>
    public static TurnState Copy(this TurnState t, Phase? phase = null, int? seat = null, int? round = null, int? startStep = null, Faction? winner = null, int? alarm = null, int? pendingDiscard = null,
        int? pendingMutationSeat = null, EntityId? pendingMutationCell = null, int? pendingMutationA = null, int? pendingMutationB = null, int? cytokineSeat = null, int? effectorRound = null,
        HexPosition? chemoAt = null, int? chemoRounds = null, int? chemoOwner = null,
        bool setPendingDiscard = false, bool setPendingMutation = false, bool setChemoAt = false)
        => new() { WorldRound = round ?? t.WorldRound, Phase = phase ?? t.Phase, ActivePlayerSeat = seat ?? t.ActivePlayerSeat,
            StartStep = startStep ?? t.StartStep, Winner = winner ?? t.Winner, CancerAlarmRound = alarm ?? t.CancerAlarmRound,
            PendingDiscardSeat = setPendingDiscard ? pendingDiscard : pendingDiscard ?? t.PendingDiscardSeat,
            PendingMutationSeat = setPendingMutation ? pendingMutationSeat : pendingMutationSeat ?? t.PendingMutationSeat,
            PendingMutationCell = setPendingMutation ? pendingMutationCell : pendingMutationCell ?? t.PendingMutationCell,
            PendingMutationA = pendingMutationA ?? t.PendingMutationA, PendingMutationB = pendingMutationB ?? t.PendingMutationB,
            CytokineNetworkSeat = cytokineSeat ?? t.CytokineNetworkSeat,
            EffectorRound = effectorRound ?? t.EffectorRound,
            ChemoAt = setChemoAt ? chemoAt : chemoAt ?? t.ChemoAt,
            ChemoRounds = chemoRounds ?? t.ChemoRounds, ChemoOwner = chemoOwner ?? t.ChemoOwner };
    public static TurnState WithPhase(this TurnState t, Phase p) => t.Copy(phase: p);
    public static TurnState WithActivePlayer(this TurnState t, int seat) => t.Copy(seat: seat);
    public static TurnState WithWorldRound(this TurnState t, int round) => t.Copy(round: round);
    public static TurnState WithPendingDiscard(this TurnState t, int? seat)
        => t.Copy(pendingDiscard: seat, setPendingDiscard: true);
    public static TurnState WithPendingMutation(this TurnState t, int seat, EntityId cell, int a, int b)
        => t.Copy(pendingMutationSeat: seat, pendingMutationCell: cell, pendingMutationA: a, pendingMutationB: b, setPendingMutation: true);
    public static TurnState ClearPendingMutation(this TurnState t)
        => t.Copy(pendingMutationSeat: null, pendingMutationCell: null, pendingMutationA: 0, pendingMutationB: 0, setPendingMutation: true);
    public static TurnState WithCytokineNetwork(this TurnState t, int seat)
        => t.Copy(cytokineSeat: seat);
    public static TurnState WithChemo(this TurnState t, HexPosition? at, int rounds, int owner)
        => t.Copy(chemoAt: at, chemoRounds: rounds, chemoOwner: owner, setChemoAt: true);
    public static WorldState UpdateTissueState(this WorldState s, HexPosition pos, TissueState type) => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithState(type)));
    public static WorldState UpdateTissueOccupant(this WorldState s, HexPosition pos, EntityId? id) => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithOccupyingCell(id)));
    public static WorldState UpdateTissueSolidification(this WorldState s, HexPosition pos, int count) => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithSolidificationCount(count)));
    public static Cell? GetCell(this WorldState s, EntityId id) => s.Cells.TryGetValue(id, out var cell) ? cell : null;
    public static Cell? GetCellAt(this WorldState s, HexPosition pos) => s.Board.Tissues.TryGetValue(pos, out var tissue) && tissue.OccupyingCell is { } id ? s.GetCell(id) : null;
    public static IEnumerable<Cell> GetAliveCells(this WorldState s, Faction? faction = null) => s.Cells.Values.Where(c => c.IsAlive && (faction == null || c.Faction == faction));
    public static IEnumerable<HexPosition> GetAdjacentPositions(this Board b, HexPosition p) => p.GetNeighbors().Where(b.Tissues.ContainsKey);
}
