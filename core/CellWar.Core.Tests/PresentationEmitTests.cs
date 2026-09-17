namespace CellWar.Core.Tests;

/// <summary>
/// 口径二 · 批 0 步 6（一）：规则代码里的演出 emit 点（docs/口径二_批0_底座规格.md A-4.2）。
/// 钉的是「GD 在哪一刻演什么」：攻击的骰子 / 判词 / AttackResolved / 本体冲撞、【高亲和力克隆】不掷骰、定殖过场的方向、出牌与抽卡通报。
/// 演出只从 <see cref="BasicRulesEngine"/> 的结算结果里出来；直接调纯函数没有作用域，什么都不发也不抛。
/// </summary>
public class PresentationEmitTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，(-4,0)
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，(-1,0)
    private static HexPosition P(int q, int r) => new(q, r, -q - r);
    private static RecordingRng Rng(int seed = 5) => new(new Xoshiro256StarStar((ulong)seed));
    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));

    private static WorldState MoveTo(WorldState s, EntityId id, HexPosition to)
    {
        var c = s.Cells[id];
        return s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(to, id).UpdateCell(id, c.Copy(position: to));
    }

    private static WorldState World(int seat = 0)
    {
        var s = DemoScenario.Create();
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: seat, startStep: 2));
    }

    private static IEnumerable<IPresentationEvent> Staged(RulesResult r) => r.Events.OfType<IPresentationEvent>();

    [Fact]
    public void 攻击_先掷骰再报判词_结算完演本体冲撞()
    {
        var s = MoveTo(World(), Cancer1, P(-3, 0));
        var r = Engine.ExecuteDecision(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng(3));
        Assert.True(r.Success, r.ErrorMessage);
        var staged = Staged(r).ToList();
        var dice = Assert.Single(staged.OfType<DiceRolled>());
        Assert.Equal(("攻击", 6, 0, P(-3, 0)), (dice.Reason, dice.Sides, dice.Seat, dice.At));
        Assert.InRange(dice.Value, 1, 6);
        var verdict = Assert.Single(staged.OfType<ResultAnnounced>());
        Assert.Contains(verdict.Text, new[] { "攻击无效", "攻击成功", "攻击大成功" });
        var resolved = Assert.Single(staged.OfType<AttackResolved>());
        Assert.Equal(dice.Value, resolved.Roll);
        Assert.Equal(verdict.Text == "攻击无效" ? "fail" : verdict.Text == "攻击大成功" ? "crit" : "success", resolved.Outcome);
        var fx = Assert.Single(staged.OfType<SkillFx>());
        Assert.Equal("immune_attack", fx.Kind);
        Assert.Equal(resolved.Outcome != "fail", (bool)fx.Data["hit"]);
        Assert.Equal(P(-4, 0), (HexPosition)fx.Data["from"]);
        Assert.True(staged.IndexOf(dice) < staged.IndexOf(verdict) && staged.IndexOf(verdict) < staged.IndexOf(resolved) && staged.IndexOf(resolved) < staged.IndexOf(fx));
    }

    [Fact]
    public void 高亲和力克隆_不掷骰直接大成功_不消耗那一发rng()
    {
        var s = MoveTo(World(), Cancer1, P(-3, 0));
        s = CellRules.AddModifier(s, s.Cells[Immune0], new ActiveModifier("高亲和力克隆", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 0, null, 1, ModifierDuration.Turn));
        var rng = Rng(3);
        var r = Engine.ExecuteDecision(s, new MoveDecision(0, Immune0, P(-3, 0)), rng);
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Empty(Staged(r).OfType<DiceRolled>());
        Assert.DoesNotContain(rng.Ranges, range => range == (1, 7));
        Assert.Equal("crit", Assert.Single(Staged(r).OfType<AttackResolved>()).Outcome);
        Assert.Equal("攻击大成功", Assert.Single(Staged(r).OfType<ResultAnnounced>()).Text);
    }

    [Fact]
    public void 定殖_过场方向是来路那一侧()
    {
        var s = World(1);
        var from = s.Cells[Cancer1].Position;                       // (-1,0)
        var dest = P(-2, 0);
        s = Tissue(s, dest, t => t.WithState(TissueState.Healthy));
        var r = Engine.ExecuteDecision(s, new MoveDecision(1, Cancer1, dest), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var converted = Assert.Single(Staged(r).OfType<TissueConverted>());
        Assert.Equal((dest, "定殖"), (converted.At, converted.Cause));
        Assert.Equal(Stage.DirToward(dest, from), converted.Dir);
        Assert.Equal(0, converted.Dir);                             // 来路在 +q 那一侧 = DIRS[0] = (1,0)
    }

    [Fact]
    public void 抽卡_通报带来源不带牌名_事件卡另报一条()
    {
        var s = World();
        var found = false;
        for (var seed = 1; seed <= 40 && !found; seed++)
        {
            var r = Engine.ExecuteDecision(s, new DrawDecision(0, Immune0), Rng(seed));
            Assert.True(r.Success, r.ErrorMessage);
            var drawn = Assert.Single(Staged(r).OfType<CardDrawn>());
            Assert.Equal(("基因表达", 0, Immune0), (drawn.Source, drawn.Seat, drawn.CellId));
            var events = Staged(r).OfType<EventCardDrawn>().ToList();
            if (events.Count == 1) { Assert.Equal(Faction.Immune, events[0].Faction); found = true; }
        }
        Assert.True(found, "40 颗种子没有一次抽到事件卡");
    }

    [Fact]
    public void 出牌_通报用席位名()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: ["细胞膜修复"]));
        var r = Engine.ExecuteDecision(s, new PlayCardDecision(0, Immune0, "细胞膜修复", null), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var played = Assert.Single(Staged(r).OfType<CardPlayed>());
        Assert.Equal("免疫A 打出【细胞膜修复】", played.Text);
        Assert.Equal(Faction.Immune, played.Faction);
        Assert.Equal("癌症A", Stage.SeatName(s, 1));
        Assert.Equal("免疫B", Stage.SeatName(s, 2));
    }

    [Fact]
    public void 没有作用域时直接调纯函数_不发也不抛()
    {
        var s = MoveTo(World(), Cancer1, P(-3, 0));
        var r = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng(3));
        Assert.True(r.Success);
        Assert.Empty(Staged(r));
    }

    [Fact]
    public void 方向_相邻取那一侧_跃进取最接近来路的一侧_原地不演()
    {
        var o = P(0, 0);
        Assert.Equal(0, Stage.DirToward(o, P(1, 0)));
        Assert.Equal(3, Stage.DirToward(o, P(-1, 0)));
        Assert.Equal(0, Stage.DirToward(o, P(2, 0)));        // 远处同向
        Assert.Equal(-1, Stage.DirToward(o, o));
    }

    [Fact]
    public void 突变_先掷d3再演粒子再报判词()
    {
        var s = World(1);
        var r = Engine.ExecuteDecision(s, new MutateDecision(1, Cancer1), Rng(2));
        Assert.True(r.Success, r.ErrorMessage);
        var staged = Staged(r).ToList();
        var dice = Assert.Single(staged.OfType<DiceRolled>());
        Assert.Equal(("突变", 3, 1), (dice.Reason, dice.Sides, dice.Seat));
        var fx = Assert.Single(staged.OfType<SkillFx>(), f => f.Kind == "mutate");
        var verdict = Assert.Single(staged.OfType<ResultAnnounced>());
        Assert.StartsWith("突变：", verdict.Text);
        Assert.True(staged.IndexOf(dice) < staged.IndexOf(fx) && staged.IndexOf(fx) < staged.IndexOf(verdict));
    }

    [Fact]
    public void 抗体_无目标且无可转化癌组织_不掷骰直接落空()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.BCell, differentiated: true));
        foreach (var c in s.Cells.Values.Where(c => c.Faction == Faction.Cancer).ToArray())
            s = s.UpdateCell(c.Id, c.Copy(alive: false, energy: 0)).UpdateTissueOccupant(c.Position, null);
        foreach (var t in s.Board.Tissues.Values.Where(t => t.State != TissueState.Healthy).ToArray())
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithState(TissueState.Healthy).WithSolidificationCount(0)));
        var rng = Rng();
        var r = Engine.ExecuteDecision(s, new TypeSkillDecision(0, Immune0, "抗体", null), rng);
        Assert.True(r.Success, r.ErrorMessage);
        Assert.DoesNotContain(rng.Ranges, range => range == (1, 4));
        Assert.Empty(Staged(r).OfType<DiceRolled>());
    }

    [Fact]
    public void S阶段有氧_每只免疫一条呼吸演出()
    {
        var s = DemoScenario.Create().WithTurn(DemoScenario.Create().Turn.Copy(phase: Phase.S, startStep: 0));
        var r = Engine.AdvancePhase(s, Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var respire = Staged(r).OfType<SkillFx>().Where(f => f.Kind == "respire").ToList();
        Assert.Equal(s.Cells.Values.Count(c => c.IsAlive && c.Faction == Faction.Immune), respire.Count);
    }

    [Fact]
    public void E阶段无氧_每只癌细胞一条输能演出_带最近的来源格()
    {
        var s = DemoScenario.Create().WithTurn(DemoScenario.Create().Turn.Copy(phase: Phase.E));
        var r = Engine.AdvancePhase(s, Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var anaerobic = Staged(r).OfType<SkillFx>().Where(f => f.Kind == "anaerobic").ToList();
        Assert.Equal(s.Cells.Values.Count(c => c.IsAlive && c.Faction == Faction.Cancer), anaerobic.Count);
        Assert.All(anaerobic, f => Assert.DoesNotContain((HexPosition)f.Data["at"], (HexPosition[])f.Data["sources"]));
    }

    [Fact]
    public void 方向_正对角来路照GD的单精度打平取在前的下标()
    {
        Assert.Equal(2, Stage.DirToward(P(0, 0), P(-1, -1)));   // float32 下 DIRS[2] 与 DIRS[3] 点积打平，GD 取 2；double 会取 3
        Assert.Equal(0, Stage.DirToward(P(0, 0), P(1, 1)));
        Assert.Equal(2, Stage.DirToward(P(0, 0), P(-3, -3)));
    }

    [Fact]
    public void 攻击_用掉最后一次时报攻击次数已用尽()
    {
        var s = MoveTo(World(), Cancer1, P(-3, 0));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(attacks: s.Tuning.AttackMaxPerTurn - 1));
        var r = Engine.ExecuteDecision(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng(3));
        Assert.True(r.Success, r.ErrorMessage);
        var notices = Staged(r).OfType<ResultAnnounced>().Select(a => a.Text).ToList();
        Assert.Contains($"攻击次数已用尽（{s.Tuning.AttackMaxPerTurn}/{s.Tuning.AttackMaxPerTurn}）", notices);
        Assert.True(notices.IndexOf(notices.First(x => x.StartsWith("攻击次数"))) < notices.IndexOf(notices.First(x => x.StartsWith("攻击") && !x.StartsWith("攻击次数"))), "用尽那句在判词之前");
    }

    [Fact]
    public void 克隆增殖_每转一格发一条过场_方向从发动者那一侧来()
    {
        var s = World(1);
        s = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(hand: ["克隆增殖"]));
        s = Tissue(s, P(-2, 0), t => t.WithState(TissueState.Healthy).WithSolidificationCount(0));   // 中央 15 格全是癌组织：腾两格健康的当候选
        s = Tissue(s, P(-2, 1), t => t.WithState(TissueState.Healthy).WithSolidificationCount(0));
        var r = Engine.ExecuteDecision(s, new PlayCardDecision(1, Cancer1, "克隆增殖", null), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var fx = Assert.Single(Staged(r).OfType<SkillFx>(), f => f.Kind == "card_clone");
        var tiles = (HexPosition[])fx.Data["tiles"];
        var converted = Staged(r).OfType<TissueConverted>().ToList();
        Assert.Equal(tiles.Length, converted.Count);
        Assert.All(converted, t => Assert.Equal(Stage.DirToward(t.At, s.Cells[Cancer1].Position), t.Dir));
    }

    [Fact]
    public void E阶段_增生与侵蚀翻掉的每一格都有过场()
    {
        for (var seed = 1; seed <= 30; seed++)
        {
            var s = DemoScenario.Create().WithTurn(DemoScenario.Create().Turn.Copy(phase: Phase.E));
            var r = Engine.AdvancePhase(s, Rng(seed));
            Assert.True(r.Success, r.ErrorMessage);
            var flipped = r.NewState.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy && s.Board.Tissues[t.Position].State == TissueState.Healthy);
            var shown = Staged(r).OfType<TissueConverted>().Count(t => t.Cause is "增生" or "侵蚀");
            Assert.Equal(flipped, shown);
            if (Staged(r).OfType<TissueConverted>().Any(t => t.Cause == "增生")) return;
        }
        Assert.Fail("30 颗种子没有一次增生");
    }

    [Fact]
    public void E阶段无氧_同一块里按细胞序演()
    {
        var s = DemoScenario.Create().WithTurn(DemoScenario.Create().Turn.Copy(phase: Phase.E));
        var r = Engine.AdvancePhase(s, Rng());
        var order = Staged(r).OfType<SkillFx>().Where(f => f.Kind == "anaerobic").Select(f => (HexPosition)f.Data["at"]).ToList();
        Assert.Equal(new[] { s.Cells[Cancer1].Position, s.Cells[new EntityId(4)].Position }, order);   // 两只癌细胞同在中央块：席位 1 先于席位 3
    }

    [Fact]
    public void Excalibur_侧向只打掷中的格_候选按DIRS序配骰()
    {
        // T 细胞在 (-4,0) 朝 +q 射：主射线 (-3,0)…；两侧 (-3,-1) 与 (-4,1)… 放癌组织 + 癌细胞，掷中的那格才挨打
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.TCell, differentiated: true, effectorUsed: false));
        s = s.UpdatePlayer(0, s.Players[0].WithImmuneLevel(ImmuneLevel.X).WithAntigenMemory(40));   // 效应应答：X 级 + 记忆 ≥ 20
        foreach (var t in s.Board.Tissues.Values.Where(t => t.State != TissueState.Healthy).ToArray())
            s = Tissue(s, t.Position, x => x.WithState(TissueState.Healthy).WithSolidificationCount(0));
        var a = P(-3, -1);
        var b = P(-4, 1);
        s = Tissue(s, a, t => t.WithState(TissueState.Cancer));
        s = Tissue(s, b, t => t.WithState(TissueState.Cancer));
        s = MoveTo(s, Cancer1, a);
        s = MoveTo(s, new EntityId(4), b);
        var seenHit = false;
        var seenMiss = false;
        for (var seed = 1; seed <= 60 && !(seenHit && seenMiss); seed++)
        {
            var r = Engine.ExecuteDecision(s, new TypeSkillDecision(0, Immune0, "Excalibur", P(-3, 0)), Rng(seed));
            Assert.True(r.Success, r.ErrorMessage);
            var beam = Assert.Single(Staged(r).OfType<BeamFired>());
            foreach (var (tile, id) in new[] { (a, Cancer1), (b, new EntityId(4)) })
            {
                var hit = beam.Splash.Contains(tile);
                var damaged = r.NewState.Cells[id].Energy < s.Cells[id].Energy;
                Assert.Equal(hit, damaged);
                Assert.Equal(hit, r.NewState.Board.Tissues[tile].State == TissueState.Healthy);
                seenHit |= hit;
                seenMiss |= !hit;
            }
        }
        Assert.True(seenHit && seenMiss, "60 颗种子里要同时见过掷中与没掷中");
    }
}
