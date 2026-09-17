namespace CellWar.Core.Tests;

/// <summary>
/// 【细胞因子网络】+ 强制弃置管线（2026-09-17 深夜，口径一第三批第 5 步；2026-09-16 复核的四条）：
/// GD `_cytokine_chain`：只有免疫细胞打的即时卡走链；先领别人的赏（按 id 序遍历其他活着的免疫细胞，谁身上有「细胞因子网络·待发」就花掉、**打出者** +0.5），
/// 再给自己上膛（装备了、没被中和、身上还没有待发条目 → 挂一条 uses=1、本世界回合到期的条目，占一个打出序号）。
/// C# 此前是一个全局席位槽：没有阵营闸、装备者一有技能就先上膛并 return、+5 给网络主人、永不过期、同席位另一只细胞不触发。
/// 强制弃置：GD `discard_to_limit(cell)` 只问超限的那一只、问到它降到上限为止，且在结算内部问完才让即时卡离手 / 走链。
/// </summary>
public class CytokineNetworkTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId A = new(1);       // 席位 0：免疫，(-4,0)，30
    private static readonly EntityId Cancer = new(2);  // 席位 1：黑色素瘤
    private static readonly EntityId B = new(3);       // 席位 2：免疫，(4,0)，30
    private static readonly EntityId Y = new(9);       // 席位 0 的第二只免疫细胞（测试造的）
    private static HexPosition P(int q, int r) => new(q, r, -q - r);
    private const string Primed = CardRules.CytokinePrimed;

    private static WorldState World()
    {
        var s = DemoScenario.Create();
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
    }

    private static WorldState Equip(WorldState s, EntityId id) => s.UpdateCell(id, s.Cells[id].Copy(equipped: ["细胞因子网络"]));
    private static WorldState Finish(WorldState s, EntityId id, string card = "炎症风暴") => CardRules.FinishInstant(s, id, card);
    private static bool IsPrimed(WorldState s, EntityId id) => CellRules.HasModifier(s.Cells[id], Primed);
    private static int Energy(WorldState s, EntityId id) => s.Cells[id].Energy;

    private static WorldState WithSecondCell(WorldState s)
    {
        var cell = new Cell { Id = Y, OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic, Position = P(-5, 1), Energy = 30, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>() };
        return s.AddCell(cell).UpdateTissueOccupant(P(-5, 1), Y);
    }

    [Fact]
    public void 只有免疫细胞打的即时卡走链_癌方打牌不吃别人的网络()
    {
        var s = Finish(Equip(World(), A), A);
        Assert.True(IsPrimed(s, A));
        var after = Finish(s, Cancer);
        Assert.True(IsPrimed(after, A));
        Assert.Equal(Energy(s, Cancer), Energy(after, Cancer));
    }

    [Fact]
    public void 上膛挂在装备者身上_触发时回能给的是打出者()
    {
        var s = Finish(Equip(World(), A), A);
        Assert.Equal(30, Energy(s, A));
        Assert.True(IsPrimed(s, A));
        var after = Finish(s, B);
        Assert.Equal(35, Energy(after, B));      // 此前给的是网络主人席位的细胞
        Assert.Equal(30, Energy(after, A));
        Assert.False(IsPrimed(after, A));
    }

    [Fact]
    public void 先领别人的赏_再给自己上膛()
    {
        var s = Finish(Equip(World(), B), B);    // B 已上膛
        s = Finish(Equip(s, A), A);              // A 也装备了：此前一有技能就先上膛 return，永远领不到赏
        Assert.Equal(35, Energy(s, A));
        Assert.True(IsPrimed(s, A));
        Assert.False(IsPrimed(s, B));
    }

    [Fact]
    public void 自己连打两张不触发自己_始终只有一条待发()
    {
        var s = Finish(Finish(Equip(World(), A), A), A);
        Assert.Equal(30, Energy(s, A));
        Assert.Equal(1, s.Cells[A].Modifiers.Count(m => m.Card == Primed));
    }

    [Fact]
    public void 同席位的另一只细胞打即时卡照样触发_GD只按细胞id排除自己()
    {
        var s = Finish(Equip(WithSecondCell(World()), A), A);
        var after = Finish(s, Y);
        Assert.Equal(35, Energy(after, Y));      // 此前按席位排除，不给
        Assert.False(IsPrimed(after, A));
    }

    [Fact]
    public void 两只上膛的细胞叠加_一次拿两份()
    {
        // 走链到不了「两只同时上膛」（后上膛的那只打牌时会先把前一只的领走），手摆两条待发钉住循环不 break
        var s = WithSecondCell(World());
        foreach (var id in new[] { A, B })
            s = CellRules.AddModifier(s, s.Cells[id], new ActiveModifier(Primed, ModifierTarget.Flag, ModifierStage.Add, SourceLayer.Skill, 0, 0, null, 1, ModifierDuration.Round));
        var after = Finish(s, Y);
        Assert.Equal(40, Energy(after, Y));
        Assert.False(IsPrimed(after, A));
        Assert.False(IsPrimed(after, B));
    }

    [Fact]
    public void 待发条目本世界回合到期_跨回合不再触发()
    {
        var s = Finish(Equip(World(), A), A);
        var next = CellRules.ExpireRoundModifiers(s);   // GD tick_durations（E 阶段第 8 步）清 round 修饰
        Assert.False(IsPrimed(next, A));
        Assert.Equal(30, Energy(Finish(next, B), B));   // 此前席位槽永不过期
    }

    [Fact]
    public void 被中和的装备者不上膛_已上膛的条目不因中和失效()
    {
        var s = Equip(World(), A);
        var neutralized = s.UpdateCell(A, s.Cells[A].Copy(neutralUntil: s.Turn.WorldRound));
        Assert.False(IsPrimed(Finish(neutralized, A), A));

        var primed = Finish(s, A);
        var primedThenNeutralized = primed.UpdateCell(A, primed.Cells[A].Copy(neutralUntil: primed.Turn.WorldRound));
        Assert.Equal(35, Energy(Finish(primedThenNeutralized, B), B));   // GD 触发侧只调 spend_mods，不看 has_skill
    }

    [Fact]
    public void 上膛的细胞死了_网络就哑()
    {
        var s = Finish(Equip(World(), A), A);
        var dead = CellRules.Kill(s, A);
        Assert.Equal(30, Energy(Finish(dead, B), B));
    }

    [Fact]
    public void 上膛占一个打出序号_条目形状进L1视图()
    {
        var s = Equip(World(), A);
        var before = s.Cells[A].PlayCounter;
        var after = Finish(s, A);
        Assert.Equal(before + 1, after.Cells[A].PlayCounter);                       // GD add_mod：play_n += 1
        var m = Assert.Single(after.Cells[A].Modifiers, x => x.Card == Primed);
        Assert.Equal(1, m.Uses);
        Assert.Equal(ModifierDuration.Round, m.Duration);
        Assert.Equal(before + 1, m.Sequence);
    }

    [Fact]
    public void 离手只摘第一张同名()
    {
        var s = World();
        s = s.UpdateCell(A, s.Cells[A].Copy(hand: ["炎症风暴", "炎症风暴"]));
        Assert.Single(Finish(s, A, "炎症风暴").Cells[A].Hand);                       // 此前 Where(x != card) 两张全摘
    }

    [Fact]
    public void 永久卡打出即装备_不进结算也不碰card_resolve_depth()
    {
        var s = World();
        s = s.UpdateCell(A, s.Cells[A].Copy(hand: ["细胞因子网络"]));
        var r = Engine.ExecuteDecision(s, new PlayCardDecision(0, A, "细胞因子网络", null, null), new Xoshiro256StarStar(3));
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Contains("细胞因子网络", r.NewState.Cells[A].Equipped);
        Assert.Empty(r.NewState.Cells[A].Hand);
        Assert.Equal(0, r.NewState.Turn.CardResolveDepth);
        Assert.Null(r.NewState.Turn.PendingCard);
        Assert.False(IsPrimed(r.NewState, A));                                        // 永久卡不走链
    }

    [Fact]
    public void 结算里骨髓抽卡撑爆手牌_先弃置再离手_刚打出的那张也在可弃之列()
    {
        var s = World();
        var filler = Enumerable.Repeat("细胞膜修复", 7).Append("炎症性趋化").ToList();   // 8 张 = 上限
        s = s.UpdateCell(A, s.Cells[A].Copy(hand: filler));
        s = s.WithBoard(s.Board.UpdateTissue(P(-2, -2), s.Board.Tissues[P(-2, -2)].WithType(TissueType.BoneMarrow).WithCharge(1)));
        var played = Engine.ExecuteDecision(s, new PlayCardDecision(0, A, "炎症性趋化", P(-3, 0), null), new Xoshiro256StarStar(1));
        Assert.True(played.Success, played.ErrorMessage);
        var step2 = Engine.ExecuteDecision(played.NewState, new ChemotaxisStepDecision(0, A, P(-3, -1)), new Xoshiro256StarStar(1));
        Assert.True(step2.Success, step2.ErrorMessage);

        for (var seed = 1; seed <= 200; seed++)
        {
            var r = Engine.ExecuteDecision(step2.NewState, new ChemotaxisStepDecision(0, A, P(-2, -2)), new Xoshiro256StarStar((ulong)seed));   // 第 3 步踩骨髓抽一张
            Assert.True(r.Success, r.ErrorMessage);
            var t = r.NewState;
            if (t.Turn.PendingDiscardSeat is null) continue;   // 抽到的是抽到即结算的事件卡，没进手：换颗种子

            Assert.Equal(A, t.Turn.PendingDiscardCell);
            Assert.Equal("炎症性趋化", t.Turn.PendingCard);                 // 还没离手、链还没走
            Assert.Contains("炎症性趋化", t.Cells[A].Hand);
            Assert.Equal(A, t.Turn.PendingChemotaxisCell);                 // 连走的挂起也不摘：弃置排在最前
            var options = Engine.GetAvailableDecisions(t, 0);
            Assert.All(options, d => Assert.IsType<DiscardDecision>(d));
            Assert.Equal(9, options.Count);
            Assert.Contains(options, d => d is DiscardDecision { CellId: var c, Card: "炎症性趋化" } && c == A);

            var done = Engine.ExecuteDecision(t, new DiscardDecision(0, A, "炎症性趋化"), new Xoshiro256StarStar(1));   // 把刚打出的那张弃掉
            Assert.True(done.Success, done.ErrorMessage);
            Assert.Null(done.NewState.Turn.PendingDiscardSeat);
            Assert.Null(done.NewState.Turn.PendingCard);                    // 弃完才收尾（erase 变成空操作）
            Assert.Null(done.NewState.Turn.PendingChemotaxisCell);
            Assert.Equal(8, done.NewState.Cells[A].Hand.Count);
            Assert.DoesNotContain("炎症性趋化", done.NewState.Cells[A].Hand);
            return;
        }
        Assert.Fail("200 颗种子骨髓抽到的全是抽到即结算的卡，没撑爆过手牌");
    }

    [Fact]
    public void 强制弃置只问超限的那一只细胞()
    {
        var s = WithSecondCell(World());
        s = s.UpdateCell(A, s.Cells[A].Copy(hand: Enumerable.Repeat("细胞膜修复", 8).ToList()));
        s = s.UpdateCell(Y, s.Cells[Y].Copy(hand: ["炎症风暴"]));
        s = CellRules.AddToHand(s, s.Cells[A], "炎症风暴");                     // A 撑到 9
        Assert.Equal(A, s.Turn.PendingDiscardCell);
        var options = Engine.GetAvailableDecisions(s, 0);
        Assert.Equal(9, options.Count);
        Assert.All(options, d => Assert.Equal(A, ((DiscardDecision)d).CellId));   // 此前把 Y 的手牌也摊出来
        Assert.False(Engine.ValidateDecision(s, new DiscardDecision(0, Y, "炎症风暴")).IsValid);
    }
}
