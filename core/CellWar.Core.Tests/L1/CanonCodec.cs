using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// `WorldState` ↔ <see cref="CanonState"/> 的双向转换。
///
/// **它的正确性由一条测试定义**：`w → To → From → w'`，两边的**全量 JSON 逐字节相同**。
/// 不是「canon 覆盖的字段相等」—— 那样在缺失的字段上必然空过（对拍规格点名的坑）。
/// 少搬一个字段，那条测试立刻把字段名打给你。
/// </summary>
public static class CanonCodec
{
    public static CanonState To(WorldState s) => new()
    {
        Board = new CanonBoard(s.Board.Radius,
            s.Board.Tissues.Values.OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R).Select(t => new CanonTile(
                Pos(t.Position), (int)t.State, (int)t.Type, t.SolidificationCount,
                t.OccupyingCell is { } id ? Seat(id) : -1,
                t.NecrosisRounds, t.Mucus, t.Newborn, t.OssifyAtRound, t.ToxinRound,
                t.Charge ?? 0, t.ProductionCounter)).ToList()),

        Cells = s.Cells.Values.OrderBy(c => c.Id.Value).Select(c => new CanonCell(
            c.OwnerSeat, Pos(c.Position), (int)c.Faction,
            c.Faction == Faction.Immune ? (int)c.Type : -1,
            c.Faction == Faction.Cancer ? (int)c.Type : -1,
            c.Energy, c.IsAlive, c.DeathRound, c.AttacksThisTurn, c.DrawsThisTurn, c.ToxinThisRound,
            c.MutateUsedThisRound, c.AntibodyThisRound, c.MetastasisUsedThisRound, c.JumpUsedThisRound,
            c.ArmorUsedThisRound, c.Differentiated, c.EffectorUsed,
            c.Marked, c.MarkLeft, c.MarkRound, c.RespawnRound, c.CampRound, PosOrNull(c.CampPosition),
            c.HandMax, c.PlayCounter, c.NeutralUntil, c.ChemoCooldown, c.ChainLeft, c.ChainBonus)
        {
            Hand = c.Hand.ToList(),
            Equipped = c.Equipped.ToList(),
            EquipSeq = c.EquipSeq.ToDictionary(kv => kv.Key, kv => kv.Value),
            FxTurn = c.FxTurn.ToDictionary(kv => kv.Key, kv => kv.Value),
            FxRound = c.FxRound.ToList(),
            Mods = c.Modifiers.Select(m => new CanonMod(m.Card, (int)m.Target, (int)m.Stage, (int)m.Layer,
                m.Sequence, m.Value, m.Floor, m.Uses, (int)m.Duration, (int)m.Requirement)).ToList(),
        }).ToList(),

