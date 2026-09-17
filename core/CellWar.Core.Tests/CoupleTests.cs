using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests;

/// <summary>
/// 【代谢耦联】跟 GD 的三问形状（Kevin 2026-09-16 拍板，外加一个「取消」）：
/// 打出时按队友逐个出选项 → 问方向（送给 / 索取）→ 问档位（1.0→1.2 / 1.5→2.0 / 2.0→2.5）；
/// 两问的下标 0 都是「取消」：无效果、**卡不弃置**。权威实现 cw_card_fx.gd `_couple` / `_couple_tiers`。
/// </summary>
public class CoupleTests
{
    private const string Card = "代谢耦联";
    private static readonly EntityId Me = new(1);     // DemoScenario 席位 0：免疫
    private static readonly EntityId Ally = new(3);   // 席位 2：免疫（唯一的队友）
    private static readonly BasicRulesEngine Engine = new();
    private static IDeterministicRng Rng() => new Xoshiro256StarStar(3);

    private static WorldState World(int myEnergy = 30, int allyEnergy = 30)
    {
        var s = DemoScenario.Create();
        s = s.UpdateCell(Me, s.Cells[Me].Copy(hand: [Card], energy: myEnergy))
             .UpdateCell(Ally, s.Cells[Ally].Copy(energy: allyEnergy));
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
    }

