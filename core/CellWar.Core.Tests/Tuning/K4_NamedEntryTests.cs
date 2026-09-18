using CellWar.Core;

namespace CellWar.Core.Tests.Tuning;

/// <summary>
/// K4 · 规格 §0.6.7 的四个具名入口：`RulePolicies.AnaerobicPool` / `RulePolicies.SplitShare`
/// （从 `AnaerobicShare` 里**原样**抽出的两段）、`CellRules.MoveLegal`、`Settlement.SettleLoss`。
///
/// 这一组**不验任何新规则**，只钉三件事：
///   ① 抽出来的两段合起来 ≡ 抽之前的 `AnaerobicShare`（零行为改动的直接证据）；
///   ② `MoveLegal` 的每一个分支与 GD `cw_actions.gd:_is_move_legal_now`（392-419）一一对应；
///   ③ `SettleLoss` 与 GD `cw_game.gd:settle_loss` 同值 —— 4 条期望逐字取自
///      `game/tests/headless_test.gd:t_hit_order`（408-414）。
/// </summary>
public class K4NamedEntryTests
{
    // ======== ① AnaerobicPool + SplitShare ≡ AnaerobicShare ========

    /// <summary>
    /// 四块盘面上比「抽出来的两段串起来」与「抽之前的那一条」。
    /// 细胞一律是**黑色素瘤、不带【GLUT1高表达】** —— `AnaerobicShare` 末尾的瓦伯格 / GLUT1
    /// 两条加成不在这两个入口里，挑个都不触发的种类，等式才是干净的。
    /// </summary>
    [Theory]
    [InlineData(1, 0)]
    [InlineData(2, 0)]
    [InlineData(3, 0)]
    [InlineData(2, 3)]   // 全图 3 格固化：把 `solid × bonus` 那一项也带进来
    public void 池子加均分组合起来等于抽之前的无氧份额(int cancerCells, int solids)
    {
        var s = AnaerobicWorld(cancerCells, solids);
        var c = s.Cells[new EntityId(1)];
        var block = RulePolicies.Blocks(s, true).First(b => b.Contains(c.Position));
        var living = s.Cells.Values.Count(x => x.IsAlive && x.Faction == Faction.Cancer && block.Contains(x.Position));

        var combined = RulePolicies.SplitShare(s.Tuning, RulePolicies.AnaerobicPool(s, block), living);

        Assert.Equal(cancerCells, living);
        Assert.Equal(RulePolicies.AnaerobicShare(s, c), combined);
    }

    /// <summary>
    /// `AnaerobicPool` 给的是 GD `_anaerobic_pool` 那条**未取整**的浮点式：
    /// `块内普通癌组织数^(指数/100) × 系数 + 全图固化数 × 每格加成`。
    /// 断言到小数位上 —— 这正是「不许在池子这一步取整」的钉子。
    /// </summary>
    [Fact]
    public void 池子按GD算式给出未取整的十分能量()
    {
        var s = AnaerobicWorld(cancerCells: 2, solids: 3);
        var tune = s.Tuning;
        var block = RulePolicies.Blocks(s, true).First(b => b.Contains(s.Cells[new EntityId(1)].Position));

        // 盘面是 4 格普通癌组织 + 3 格（不连通的）固化，四人局
        var expected = Math.Pow(4, tune.AnaerobicBlockExpByPlayers[4] / 100.0) * tune.AnaerobicBlockCoefByPlayers[4]
            + 3 * tune.AnaerobicSolidBonus;

        Assert.Equal(4, s.Players.Count);
        Assert.Equal(expected, RulePolicies.AnaerobicPool(s, block), 9);
    }

