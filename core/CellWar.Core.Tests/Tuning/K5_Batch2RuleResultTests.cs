using CellWar.Core;

namespace CellWar.Core.Tests.Tuning;

/// <summary>
/// K5 · 批 2 第二段 P1 的**四处规则结果差**（口径一补充口径：差的是规则结果就合、签名不变）。
/// 每一组都先钉「默认旋钮下与改前逐位相同」，再钉「非默认档上与 GD 同值」——
/// 因为这四处的验收条件正是「默认旋钮下零行为改动」。
///
///   ① <see cref="CellRules.AddMemory"/> 的门槛表（GD `CWData.level_min_memory`，空档 immune-level-threshold-table）；
///   ② <see cref="RulePolicies.AerobicBase"/> 的**按人数分档**与**盘面式**（空档 aerobic-board-formula-not-migrated）；
///   ③ <see cref="RulePolicies.AerobicShare"/> 的 floor / cap 夹钳（空档 aerobic-floor-cap-not-migrated）；
///   ④ <see cref="RulePolicies.SplitShare"/> 的 `count &lt;= 0`（空档 split-share-count-zero）。
///
/// GD 原文：`cw_game.gd:gain_memory` / `cw_data.gd:level_min_memory` / `cw_world.gd:_aerobic_base`
/// / `cw_world.gd:aerobic_share` / `cw_tuning.gd:clamp_income` / `cw_world.gd:_split_share`。
/// </summary>
public class K5Batch2RuleResultTests
{
    // ======== ① 抗原记忆门槛表：GD CWData.level_min_memory(n_players) ========

    /// <summary>四人档 `[0,10,20,50]`、其余（含 **2 人**与 balance_scan 的 5 / 7 人）走缺省的六人档 `[0,10,30,70]`。
    /// 2 人局那两行就是本批要合的分叉：此前 C# 行内 `Count==6 ? 70/30 : 50/20` 给 2 人局发的是四人档。</summary>
    [Theory]
    // 2 人局（L0 的绝大多数盘面）：20 还在 II、30 才 III；50 还在 III、70 才 X
    [InlineData(2, 19, ImmuneLevel.II)]
    [InlineData(2, 20, ImmuneLevel.II)]
    [InlineData(2, 29, ImmuneLevel.II)]
    [InlineData(2, 30, ImmuneLevel.III)]
    [InlineData(2, 69, ImmuneLevel.III)]
    [InlineData(2, 70, ImmuneLevel.X)]
    // 四人局：20 → III、50 → X
    [InlineData(4, 19, ImmuneLevel.II)]
    [InlineData(4, 20, ImmuneLevel.III)]
    [InlineData(4, 49, ImmuneLevel.III)]
    [InlineData(4, 50, ImmuneLevel.X)]
    // 六人局：30 → III、70 → X
    [InlineData(6, 29, ImmuneLevel.II)]
    [InlineData(6, 30, ImmuneLevel.III)]
    [InlineData(6, 69, ImmuneLevel.III)]
    [InlineData(6, 70, ImmuneLevel.X)]
    // 表里没有的人数（balance_scan 会扫）退回缺省的六人档
    [InlineData(5, 20, ImmuneLevel.II)]
    [InlineData(5, 30, ImmuneLevel.III)]
    [InlineData(7, 69, ImmuneLevel.III)]
    [InlineData(7, 70, ImmuneLevel.X)]
    public void 免疫等级门槛按人数分档(int seats, int gained, ImmuneLevel expected)
    {
        var after = CellRules.AddMemory(Seats(seats), gained);
        Assert.Equal(expected, after.Players[0].ImmuneLevel);
    }

    /// <summary>I 级的门槛是 0、II 级两张表都是 10 —— 分档只在 III / X 两级上分叉。</summary>
    [Theory]
    [InlineData(2)]
    [InlineData(4)]
    [InlineData(6)]
    public void 前两级的门槛两张表一样(int seats)
    {
        Assert.Equal(ImmuneLevel.I, CellRules.AddMemory(Seats(seats), 9).Players[0].ImmuneLevel);
        Assert.Equal(ImmuneLevel.II, CellRules.AddMemory(Seats(seats), 10).Players[0].ImmuneLevel);
    }

