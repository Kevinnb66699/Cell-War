namespace CellWar.Core.Tests;

/// <summary>
/// 【基质重塑】三问（2026-09-17 深夜，口径一第三批第 6 步）：GD `_remodel`（cw_card_fx.gd:934-969）零随机 ——
/// 手牌选项选定第 1 格固化先拆；「还可再拆 1 格」（候选 = 重算后的 2 环内固化，为空不问）；「选择要转健康的癌组织」×2
/// （候选 = 拆过的格自身 + DIRS 序相邻格里无细胞占据的普通癌组织，跨格去重，为空不问也不再问）。每段都可「停」，停不是取消：卡照常离手。
/// C# 此前一次性同步跑完：强制拆第 2 格、从「距施法者 ≤2 或挨着任一固化格」里随机转两格（两发随机、候选域是 GD 的超集）。
/// </summary>
public class RemodelTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，站 (-4,0)；黑色素瘤站 (-1,0)
    private static HexPosition P(int q, int r) => new(q, r, -q - r);
    private const string Card = "基质重塑";

    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));
    private static WorldState Solid(WorldState s, HexPosition p) => Tissue(s, p, t => t.WithState(TissueState.SolidifiedCancer).WithSolidificationCount(30));

    /// <summary>固化 (-3,0) 与 (-2,0)（都在施法者 2 格内、互为邻格）；(-4,2) 是距施法者 2 格但不挨着任何拆点的普通癌组织（旧候选域会多给它）。</summary>
    private static WorldState World()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: [Card]));
        s = Solid(s, P(-3, 0));
        s = Solid(s, P(-2, 0));
        return Tissue(s, P(-4, 2), t => t.WithState(TissueState.Cancer));
    }

    private static WorldState Do(WorldState s, IDecision d, RecordingRng rng)
    {
        var r = Engine.ExecuteDecision(s, d, rng);
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    private static RecordingRng Rng() => new(new Xoshiro256StarStar(5));
    private static IReadOnlyList<HexPosition> Picks(WorldState s) => Engine.GetAvailableDecisions(s, 0).OfType<RemodelPickDecision>().Select(d => d.Target).ToList();

    private static void AssertHealthyFive(Tissue t)
    {
        Assert.Equal(TissueState.Healthy, t.State);
        Assert.Equal(0, t.SolidificationCount);
        Assert.False(t.Newborn);
        Assert.Equal(0, t.NecrosisRounds);
        Assert.Equal(0, t.OssifyAtRound);
    }

    [Fact]
    public void 打出即拆第一格_挂起再拆一问_卡还在手里()
    {
        var rng = Rng();
        var s = Do(World(), new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), rng);
        var cracked = s.Board.Tissues[P(-3, 0)];
        Assert.Equal(TissueState.Cancer, cracked.State);
        Assert.Equal(0, cracked.SolidificationCount);
        Assert.False(cracked.Newborn);                      // crack_to_cancer = to_cancer(false)
        Assert.Equal(Immune0, s.Turn.PendingRemodelCell);
        Assert.Equal(0, s.Turn.PendingRemodelStep);
        Assert.Equal(P(-3, 0), s.Turn.PendingRemodelFirst);
        Assert.Equal(Card, s.Turn.PendingCard);
        Assert.Contains(Card, s.Cells[Immune0].Hand);
        var options = Engine.GetAvailableDecisions(s, 0);
        Assert.IsType<StopRemodelDecision>(options[0]);    // GD 下标 0
        Assert.Equal(new[] { P(-2, 0) }, Picks(s));         // 重算后的 2 环内固化：第 1 格已出局
        Assert.Empty(rng.Ranges);
    }

    [Fact]
    public void 再拆一格_转健康候选是拆过的格自身与DIRS序邻格_跨格去重_不含施法者附近的别的癌组织()
    {
        var rng = Rng();
        var s = Do(World(), new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), rng);
        s = Do(s, new RemodelPickDecision(0, Immune0, P(-2, 0)), rng);
        Assert.Equal(1, s.Turn.PendingRemodelStep);
        Assert.Equal(P(-2, 0), s.Turn.PendingRemodelSecond);
        Assert.Equal(TissueState.Cancer, s.Board.Tissues[P(-2, 0)].State);
        // (-3,0) 自身 → 邻格 (-2,0)（其余邻格都健康）；(-2,0) 自身已见过 → 邻格 (-1,0) 有黑色素瘤站着不算、(-1,-1)、(-2,1)
        Assert.Equal(new[] { P(-3, 0), P(-2, 0), P(-1, -1), P(-2, 1) }, Picks(s));
        Assert.DoesNotContain(P(-4, 2), Picks(s));          // 旧候选域「距施法者 ≤2」会多给它
        Assert.Equal("k=pick_tile|g=基质重塑|to=-3,0", SemanticKey.Of(s, new RemodelPickDecision(0, Immune0, P(-3, 0))));
        Assert.Equal("k=pick_tile|g=基质重塑|stop=1", SemanticKey.Of(s, new StopRemodelDecision(0, Immune0)));
        Assert.Empty(rng.Ranges);
    }

    [Fact]
    public void 两次转健康走完_卡收尾离手_全程零随机()
    {
        var rng = Rng();
        var s = Do(World(), new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), rng);
        s = Do(s, new RemodelPickDecision(0, Immune0, P(-2, 0)), rng);
        s = Do(s, new RemodelPickDecision(0, Immune0, P(-3, 0)), rng);
        AssertHealthyFive(s.Board.Tissues[P(-3, 0)]);
        Assert.Equal(2, s.Turn.PendingRemodelStep);
        Assert.Equal(new[] { P(-2, 0), P(-1, -1), P(-2, 1) }, Picks(s));   // 转健康的那格重算时掉出候选
        s = Do(s, new RemodelPickDecision(0, Immune0, P(-2, 0)), rng);
        AssertHealthyFive(s.Board.Tissues[P(-2, 0)]);
        Assert.Null(s.Turn.PendingRemodelCell);
        Assert.Null(s.Turn.PendingCard);
        Assert.Empty(s.Cells[Immune0].Hand);
        Assert.NotEmpty(Engine.GetAvailableDecisions(s, 0).OfType<MoveDecision>());   // 回到行动栏
        Assert.Empty(rng.Ranges);                            // 此前是两发 PickRandom
    }

    [Fact]
    public void 只拆这一格_直接进转健康那一段()
    {
        var rng = Rng();
        var s = Do(World(), new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), rng);
        s = Do(s, new StopRemodelDecision(0, Immune0), rng);
        Assert.Equal(1, s.Turn.PendingRemodelStep);
        Assert.Null(s.Turn.PendingRemodelSecond);
        Assert.Equal(TissueState.SolidifiedCancer, s.Board.Tissues[P(-2, 0)].State);
        Assert.Equal(new[] { P(-3, 0) }, Picks(s));         // 没拆的 (-2,0) 还是固化，不是候选
    }

    [Fact]
    public void 到此为止不是取消_卡照常离手()
    {
        var rng = Rng();
        var s = Do(World(), new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), rng);
        s = Do(s, new RemodelPickDecision(0, Immune0, P(-2, 0)), rng);
        s = Do(s, new StopRemodelDecision(0, Immune0), rng);
        Assert.Null(s.Turn.PendingRemodelCell);
        Assert.Empty(s.Cells[Immune0].Hand);                 // 对照【代谢耦联】的取消：卡不弃置
        Assert.Equal(TissueState.Cancer, s.Board.Tissues[P(-3, 0)].State);
        Assert.Equal(TissueState.Cancer, s.Board.Tissues[P(-2, 0)].State);
    }

    [Fact]
    public void 只有一格固化_不问再拆_直接问转健康()
    {
        var s = Tissue(World(), P(-2, 0), t => t.WithState(TissueState.Cancer).WithSolidificationCount(0));
        s = Do(s, new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), Rng());
        Assert.Equal(1, s.Turn.PendingRemodelStep);
        Assert.Equal(new[] { P(-3, 0), P(-2, 0) }, Picks(s));
    }

    [Fact]
    public void 两道闸连着命中_一问不出_当场收尾()
    {
        // 施法者站在唯一的固化格上：拆完它自己占着（不是候选）、邻格全健康 → 再拆没有、转健康也没有
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: [Card]));
        s = Solid(s, P(-4, 0));
        s = Do(s, new PlayCardDecision(0, Immune0, Card, P(-4, 0), null), Rng());
        Assert.Equal(TissueState.Cancer, s.Board.Tissues[P(-4, 0)].State);
        Assert.Null(s.Turn.PendingRemodelCell);
        Assert.Null(s.Turn.PendingCard);
        Assert.Empty(s.Cells[Immune0].Hand);
    }

    [Fact]
    public void 挂起期间只接主人_别的动作一律驳回()
    {
        var s = Do(World(), new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), Rng());
        Assert.False(Engine.ValidateDecision(s, new EndTurnDecision(0)).IsValid);
        Assert.False(Engine.ValidateDecision(s, new MoveDecision(0, Immune0, P(-4, 1))).IsValid);
        Assert.False(Engine.ValidateDecision(s, new StopRemodelDecision(2, Immune0)).IsValid);
        Assert.False(Engine.ValidateDecision(s, new RemodelPickDecision(0, Immune0, P(-4, 2))).IsValid);   // 不在候选里
        Assert.Empty(Engine.GetAvailableDecisions(s, 2));
    }

    [Fact]
    public void 转健康五项清零()
    {
        var s = Tissue(World(), P(-2, 1), t => t.WithSolidificationCount(20).WithNewborn(true).WithNecrosis(1).WithOssifyAt(3));
        s = Do(s, new PlayCardDecision(0, Immune0, Card, P(-3, 0), null), Rng());
        s = Do(s, new RemodelPickDecision(0, Immune0, P(-2, 0)), Rng());
        s = Do(s, new RemodelPickDecision(0, Immune0, P(-2, 1)), Rng());
        AssertHealthyFive(s.Board.Tissues[P(-2, 1)]);
    }
}
