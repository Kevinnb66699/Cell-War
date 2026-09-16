using System.Reflection;
using CellWar.Core;

namespace CellWar.Core.Tests;

/// <summary>
/// 护栏测试：这里的每一条都是为了让**某一类**错误再也不能静默发生，
/// 而不是钉住某一个具体的值。
///
/// 由来：2026-09-15 的双内核核查发现两个 bug，它们的共同点是
/// **既有的 141 个测试全绿却一个都没抓到** ——
///   · 攻击暴击永远掷不出来：`AttackOutcome` 的判定表 16/16 全对，错的是**喂给它的骰面值域**
///   · `WithOccupyingCell` 静默丢两个字段：没有测试去问「所有字段都还在吗」
/// 所以这两条护栏断言的是**值域**与**完整性**，不是某个样例的结果。
/// </summary>
public class RegressionGuardTests
{
    // ---- 一、骰面值域 ----
    //
    // 只比判定函数会给假绿灯：`AttackOutcome(roll, cell)` 对 roll 1..6 全部正确，
    // 而调用点喂的是 `NextInt(6)` = 0..5，于是 roll==6 那一面永远掷不到、暴击恒为 0%。
    // 判据必须落在「实际掷出来的值域」上。

    /// <summary>
    /// **这一条才是真正盯住 bug 的那一条**：它断言的是**调用点请求的值域**。
    ///
    /// ⚠ 起初我写的是「`rng.NextIntRange(1,7)` 掷两万次，六个面都出现」——
    /// 那条测的是 **RNG 助手**，不是 `CellRules`。有人把调用点改回 `NextInt(6)`，
    /// 它照样绿。**那就是把靶画在自己身上**，正是这个 bug 当初能活下来的原因。
    ///
    /// 所以改成用一个记录型 rng 真跑一次攻击，把调用点**要的区间**抓出来比。
    /// </summary>
    [Fact]
    public void 攻击调用点请求的骰面值域是1到6()
    {
        var spy = new RecordingRng(new Xoshiro256StarStar(20260915));
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var world = AttackWorld(from, to);

        new BasicRulesEngine().ExecuteDecision(world, new MoveDecision(0, new EntityId(1), to), spy);

        // 攻击那一笔是区间抽取；PRD 只给概率不给面数，6 面由 Kevin 2026-09-15 裁定。
        Assert.Contains((1, 7), spy.Ranges);

        // 反过来也钉住：不许再出现 [0,6) 这种 0 基的骰子 —— 那正是旧 bug 的形状。
        Assert.DoesNotContain((0, 6), spy.Ranges);
    }

    /// <summary>
    /// 三种判词都必须真的可达。这一条才是抓到「暴击 0%」的那一条 ——
    /// 判定表本身对，但如果值域错了，就会有判词永远取不到。
    /// </summary>
    [Fact]
    public void 三种判词在1到6的值域上都可达()
    {
        var plain = MakeCell(equipped: Array.Empty<string>());
        var reachable = Enumerable.Range(1, 6)
            .Select(roll => RulePolicies.AttackOutcome(roll, plain))
            .ToHashSet();

        Assert.Contains("crit", reachable);
        Assert.Contains("fail", reachable);
        Assert.Contains("success", reachable);
    }

    /// <summary>【免疫突触成熟】那条分支同理：它把暴击面扩到 5~6、失败面收到只剩 1。</summary>
    [Fact]
    public void 免疫突触成熟分支的三种判词也都可达()
    {
        var synapse = MakeCell(equipped: new[] { "免疫突触成熟" });
        var reachable = Enumerable.Range(1, 6)
            .Select(roll => RulePolicies.AttackOutcome(roll, synapse))
            .ToHashSet();

        Assert.Contains("crit", reachable);
        Assert.Contains("fail", reachable);
        Assert.Contains("success", reachable);
    }

    /// <summary>
    /// 分布断言：PRD 的 1/3 失败、1/2 成功、1/6 暴击。
    /// 这一条不是为了验概率（那是判定表的事），是为了**万一值域又被改窄**时当场变红。
    /// </summary>
    [Fact]
    public void 攻击判词的分布符合PRD的三六比例()
    {
        var plain = MakeCell(equipped: Array.Empty<string>());
        var counts = Enumerable.Range(1, 6)
            .GroupBy(roll => RulePolicies.AttackOutcome(roll, plain))
            .ToDictionary(g => g.Key, g => g.Count());

        Assert.Equal(2, counts["fail"]);      // 1, 2      → 1/3
        Assert.Equal(3, counts["success"]);   // 3, 4, 5   → 1/2
        Assert.Equal(1, counts["crit"]);      // 6         → 1/6
    }