    /// <summary>GD：升到 X 那一次 `memory = 0`（「抗原记忆升级为【效应记忆】重新从零计数」），
    /// 已经是 X 级之后再加就**不再清零**（那时 memory 的语义已经是效应记忆）。</summary>
    [Fact]
    public void 升到X级就地清零且只清一次()
    {
        var atX = CellRules.AddMemory(Seats(2), 70);
        Assert.Equal(ImmuneLevel.X, atX.Players[0].ImmuneLevel);
        Assert.Equal(0, atX.Players[0].AntigenMemory);

        var more = CellRules.AddMemory(atX, 15);
        Assert.Equal(ImmuneLevel.X, more.Players[0].ImmuneLevel);
        Assert.Equal(15, more.Players[0].AntigenMemory);
    }

    /// <summary>GD 的 `while` 从**当前等级**往上走 ⇒ 等级只升不降：先手动降低记忆也不会掉级。</summary>
    [Fact]
    public void 等级只升不降()
    {
        var atIII = CellRules.AddMemory(Seats(2), 30);
        Assert.Equal(ImmuneLevel.III, atIII.Players[0].ImmuneLevel);
        var drained = CellRules.ReduceMemory(atIII, 30);
        Assert.Equal(0, drained.Players[0].AntigenMemory);
        Assert.Equal(ImmuneLevel.III, CellRules.AddMemory(drained, 1).Players[0].ImmuneLevel);
    }

    /// <summary>门槛表逐字等于 GD 的两张常量表（改了 `CWData` 就该红在这里）。
    /// GD 录出（2026-09-19）：`CWData.level_min_memory(n)` 对 n = 1/2/3/5/6/7 都是 [0,10,30,70]，n = 4 是 [0,10,20,50]。</summary>
    [Fact]
    public void 门槛表逐字等于GD的两张常量表()
    {
        Assert.Equal(new[] { 0, 10, 30, 70 }, CellRules.LevelMinMemory);              // CWData.LEVEL_MIN_MEMORY
        Assert.Equal(new[] { 4 }, CellRules.LevelMinMemoryByPlayers.Keys);            // 只有四人一档
        Assert.Equal(new[] { 0, 10, 20, 50 }, CellRules.LevelMinMemoryByPlayers[4]);  // CWData.LEVEL_MIN_MEMORY_BY_PLAYERS
    }

    // ======== ② AerobicBase：按人数分档 + 盘面式 ========

    /// <summary>缺省旋钮（`aerobic_by_level` 非空）永远走表档 —— 本批加的两条分支一步也走不到。</summary>
    [Theory]
    [InlineData(ImmuneLevel.I, 20)]
    [InlineData(ImmuneLevel.II, 30)]
    [InlineData(ImmuneLevel.III, 45)]
    [InlineData(ImmuneLevel.X, 50)]
    public void 缺省旋钮下有氧基准仍是查表(ImmuneLevel level, int expected)
    {
        var s = AerobicWorld(seats: 2, healthy: 40, necrotic: 7, level: level);
        Assert.Equal(expected, RulePolicies.AerobicBase(s, s.Cells[new EntityId(1)]));
    }

    /// <summary>`aerobic_level_base = -1` ⇒ 按人数取基数（GD `CWData.aerobic_level_base`：2 人 2.0 / 4 人 2.0 / 6 人 1.8，
    /// 表里没有的人数退回 `AEROBIC_LEVEL_BASE` = 2.0），再 `+ step × 等级`。</summary>
    [Theory]
    [InlineData(2, ImmuneLevel.I, 20)]
    [InlineData(4, ImmuneLevel.I, 20)]
    [InlineData(6, ImmuneLevel.I, 18)]
    [InlineData(5, ImmuneLevel.I, 20)]   // 表里没有 ⇒ 缺省 2.0
    [InlineData(6, ImmuneLevel.II, 33)]  // 1.8 + 1.5 × 1
    [InlineData(6, ImmuneLevel.X, 63)]   // 1.8 + 1.5 × 3
    [InlineData(4, ImmuneLevel.III, 50)] // 2.0 + 1.5 × 2
    public void 有氧基准按人数分档(int seats, ImmuneLevel level, int expected)
    {
        var s = AerobicWorld(seats, healthy: 40, necrotic: 7, level: level,
            tune: t => t with { AerobicByLevel = [], AerobicLevelBase = -1 });
        Assert.Equal(expected, RulePolicies.AerobicBase(s, s.Cells[new EntityId(1)]));
    }