    /// <summary>
    /// `SplitShare` 的四步（k → 均分 → 四舍五入 → 兜底）逐个可见：
    /// 池子 100（十分）、块内 2 个 ⇒ k=100%、÷2 ⇒ 50；块内 1 个 ⇒ k=80%、不分 ⇒ 80。
    /// 再验兜底：池子 1 时任何人数都被 `AnaerobicFloor`（2.0）顶上来。
    /// </summary>
    [Fact]
    public void 均分按人数系数与兜底走GD的四步()
    {
        var tune = RuleTuning.Default;
        Assert.Equal(new[] { 80, 100, 120 }, tune.AnaerobicCellsK);
        Assert.True(tune.AnaerobicSplit);

        Assert.Equal(80, RulePolicies.SplitShare(tune, 100.0, 1));    // 100 × 80% ÷ 1
        Assert.Equal(50, RulePolicies.SplitShare(tune, 100.0, 2));    // 100 × 100% ÷ 2
        Assert.Equal(40, RulePolicies.SplitShare(tune, 100.0, 3));    // 100 × 120% ÷ 3
        Assert.Equal(tune.AnaerobicFloor, RulePolicies.SplitShare(tune, 1.0, 3));   // 兜底排在 k 之后

        // 四舍五入**只做一次**：30.6 的池子、2 个细胞 ⇒ round(15.3) = 15，
        // 而不是「先把池子冻成 31 再除」的 round(15.5) = 16
        Assert.Equal(15, RulePolicies.SplitShare(tune with { AnaerobicFloor = 0 }, 30.6, 2));
    }

    // ======== ② MoveLegal：逐条对 GD `_is_move_legal_now` 的分支 ========

    /// <summary>分支 ①：`not game.is_on_board(to)` —— 棋盘外一律不合法。</summary>
    [Fact]
    public void 走到棋盘外不合法()
    {
        var s = Line(Immune(1, P(0, 0)));
        Assert.False(CellRules.MoveLegal(s, s.Cells[new EntityId(1)], P(9, 0)));
    }

    /// <summary>分支 ①：`not cell["alive"]` —— 死细胞哪儿也去不了，哪怕落点是相邻空格。</summary>
    [Fact]
    public void 死细胞不合法()
    {
        var s = Line(Immune(1, P(0, 0)).Copy(alive: false));
        Assert.False(CellRules.MoveLegal(s, s.Cells[new EntityId(1)], P(1, 0)));
    }

    /// <summary>分支 ②：原地不是「迁移」—— GD `pass_through_mid` 对 `to == cell["pos"]` 返回 MAX。</summary>
    [Fact]
    public void 原地不合法()
    {
        var s = Line(Immune(1, P(0, 0)));
        Assert.False(CellRules.MoveLegal(s, s.Cells[new EntityId(1)], P(0, 0)));
    }

    /// <summary>基线：相邻空格永远走得进（免疫、癌方都是）。</summary>
    [Fact]
    public void 相邻空格合法()
    {
        var s = Line(Immune(1, P(0, 0)));
        Assert.True(CellRules.MoveLegal(s, s.Cells[new EntityId(1)], P(1, 0)));
    }

    /// <summary>
    /// 分支 ②：借道前进。P1 站着友军 ⇒ P2 借得到、且必须**完全空着**；
    /// P1 空着 ⇒ 借不到，P2 不合法（不是相邻格，也没有连通块可借）。
    /// </summary>
    [Fact]
    public void 借道前进要有友军且落点必须空着()
    {
        var withAlly = Line(Immune(1, P(0, 0)), Immune(2, P(1, 0)));
        Assert.True(CellRules.MoveLegal(withAlly, withAlly.Cells[new EntityId(1)], P(2, 0)));

        var blocked = Line(Immune(1, P(0, 0)), Immune(2, P(1, 0)), Cancer(3, P(2, 0)));
        Assert.False(CellRules.MoveLegal(blocked, blocked.Cells[new EntityId(1)], P(2, 0)));   // 不许穿过去打人

        var noAlly = Line(Immune(1, P(0, 0)));
        Assert.False(CellRules.MoveLegal(noAlly, noAlly.Cells[new EntityId(1)], P(2, 0)));
    }

