using CellWar.Core.Observation;

namespace CellWar.Core.Tests.Tuning;

/// <summary>
/// K2 · 流程 / 全局开关三个旋钮（口径二 E-3，12 个旋钮进内核）：
/// `anaerobic_on_turn_end` / `world_events_on` / `cancer_win_hold_rounds`，外加观测协议 `tune` 块的三个键。
///
/// 每一条的期望都移植自 GD `game/tests/headless_test.gd`（`source` 注释指到那边的 check 名），
/// 默认值一律 = `game/scripts/core/cw_tuning.gd` 今天的值 —— 这一组同时是「零行为改动」的判据：
/// 默认档下每一处替换都必须与旋钮化之前的字面量等价。
/// </summary>
public class K2_FlowKnobTests
{
    private static RuleTuning Base => RuleTuning.Default;

    // ================= ① 默认值（文档钉子）=================

    /// <summary>
    /// 三个旋钮的默认值逐个等于 GD 今天的默认值：
    ///   · `cw_tuning.gd:117  var anaerobic_on_turn_end := false`（Kevin 2026-09-06 改回 E 阶段统一结算）
    ///   · `cw_tuning.gd:330  var world_events_on := false`（2026-09-10 起默认关，云端 PRD「暂时停止维护」）
    ///   · `cw_tuning.gd:297  var cancer_win_hold_rounds := CWData.CANCER_WIN_HOLD_ROUNDS`，`cw_data.gd:42 = 2`
    /// source: headless_test.gd `t_cancer_win_hold` 首条 check、`t_balance_knobs` ④ 的「默认 E 阶段统一结算」。
    /// </summary>
    [Fact]
    public void 三个流程旋钮的默认值就是GD今天的值()
    {
        Assert.False(Base.AnaerobicOnTurnEnd);
        Assert.False(Base.WorldEventsOn);
        Assert.Equal(2, Base.CancerWinHoldRounds);
    }

    // ================= ② cancer_win_hold_rounds =================

    /// <summary>
    /// hold = 1（定案 B 之前的旧规则）：第一次达标就判胜。
    /// source: headless_test.gd `t_cancer_win_hold`「hold=1（旧规则）：第一次达标就判胜」。
    /// </summary>
    [Fact]
    public void 占地胜利hold为1时第一次达标就判胜()
    {
        var world = Weighted(90, streak: 0).WithTuning(Base with { CancerWinHoldRounds = 1 });

        var (winner, streak, kind) = OutcomeRules.Evaluate(world);

        Assert.Equal(Faction.Cancer, winner);
        Assert.Equal(1, streak);
        Assert.Equal("cancer_weighted", kind);
    }

    /// <summary>
    /// hold = 2（默认）：第一次达标只拉警报（计数 1），连续第二个世界回合末仍达标（计数 2）才判胜。
    /// 计数器 `CancerWinStreak` 与 GD `cancer_win_streak` 同义（2026-09-19 起）。
    /// source: headless_test.gd `t_cancer_win_hold`「hold=2：第一次达标不判胜，计数 1」+「连续第二个回合末仍达标 → 判胜」。
    /// </summary>
    [Fact]
    public void 占地胜利hold为2时第一次达标只报警第二次才判胜()
    {
        var first = Weighted(90, streak: 0);
        var (w1, s1, kind1) = OutcomeRules.Evaluate(first);
        Assert.Null(w1);
        Assert.Equal(1, s1);
        Assert.Equal("", kind1);

        var second = Weighted(90, streak: 1);
        var (w2, s2, kind2) = OutcomeRules.Evaluate(second);
        Assert.Equal(Faction.Cancer, w2);
        Assert.Equal(2, s2);
        Assert.Equal("cancer_weighted", kind2);
    }

    /// <summary>
    /// hold = 2：中途掉到线下，计数归零；再次达标要从 1 重新数。
    /// source: headless_test.gd `t_cancer_win_hold`「回落到线下：计数归零」+「再次达标要从 1 重新数，不能沿用旧计数」。
    /// </summary>
    [Fact]
    public void 占地胜利hold为2时回落到线下计数归零再达标从1数()
    {
        var (w1, s1, _) = OutcomeRules.Evaluate(Weighted(89, streak: 1));   // 89 < 90
        Assert.Null(w1);
        Assert.Equal(0, s1);

        var (w2, s2, _) = OutcomeRules.Evaluate(Weighted(90, streak: 0));
        Assert.Null(w2);
        Assert.Equal(1, s2);
    }