    /// <summary>`aerobic_level_base = 0` ⇒ 退回盘面式 `round_tenth((健康 − 坏死) × aerobic_mult, TOTAL_TILES)`。
    /// **坏死格要扣**（它是健康组织但不为免疫供能）、**分母是常量 127** 而不是「这张盘面有几格」。
    ///
    /// 期望是 **GD 录出来的**（Godot 4.5 headless，2026-09-19 跑
    /// `CWData.round_tenth((h−n) × CWData.AEROBIC_MULT, CWData.TOTAL_TILES)`），不是抄 C# 今天算出多少；
    /// 另再和同一条算式的 C# 逐字对应物对一遍。</summary>
    [Theory]
    [InlineData(40, 0, 9)]     // GD：(40−0)×30 = 1200 → (1200+63)/127 = 9
    [InlineData(40, 7, 8)]     // GD：(40−7)×30 =  990 → (990+63)/127 = 8
    [InlineData(12, 2, 2)]     // GD：(12−2)×30 =  300 → (300+63)/127 = 2
    [InlineData(0, 0, 0)]      // 没有健康组织 ⇒ 0
    [InlineData(127, 0, 30)]   // 满盘健康 ⇒ 恰好等于系数本身
    public void 有氧基准退回盘面式(int healthy, int necrotic, int gdExpected)
    {
        var s = AerobicWorld(seats: 2, healthy: healthy, necrotic: necrotic, level: ImmuneLevel.X,
            tune: t => t with { AerobicByLevel = [], AerobicLevelBase = 0 });
        Assert.Equal(gdExpected, RulePolicies.AerobicBase(s, s.Cells[new EntityId(1)]));
        Assert.Equal(Settlement.RoundDiv((healthy - necrotic) * s.Tuning.AerobicMult, RulePolicies.TotalTiles), gdExpected);
        Assert.Equal(127, RulePolicies.TotalTiles);
    }

    /// <summary>盘面式**与等级无关**（等级式与盘面式是两套对照档，不许串味）。</summary>
    [Fact]
    public void 盘面式不看抗原记忆等级()
    {
        var mk = (ImmuneLevel lv) => AerobicWorld(2, 40, 7, lv, t => t with { AerobicByLevel = [], AerobicLevelBase = 0 });
        var one = mk(ImmuneLevel.I);
        var x = mk(ImmuneLevel.X);
        Assert.Equal(RulePolicies.AerobicBase(one, one.Cells[new EntityId(1)]),
            RulePolicies.AerobicBase(x, x.Cells[new EntityId(1)]));
    }

    /// <summary>盘面式的分母是 `TOTAL_TILES` 常量：同样的「健康 − 坏死」，盘面大小不影响结果。</summary>
    [Fact]
    public void 盘面式的分母是常量不是当前格数()
    {
        var small = AerobicWorld(2, 12, 2, ImmuneLevel.I, t => t with { AerobicByLevel = [], AerobicLevelBase = 0 });
        var large = AerobicWorld(2, 12, 2, ImmuneLevel.I, t => t with { AerobicByLevel = [], AerobicLevelBase = 0 }, padCancer: 60);
        Assert.NotEqual(small.Board.Tissues.Count, large.Board.Tissues.Count);
        Assert.Equal(RulePolicies.AerobicBase(small, small.Cells[new EntityId(1)]),
            RulePolicies.AerobicBase(large, large.Cells[new EntityId(1)]));
    }

    /// <summary>GD `aerobic_mult_at` 的 `maxi(…, 0)`：负系数会让整数除法从「向下取整」翻成「向零截断」，
    /// 取整口径当场翻面 —— 所以钳在**分子**之前（GD 2026-09-01 第一版漏过这句）。</summary>
    [Fact]
    public void 盘面式的负系数被钳成零()
    {
        var s = AerobicWorld(2, 40, 0, ImmuneLevel.I,
            t => t with { AerobicByLevel = [], AerobicLevelBase = 0, AerobicMult = -30 });
        Assert.Equal(0, RulePolicies.AerobicBase(s, s.Cells[new EntityId(1)]));
    }

    // ======== ③ AerobicShare：clamp_income(aerobic_floor, aerobic_cap) ========

    /// <summary>缺省 `aerobic_floor = aerobic_cap = 0` ⇒ 这道夹钳是恒等式（默认旋钮下零行为改动的直接证据）。</summary>
    [Fact]
    public void 缺省下有氧夹钳是恒等式()
    {
        Assert.Equal(0, RuleTuning.Default.AerobicFloor);
        Assert.Equal(0, RuleTuning.Default.AerobicCap);
        var s = AerobicWorld(2, 40, 0, ImmuneLevel.II);
        Assert.Equal(RulePolicies.AerobicBase(s, s.Cells[new EntityId(1)]),
            RulePolicies.AerobicShare(s, s.Cells[new EntityId(1)]));
    }

