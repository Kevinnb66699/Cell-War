using System.Text.Json;
using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// 把 <see cref="L0World"/>（schema `cwxworld/2`）装成一个真的 <see cref="WorldState"/>，以及它的逆 <see cref="Dump"/>。
///
/// **一条规矩贯穿全文：认不出来的就炸，不许静默跳过。**
/// 迁移计划专门点过这个坑 ——「loader 只走完三分之一」，
/// 而一个只认一半键的 loader 最坏的地方不是装不上，是**装上了但少了东西**：
/// 用例照样绿，绿得毫无意义。
///
/// **不许在靶场里重写规则**（§0.5 纪律 3）：这里一条算式都没有，缺省值一律指向生产代码里的同一张表
/// （底板走 <see cref="MatchSetup.SpecialAt"/>、事件池走 <see cref="WorldEffects.WorldEventNames"/>、
/// 旋钮走 `game/tests/contract_tune.json`）。
///
/// **装不出来就拒收**（<see cref="UnloadableException"/>）：多免疫席 level/memory 不等、非空 `mods`、
/// `events.pool` 改写、`double_next`、席位解析不出唯一活细胞 —— 逐条见 §0.6.1。
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
        foreach (var at in AllCoords(spec.Radius)) tiles[at] = Baseline(at);

        var named = new HashSet<HexPosition>();
        foreach (var t in spec.Tiles)
        {
            var at = Pos(t.At);
            if (!tiles.ContainsKey(at)) throw new InvalidOperationException($"这一格在半径 {spec.Radius} 的棋盘外：{t.At}");
            if (!named.Add(at)) throw new InvalidOperationException($"同一格写了两次：{t.At}");
            // 省略 type = 棋盘本来的特殊组织（§0.6.1 第 3 条）：点名一格只为改 state，不该顺手把骨髓格洗成普通格
            var type = t.Type is null ? MatchSetup.SpecialAt(at) : TileType(t.Type);
            if (type == TissueType.BoneMarrow ? t.Store != 0 : t.Cards != 0)
                throw new InvalidOperationException($"格 {t.At}：`store` 是代谢核心那类的存量、`cards` 只有骨髓格有（C# 侧同住 Tissue.Charge），写错那个键会静默丢值");
            tiles[at] = new Tissue
            {
                Position = at,
                Type = type,
                State = TileState(t.State),
                SolidificationCount = t.Solid,
                OccupyingCell = null,   // 占位一律从 cells[].at 反推（A-2 规矩 2）；tile 上不再有 cell 键
                Charge = type == TissueType.BoneMarrow ? t.Cards : t.Store,
                ProductionCounter = t.Prod,
                NecrosisRounds = t.Necrosis,
                Mucus = t.Mucus,
                Newborn = t.Newborn,
                OssifyAtRound = t.OssifyAt,
                ToxinRound = t.ToxinRound,
            };
        }

        var cells = new Dictionary<EntityId, Cell>();
        EntityId? chainCell = null;
        foreach (var c in spec.Cells)
        {
            var at = Pos(c.At);
            if (!tiles.ContainsKey(at)) throw new InvalidOperationException($"细胞站在没铺的格上：{c.At}");
            var type = CellKind(c.Type);
            // id = 在 cells 列表里的序号 + 1：与 GD `make_cell(g.cells.size(), …)` 同口径（闸二 2b 靠这个对得上）；席位不再决定 id
            var id = new EntityId((ulong)(cells.Count + 1));
            if (c.Mods.Count > 0)
                throw new UnloadableException($"席位 {c.Seat} 的 `mods` 非空 —— C# 的 `ActiveModifier` 要六项，"
                    + "配不出来就只能在靶场里写第二份规则（纪律 3 不许）。按 E-2 走 `setup_ops` 前奏重放，落在批 5a 的 C-2 步 2");
            // 【标记】三件套：写了 marked 就必须三个都写，loader 一个都不许自己补（A-2 规矩 3）
            var markWritten = (c.Marked is not null ? 1 : 0) + (c.MarkLeft is not null ? 1 : 0) + (c.MarkRound is not null ? 1 : 0);
            if (markWritten is > 0 and < 3)
                throw new InvalidOperationException($"席位 {c.Seat}：写了 `marked` / `mark_left` / `mark_round` 里的一部分 —— 三个要写就一起写，loader 不替人补默认值");
            if (c.Alive)
            {
                if (tiles[at].OccupyingCell is not null) throw new InvalidOperationException($"两只活细胞站在同一格：{c.At}");
                tiles[at] = tiles[at].WithOccupyingCell(id);
            }
            if (c.ChainRunning)
            {
                if (chainCell is not null) throw new InvalidOperationException("两只细胞同时 `chain_running` —— 全局只有一条连锁");
                chainCell = id;
            }
            cells[id] = new Cell
            {
                Id = id,
                OwnerSeat = c.Seat,
                Faction = IsCancer(type) ? Faction.Cancer : Faction.Immune,
                Type = type,
                Position = at,
                Energy = c.Energy,
                IsAlive = c.Alive,
                StatusEffects = Array.Empty<StatusEffect>(),
                Marked = c.Marked ?? false,
                MarkLeft = c.MarkLeft ?? 0,
                MarkRound = c.MarkRound ?? -1,
                EffectorUsed = c.EffectorUsed,
                Hand = c.Hand,
                Equipped = c.Equipped,
                Modifiers = [],
                PlayCounter = c.PlayN,
                EquipSeq = c.EquipSeq,
                FxTurn = c.FxTurn,
                FxRound = c.FxRound,
                Differentiated = c.Differentiated,
                ChemoCooldown = c.ChemoCd,
                ArmorUsedThisRound = c.ArmorUsed,
                MutateUsedThisRound = c.MutateUsed,
                ToxinThisRound = c.ToxinUsed,
                AntibodyThisRound = c.AntibodyUsed,
                MetastasisUsedThisRound = c.MetastasisUsed,
                JumpUsedThisRound = c.JumpUsed,
                DrawsThisTurn = c.DrawsUsed,
                AttacksThisTurn = c.AttacksUsed,
                RespawnRound = c.RespawnRound,
                CampRound = c.CampRound,
                CampPosition = c.CampPos is null ? null : Pos(c.CampPos),
                ChainLeft = c.ChainLeft,
                ChainBonus = c.ChainBonus,
                NeutralUntil = c.NeutralUntil <= 0 ? 0 : c.NeutralUntil,   // 协议 −1 = 从没被压过，C# 内部记 0
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
            // 癌种必填、免疫席不许写、不认 "none"（§0.6.1 第 2 条；C-1 步 7 之前是推不出来就静默拿骨肉瘤兜底）
            if (faction == Faction.Cancer && string.IsNullOrEmpty(p.CancerType))
                throw new InvalidOperationException($"席位 {p.Seat} 是癌席，`cancer_type` 必填（不设 \"none\" 哨兵）");
            if (faction == Faction.Immune && !string.IsNullOrEmpty(p.CancerType))
                throw new InvalidOperationException($"席位 {p.Seat} 是免疫席，不许写 `cancer_type`");
            players[p.Seat] = new Player
            {
                Seat = p.Seat,
                Faction = faction,
                IsAlive = true,
                DrawCount = 0,
                AntigenMemory = p.Memory,
                ImmuneLevel = Level(p.Level),
                CancerType = faction == Faction.Cancer ? CellKind(p.CancerType!) : null,
            };
        }
        // 抗原记忆 / 免疫等级 GD 侧是**阵营级全局量**（E-5）：多免疫席不等的世界 GD 结构上装不出来
        var immune = players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat).ToArray();
        if (immune.Length > 1 && immune.Any(p => p.AntigenMemory != immune[0].AntigenMemory || p.ImmuneLevel != immune[0].ImmuneLevel))
            throw new UnloadableException("多免疫席的 `memory` / `level` 不等 —— GD 那边它们是阵营级全局量，这个世界装不出来（E-5）");

        var events = spec.Events ?? new L0Events();
        if (events.Pool is { } pool && !pool.SequenceEqual(WorldEffects.WorldEventNames))
            throw new UnloadableException("`events.pool` 与全表不同 —— 世界事件整块未迁，C# 的 `ObservationV1Codec` 恒产全表（批 5b 解除）");
        if (events.DoubleNext)
            throw new UnloadableException("`events.double_next` = true —— C# 侧没有落点，恒 false（批 5b 解除）");

        // 终局：`phase` 写 Finished 当且仅当 `winner` 非空（GD 的协议 phase 由 is_over 派生，C# 是 Phase.Finished —— 两侧同一条校验）
        if ((spec.Phase == "Finished") != (spec.Winner != ""))
            throw new UnloadableException($"phase 写 Finished 当且仅当 winner 非空（拿到 phase = {spec.Phase}、winner = {spec.Winner}）");

        var world = new WorldState
        {
            Board = new Board { Radius = spec.Radius, Tissues = tiles },
            Cells = cells,
            Players = players,
            Turn = new TurnState
            {
                WorldRound = spec.Round,
                Phase = PhaseOf(spec.Phase),
                ActivePlayerSeat = spec.Seat,
                Winner = spec.Winner switch
                {
                    "" => null,
                    "immune" => Faction.Immune,
                    "cancer" => Faction.Cancer,
                    var other => throw new InvalidOperationException($"不认识的 winner：{other}（只认 \"\" / immune / cancer）"),
                },
                WinKind = WinKind(spec.WinKind),
                EffectorRound = spec.EffectorRound <= 0 ? 0 : spec.EffectorRound,   // 协议 −1 = 从没发动过，C# 内部记 0
                CancerWinStreak = spec.CancerAlarm?.Streak ?? 0,
                ChemoAt = spec.Chemo is { } ch ? Pos(ch.At) : null,
                ChemoRounds = spec.Chemo?.Left ?? 0,
                ChemoOwner = spec.Chemo?.By ?? -1,
                ChemoCreator = spec.Chemo is { Cid: >= 0 } cc ? LivingOfSeat(cells, cc.Cid, "chemo.cid") : null,
                TrackCell = spec.ChemoTrack is { Cid: >= 0 } tk ? LivingOfSeat(cells, tk.Cid, "chemo_track.cid") : null,
                TrackFrozenAt = spec.ChemoTrack is { Cid: < 0 } dead ? Pos(dead.At) : null,
                TrackRounds = spec.ChemoTrack?.Left ?? 0,
                PendingChainCell = chainCell,
            },
        };
        // `active` 每条挂一条：转调生产入口 `InstallEffect`（纪律 3），`stacks: n` 就是一条 stacks = n
        foreach (var fx in events.Active ?? [])
        {
            world = world.InstallEffect(fx.Name, fx.Left, fx.Stacks,
                fx.Data is null ? null : new Dictionary<string, int>(fx.Data, StringComparer.Ordinal));
            if (fx.Doubled.Length > 0)   // `doubled` 不在 InstallEffect 的形参里，挂完补一手
                world = world.Copy(effects: [.. world.Effects.Take(world.Effects.Count - 1), world.Effects[^1] with { Doubled = fx.Doubled }]);
        }
        return spec.Tuning.Count == 0 ? world : world.WithTuning(Tune(world.Tuning, spec.Tuning));
    }

    /// <summary>
    /// 世界 → `cwxworld/2`。**没有它「只进世界不进文件」的字段永远漏**（`effector_round` 就是这么漏的），
    /// 录制代理也落不了 pre。闸二 2a / 2d 的载体。
    ///
    /// 派生量不回写：`win_reason`（由 `win_kind` 现算）、`differentiated`（由 cells 现算）、
    /// `chain_cell`（= `cells[].chain_running`）、`feed_seq`（不是规则量）—— 它们连键都没有。
    /// tile 只导**与底板不同**的格（同一张默认表：`type` 等于 `MatchSetup.SpecialAt(at)` 时省略）。
    /// </summary>
    public static L0World Dump(WorldState s)
    {
        int SeatOf(EntityId? id) => id is { } v && s.Cells.TryGetValue(v, out var c) ? c.OwnerSeat : -1;
        return new L0World
        {
            Radius = s.Board.Radius,
            Round = s.Turn.WorldRound,
            Phase = s.Turn.Phase.ToString(),
            Seat = s.Turn.ActivePlayerSeat,
            Players = s.Players.Values.OrderBy(p => p.Seat).Select(p => new L0Player(p.Seat,
                p.Faction == Faction.Immune ? "immune" : "cancer", p.ImmuneLevel.ToString(), p.AntigenMemory,
                p.CancerType?.ToString())).ToList(),
            Tiles = s.Board.Tissues.Values.Where(NotBaseline)
                .OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R).Select(DumpTile).ToList(),
            Cells = s.Cells.Values.OrderBy(c => c.Id.Value).Select(c => DumpCell(s, c)).ToList(),
            Winner = s.Turn.Winner is { } w ? (w == Faction.Immune ? "immune" : "cancer") : "",
            WinKind = s.Turn.WinKind,
            EffectorRound = s.Turn.EffectorRound <= 0 ? -1 : s.Turn.EffectorRound,
            Chemo = s.Turn.ChemoAt is { } ca
                ? new L0Chemo(At(ca), s.Turn.ChemoRounds, s.Turn.ChemoOwner, SeatOf(s.Turn.ChemoCreator)) : null,
            ChemoTrack = s.Turn.TrackCell is { } tc ? new L0Track(SeatOf(tc), At(s.Cells[tc].Position), s.Turn.TrackRounds)
                : s.Turn.TrackFrozenAt is { } fa ? new L0Track(-1, At(fa), s.Turn.TrackRounds) : null,
            CancerAlarm = s.Turn.CancerWinStreak == 0 ? null : new L0CancerAlarm(s.Turn.CancerWinStreak),
            Events = s.Effects.Count == 0 ? null : new L0Events(Active: s.Effects
                .Select(e => new L0Effect(e.Name, e.Left, e.Stacks, e.Doubled,
                    e.Data.Count == 0 ? null : new Dictionary<string, int>(e.Data, StringComparer.Ordinal))).ToList()),
            Tuning = DumpTuning(s.Tuning),
        };
    }

    /// <summary>
    /// 按同一张默认表削掉等于默认值的键（§0.6.5 第 1 条）。
    /// **独立实现，不转调 <see cref="Load"/> / <see cref="Dump"/>** —— 转调的话闸二 2a 就成了自己证自己。
    /// 只剩 `at` 的 tile 整条删掉（它什么都没改，等于没点名）。
    /// </summary>
    public static L0World Minify(L0World w)
    {
        var events = w.Events is null ? null : MinifyEvents(w.Events);
        return new L0World
        {
            Radius = w.Radius,
            Round = w.Round,
            Phase = w.Phase,
            Seat = w.Seat,
            Players = w.Players.OrderBy(p => p.Seat).ToList(),
            Tiles = w.Tiles.Where(t => Named(t)).OrderBy(t => Pos(t.At).Q).ThenBy(t => Pos(t.At).R)
                .Select(t => t.Type is { } ty && TileType(ty) == MatchSetup.SpecialAt(Pos(t.At)) ? t with { Type = null } : t).ToList(),
            Cells = w.Cells.Select(MinifyCell).ToList(),
            Winner = w.Winner,
            WinKind = w.WinKind,
            EffectorRound = w.EffectorRound,
            Chemo = w.Chemo,
            ChemoTrack = w.ChemoTrack,
            CancerAlarm = w.CancerAlarm is { Streak: 0 } ? null : w.CancerAlarm,
            Events = events,
            Tuning = new Dictionary<string, int>(w.Tuning, StringComparer.Ordinal),
        };

        // 11 个非 at 键全等于默认值 = 这一格什么都没改，整条删掉（`type` 的默认是 special_of(at)）
        bool Named(L0Tile t)
            => !((t.Type is null || TileType(t.Type) == MatchSetup.SpecialAt(Pos(t.At)))
                && t.State == "healthy" && t.Solid == 0 && !t.Mucus && t.Necrosis == 0 && t.OssifyAt == 0
                && !t.Newborn && t.Store == 0 && t.Cards == 0 && t.Prod == 0 && t.ToxinRound == 0);

        L0Cell MinifyCell(L0Cell c) => c.Marked is null or false && c.MarkLeft is null or 0 && c.MarkRound is null or -1
            ? c with { Marked = null, MarkLeft = null, MarkRound = null } : c;

        L0Events? MinifyEvents(L0Events e)
        {
            var pool = e.Pool is { } p && p.SequenceEqual(WorldEffects.WorldEventNames) ? null : e.Pool;
            // 空 `data` 与没写等价（Dump 也写 null）—— 默认表两侧同：GD dump 同样省略空 data
            var active = e.Active is { Count: 0 } ? null : e.Active?.Select(x => x.Data is { Count: 0 } ? x with { Data = null } : x).ToList();
            return pool is null && active is null && !e.DoubleNext ? null : new L0Events(pool, active, e.DoubleNext);
        }
    }

    private static L0Tile DumpTile(Tissue t) => new(At(t.Position),
        t.State switch { TissueState.Healthy => "healthy", TissueState.Cancer => "cancer", _ => "solid" },
        t.Type == MatchSetup.SpecialAt(t.Position) ? null : TypeWord(t.Type),   // 同一张默认表：等于底板就省略
        t.SolidificationCount, t.Mucus, t.NecrosisRounds, t.OssifyAtRound, t.Newborn,
        t.Type == TissueType.BoneMarrow ? 0 : t.Charge ?? 0,
        t.Type == TissueType.BoneMarrow ? t.Charge ?? 0 : 0,
        t.ProductionCounter, t.ToxinRound);

    private static L0Cell DumpCell(WorldState s, Cell c) => new()
    {
        Seat = c.OwnerSeat, Type = c.Type.ToString(), At = At(c.Position),
        Energy = c.Energy, Alive = c.IsAlive,
        Marked = c.Marked, MarkLeft = c.MarkLeft, MarkRound = c.MarkRound, EffectorUsed = c.EffectorUsed,
        Hand = c.Hand.ToList(), Equipped = c.Equipped.ToList(),
        Mods = c.Modifiers.Select(m => new L0Mod(m.Card, m.Uses,
            m.Duration switch { ModifierDuration.Turn => "turn", ModifierDuration.Round => "round", _ => "" }, m.Sequence)).ToList(),
        PlayN = c.PlayCounter,
        EquipSeq = new Dictionary<string, int>(c.EquipSeq, StringComparer.Ordinal),
        FxTurn = new Dictionary<string, int>(c.FxTurn, StringComparer.Ordinal),
        FxRound = c.FxRound.ToList(),
        Differentiated = c.Differentiated, ChemoCd = c.ChemoCooldown,
        ArmorUsed = c.ArmorUsedThisRound, MutateUsed = c.MutateUsedThisRound, ToxinUsed = c.ToxinThisRound,
        AntibodyUsed = c.AntibodyThisRound, MetastasisUsed = c.MetastasisUsedThisRound, JumpUsed = c.JumpUsedThisRound,
        DrawsUsed = c.DrawsThisTurn, AttacksUsed = c.AttacksThisTurn,
        RespawnRound = c.RespawnRound, CampRound = c.CampRound,
        CampPos = c.CampRound >= 0 && c.CampPosition is { } cp ? At(cp) : null,
        ChainLeft = c.ChainLeft, ChainBonus = c.ChainBonus,
        NeutralUntil = c.NeutralUntil <= 0 ? -1 : c.NeutralUntil,
        ChainRunning = s.Turn.PendingChainCell == c.Id,
    };

    /// <summary>某一席**唯一的活细胞**（0 只或 ≥2 只 ⇒ UNLOADABLE，§0.6.1 第 1 条）。</summary>
    private static EntityId LivingOfSeat(Dictionary<EntityId, Cell> cells, int seat, string where)
    {
        var hits = cells.Values.Where(c => c.OwnerSeat == seat && c.IsAlive).ToArray();
        if (hits.Length != 1)
            throw new UnloadableException($"{where} 写了席位 {seat}，但这一席有 {hits.Length} 只活细胞 —— 「该席唯一的活细胞」解析不出来");
        return hits[0].Id;
    }

    /// <summary>半径内的所有格（与 GD 的 `CWData.all_coords` 同一套：|q|、|r|、|s| 都 ≤ radius）。</summary>
    private static IEnumerable<HexPosition> AllCoords(int radius)
    {
        for (var q = -radius; q <= radius; q++)
            for (var r = Math.Max(-radius, -q - radius); r <= Math.Min(radius, -q + radius); r++)
                yield return new HexPosition(q, r, -q - r);
    }

    /// <summary>底板 = 全健康 + 特殊组织按坐标表（GD `build_board` 走 `CWData.special_of`）。`Dump` / `Minify` 同读这一张。</summary>
    private static Tissue Baseline(HexPosition at) => new()
    {
        Position = at, Type = MatchSetup.SpecialAt(at), State = TissueState.Healthy,
        SolidificationCount = 0, OccupyingCell = null, Charge = 0,
    };

    /// <summary>这一格与底板不同吗（占位不算 —— 它是从 cells 反推的派生量）。</summary>
    private static bool NotBaseline(Tissue t)
    {
        var b = Baseline(t.Position);
        return t.Type != b.Type || t.State != b.State || t.SolidificationCount != 0 || (t.Charge ?? 0) != 0
            || t.ProductionCounter != 0 || t.NecrosisRounds != 0 || t.Mucus || t.Newborn || t.OssifyAtRound != 0 || t.ToxinRound != 0;
    }

    /// <summary>坐标 `"q,r"` → 立方坐标（s 由 q、r 定死）。</summary>
    public static HexPosition Pos(string text)
    {
        var parts = text.Split(',');
        if (parts.Length != 2 || !int.TryParse(parts[0].Trim(), out var q) || !int.TryParse(parts[1].Trim(), out var r))
            throw new InvalidOperationException($"坐标要写成 \"q,r\"，拿到的是 \"{text}\"");
        return new HexPosition(q, r, -q - r);
    }

    public static string At(HexPosition p) => $"{p.Q},{p.R}";

    /// <summary>按席位找细胞（id 不再等于席位 + 1）。</summary>
    public static Cell CellOfSeat(WorldState s, int seat)
        => s.Cells.Values.FirstOrDefault(c => c.OwnerSeat == seat) ?? throw new InvalidOperationException($"要的细胞（席位 {seat}）不在这个盘面上");

    private static bool IsCancer(CellType t)
        => t is CellType.Melanoma or CellType.SignetRing or CellType.Osteosarcoma or CellType.SmallCellLung;

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

    private static string TypeWord(TissueType t) => t switch
    {
        TissueType.Normal => "normal",
        TissueType.MetabolicCore => "core",
        TissueType.BoneMarrow => "marrow",
        _ => "vessel",
    };

    private static string WinKind(string s) => s is "" or "immune_clear" or "cancer_weighted" or "limit_cancer" or "limit_immune"
        ? s
        : throw new InvalidOperationException($"不认识的 win_kind：{s}（只认 \"\" / immune_clear / cancer_weighted / limit_cancer / limit_immune）");

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
    /// 拧旋钮。四档白名单在 `game/tests/contract_tune.json`（两侧同读一份，拒绝的集合必须一样）。
    /// 分档表写下标：`proliferate_per_adjacent[1]`，**1 基**（与 `RuleTuning.ByStage` 同基）。
    /// </summary>
    private static RuleTuning Tune(RuleTuning tune, Dictionary<string, int> knobs)
    {
        foreach (var (key, value) in knobs) tune = WithKnob(tune, key, value);
        return tune;
    }

    /// <summary>
    /// 旋钮按**GD 的名字**（snake_case）认 —— 用例说的是权威那边的话，不是 C# 的属性名。
    ///
    /// **B 档报的是「C# 无对应物」而不是「规则不等价」**（E-3）：
    /// 往这里加「假旋钮」或静默跳过，两条都不许 —— 前者等于在靶场里写第二份规则，后者是假绿灯。
    /// </summary>
    internal static RuleTuning WithKnob(RuleTuning tune, string name, int value)
    {
        var (key, index) = SplitIndex(name);
        switch (TuneTable.Shared.TierOf(key))
        {
            case "B":
                throw new InvalidOperationException(
                    $"旋钮 {key}：**C# 无对应物（E-3）** —— `RuleTuning` 上根本没有这个属性（contract_tune.json 的 B 档）。"
                    + "不许在这里造假旋钮，也不许静默跳过：要么内核补上，要么这条断言留 GD 并挂 OUT_OF_SCOPE");
            case "C":
                throw new InvalidOperationException(
                    $"旋钮 {key} **不在白名单**（contract_tune.json 的 C 档：`headless_test.gd` 从没拧过）—— 真要用先挪进 A′ 并在这里接一行");
            case null:
                throw new InvalidOperationException(
                    $"**未知旋钮** {key} —— contract_tune.json 里没有这一行（两侧同读一份，只改一边会让拒绝集合分叉）");
        }

        if (index is { } i)
            return key switch
            {
                // A′ 的两个分档表（`headless_test.gd` 拧过、C# 有属性没接线）
                "proliferate_per_adjacent" => tune with { ProliferatePerAdjacent = Replace(tune.ProliferatePerAdjacent, key, i, value) },
                "proliferate_per_solid" => tune with { ProliferatePerSolid = Replace(tune.ProliferatePerSolid, key, i, value) },
                // 2026-09-19 进内核（拍板记录 §九）：按免疫等级分档的有氧基数，下标 1 基 = I / II / III / X
                "aerobic_by_level" => tune with { AerobicByLevel = Replace(tune.AerobicByLevel, key, i, value) },
                _ => throw new InvalidOperationException($"旋钮 {key} 还没接下标语法 —— 语法一次定完、用到的先接（A-2 的 A′ 档）"),
            };

        return key switch
        {
            // ---- A 档：已接的 22 个 ----
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
            // ---- A′ 档：有属性、以前没接线的标量 ----
            "anaerobic_block_coef" => tune with { AnaerobicBlockCoef = value },
            // ---- 2026-09-19 进内核的 12 个 + 配件（拍板记录 §九：E-3 补 6 + 待定 6 + aerobic_level_step）----
            "aerobic_level_base" => tune with { AerobicLevelBase = value },
            "aerobic_level_step" => tune with { AerobicLevelStep = value },
            "aerobic_split" => tune with { AerobicSplit = value != 0 },
            "aerobic_split_ref" => tune with { AerobicSplitRef = value },
            "necrosis_aerobic_pct" => tune with { NecrosisAerobicPct = value },
            "anaerobic_on_turn_end" => tune with { AnaerobicOnTurnEnd = value != 0 },
            "world_events_on" => tune with { WorldEventsOn = value != 0 },
            "cancer_win_hold_rounds" => tune with { CancerWinHoldRounds = value },
            "attack_dmg_success" => tune with { AttackDmgSuccess = value },
            "antibody_halve" => tune with { AntibodyHalve = value != 0 },
            "antibody_max_per_round" => tune with { AntibodyMaxPerRound = value },
            "osteo_ossify_cost" => tune with { OsteoOssifyCost = value },
            _ => throw new InvalidOperationException(
                $"旋钮 {key} 在 contract_tune.json 的 A / A′ 档里，但 `WithKnob` 没接 —— 加一行，别绕过去"),
        };
    }

    /// <summary>`proliferate_per_adjacent[1]` → (`proliferate_per_adjacent`, 1)；没下标就是 (name, null)。</summary>
    private static (string Key, int? Index) SplitIndex(string name)
    {
        var open = name.IndexOf('[');
        if (open < 0) return (name, null);
        if (!name.EndsWith(']') || !int.TryParse(name[(open + 1)..^1], out var i))
            throw new InvalidOperationException($"分档表的下标要写成 `名字[1]`（1 基），拿到的是 {name}");
        return (name[..open], i);
    }

    private static IReadOnlyList<int> Replace(IReadOnlyList<int> table, string key, int oneBased, int value)
    {
        if (oneBased < 1 || oneBased > table.Count)
            throw new InvalidOperationException($"{key} 只有 {table.Count} 档，下标 {oneBased} 越界（1 基）");
        var copy = table.ToArray();
        copy[oneBased - 1] = value;
        return copy;
    }

    /// <summary>与 <see cref="WithKnob"/> 互为逆：与 PRD 缺省不同的旋钮逐个写回 GD 的名字。</summary>
    public static Dictionary<string, int> DumpTuning(RuleTuning t)
    {
        var d = RuleTuning.Default;
        var outp = new Dictionary<string, int>(StringComparer.Ordinal);
        void N(string name, int a, int b) { if (a != b) outp[name] = a; }
        void B(string name, bool a, bool b) { if (a != b) outp[name] = a ? 1 : 0; }
        void T(string name, IReadOnlyList<int> a, IReadOnlyList<int> b)
        {
            for (var i = 0; i < a.Count; i++) if (i >= b.Count || a[i] != b[i]) outp[$"{name}[{i + 1}]"] = a[i];
        }
        N("cancer_move_cancerous", t.CancerMoveCancerous, d.CancerMoveCancerous);
        N("cancer_move_healthy", t.CancerMoveHealthy, d.CancerMoveHealthy);
        N("sclc_move_healthy", t.SclcMoveHealthy, d.SclcMoveHealthy);
        N("pseudopod_cost", t.PseudopodCost, d.PseudopodCost);
        N("mucus_move_surcharge", t.MucusMoveSurcharge, d.MucusMoveSurcharge);
        N("metastasis_cost", t.MetastasisCost, d.MetastasisCost);
        N("metastasis_max_per_round", t.MetastasisMaxPerRound, d.MetastasisMaxPerRound);
        N("immune_respawn_delay", t.ImmuneRespawnDelay, d.ImmuneRespawnDelay);
        N("macro_heal_purify", t.MacroHealPurify, d.MacroHealPurify);
        N("counter_dmg_on_fail", t.CounterDamageOnFail, d.CounterDamageOnFail);
        N("attack_max_per_turn", t.AttackMaxPerTurn, d.AttackMaxPerTurn);
        N("anaerobic_solid_bonus", t.AnaerobicSolidBonus, d.AnaerobicSolidBonus);
        N("anaerobic_floor", t.AnaerobicFloor, d.AnaerobicFloor);
        N("anaerobic_cap", t.AnaerobicCap, d.AnaerobicCap);
        B("anaerobic_split", t.AnaerobicSplit, d.AnaerobicSplit);
        B("newborn_protect", t.NewbornProtect, d.NewbornProtect);
        N("cancer_upkeep_pct", t.CancerUpkeepPercent, d.CancerUpkeepPercent);
        N("energy_cap", t.EnergyCap, d.EnergyCap);
        N("overload_threshold", t.OverloadThreshold, d.OverloadThreshold);
        N("overload_div", t.OverloadDiv, d.OverloadDiv);
        N("overload_exp", t.OverloadExp, d.OverloadExp);
        N("overload_cap", t.OverloadCap, d.OverloadCap);
        N("anaerobic_block_coef", t.AnaerobicBlockCoef, d.AnaerobicBlockCoef);
        T("proliferate_per_adjacent", t.ProliferatePerAdjacent, d.ProliferatePerAdjacent);
        T("proliferate_per_solid", t.ProliferatePerSolid, d.ProliferatePerSolid);
        // 2026-09-19 进内核的 13 个（与 WithKnob 同表）
        N("aerobic_level_base", t.AerobicLevelBase, d.AerobicLevelBase);
        N("aerobic_level_step", t.AerobicLevelStep, d.AerobicLevelStep);
        B("aerobic_split", t.AerobicSplit, d.AerobicSplit);
        N("aerobic_split_ref", t.AerobicSplitRef, d.AerobicSplitRef);
        N("necrosis_aerobic_pct", t.NecrosisAerobicPct, d.NecrosisAerobicPct);
        B("anaerobic_on_turn_end", t.AnaerobicOnTurnEnd, d.AnaerobicOnTurnEnd);
        B("world_events_on", t.WorldEventsOn, d.WorldEventsOn);
        N("cancer_win_hold_rounds", t.CancerWinHoldRounds, d.CancerWinHoldRounds);
        N("attack_dmg_success", t.AttackDmgSuccess, d.AttackDmgSuccess);
        B("antibody_halve", t.AntibodyHalve, d.AntibodyHalve);
        N("antibody_max_per_round", t.AntibodyMaxPerRound, d.AntibodyMaxPerRound);
        N("osteo_ossify_cost", t.OsteoOssifyCost, d.OsteoOssifyCost);
        T("aerobic_by_level", t.AerobicByLevel, d.AerobicByLevel);
        return outp;
    }

    /// <summary>
    /// 旋钮四档白名单（§0.6.3）：`{"schema":"cwxtune/1","knobs":[{name,tier,gd,cs,in_rule_fields,note} × 65]}`。
    /// **两侧同读 `game/tests/contract_tune.json` 一份**，按 `tier` 分桶，不再各写一张桶表 ——
    /// 拒绝的集合必须一样，否则「拧了个寂寞」在一边绿一边红。
    /// </summary>
    internal sealed class TuneTable
    {
        public static readonly TuneTable Shared = Read();

        private readonly Dictionary<string, string> tier = new(StringComparer.Ordinal);

        /// <summary>name → tier（`A` / `A'` / `B` / `C`）；表外返回 null。</summary>
        public string? TierOf(string key) => tier.GetValueOrDefault(key);

        public IReadOnlyDictionary<string, string> Tiers => tier;

        public static string Path() => System.IO.Path.Combine(L0RunnerTests.GameTestsDir(), "contract_tune.json");

        private static TuneTable Read()
        {
            var path = Path();
            if (!File.Exists(path))
                throw new FileNotFoundException($"缺旋钮白名单 {path} —— 两侧同读一份（§0.6.3）", path);
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            if (root.GetProperty("schema").GetString() != "cwxtune/1")
                throw new InvalidOperationException($"{path} 的 schema 不是 cwxtune/1");
            var w = new TuneTable();
            foreach (var row in root.GetProperty("knobs").EnumerateArray())
            {
                var name = row.GetProperty("name").GetString()!;
                var t = row.GetProperty("tier").GetString()!;
                if (t is not ("A" or "A'" or "B" or "C")) throw new InvalidOperationException($"{name} 的 tier 是 {t}（只认 A / A' / B / C）");
                if (!w.tier.TryAdd(name, t == "A'" ? "A" : t)) throw new InvalidOperationException($"contract_tune.json 里 {name} 写了两行");
            }
            return w;
        }
    }
}

/// <summary>
/// **装不出来就拒收，不许编**（§0.6.1 第 7 条）：spec 表达得了、但 C# 的世界结构上装不下的那些。
/// 与「用例写错了」（<see cref="InvalidOperationException"/>）分开报 —— 两个 runner 单列这一档计数并整体红，
/// **仓库用例集里不许有装不进的用例**；只有收割器拿它跳条目。
/// </summary>
public sealed class UnloadableException(string detail) : Exception("UNLOADABLE：" + detail);