    /// <summary>分支 ③：癌方**一格一细胞** —— 相邻格上有任何存活细胞都不合法（癌方没有「攻击」这条路）。</summary>
    [Fact]
    public void 癌方一格一细胞()
    {
        var s = Line(Cancer(1, P(0, 0)), Cancer(2, P(1, 0)));
        Assert.False(CellRules.MoveLegal(s, s.Cells[new EntityId(1)], P(1, 0)));

        var vsImmune = Line(Cancer(1, P(0, 0)), Immune(2, P(1, 0)));
        Assert.False(CellRules.MoveLegal(vsImmune, vsImmune.Cells[new EntityId(1)], P(1, 0)));
    }

    /// <summary>分支 ④：免疫踩免疫不是攻击，也走不进；踩癌细胞才是攻击，合法。</summary>
    [Fact]
    public void 免疫踩免疫不合法踩癌细胞是攻击()
    {
        var vsAlly = Line(Immune(1, P(0, 0)), Immune(2, P(1, 0)));
        Assert.False(CellRules.MoveLegal(vsAlly, vsAlly.Cells[new EntityId(1)], P(1, 0)));

        var vsEnemy = Line(Immune(1, P(0, 0)), Cancer(2, P(1, 0)));
        Assert.True(CellRules.MoveLegal(vsEnemy, vsEnemy.Cells[new EntityId(1)], P(1, 0)));
    }

    /// <summary>分支 ⑤：树突【I-各司其职】—— 不能通过【迁移】攻击癌细胞，但空格照走。</summary>
    [Fact]
    public void 树突不能靠迁移攻击癌细胞()
    {
        var s = Line(Immune(1, P(0, 0)).Copy(type: CellType.Dendritic), Cancer(2, P(1, 0)));
        Assert.False(CellRules.MoveLegal(s, s.Cells[new EntityId(1)], P(1, 0)));

        var empty = Line(Immune(1, P(0, 0)).Copy(type: CellType.Dendritic));
        Assert.True(CellRules.MoveLegal(empty, empty.Cells[new EntityId(1)], P(1, 0)));
    }

    /// <summary>
    /// 分支 ⑥：每行动回合攻击次数上限（旋钮 `AttackMaxPerTurn`，GD `tune.attack_max_per_turn`）。
    /// 用完之后**只是这一格进不去**，别的迁移照常 —— 空格那一步仍然合法。
    /// </summary>
    [Fact]
    public void 攻击次数用完只挡攻击那一格()
    {
        var cap = RuleTuning.Default.AttackMaxPerTurn;
        var used = Line(Immune(1, P(0, 0)).Copy(attacks: cap), Cancer(2, P(1, 0)), Cancer(3, P(-1, 0)));
        Assert.False(CellRules.MoveLegal(used, used.Cells[new EntityId(1)], P(1, 0)));
        Assert.True(CellRules.MoveLegal(used, used.Cells[new EntityId(1)], P(0, 1)));   // 空格照走

        var left = Line(Immune(1, P(0, 0)).Copy(attacks: cap - 1), Cancer(2, P(1, 0)));
        Assert.True(CellRules.MoveLegal(left, left.Cells[new EntityId(1)], P(1, 0)));
    }

    // ======== ③ SettleLoss：headless_test.gd:t_hit_order 的 4 条 ========

    /// <summary>`check(CWGame.settle_loss(10, 0, 2, 1, 5) == 15, "1.0 ×2 −0.5 = 1.5（倍增在减免之前）")`</summary>
    [Fact]
    public void 倍增排在减免之前() => Assert.Equal(15, Settlement.SettleLoss(10, 0, 2, 1, 5));