    // ---- 二、Tissue 的 With* 不许悄悄丢字段 ----
    //
    // `WithOccupyingCell` 曾经自己手写了一份初始化器、漏掉 SolidLockRound 与 ToxinRound，
    // 于是「格上放一个细胞」会把【TNF-α局部炎症】的锁与【细胞毒素】的格记录清零 ——
    // 而那正是这两个字段唯一起作用的场合。
    //
    // 下面这条用**反射**断言：调用任何一个 With*，除了它该改的那个字段之外，
    // 其余每一个属性都必须原样保留。新加字段自动纳入，不用记得回来改测试。

    [Fact]
    public void 每个With方法只改它该改的那个字段()
    {
        var full = FullyPopulatedTissue();
        var props = typeof(Tissue).GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(p => p.CanRead).ToArray();

        // (被调用的 With*, 它允许改动的属性名, 改成什么)
        var cases = new (string Name, string Changes, Func<Tissue, Tissue> Apply)[]
        {
            ("WithOccupyingCell", nameof(Tissue.OccupyingCell), t => t.WithOccupyingCell(new EntityId(99))),
            ("WithOccupyingCell(null)", nameof(Tissue.OccupyingCell), t => t.WithOccupyingCell(null)),
            ("WithSolidificationCount", nameof(Tissue.SolidificationCount), t => t.WithSolidificationCount(7)),
            ("WithCharge", nameof(Tissue.Charge), t => t.WithCharge(42)),
            ("WithProductionCounter", nameof(Tissue.ProductionCounter), t => t.WithProductionCounter(5)),
            ("WithNecrosis", nameof(Tissue.NecrosisRounds), t => t.WithNecrosis(2)),
            ("WithMucus", nameof(Tissue.Mucus), t => t.WithMucus(false)),
            ("WithNewborn", nameof(Tissue.Newborn), t => t.WithNewborn(false)),
            ("WithOssifyAt", nameof(Tissue.OssifyAtRound), t => t.WithOssifyAt(9)),
            ("WithSolidLockRound", nameof(Tissue.SolidLockRound), t => t.WithSolidLockRound(4)),
            ("WithToxinRound", nameof(Tissue.ToxinRound), t => t.WithToxinRound(6)),
            ("WithType", nameof(Tissue.Type), t => t.WithType(TissueType.BoneMarrow)),
        };

        foreach (var (name, changes, apply) in cases)
        {
            var after = apply(full);
            foreach (var p in props)
            {
                if (p.Name == changes) continue;
                Assert.Equal(
                    $"{name} 保留 {p.Name} = {p.GetValue(full)}",
                    $"{name} 保留 {p.Name} = {p.GetValue(after)}");
            }
        }
    }

    /// <summary>
    /// `Clone()` 也是一份手写的字段清单。它今天是全的，但同样该被钉住 ——
    /// 三份清单里只要有一份漏，就是一个静默 bug。
    /// </summary>
    [Fact]
    public void Clone保留每一个字段()
    {
        var full = FullyPopulatedTissue();
        var clone = full.Clone();

        foreach (var p in typeof(Tissue).GetProperties(BindingFlags.Public | BindingFlags.Instance).Where(p => p.CanRead))
        {
            Assert.Equal($"{p.Name}={p.GetValue(full)}", $"{p.Name}={p.GetValue(clone)}");
        }
    }

    /// <summary>
    /// `Player` 犯的是**同一类病**：5 个 With* 各自手写了一份 7 字段清单
    /// （`WithIsAlive` / `WithAntigenMemory` / `WithImmuneLevel` / `WithDrawCount` / `WithCancerType`）。
    /// 今天五份都是全的，但只要给 Player 加一个字段而漏改其中一份，就又是一个静默清零。
    /// 这里不去重构那五个函数（那是另一次改动），只把**不变量**钉住。
    /// </summary>
    [Fact]
    public void Player的每个With方法也只改它该改的那个字段()
    {
        var full = new Player
        {
            Seat = 1,
            Faction = Faction.Cancer,
            IsAlive = true,
            DrawCount = 4,
            AntigenMemory = 17,
            ImmuneLevel = ImmuneLevel.III,
            CancerType = CellType.Melanoma,
        };
        var props = typeof(Player).GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(p => p.CanRead).ToArray();

        var cases = new (string Name, string Changes, Func<Player, Player> Apply)[]
        {
            ("WithIsAlive", nameof(Player.IsAlive), p => p.WithIsAlive(false)),
            ("WithAntigenMemory", nameof(Player.AntigenMemory), p => p.WithAntigenMemory(99)),
            ("WithImmuneLevel", nameof(Player.ImmuneLevel), p => p.WithImmuneLevel(ImmuneLevel.X)),
            ("WithDrawCount", nameof(Player.DrawCount), p => p.WithDrawCount(9)),
            ("WithCancerType", nameof(Player.CancerType), p => p.WithCancerType(CellType.SmallCellLung)),
        };

        foreach (var (name, changes, apply) in cases)
        {
            var after = apply(full);
            foreach (var p in props)
            {
                if (p.Name == changes) continue;
                Assert.Equal(
                    $"{name} 保留 {p.Name} = {p.GetValue(full)}",
                    $"{name} 保留 {p.Name} = {p.GetValue(after)}");
            }
        }
    }