    /// <summary>
    /// hold = 3：真计数器数得出三连 —— 2026-09-19 之前 C# 只存「上一次达标的回合号」，这里只能抛错；Kevin 拍板改计数器。
    /// </summary>
    [Fact]
    public void 占地胜利hold为3时要连续三个回合末达标()
    {
        var tune = Base with { CancerWinHoldRounds = 3 };
        var (w2, s2, _) = OutcomeRules.Evaluate(Weighted(90, streak: 1).WithTuning(tune));
        Assert.Null(w2);
        Assert.Equal(2, s2);

        var (w3, s3, kind3) = OutcomeRules.Evaluate(Weighted(90, streak: 2).WithTuning(tune));
        Assert.Equal(Faction.Cancer, w3);
        Assert.Equal(3, s3);
        Assert.Equal("cancer_weighted", kind3);
    }

    // ================= ③ anaerobic_on_turn_end =================

    /// <summary>
    /// 默认（false）：E 阶段第 1 步统一结算，行动回合末**不进账**。
    /// source: headless_test.gd `t_balance_knobs` ④「默认：回合末不进账」+「默认：E 阶段一次算」。
    /// </summary>
    [Fact]
    public void 无氧默认在E阶段结算回合末不进账()
    {
        var world = LoneCancer();
        var id = new EntityId(1);
        var share = RulePolicies.AnaerobicShare(world, world.Cells[id]);
        Assert.True(share > 0, "夹具要保证这一块真有进账，否则两档分不开");

        var ended = PhaseRules.AdvancePhase(Acting(world), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(0, ended.Cells[id].Energy);

        var evolved = BoardRules.EvolveEndOfRoundA(world, new Xoshiro256StarStar(1));
        Assert.Equal(share, evolved.Cells[id].Energy);
    }

    /// <summary>
    /// 拨成回合末（true，扫描的 `eturn=1`）：自己的行动回合末进账，E 阶段那一步**不再重复算**。
    /// 口径 = GD `CWWorld.settle_anaerobic_turn`（走同一个 `anaerobic_gain_for` / `AnaerobicShare`）。
    /// source: headless_test.gd `t_balance_knobs` ④ 的 `eturn=1` 对照档。
    /// </summary>
    [Fact]
    public void 无氧拨到回合末就在回合末进账且E阶段不再算()
    {
        var world = LoneCancer().WithTuning(Base with { AnaerobicOnTurnEnd = true });
        var id = new EntityId(1);
        var share = RulePolicies.AnaerobicShare(world, world.Cells[id]);

        var ended = PhaseRules.AdvancePhase(Acting(world), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(share, ended.Cells[id].Energy);

        var evolved = BoardRules.EvolveEndOfRoundA(world, new Xoshiro256StarStar(1));
        Assert.Equal(0, evolved.Cells[id].Energy);
    }

    /// <summary>免疫细胞的回合末不吃这条分支（GD 的判据是 `cell["faction"] == CANCER`）。</summary>
    [Fact]
    public void 回合末结算只给活着的癌细胞()
    {
        var world = LoneCancer(immuneSeat: true).WithTuning(Base with { AnaerobicOnTurnEnd = true });
        var immune = new EntityId(2);
        var before = world.Cells[immune].Energy;

        // 轮到免疫那一席结束回合：它不是癌细胞，一分不进
        var acting = world.WithTurn(world.Turn.Copy(phase: Phase.PlayerAction, seat: 1));
        var ended = PhaseRules.AdvancePhase(acting, new Xoshiro256StarStar(1)).NewState;

        Assert.Equal(before, ended.Cells[immune].Energy);
    }

    // ================= ④ world_events_on + 观测协议 tune 块 =================

    /// <summary>
    /// 观测协议 `$.g.tune` 的三个键跟着旋钮走（GD `cw_obs_codec.gd:239-242` 逐个读 `game.tune.*`）；
    /// `$.g.cancer_alarm.hold_rounds` 同一个旋钮（GD `cw_obs_codec.gd:231`）。
    /// 默认档的值 = 旋钮化之前写死的字面量（false / 2 / 20）—— 这就是零行为改动那一条。
    /// </summary>
    [Fact]
    public void 观测协议tune块的三个键默认值不变()
    {
        using var session = new MatchSession(DemoScenario.Create());
        var g = session.ObserveV1(ObservationV1Codec.ViewerOmniscient).State.G;

        Assert.False(g.Tune.WorldEventsOn);
        Assert.Equal(2, g.Tune.CancerWinHoldRounds);
        Assert.Equal(20, g.Tune.OsteoOssifyCost);
        Assert.Equal(2, g.CancerAlarm.HoldRounds);
    }

    /// <summary>拧一下，三个键都跟着变（旋钮化之前这三个是常量，拧了也纹丝不动 —— 这条就是那个判据）。</summary>
    [Fact]
    public void 观测协议tune块的三个键跟着旋钮走()
    {
        var world = DemoScenario.Create();
        world = world.WithTuning(world.Tuning with { WorldEventsOn = true, CancerWinHoldRounds = 1, OsteoOssifyCost = 77 });
        using var session = new MatchSession(world);
        var g = session.ObserveV1(ObservationV1Codec.ViewerOmniscient).State.G;

        Assert.True(g.Tune.WorldEventsOn);
        Assert.Equal(1, g.Tune.CancerWinHoldRounds);
        Assert.Equal(77, g.Tune.OsteoOssifyCost);
        Assert.Equal(1, g.CancerAlarm.HoldRounds);
    }

    // ================= 夹具 =================

    /// <summary>加权占地 = `score` 的盘面（全是普通癌组织，1 格 1 分），`streak` = 进入这一回合末之前的连续达标计数。</summary>
    private static WorldState Weighted(int score, int streak)
    {
        var tiles = new Dictionary<HexPosition, Tissue>();
        for (var i = 0; i < score; i++)
        {
            var p = new HexPosition(i, -i, 0);
            tiles[p] = new Tissue { Position = p, Type = TissueType.Normal, State = TissueState.Cancer, SolidificationCount = 0, OccupyingCell = null, Charge = 0 };
        }
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>(),
            Players = new Dictionary<int, Player>
            {
                [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma },
            },
            Turn = new TurnState { WorldRound = 4, Phase = Phase.E, ActivePlayerSeat = 1, CancerWinStreak = streak },
        };
    }

    /// <summary>七格癌组织块、块里只有一个能量为 0 的癌细胞（= GD `t_balance_knobs` ④ 的那个夹具）。</summary>
    private static WorldState LoneCancer(bool immuneSeat = false)
    {
        var at = new HexPosition(0, 0, 0);
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [at] = new() { Position = at, Type = TissueType.Normal, State = TissueState.Cancer, SolidificationCount = 0, OccupyingCell = new EntityId(1), Charge = 0 },
        };
        foreach (var n in at.GetNeighbors())
            tiles[n] = new Tissue { Position = n, Type = TissueType.Normal, State = TissueState.Cancer, SolidificationCount = 0, OccupyingCell = null, Charge = 0 };

        var cells = new Dictionary<EntityId, Cell>
        {
            [new EntityId(1)] = new()
            {
                Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Cancer, Type = CellType.Melanoma,
                Position = at, Energy = 0, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(), Hand = [], Equipped = [],
            },
        };
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma },
        };
        if (immuneSeat)
        {
            var far = new HexPosition(3, -3, 0);
            tiles[far] = new Tissue { Position = far, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = new EntityId(2), Charge = 0 };
            cells[new EntityId(2)] = new()
            {
                Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                Position = far, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(), Hand = [], Equipped = [],
            };
            players[1] = new() { Seat = 1, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };
        }

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = cells,
            Players = players,
            Turn = new TurnState { WorldRound = 3, Phase = Phase.E, ActivePlayerSeat = 0 },
        };
    }

    /// <summary>把夹具摆成「0 号席正在行动」，好让 <see cref="PhaseRules.AdvancePhase"/> 走结束回合那一支。</summary>
    private static WorldState Acting(WorldState s) => s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0));
}
