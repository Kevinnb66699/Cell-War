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

    // ---- 五、规则路径上不许有浮点抽取 ----

    /// <summary>
    /// **这是双内核对拍的硬前提**，不是风格偏好。
    ///
    /// 我们的随机数带子记的是「整数区间抽取」—— 一方录、一方念。
    /// 浮点抽取（`NextDouble`）在带子上**没有任何对应物**：实测不改的话，
    /// 2 人局跑 40 步就撞 64 条 `RNG_NO_COUNTERPART`，而 E 阶段 100% 走增生那一行、
    /// 每回合约 27 次 —— 于是任何跨 E 阶段的对拍结果整段作废。
    ///
    /// 所以这里断言的是**一个次数**：规则跑完，浮点抽取必须是 0 次。
    /// 将来谁再往规则里写一个 `NextDouble`，这条当场红。
    /// </summary>
    [Fact]
    public void 规则推进一整局都不做浮点抽取()
    {
        var spy = new RecordingRng(new Xoshiro256StarStar(4242));
        var engine = new BasicRulesEngine();
        var world = MatchSetup.Create(4, 4242);

        // 一路推进阶段：S / 玩家行动 / E 全都走一遍，重点是把 E 阶段的增生跑到。
        for (var i = 0; i < 400 && world.Turn.Winner == null; i++)
        {
            var options = engine.GetAvailableDecisions(world, world.Turn.ActivePlayerSeat);
            if (options.Count > 0)
            {
                // 挑 EndTurn（没有就取第一项）：目的是把回合推完、进 E 阶段，不是打得好
                var pick = options.FirstOrDefault(d => d.DecisionType == "EndTurn") ?? options[0];
                world = engine.ExecuteDecision(world, pick, spy).NewState;
            }
            else
            {
                world = engine.AdvancePhase(world, spy).NewState;
            }
        }

        Assert.True(spy.Ranges.Count > 0, "夹具本身要真的抽过随机数，否则这条测试什么都证明不了");
        Assert.Equal(0, spy.DoubleDraws);
    }

    // ---- 六、注入的随机源必须真的被用 ----

    /// <summary>
    /// `Runtime` 原来每个事件都现场 `new Xoshiro256StarStar(1)` —— **状态流过去了，算法写死了**。
    /// 构造函数收下的那个 `IDeterministicRng` 只在初始化时被 `GetState()` 用过一次，
    /// 于是「注入随机源」在执行层完全无效。
    ///
    /// 这一条断言的是「注入的那个实例**确实参与了每一次抽取**」，
    /// 而不是「构造函数收下了它」—— 后者旧代码也满足。
    /// </summary>
    [Fact]
    public void 注入的随机源在事件执行层真的生效()
    {
        var draws = 0;
        var store = new InMemoryStateStore();
        var prototype = new CountingRng(new Xoshiro256StarStar(123), () => draws++);

        using var runtime = new Runtime(store, store.Allocate(new(DemoScenario.Create())),
            new IRuleHandler[] { new InlineHandler("roll", c => c.Rng.NextInt(6)) }, prototype);

        runtime.Schedule(1, "roll", null);
        runtime.Schedule(2, "roll", null);
        runtime.Run();

        Assert.True(draws >= 2, $"注入的 rng 应当参与每一次抽取，实际只记到 {draws} 次");
    }

    /// <summary>`Fork()` 出来的 Runtime（AI 推演正是从这里分叉）也必须带着注入的实现走。</summary>
    [Fact]
    public void 分支出来的Runtime也带着注入的随机源()
    {
        var draws = 0;
        var store = new InMemoryStateStore();
        var prototype = new CountingRng(new Xoshiro256StarStar(123), () => draws++);

        using var runtime = new Runtime(store, store.Allocate(new(DemoScenario.Create())),
            new IRuleHandler[] { new InlineHandler("roll", c => c.Rng.NextInt(6)) }, prototype);
        var branch = runtime.Fork();

        var before = draws;
        branch.Schedule(1, "roll", null);
        branch.Run();

        Assert.True(draws > before, "Fork 出来的 Runtime 退回了写死的 xoshiro —— AI 推演里注入会当场失效");
    }

    private sealed class InlineHandler(string type, Action<IEventContext> action) : IRuleHandler
    {
        public string EventType => type;
        public void Handle(IEventContext context) => action(context);
    }

    /// <summary>只数抽取次数，不改任何取值。</summary>
    private sealed class CountingRng(IDeterministicRng inner, Action onDraw) : IDeterministicRng
    {
        public double NextDouble() { onDraw(); return inner.NextDouble(); }
        public int NextInt(int max) { onDraw(); return inner.NextInt(max); }
        public int NextIntRange(int min, int max) { onDraw(); return inner.NextIntRange(min, max); }
        public T Choose<T>(IReadOnlyList<T> items) { onDraw(); return inner.Choose(items); }
        public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items) { onDraw(); return inner.Shuffle(items); }
        public IDeterministicRng Fork() => new CountingRng(inner.Fork(), onDraw);
        public RngState GetState() => inner.GetState();
        public void SetState(RngState state) => inner.SetState(state);
    }

    // ---- 七、分化去重是「全阵营」不是「每席位」 ----

    /// <summary>
    /// 旧判据是 `x.OwnerSeat == d.PlayerSeat && x.IsAlive && x.Type == d.Type` ——
    /// **等于完全没有去重**：每个席位只有一只细胞，而那只此刻还是分化前的种类，条件恒为假。
    ///
    /// PRD:469「每个细胞每局游戏仅能分化一次，**每种细胞仅能有一个**」——范围是全阵营。
    /// 这条专测旧代码漏掉的那个情形：**另一个席位**分化成同一种。
    /// </summary>
    [Fact]
    public void 同一种免疫细胞全阵营只能有一个()
    {
        var world = TwoImmuneSeats(firstAlreadyBCell: true);
        var second = new DifferentiateDecision(1, new EntityId(2), CellType.BCell);

        var verdict = PlacementRules.ValidateDifferentiate(world, second);

        Assert.False(verdict.IsValid, "另一个席位不该还能分化成 B 细胞");
    }

    /// <summary>反面：别人占了 B 细胞，我分化成 T 细胞照样可以 —— 去重不能矫枉过正。</summary>
    [Fact]
    public void 别人占了一种不影响我分化成另一种()
    {
        var world = TwoImmuneSeats(firstAlreadyBCell: true);
        var second = new DifferentiateDecision(1, new EntityId(2), CellType.TCell);

        Assert.True(PlacementRules.ValidateDifferentiate(world, second).IsValid);
    }

    /// <summary>
    /// 死亡**不释放**种类 —— 与 GDScript 侧一致（`game.differentiated` 只 append 不 remove）。
    /// 这一条同时钉住「判据不看 IsAlive」这个细节，免得有人「顺手」加回存活过滤。
    /// </summary>
    [Fact]
    public void 分化过的细胞死了也不释放那个种类()
    {
        var world = TwoImmuneSeats(firstAlreadyBCell: true);
        var dead = world.Cells[new EntityId(1)];
        world = world.UpdateCell(dead.Id, dead.Copy(alive: false, energy: 0));

        var second = new DifferentiateDecision(1, new EntityId(2), CellType.BCell);
        Assert.False(PlacementRules.ValidateDifferentiate(world, second).IsValid);
    }

    /// <summary>两个免疫席位，各一只细胞；第一只可选已经分化成 B 细胞。III 级才解锁分化。</summary>
    private static WorldState TwoImmuneSeats(bool firstAlreadyBCell)
    {
        var a = new HexPosition(0, 0, 0);
        var b = new HexPosition(2, 0, -2);
        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [a] = new() { Position = a, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = new EntityId(1), Charge = 0 },
                    [b] = new() { Position = b, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = new EntityId(2), Charge = 0 },
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune,
                    Type = firstAlreadyBCell ? CellType.BCell : CellType.ImmuneBasic,
                    Position = a, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [], Differentiated = firstAlreadyBCell,
                },
                [new EntityId(2)] = new()
                {
                    Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                    Position = b, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 30, ImmuneLevel = ImmuneLevel.III },
                [1] = new() { Seat = 1, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 30, ImmuneLevel = ImmuneLevel.III },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 1 }
        };
    }

    // ---- 八、树突【标记】必须在伤害管线里真的生效 ----
    //
    // 此前 Marked / MarkLeft / MarkRound 三个字段建好了、ApplyMark 也在跑，
    // 但伤害管线里**根本没有这一步** —— MarkLeft 只流进了观测。
    // 于是树突整条标记链（含【交叉呈递】【抗原呈递强化】【免疫猎杀】）零收益，
    // 而 141 个测试一条都不会红。

    [Fact]
    public void 被标记的细胞受到的伤害翻倍并消耗标记()
    {
        var world = MarkedTarget(markLeft: 1);
        var before = world.Cells[new EntityId(2)].Energy;

        var after = CellRules.Damage(world, new EntityId(2), 10);
        var cell = after.Cells[new EntityId(2)];

        Assert.Equal(before - 20, cell.Energy);   // 1.0 → ×2 → 2.0
        Assert.False(cell.Marked);
        Assert.Equal(0, cell.MarkLeft);
    }

    /// <summary>树突【抗原呈递强化】给 2 层：耗掉一层之后还留着。</summary>
    [Fact]
    public void 两层标记耗掉一层之后还在()
    {
        var world = MarkedTarget(markLeft: 2);

        var after = CellRules.Damage(world, new EntityId(2), 10);
        var cell = after.Cells[new EntityId(2)];

        Assert.True(cell.Marked);
        Assert.Equal(1, cell.MarkLeft);
    }

    /// <summary>
    /// ON_BENEFIT：一次 0 伤害不许把标记白白吃掉（GDScript 侧 cw_damage.gd:185 的
    /// `base + bonus > 0` 就是这个意思）。
    /// </summary>
    [Fact]
    public void 零伤害不消耗标记()
    {
        var world = MarkedTarget(markLeft: 1);

        var after = CellRules.Damage(world, new EntityId(2), 0);
        var cell = after.Cells[new EntityId(2)];

        Assert.True(cell.Marked);
        Assert.Equal(1, cell.MarkLeft);
    }

    /// <summary>没被标记的细胞照常扣，不受这条影响。</summary>
    [Fact]
    public void 没被标记就不翻倍()
    {
        var world = MarkedTarget(markLeft: 0);
        var before = world.Cells[new EntityId(2)].Energy;

        var after = CellRules.Damage(world, new EntityId(2), 10);

        Assert.Equal(before - 10, after.Cells[new EntityId(2)].Energy);
    }

    /// <summary>一只免疫 + 一只（可选被标记的）癌细胞。</summary>
    private static WorldState MarkedTarget(int markLeft)
    {
        var world = AttackWorld(new HexPosition(0, 0, 0), new HexPosition(1, 0, -1));
        var target = world.Cells[new EntityId(2)];
        return world.UpdateCell(target.Id, target.Copy(marked: markLeft > 0, markLeft: markLeft, markRound: 1));
    }

    // ---- 九、「每回合第一次」的闸门不许被移动吃掉 ----

    /// <summary>
    /// 四处「每世界回合第一次…」的技能（【模式识别增强】【效应记忆形成】【免疫记忆库】
    /// 与每行动回合的【RAS持续激活】）都是拿一条 Value=0 的**假 Move 修饰**当闸门。
    /// 它们原来写 `Uses = 1`，而移动结算会把**所有** Target==Move 的条目消耗一次 ——
    /// 于是闸门被**下一次移动**吃掉，当场失效。
    ///
    /// 这条复现的就是那个实锤：净化一次拿 0.5，再走一步，同一世界回合**不该**再拿一次。
    /// </summary>
    [Fact]
    public void 每世界回合第一次的闸门不会被下一次移动吃掉()
    {
        // 一条直线：免疫站 (0,0)，右边两格都是癌组织
        var home = new HexPosition(0, 0, 0);
        var first = new HexPosition(1, 0, -1);
        var second = new HexPosition(2, 0, -2);

        var world = PurifyLine(home, first, second, "模式识别增强");
        var engine = new BasicRulesEngine();
        var id = new EntityId(1);

        var start = world.Cells[id].Energy;
        var afterFirst = engine.ExecuteDecision(world, new MoveDecision(0, id, first), new Xoshiro256StarStar(7)).NewState;
        var gainedOnce = afterFirst.Cells[id].Energy;
        var afterSecond = engine.ExecuteDecision(afterFirst, new MoveDecision(0, id, second), new Xoshiro256StarStar(7)).NewState;

        // 第一次净化该拿到 +0.5；第二次**同一世界回合内**不该再拿
        var firstDelta = gainedOnce - start;          // = -第一步费用 + 0.5
        var secondDelta = afterSecond.Cells[id].Energy - gainedOnce;   // = -第二步费用（没有 +0.5）
        Assert.True(secondDelta < firstDelta,
            $"闸门被第二次移动吃掉了：第一次 {firstDelta}、第二次 {secondDelta}（两次都拿到了 +0.5）");
        Assert.True(CellRules.HasModifier(afterSecond.Cells[id], "模式识别增强"),
            "闸门在第二次移动之后应当还挂着");
    }

    /// <summary>一条直线上两格癌组织，免疫细胞装了指定永久技能。</summary>
    private static WorldState PurifyLine(HexPosition home, HexPosition a, HexPosition b, string skill)
    {
        Tissue Tile(HexPosition p, TissueState st, EntityId? occ) =>
            new() { Position = p, Type = TissueType.Normal, State = st, SolidificationCount = 0, OccupyingCell = occ, Charge = 0 };

        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [home] = Tile(home, TissueState.Healthy, new EntityId(1)),
                    [a] = Tile(a, TissueState.Cancer, null),
                    [b] = Tile(b, TissueState.Cancer, null),
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                    Position = home, Energy = 500, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [skill],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    // ---- 十、【癌症转移】（PRD:1465，此前 C# 侧整张缺失） ----

    [Fact]
    public void 癌症转移落到健康组织会触发定殖()
    {
        var home = new HexPosition(0, 0, 0);
        var far = new HexPosition(2, 0, -2);          // 两环内
        var world = MetastasisBoard(home, far);
        var cancer = world.Cells[new EntityId(1)];

        var after = CardRules.Resolve(world, cancer, "癌症转移", new Xoshiro256StarStar(1), far, null);

        Assert.Equal(far, after.Cells[new EntityId(1)].Position);
        Assert.Equal(TissueState.Cancer, after.Board.Tissues[far].State);
        Assert.True(after.Board.Tissues[far].Newborn, "【定殖】造出来的应当是**新生**癌组织");
        Assert.Null(after.Board.Tissues[home].OccupyingCell);
        Assert.Equal(new EntityId(1), after.Board.Tissues[far].OccupyingCell);
    }

    /// <summary>「两环内」是硬边界：三环外的格子不在合法落点里，直接喂进去也不生效。</summary>
    [Fact]
    public void 癌症转移够不到三环外()
    {
        var home = new HexPosition(0, 0, 0);
        var tooFar = new HexPosition(3, 0, -3);
        var world = MetastasisBoard(home, tooFar);
        var cancer = world.Cells[new EntityId(1)];

        Assert.DoesNotContain(tooFar, CardRules.MetastasisTargets(world, cancer));

        var after = CardRules.Resolve(world, cancer, "癌症转移", new Xoshiro256StarStar(1), tooFar, null);
        Assert.Equal(home, after.Cells[new EntityId(1)].Position);
    }

    /// <summary>有细胞占着的格子不是合法落点 —— 一格只能站一个。自己脚下那格也因此自动排除。</summary>
    [Fact]
    public void 癌症转移不能落到有细胞的格子()
    {
        var home = new HexPosition(0, 0, 0);
        var taken = new HexPosition(1, 0, -1);
        var world = MetastasisBoard(home, taken);
        var blocker = new Cell
        {
            Id = new EntityId(9), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
            Position = taken, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
            Hand = [], Equipped = [],
        };
        world = world.AddCell(blocker);
        world = world.WithBoard(world.Board.UpdateTissue(taken, world.Board.Tissues[taken].WithOccupyingCell(blocker.Id)));

        var targets = CardRules.MetastasisTargets(world, world.Cells[new EntityId(1)]);
        Assert.DoesNotContain(taken, targets);
        Assert.DoesNotContain(home, targets);   // 自己脚下
    }

    /// <summary>一个癌细胞在 home，外加一格目标；棋盘铺到三环，够验「够不到」。</summary>
    private static WorldState MetastasisBoard(HexPosition home, HexPosition extra)
    {
        var tiles = new Dictionary<HexPosition, Tissue>();
        for (var q = -3; q <= 3; q++)
            for (var r = -3; r <= 3; r++)
            {
                var p = new HexPosition(q, r, -q - r);
                if (p.DistanceTo(new HexPosition(0, 0, 0)) > 3) continue;
                tiles[p] = new() { Position = p, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = null, Charge = 0 };
            }
        tiles[home] = tiles[home].WithOccupyingCell(new EntityId(1));
        _ = extra;   // 目标格就是普通健康格，不需要额外处理

        return new WorldState
        {
            Board = new Board { Radius = 3, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
                    Position = home, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = ["癌症转移"], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 1 }
        };
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