    /// <summary>`check(CWGame.settle_loss(10, 0, 2, 2, 0) == 10, "×2 再 ÷2 = 原值")`</summary>
    [Fact]
    public void 乘二再除二回到原值() => Assert.Equal(10, Settlement.SettleLoss(10, 0, 2, 2, 0));

    /// <summary>`check(CWGame.settle_loss(10, 0, 1, 2, 0) == 5, "÷2 向下取整到十分位")`</summary>
    [Fact]
    public void 除二向下取整到十分位() => Assert.Equal(5, Settlement.SettleLoss(10, 0, 1, 2, 0));

    /// <summary>`check(CWGame.settle_loss(5, 0, 1, 1, 10) == 0, "减免不会减成负数")`</summary>
    [Fact]
    public void 减免不会减成负数() => Assert.Equal(0, Settlement.SettleLoss(5, 0, 1, 1, 10));

    // ======== 盘面搭建 ========

    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static Tissue Tile(HexPosition p, TissueState st, EntityId? occ) =>
        new() { Position = p, Type = TissueType.Normal, State = st, SolidificationCount = 0, OccupyingCell = occ, Charge = 0 };

    private static Cell Immune(ulong id, HexPosition at) => new()
    {
        Id = new EntityId(id), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
        Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
        Hand = [], Equipped = [],
    };

    private static Cell Cancer(ulong id, HexPosition at) => new()
    {
        Id = new EntityId(id), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
        Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
        Hand = [], Equipped = [],
    };

    /// <summary>
    /// 一条 (q,0)、q ∈ [-1, 3] 的健康组织带 + (0,1) 一格（用来验「别的迁移照常」），
    /// 上面按参数摆细胞。`(9,0)` 不在这张表里 —— 那就是「棋盘外」。
    /// </summary>
    private static WorldState Line(params Cell[] cells)
    {
        var spots = new[] { P(-1, 0), P(0, 0), P(1, 0), P(2, 0), P(3, 0), P(0, 1) };
        var tiles = spots.ToDictionary(p => p, p => Tile(p, TissueState.Healthy, null));
        foreach (var c in cells) tiles[c.Position] = Tile(c.Position, TissueState.Healthy, c.Id);

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = cells.ToDictionary(c => c.Id, c => c),
            Players = Seats(2),
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 },
        };
    }

    /// <summary>
    /// 四人局：一条 4 格的普通癌组织带（(0,0)…(3,0)）上摆 <paramref name="cancerCells"/> 个癌细胞，
    /// 外加 <paramref name="solids"/> 格**不与它连通**的固化癌组织（摆在 r=3 那一行）——
    /// 固化那一项按**全图**计数，不进块，正好把两件事分开验。
    /// </summary>
    private static WorldState AnaerobicWorld(int cancerCells, int solids)
    {
        var spots = new[] { P(0, 0), P(1, 0), P(2, 0), P(3, 0) };
        var tiles = new Dictionary<HexPosition, Tissue>();
        var cells = new Dictionary<EntityId, Cell>();
        for (var i = 0; i < spots.Length; i++)
        {
            var occupant = i < cancerCells ? new EntityId((ulong)(i + 1)) : (EntityId?)null;
            tiles[spots[i]] = Tile(spots[i], TissueState.Cancer, occupant);
            if (occupant is not { } id) continue;
            cells[id] = Cancer(id.Value, spots[i]);
        }
        for (var i = 0; i < solids; i++)
        {
            var at = P(i, 3);
            tiles[at] = Tile(at, TissueState.SolidifiedCancer, null);
        }

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = cells,
            Players = Seats(4),
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 1 },
        };
    }

    /// <summary>座位 1 是癌方，其余免疫（无氧分档只看 `Players.Count`）。</summary>
    private static Dictionary<int, Player> Seats(int count)
    {
        var seats = new Dictionary<int, Player>();
        for (var i = 0; i < count; i++)
            seats[i] = i == 1
                ? new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
                : new() { Seat = i, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };
        return seats;
    }
}