    // ---- 三、观测不许泄漏别人的手牌 ----
    //
    // MatchObservationProvider 的文档注释写着「No scheduler, RNG or other seat's legal input
    // is exposed」，但 Hand 此前是**无条件**导出的 —— authorizedSeat 只门控了 options。
    // 而且现有 141 个测试里没有一条覆盖过这件事：修之前它们照样全绿。

    [Fact]
    public void 观测只让你看见自己的手牌()
    {
        using var session = new MatchSession(DemoScenario.Create());
        DrawSomeCards(session);

        var view = session.Observe(0);
        var mine = view.Cells.Where(c => c.OwnerSeat == 0).ToArray();
        var theirs = view.Cells.Where(c => c.OwnerSeat != 0).ToArray();

        Assert.NotEmpty(mine);
        Assert.NotEmpty(theirs);
        Assert.All(mine, c => Assert.DoesNotContain(MatchObservationProvider.HiddenCard, c.Hand));
        Assert.All(theirs, c => Assert.All(c.Hand, card => Assert.Equal(MatchObservationProvider.HiddenCard, card)));
    }

    /// <summary>「他有几张牌」是公开信息，「是哪几张」不是 —— 所以张数必须原样保留。</summary>
    [Fact]
    public void 别人的手牌张数照样看得见()
    {
        using var session = new MatchSession(DemoScenario.Create());
        DrawSomeCards(session);

        var truth = session.Observe(null);          // 张数这一项对谁都一样
        var asSeat0 = session.Observe(0);

        foreach (var c in truth.Cells)
        {
            var seen = asSeat0.Cells.Single(x => x.Id == c.Id);
            Assert.Equal(c.Hand.Length, seen.Hand.Length);
        }
        foreach (var p in truth.Players)
            Assert.Equal(p.HandCount, asSeat0.Players.Single(x => x.Seat == p.Seat).HandCount);
    }

    /// <summary>没有指定席位 = 最受限的视角，谁的牌都不给。上帝视角要另开显式入口，不能靠 null 兜底。</summary>
    [Fact]
    public void 不指定席位时谁的手牌都看不见()
    {
        using var session = new MatchSession(DemoScenario.Create());
        DrawSomeCards(session);

        var view = session.Observe(null);
        Assert.All(view.Cells, c => Assert.All(c.Hand, card => Assert.Equal(MatchObservationProvider.HiddenCard, card)));
    }

    // ---- 四、预计收入必须走 RulePolicies，不许观测层自己算一遍 ----