    /// <summary>低保夹在**基准**上、**排在均分之前**：基数 0.5、低保 2.0、3 个免疫均分（ref = 0 = 纯 ÷ n）
    /// ⇒ 先顶到 20 再 `(2×20+3)/(2×3)` = 7；顺序反过来则是 `(2×5+3)/6` = 2 再顶回 20 —— 两条数不一样，钉的就是顺序。</summary>
    [Fact]
    public void 低保夹在基准上排在均分之前()
    {
        var s = AerobicWorld(2, 40, 0, ImmuneLevel.I, immuneCells: 3,
            tune: t => t with { AerobicByLevel = [5], AerobicFloor = 20, AerobicSplit = true, AerobicSplitRef = 0 });
        Assert.Equal(7, RulePolicies.AerobicShare(s, s.Cells[new EntityId(1)]));
    }

    /// <summary>封顶排在低保**之后**、且 `cap = 0` 时不封顶（GD `clamp_income` 的两个 `> 0` 闸）。</summary>
    [Theory]
    [InlineData(0, 0, 45)]     // 都关 ⇒ 恒等
    [InlineData(60, 0, 60)]    // 只开低保
    [InlineData(0, 30, 30)]    // 只开封顶
    [InlineData(60, 50, 50)]   // 低保先把 45 顶到 60，封顶再压到 50
    public void 封顶排在低保之后(int floor, int cap, int expected)
    {
        var s = AerobicWorld(2, 40, 0, ImmuneLevel.III,
            tune: t => t with { AerobicFloor = floor, AerobicCap = cap });
        Assert.Equal(expected, RulePolicies.AerobicShare(s, s.Cells[new EntityId(1)]));
    }

    /// <summary>夹钳排在【TGF-β释放】的逐份 −20% **之前**（GD：clamp 在 `aerobic_share` 的第一步）。</summary>
    [Fact]
    public void 夹钳排在TGF减免之前()
    {
        var s = AerobicWorld(2, 40, 0, ImmuneLevel.III, tune: t => t with { AerobicCap = 30 },
            effects: [new ActiveEffect("TGF-β释放", 2)]);
        Assert.Equal(24, RulePolicies.AerobicShare(s, s.Cells[new EntityId(1)]));   // 45 → 封顶 30 → ×80% = 24
    }

    // ======== ④ SplitShare：count <= 0 ========

    /// <summary>GD 在 `count <= 0` 上是 `scaled / 0.0` 的溢出（实测 `int(inf)` = INT64_MIN，随后被地板兜成 2.0）——
    /// 那是 UB 不是规则，C# 不复刻，当场炸。</summary>
    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void 均分的细胞数不许小于一(int count)
    {
        var e = Assert.Throws<NotSupportedException>(() => RulePolicies.SplitShare(RuleTuning.Default, 100.0, count));
        Assert.Contains("count", e.Message);
    }

    /// <summary>`count >= 1` 的每一档与改前**逐位相同**（这四个数逐字取自 K4 的既有断言）。</summary>
    [Fact]
    public void 正常人数下的均分与改前逐位相同()
    {
        var tune = RuleTuning.Default;
        Assert.Equal(80, RulePolicies.SplitShare(tune, 100.0, 1));
        Assert.Equal(50, RulePolicies.SplitShare(tune, 100.0, 2));
        Assert.Equal(40, RulePolicies.SplitShare(tune, 100.0, 3));
        Assert.Equal(tune.AnaerobicFloor, RulePolicies.SplitShare(tune, 1.0, 3));
        Assert.Equal(15, RulePolicies.SplitShare(tune with { AnaerobicFloor = 0 }, 30.6, 2));
    }

    /// <summary>块内一个存活癌细胞都没有时，`AnaerobicShare` 仍按 `count = 1` 算 —— GD `anaerobic_gain_for`
    /// 写的就是 `maxi(count, 1)`。守卫从 `SplitShare` 挪到这里是**零行为改动**（k 的下标与除数都不变）。</summary>
    [Fact]
    public void 块内无存活癌细胞时按一个算()
    {
        var s = DeadCancerWorld();
        var c = s.Cells[new EntityId(1)];
        var block = RulePolicies.Blocks(s, true).First(b => b.Contains(c.Position));
        Assert.Equal(0, s.Cells.Values.Count(x => x.IsAlive && x.Faction == Faction.Cancer && block.Contains(x.Position)));
        Assert.Equal(RulePolicies.SplitShare(s.Tuning, RulePolicies.AnaerobicPool(s, block), 1),
            RulePolicies.AnaerobicShare(s, c));
    }