    private static WorldState Do(WorldState s, IDecision d)
    {
        var r = Engine.ExecuteDecision(s, d, Rng());
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    private static WorldState Play(WorldState s) => Do(s, new PlayCardDecision(0, Me, Card, null, Ally));

    [Fact]
    public void 选项按队友逐个摊开_双方都付不起最低档的队友不出现()
    {
        var plays = Engine.GetAvailableDecisions(World(), 0).OfType<PlayCardDecision>().Where(p => p.Card == Card).ToList();
        Assert.Single(plays);
        Assert.Equal(Ally, plays[0].TargetCell);

        // 1.0 那档要付完还留正能量：两边都只有 0.8 → 谁也付不起 → 这条选项不出现（GD hand_options 那条）
        Assert.DoesNotContain(Engine.GetAvailableDecisions(World(8, 8), 0).OfType<PlayCardDecision>(), p => p.Card == Card);
        Assert.False(Engine.ValidateDecision(World(), new PlayCardDecision(0, Me, Card)).IsValid);   // 没选队友不行
    }

    [Fact]
    public void 打出之后先问方向_下标零是取消_方向只列付得起的那一侧()
    {
        var pending = Play(World());
        Assert.Equal(Me, pending.Turn.PendingCoupleCell);
        Assert.Equal(Ally, pending.Turn.PendingCoupleAlly);
        Assert.Null(pending.Turn.PendingCouplePayer);
        Assert.Equal(Card, pending.Turn.PendingCard);                 // 结算到一半：卡还在手上
        Assert.Contains(Card, pending.Cells[Me].Hand);

        var opts = Engine.GetAvailableDecisions(pending, 0);
        Assert.IsType<CancelCoupleDecision>(opts[0]);
        Assert.Equal(new[] { (Me, Ally), (Ally, Me) },
            opts.OfType<CoupleDirectionDecision>().Select(d => (d.Payer, d.Getter)).ToArray());

        // 队友付不起 → 「索取」那个方向不存在（GD：dirs 只在那一侧 _couple_tiers 非空时才 append）
        var onlySend = Engine.GetAvailableDecisions(Play(World(30, 8)), 0).OfType<CoupleDirectionDecision>().ToList();
        Assert.Single(onlySend);
        Assert.Equal((Me, Ally), (onlySend[0].Payer, onlySend[0].Getter));
    }

    [Fact]
    public void 选定方向再问档位_档位按付方能量筛_取消仍在下标零()
    {
        var pending = Do(Play(World(myEnergy: 16)), new CoupleDirectionDecision(0, Me, Me, Ally));
        Assert.Equal(Me, pending.Turn.PendingCouplePayer);

        var opts = Engine.GetAvailableDecisions(pending, 0);
        Assert.IsType<CancelCoupleDecision>(opts[0]);
        // 1.6 能量：1.0 与 1.5 付完都还留正数，2.0 不行
        Assert.Equal(new[] { (10, 12), (15, 20) }, opts.OfType<CoupleTierDecision>().Select(t => (t.Pay, t.Get)).ToArray());
        Assert.False(Engine.ValidateDecision(pending, new CoupleTierDecision(0, Me, 20, 25)).IsValid);

        // **正好等于档位**的那一档不给：付完是 0，GD `payer["energy"] > pay`（变异检验抓出来的边界）
        var exact = Do(Play(World(myEnergy: 15)), new CoupleDirectionDecision(0, Me, Me, Ally));
        Assert.Equal(new[] { (10, 12) }, Engine.GetAvailableDecisions(exact, 0).OfType<CoupleTierDecision>().Select(t => (t.Pay, t.Get)).ToArray());
        // 正好 1.0 连最低档都付不起 → 队友那侧也付不起时这张卡根本不出现
        Assert.DoesNotContain(Engine.GetAvailableDecisions(World(10, 10), 0).OfType<PlayCardDecision>(), p => p.Card == Card);
    }

    [Fact]
    public void 选定档位就转移_然后卡才离手()
    {
        var pending = Do(Play(World()), new CoupleDirectionDecision(0, Me, Me, Ally));
        var done = Do(pending, new CoupleTierDecision(0, Me, 15, 20));

        Assert.Equal(15, done.Cells[Me].Energy);
        Assert.Equal(50, done.Cells[Ally].Energy);
        Assert.Null(done.Turn.PendingCoupleCell);
        Assert.Null(done.Turn.PendingCard);
        Assert.DoesNotContain(Card, done.Cells[Me].Hand);   // 结算完才弃置（GD _resolve_played 的尾巴）
    }

    [Fact]
    public void 索取方向是队友付_自己得()
    {
        var pending = Do(Play(World()), new CoupleDirectionDecision(0, Me, Ally, Me));
        var done = Do(pending, new CoupleTierDecision(0, Me, 10, 12));

        Assert.Equal(20, done.Cells[Ally].Energy);
        Assert.Equal(42, done.Cells[Me].Energy);
    }

    [Fact]
    public void 两问里取消都是无效果_卡不弃置()
    {
        var atDirection = Do(Play(World()), new CancelCoupleDecision(0, Me));
        Assert.Equal(30, atDirection.Cells[Me].Energy);
        Assert.Equal(30, atDirection.Cells[Ally].Energy);
        Assert.Contains(Card, atDirection.Cells[Me].Hand);
        Assert.Null(atDirection.Turn.PendingCoupleCell);
        Assert.Null(atDirection.Turn.PendingCard);
        Assert.False(CellRules.HasModifier(atDirection.Cells[Me], CardRules.CytokinePrimed));   // 没算「发动完」，网络不上膛
        Assert.NotEmpty(Engine.GetAvailableDecisions(atDirection, 0).OfType<MoveDecision>());   // 回到行动栏

        var atTier = Do(Do(Play(World()), new CoupleDirectionDecision(0, Me, Me, Ally)), new CancelCoupleDecision(0, Me));
        Assert.Equal(30, atTier.Cells[Me].Energy);
        Assert.Contains(Card, atTier.Cells[Me].Hand);
        Assert.Null(atTier.Turn.PendingCoupleCell);
    }

    [Fact]
    public void 追问只接主人_别的席位一律驳回()
    {
        var pending = Play(World());
        Assert.False(Engine.ValidateDecision(pending, new CancelCoupleDecision(2, Me)).IsValid);
        Assert.False(Engine.ValidateDecision(pending, new CoupleDirectionDecision(2, Me, Me, Ally)).IsValid);
        Assert.False(Engine.ValidateDecision(pending, new MoveDecision(0, Me, new HexPosition(-3, 0, 3))).IsValid);   // 挂起期间别的动作也不行
        Assert.Empty(Engine.GetAvailableDecisions(pending, 2));
    }

    [Fact]
    public void 语义键照GD的两问()
    {
        var s = Play(World());
        Assert.Equal("k=pick|g=代谢耦联|from=0|to_cid=2", SemanticKey.Of(s, new CoupleDirectionDecision(0, Me, Me, Ally)));
        Assert.Equal("k=pick|g=代谢耦联|pay=15|get=20", SemanticKey.Of(s, new CoupleTierDecision(0, Me, 15, 20)));
        Assert.Equal("k=pick|g=代谢耦联|stop=1", SemanticKey.Of(s, new CancelCoupleDecision(0, Me)));
    }
}