    /// <summary>
    /// 旧 IncomeFor 把免疫基数 20/30/45/50 与两张装备的 +5/+8 写成了字面量，
    /// **而且抄漏了 TGF-β 每层 -20% 与坏死减半**。这条用「让 TGF 生效、看收入有没有跟着降」
    /// 来钉住它 —— 手抄那份对 TGF 毫无反应。
    /// </summary>
    [Fact]
    public void 预计收入跟着TGFβ走()
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);

        var plain = AttackWorld(from, to);
        var tgf = plain.WithTurn(new TurnState
        {
            WorldRound = plain.Turn.WorldRound,
            Phase = plain.Turn.Phase,
            ActivePlayerSeat = plain.Turn.ActivePlayerSeat,
            TgfStacks = 1,
        });

        var provider = new MatchObservationProvider(new BasicRulesEngine());
        var before = IncomeOfSeat0(provider, plain);
        var after = IncomeOfSeat0(provider, tgf);

        Assert.True(before > 0, "夹具本身要有正收入，否则这条测试什么都证明不了");
        Assert.True(after < before, $"TGF-β 一层应让有氧收入下降（每层 ×80% 向下取整）：{before} → {after}");
    }

    /// <summary>
    /// 站在坏死格上有氧减半 —— 旧 IncomeFor 抄漏的第二条。
    /// 与 TGF 那条一起，两个独立方向都证明「收入不是那份手抄的」。
    /// </summary>
    [Fact]
    public void 预计收入跟着坏死走()
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);

        var plain = AttackWorld(from, to);
        var rotten = plain.WithBoard(plain.Board.UpdateTissue(from, plain.Board.Tissues[from].WithNecrosis(2)));

        var provider = new MatchObservationProvider(new BasicRulesEngine());
        var before = IncomeOfSeat0(provider, plain);
        var after = IncomeOfSeat0(provider, rotten);

        Assert.True(before > 0);
        Assert.True(after < before, $"站在坏死格上有氧应减半：{before} → {after}");
    }

    // ---- 夹具 ----

    /// <summary>让每个席位手里都有点牌，否则「看不看得见手牌」这件事没法验。</summary>
    private static void DrawSomeCards(MatchSession session)
    {
        for (var i = 0; i < 24; i++)
        {
            var view = session.Observe(null);
            if (view.Winner != null) return;
            var seat = view.ActiveSeat;
            var mine = session.Observe(seat);
            if (mine.RequestId is not { } req) return;
            var draw = mine.Options.FirstOrDefault(o => o.Kind == "Draw")
                       ?? mine.Options.FirstOrDefault(o => o.Kind == "EndTurn");
            if (draw == null) return;
            session.Submit(seat, new(req, mine.Revision, draw.Id));
        }
    }

    /// <summary>直接问观测层：0 号席（免疫）的「预计收入」是多少。</summary>
    private static double IncomeOfSeat0(MatchObservationProvider provider, WorldState world)
    {
        using var session = new MatchSession(world);
        return session.Observe(0).Players.Single(p => p.Seat == 0).Income;
    }

    /// <summary>
    /// **每一个字段都填成非默认值**——这是上面两条反射断言能成立的前提：
    /// 字段若是默认值（0 / false / null），被清零也看不出来。
    /// </summary>
    private static Tissue FullyPopulatedTissue() => new()
    {
        Position = new HexPosition(1, -2, 1),
        Type = TissueType.MetabolicCore,
        State = TissueState.Cancer,
        SolidificationCount = 13,
        OccupyingCell = new EntityId(3),
        Charge = 21,
        ProductionCounter = 2,
        NecrosisRounds = 1,
        Mucus = true,
        Newborn = true,
        OssifyAtRound = 8,
        SolidLockRound = 3,
        ToxinRound = 7,
    };

    /// <summary>一个免疫细胞紧邻一个癌细胞：往那格「移动」即触发攻击。</summary>
    private static WorldState AttackWorld(HexPosition from, HexPosition to) => new()
    {
        Board = new Board
        {
            Radius = 6,
            Tissues = new Dictionary<HexPosition, Tissue>
            {
                [from] = new() { Position = from, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = new EntityId(1), Charge = 0 },
                [to] = new() { Position = to, Type = TissueType.Normal, State = TissueState.Cancer, SolidificationCount = 0, OccupyingCell = new EntityId(2), Charge = 0 },
            }
        },
        Cells = new Dictionary<EntityId, Cell>
        {
            [new EntityId(1)] = new()
            {
                Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                Position = from, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [], Equipped = []
            },
            [new EntityId(2)] = new()
            {
                Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
                Position = to, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [], Equipped = []
            },
        },
        Players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma },
        },
        Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
    };

    /// <summary>
    /// 记录型 rng：**不改变任何取值**，只把每一笔抽取**请求的区间**记下来。
    /// 值域断言靠它才能落在调用点上，而不是落在 RNG 助手上。
    /// </summary>
    private sealed class RecordingRng(IDeterministicRng inner) : IDeterministicRng
    {
        public List<(int Min, int Max)> Ranges { get; } = [];
        public int DoubleDraws { get; private set; }

        public double NextDouble() { DoubleDraws++; return inner.NextDouble(); }
        public int NextInt(int max) { Ranges.Add((0, max)); return inner.NextInt(max); }
        public int NextIntRange(int min, int max) { Ranges.Add((min, max)); return inner.NextIntRange(min, max); }
        public T Choose<T>(IReadOnlyList<T> items) { Ranges.Add((0, items.Count)); return inner.Choose(items); }
        public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items) => inner.Shuffle(items);
        public IDeterministicRng Fork() => new RecordingRng(inner.Fork());
        public RngState GetState() => inner.GetState();
        public void SetState(RngState state) => inner.SetState(state);
    }

    private static Cell MakeCell(IReadOnlyList<string> equipped) => new()
    {
        Id = new EntityId(1),
        OwnerSeat = 0,
        Faction = Faction.Immune,
        Type = CellType.ImmuneBasic,
        Position = new HexPosition(0, 0, 0),
        Energy = 30,
        IsAlive = true,
        StatusEffects = Array.Empty<StatusEffect>(),
        AttacksThisTurn = 0,
        Hand = Array.Empty<string>(),
        Equipped = equipped,
    };
}