        G = new CanonGlobal(s.Turn.WorldRound, (int)s.Turn.Phase, s.Turn.ActivePlayerSeat,
            s.Players.Values.Where(p => p.Faction == Faction.Immune).Select(p => p.AntigenMemory).FirstOrDefault(),
            (int)s.Players.Values.Where(p => p.Faction == Faction.Immune).Select(p => p.ImmuneLevel).FirstOrDefault(ImmuneLevel.I),
            s.Turn.StartStep, s.Turn.Winner is { } w ? (int)w : null, s.Turn.CancerAlarmRound,
            s.Turn.PendingDiscardSeat,
            s.Turn.PendingMutationSeat, s.Turn.PendingMutationCell is { } pm ? Seat(pm) : null,
            s.Turn.PendingMutationA, s.Turn.PendingMutationB,
            s.Turn.EffectorRound,
            PosOrNull(s.Turn.ChemoAt), s.Turn.ChemoRounds, s.Turn.ChemoOwner,
            s.Turn.ChemoCreator is { } cc ? Seat(cc) : null,
            s.Turn.TrackCell is { } tc ? Seat(tc) : null, PosOrNull(s.Turn.TrackFrozenAt), s.Turn.TrackRounds,
            s.Turn.PendingChainCell is { } pc ? Seat(pc) : null,
            s.Turn.PendingChemotaxisCell is { } px ? Seat(px) : null, s.Turn.ChemotaxisStepsLeft, s.Turn.PendingWalkCard ?? "",
            s.Turn.CardResolveDepth, s.Turn.PendingCard ?? "", s.Turn.PendingCardCell is { } pcc ? Seat(pcc) : null,
            s.Turn.CancerReviveFrom,
            s.Turn.PendingCoupleCell is { } cp1 ? Seat(cp1) : null, s.Turn.PendingCoupleAlly is { } cp2 ? Seat(cp2) : null,
            s.Turn.PendingCouplePayer is { } cp3 ? Seat(cp3) : null)
        {
            PendingDiscardCell = s.Turn.PendingDiscardCell is { } pdc ? Seat(pdc) : null,
            PendingRemodelCell = s.Turn.PendingRemodelCell is { } prc ? Seat(prc) : null,
            PendingRemodelFirst = PosOrNull(s.Turn.PendingRemodelFirst), PendingRemodelSecond = PosOrNull(s.Turn.PendingRemodelSecond),
            PendingRemodelStep = s.Turn.PendingRemodelStep,
            PendingLandCell = s.Turn.PendingLandCell is { } plc ? Seat(plc) : null,
            PendingLandAt = PosOrNull(s.Turn.PendingLandAt), PendingLandWalkDepth = s.Turn.PendingLandWalkDepth, PendingLandStep = s.Turn.PendingLandStep,
            EndStep = s.Turn.EndStep, PendingChainWalkDepth = s.Turn.PendingChainWalkDepth,
            WalkOuter = s.Turn.WalkOuter.Select(f => new CanonWalkFrame(Seat(f.Cell), f.StepsLeft, f.Card)).ToList(),
            PendingMarrow = s.Turn.PendingMarrow.Select(Pos).ToList(), PendingMarrowWalkDepth = s.Turn.PendingMarrowWalkDepth,
            Players = s.Players.Values.OrderBy(p => p.Seat).Select(p => new CanonPlayer(
                p.Seat, (int)p.Faction, p.IsAlive, p.DrawCount, p.AntigenMemory, (int)p.ImmuneLevel,
                p.CancerType is { } ct ? (int)ct : null)).ToList(),
        },

        Events = s.Effects.Select(e => new CanonEffect(e.Name, e.Left, e.Stacks, e.Doubled,
            e.Data.ToDictionary(kv => kv.Key, kv => kv.Value))).ToList(),