    // ======== 盘面搭建 ========

    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static Tissue Tile(HexPosition p, TissueState st, EntityId? occ, int necrosis = 0) =>
        new() { Position = p, Type = TissueType.Normal, State = st, SolidificationCount = 0, OccupyingCell = occ, Charge = 0, NecrosisRounds = necrosis };

    /// <summary>座位 0..n−1，最后一个是癌方、其余免疫（`Players.Count` 才是分档表的输入）。</summary>
    private static Dictionary<int, Player> SeatMap(int count)
    {
        var seats = new Dictionary<int, Player>();
        for (var i = 0; i < count; i++)
            seats[i] = i == count - 1
                ? new() { Seat = i, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
                : new() { Seat = i, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };
        return seats;
    }

    /// <summary>只有席位、没有棋盘的最小世界：门槛表那一组只读 `Players`。</summary>
    private static WorldState Seats(int count) => new()
    {
        Board = new Board { Radius = 6, Tissues = new Dictionary<HexPosition, Tissue>() },
        Cells = new Dictionary<EntityId, Cell>(),
        Players = SeatMap(count),
        Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 },
    };

    /// <summary>
    /// 一张直线盘面：<paramref name="healthy"/> 格健康组织（其中前 <paramref name="necrotic"/> 格带坏死），
    /// 外加 <paramref name="padCancer"/> 格癌组织（只用来把「棋盘格数」和「健康格数」拆开）。
    /// 免疫细胞 1..<paramref name="immuneCells"/> 摆在最前面几格，等级统一设成 <paramref name="level"/>。
    /// </summary>
    private static WorldState AerobicWorld(int seats, int healthy, int necrotic, ImmuneLevel level,
        Func<RuleTuning, RuleTuning>? tune = null, int immuneCells = 1, int padCancer = 0,
        IReadOnlyList<ActiveEffect>? effects = null)
    {
        var tiles = new Dictionary<HexPosition, Tissue>();
        var cells = new Dictionary<EntityId, Cell>();
        for (var i = 0; i < healthy; i++)
        {
            var at = P(i % 20, i / 20);
            EntityId? occ = null;
            if (i < immuneCells && i >= necrotic)   // 免疫不站坏死格：necrosis_cut 是另一条口径，别混进来
            {
                occ = new EntityId((ulong)(i - necrotic + 1));
                cells[occ.Value] = new Cell
                {
                    Id = occ.Value, OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                    Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                };
            }
            tiles[at] = Tile(at, TissueState.Healthy, occ, i < necrotic ? 2 : 0);
        }
        for (var i = 0; i < padCancer; i++)
        {
            var at = P(i % 20, 40 + i / 20);
            tiles[at] = Tile(at, TissueState.Cancer, null);
        }
        if (cells.Count == 0)   // healthy = 0 的档也得有个免疫细胞才能问基准
        {
            var at = P(0, 60);
            tiles[at] = Tile(at, TissueState.Cancer, new EntityId(1));
            cells[new EntityId(1)] = new Cell
            {
                Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [], Equipped = [],
            };
        }

        var players = SeatMap(seats);
        foreach (var (seat, p) in players.ToArray())
            if (p.Faction == Faction.Immune)
                players[seat] = p.WithImmuneLevel(level);

        var s = new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = cells,
            Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 },
            Effects = effects ?? [],
        };
        return tune is null ? s : s.WithTuning(tune(s.Tuning));
    }

    /// <summary>一条 4 格的癌组织带，上面只有一个**已死**的癌细胞 ⇒ 块内存活癌细胞数 = 0。</summary>
    private static WorldState DeadCancerWorld()
    {
        var spots = new[] { P(0, 0), P(1, 0), P(2, 0), P(3, 0) };
        var tiles = spots.ToDictionary(p => p, p => Tile(p, TissueState.Cancer, null));
        var dead = new Cell
        {
            Id = new EntityId(1), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
            Position = spots[0], Energy = 0, IsAlive = false, StatusEffects = Array.Empty<StatusEffect>(),
            Hand = [], Equipped = [],
        };
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell> { [dead.Id] = dead },
            Players = SeatMap(4),
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 1 },
        };
    }
}