        Tune = TuneToCanon(s.Tuning),
    };

    public static WorldState From(CanonState c)
    {
        var tiles = c.Board.Tiles.ToDictionary(t => Pos(t.At), t => new Tissue
        {
            Position = Pos(t.At),
            Type = (TissueType)t.Special,
            State = (TissueState)t.Tissue,
            SolidificationCount = t.Solid,
            OccupyingCell = t.Cell >= 0 ? Id(t.Cell) : null,
            Charge = t.Store,
            ProductionCounter = t.Prod,
            NecrosisRounds = t.Necrosis,
            Mucus = t.Mucus,
            Newborn = t.Newborn,
            OssifyAtRound = t.OssifyAt,
            ToxinRound = t.ToxinRound,
        });

        var cells = c.Cells.ToDictionary(x => Id(x.Pid), x => new Cell
        {
            Id = Id(x.Pid),
            OwnerSeat = x.Pid,
            Faction = (Faction)x.Faction,
            Type = (CellType)(x.Faction == (int)Faction.Immune ? x.IType : x.CType),
            Position = Pos(x.Pos),
            Energy = x.Energy,
            IsAlive = x.Alive,
            StatusEffects = Array.Empty<StatusEffect>(),
            DeathRound = x.DeathRound,
            AttacksThisTurn = x.AttacksUsed,
            DrawsThisTurn = x.DrawsUsed,
            ToxinThisRound = x.ToxinUsed,
            MutateUsedThisRound = x.MutateUsed,
            AntibodyThisRound = x.AntibodyUsed,
            MetastasisUsedThisRound = x.MetastasisUsed,
            JumpUsedThisRound = x.JumpUsed,
            ArmorUsedThisRound = x.ArmorUsed,
            Differentiated = x.Differentiated,
            EffectorUsed = x.EffectorUsed,
            Marked = x.Marked,
            MarkLeft = x.MarkLeft,
            MarkRound = x.MarkRound,
            RespawnRound = x.RespawnRound,
            CampRound = x.CampRound,
            CampPosition = PosOrNull(x.CampPos),
            HandMax = x.HandMax,
            PlayCounter = x.PlayN,
            NeutralUntil = x.NeutralUntil,
            ChemoCooldown = x.ChemoCd,
            ChainLeft = x.ChainLeft,
            ChainBonus = x.ChainBonus,
            Hand = x.Hand,
            Equipped = x.Equipped,
            EquipSeq = x.EquipSeq,
            FxTurn = x.FxTurn,
            FxRound = x.FxRound,
            Modifiers = x.Mods.Select(m => new ActiveModifier(m.Name, (ModifierTarget)m.Target,
                (ModifierStage)m.Stage, (SourceLayer)m.Layer, m.Seq, m.Value, m.Floor, m.Uses,
                (ModifierDuration)m.Until, (ModifierRequirement)m.Requirement)).ToList(),
        });

        var players = c.G.Players.ToDictionary(p => p.Seat, p => new Player
        {
            Seat = p.Seat,
            Faction = (Faction)p.Faction,
            IsAlive = p.Alive,
            DrawCount = p.DrawCount,
            AntigenMemory = p.Memory,
            ImmuneLevel = (ImmuneLevel)p.Level,
            CancerType = p.CType is { } ct ? (CellType)ct : null,
        });

        return new WorldState
        {
            Board = new Board { Radius = c.Board.Radius, Tissues = tiles },
            Cells = cells,
            Players = players,
            Effects = c.Events.Select(e => new ActiveEffect(e.Name, e.Left, e.Stacks, e.Doubled) { Data = e.Data }).ToList(),
            Tuning = TuneFromCanon(c.Tune),
            Turn = new TurnState
            {
                WorldRound = c.G.RoundNo,
                Phase = (Phase)c.G.Phase,
                ActivePlayerSeat = c.G.CurrentPid,
                StartStep = c.G.StartStep,
                Winner = c.G.Winner is { } w ? (Faction)w : null,
                CancerAlarmRound = c.G.CancerAlarmRound,
                PendingDiscardSeat = c.G.PendingDiscardPid,
                PendingDiscardCell = c.G.PendingDiscardCell is { } pdc ? Id(pdc) : null,
                PendingMutationSeat = c.G.PendingMutationPid,
                PendingMutationCell = c.G.PendingMutationCell is { } pm ? Id(pm) : null,
                PendingMutationA = c.G.PendingMutationA,
                PendingMutationB = c.G.PendingMutationB,
                EffectorRound = c.G.EffectorRound,
                ChemoAt = PosOrNull(c.G.ChemoAt),
                ChemoRounds = c.G.ChemoRounds,
                ChemoOwner = c.G.ChemoOwner,
                ChemoCreator = c.G.ChemoCreator is { } cc ? Id(cc) : null,
                TrackCell = c.G.TrackCell is { } tc ? Id(tc) : null,
                TrackFrozenAt = PosOrNull(c.G.TrackFrozenAt),
                TrackRounds = c.G.TrackRounds,
                PendingChainCell = c.G.PendingChainCell is { } pc ? Id(pc) : null,
                PendingChemotaxisCell = c.G.PendingChemotaxisCell is { } px ? Id(px) : null,
                ChemotaxisStepsLeft = c.G.ChemotaxisStepsLeft,
                PendingWalkCard = c.G.PendingWalkCard == "" ? null : c.G.PendingWalkCard,
                WalkOuter = c.G.WalkOuter.Select(f => new WalkFrame(Id(f.Cell), f.StepsLeft, f.Card)).ToArray(),
                PendingMarrow = c.G.PendingMarrow.Select(Pos).ToArray(),
                PendingMarrowWalkDepth = c.G.PendingMarrowWalkDepth,
                CardResolveDepth = c.G.CardResolveDepth,
                PendingCard = c.G.PendingCard == "" ? null : c.G.PendingCard,
                PendingCardCell = c.G.PendingCardCell is { } pcc ? Id(pcc) : null,
                CancerReviveFrom = c.G.CancerReviveFrom,
                PendingCoupleCell = c.G.PendingCoupleCell is { } cp1 ? Id(cp1) : null,
                PendingCoupleAlly = c.G.PendingCoupleAlly is { } cp2 ? Id(cp2) : null,
                PendingCouplePayer = c.G.PendingCouplePayer is { } cp3 ? Id(cp3) : null,
                PendingRemodelCell = c.G.PendingRemodelCell is { } prc ? Id(prc) : null,
                PendingRemodelFirst = PosOrNull(c.G.PendingRemodelFirst),
                PendingRemodelSecond = PosOrNull(c.G.PendingRemodelSecond),
                PendingRemodelStep = c.G.PendingRemodelStep,
                PendingLandCell = c.G.PendingLandCell is { } plc ? Id(plc) : null,
                PendingLandAt = PosOrNull(c.G.PendingLandAt),
                PendingLandWalkDepth = c.G.PendingLandWalkDepth,
                PendingLandStep = c.G.PendingLandStep,
                EndStep = c.G.EndStep, PendingChainWalkDepth = c.G.PendingChainWalkDepth,
            },
        };
    }

    // ---- 旋钮：键名用 GD 的（与 L0 用例表同一套词） ----
    private static Dictionary<string, int> TuneToCanon(RuleTuning t) => new()
    {
        ["cancer_move_cancerous"] = t.CancerMoveCancerous,
        ["cancer_move_healthy"] = t.CancerMoveHealthy,
        ["sclc_move_healthy"] = t.SclcMoveHealthy,
        ["pseudopod_cost"] = t.PseudopodCost,
        ["mucus_move_surcharge"] = t.MucusMoveSurcharge,
        ["metastasis_cost"] = t.MetastasisCost,
        ["metastasis_max_per_round"] = t.MetastasisMaxPerRound,
        ["immune_respawn_delay"] = t.ImmuneRespawnDelay,
        ["macro_heal_purify"] = t.MacroHealPurify,
        ["counter_dmg_on_fail"] = t.CounterDamageOnFail,
        ["attack_max_per_turn"] = t.AttackMaxPerTurn,
        ["anaerobic_solid_bonus"] = t.AnaerobicSolidBonus,
        ["anaerobic_floor"] = t.AnaerobicFloor,
        ["anaerobic_cap"] = t.AnaerobicCap,
        ["anaerobic_split"] = t.AnaerobicSplit ? 1 : 0,
        ["newborn_protect"] = t.NewbornProtect ? 1 : 0,
        ["cancer_upkeep_pct"] = t.CancerUpkeepPercent,
        ["energy_cap"] = t.EnergyCap,
        ["overload_threshold"] = t.OverloadThreshold,
        ["overload_div"] = t.OverloadDiv,
        ["overload_exp"] = t.OverloadExp,
        ["overload_cap"] = t.OverloadCap,
    };

    private static RuleTuning TuneFromCanon(Dictionary<string, int> k) => RuleTuning.Default with
    {
        CancerMoveCancerous = k["cancer_move_cancerous"],
        CancerMoveHealthy = k["cancer_move_healthy"],
        SclcMoveHealthy = k["sclc_move_healthy"],
        PseudopodCost = k["pseudopod_cost"],
        MucusMoveSurcharge = k["mucus_move_surcharge"],
        MetastasisCost = k["metastasis_cost"],
        MetastasisMaxPerRound = k["metastasis_max_per_round"],
        ImmuneRespawnDelay = k["immune_respawn_delay"],
        MacroHealPurify = k["macro_heal_purify"],
        CounterDamageOnFail = k["counter_dmg_on_fail"],
        AttackMaxPerTurn = k["attack_max_per_turn"],
        AnaerobicSolidBonus = k["anaerobic_solid_bonus"],
        AnaerobicFloor = k["anaerobic_floor"],
        AnaerobicCap = k["anaerobic_cap"],
        AnaerobicSplit = k["anaerobic_split"] != 0,
        NewbornProtect = k["newborn_protect"] != 0,
        CancerUpkeepPercent = k["cancer_upkeep_pct"],
        EnergyCap = k["energy_cap"],
        OverloadThreshold = k["overload_threshold"],
        OverloadDiv = k["overload_div"],
        OverloadExp = k["overload_exp"],
        OverloadCap = k["overload_cap"],
    };

    private static string Pos(HexPosition p) => $"{p.Q},{p.R}";
    private static string PosOrNull(HexPosition? p) => p is { } v ? Pos(v) : "";
    private static HexPosition Pos(string text)
    {
        var parts = text.Split(',');
        var q = int.Parse(parts[0]);
        var r = int.Parse(parts[1]);
        return new HexPosition(q, r, -q - r);
    }
    private static HexPosition? PosOrNull(string text) => text == "" ? null : Pos(text);

    /// <summary>席位 ↔ 细胞 id（对拍规格：`EntityId = seat + 1`）。</summary>
    private static EntityId Id(int seat) => new((ulong)(seat + 1));
    private static int Seat(EntityId id) => (int)id.Value - 1;
}
