using CellWar.Core.Observation;

namespace CellWar.Core.Tests;

/// <summary>
/// 换内核「P0 补」（docs/内核替换_重启计划.md §七，2026-10-01）：日志批顺手查出、L1 四条夹具没走到的几处规则差。
/// GD 是参照（线上产品内核），每条断言的都是 GD 那一段的行为，旁边注出处：
/// ① `energy_cap` > 0 的三个削顶点（每次行动结算完 / S 阶段末 / E 阶段）；
/// ② 【全身免疫动员】「各可迁移 1 次」—— 逐只问**主人**（可以是队友），宿主要把追问送到那一席；
/// ③ 效应应答扣的是阵营共用的效应记忆；
/// ④ 阶段推进（S 产出 / E 蹲守）抽到无路可走的连走卡不多出「停在这里」；
/// ⑤ 【补体调理】叠几张就最多重掷几次。
/// （第六处「反弹打死攻击者时 GD 不演 immune_attack」判为 GD 侧疏漏、C# 不跟，见开发日志 2026-10-01。）
/// </summary>
public class P0GapTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，(-4,0)，30
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，(-1,0)，60
    private static readonly EntityId Immune2 = new(3);   // 席位 2：免疫，(4,0)，30
    private static readonly EntityId Cancer3 = new(4);   // 席位 3：印戒，(1,0)，60
    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static WorldState Turn(int seat)
    {
        var s = DemoScenario.Create();
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: seat, startStep: 2));
    }

    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));

    private static RulesResult Do(WorldState s, IDecision d, IDeterministicRng? rng = null)
    {
        var r = Engine.ExecuteDecision(s, d, rng ?? new Xoshiro256StarStar(5));
        Assert.True(r.Success, r.ErrorMessage);
        return r;
    }

    private static string[] Logs(RulesResult r) => r.Events.OfType<LogLine>().Select(l => l.Text).ToArray();

    /// <summary>让这只细胞的卡池里只剩 <paramref name="card"/> 一张可抽：同池其余已实现的牌全塞进手里（EligibleCards 排除手里的同名牌）。</summary>
    private static WorldState OnlyDrawable(WorldState s, EntityId id, CardPool pool, string card)
        => s.UpdateCell(id, s.Cells[id].Copy(hand: CardCatalog.Pool(pool).Where(CardImplementation.IsImplemented)
            .Select(d => d.Name).Where(n => n != card).Distinct().ToArray()));

    /// <summary>六邻全固化：【趋化募集】一格都进不了（只进无细胞的健康组织）。</summary>
    private static WorldState BoxIn(WorldState s, HexPosition at)
    {
        foreach (var n in RulePolicies.GdNeighbors(s, at)) s = Tissue(s, n, t => t.WithState(TissueState.SolidifiedCancer));
        return s;
    }

    // ---------- ① energy_cap > 0：三个削顶点 ----------

    /// <summary>GD `step()` 的行动分支（cw_game.gd:228-230）：`await actions.execute` 回来 —— 连同中途问答全部结算完 —— 才 `cap_energy()`；
    /// `cap_energy` 削的是 `living_cells()`，两个阵营一起（cw_game.gd:431-440）。</summary>
    [Fact]
    public void 能量上限_一次行动连同它追出的问答结算完才削_两个阵营都削()
    {
        var s = Turn(0).WithTuning(RuleTuning.Default with { EnergyCap = 200 });
        s = Tissue(s, P(-3, 0), t => t.WithType(TissueType.MetabolicCore).WithCharge(300));   // 走一步踩上去收 30.0
        s = s.UpdateCell(Cancer3, s.Cells[Cancer3].WithEnergy(500));                            // 别人的细胞也超了
        s = CardRules.Resolve(s, s.Cells[Immune0], "趋化募集", new Xoshiro256StarStar(5));         // 行动里抽到的两步免费连走

        var step = Do(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0)));
        Assert.NotNull(step.NewState.Turn.PendingChemotaxisCell);                                 // 还有一步要问：这次行动没结算完
        Assert.Equal(330, step.NewState.Cells[Immune0].Energy);                                   // GD 不削（PRD「先抵消再算溢出」）
        Assert.Equal(500, step.NewState.Cells[Cancer3].Energy);

        var done = Do(step.NewState, new StopChemotaxisDecision(0, Immune0));
        Assert.Equal(200, done.NewState.Cells[Immune0].Energy);
        Assert.Equal(200, done.NewState.Cells[Cancer3].Energy);
        Assert.Equal(["　【趋化募集】提前停止", "【溢出】免疫A(免疫细胞) 能量 33.0 → 20.0", "【溢出】癌症B(印戒细胞癌) 能量 50.0 → 20.0"], Logs(done));
    }

    /// <summary>「结束回合」不削（GD `_end_turn` cw_game.gd:335-341 里没有 cap_energy）；S 阶段末削在【过载】之后、开打之前（cw_game.gd:258-261）。</summary>
    [Fact]
    public void 能量上限_结束回合不削_S阶段末在过载之后开打之前削()
    {
        var cap = RuleTuning.Default with { EnergyCap = 200 };
        var t = Turn(0).WithTuning(cap);
        t = t.UpdateCell(Immune0, t.Cells[Immune0].WithEnergy(500));
        Assert.Equal(500, Do(t, new EndTurnDecision(0)).NewState.Cells[Immune0].Energy);

        var s = DemoScenario.Create().WithTuning(cap);
        s = s.WithTurn(s.Turn.Copy(startStep: 1));                                                // S 阶段、没人要复活：有氧 → 过载 → 开打
        s = s.UpdateCell(Cancer1, s.Cells[Cancer1].WithEnergy(500));
        var r = Engine.AdvancePhase(s, new Xoshiro256StarStar(5));
        Assert.Equal(Phase.PlayerAction, r.NewState.Turn.Phase);
        Assert.Equal(200, r.NewState.Cells[Cancer1].Energy);
        var logs = Logs(r);
        var overload = Array.FindIndex(logs, l => l.StartsWith("【过载】癌症A"));
        var spill = Array.FindIndex(logs, l => l.StartsWith("【溢出】癌症A"));
        var go = Array.FindIndex(logs, l => l.StartsWith("▶"));
        Assert.True(overload >= 0 && overload < spill && spill < go, string.Join("\n", logs));
    }

    // ---------- ② 【全身免疫动员】各可迁移 1 次 ----------

    /// <summary>四人局：两个免疫席位都升到 X 级，席位 0 的卡池里只剩【全身免疫动员】。</summary>
    private static WorldState MobilizationWorld()
    {
        var s = Turn(0);
        foreach (var seat in new[] { 0, 2 }) s = s.UpdatePlayer(seat, s.Players[seat].WithImmuneLevel(ImmuneLevel.X));
        return OnlyDrawable(s, Immune0, CardPool.ImmuneX, CellRules.MobilizationCard);
    }

    /// <summary>GD `_mobilization`（cw_card_fx.gd:731-752）：全体 +1.5 之后按细胞序逐只问主人「放弃迁移 / 照付费迁移 1 次」，
    /// 选项 data 是 `{act: move, to, cost}`、kind `free_move`、tag 卡名；「放弃迁移」直接 `continue`，不报。</summary>
    [Fact]
    public void 全身免疫动员_按细胞序逐只问主人_迁移照付费_放弃不报_问完回到行动栏()
    {
        var s = Do(MobilizationWorld(), new DrawDecision(0, Immune0)).NewState;
        Assert.Equal(30 - CardRules.ImmuneDrawCost + 15, s.Cells[Immune0].Energy);
        Assert.Equal(30 + 15, s.Cells[Immune2].Energy);

        // 第一只：席位 0 自己
        var first = Engine.GetAvailableDecisions(s, 0);
        Assert.Equal(new StopChemotaxisDecision(0, Immune0), first[0]);                          // 下标 0 =「放弃迁移」
        Assert.Equal("k=free_move|g=全身免疫动员|stop=1", SemanticKey.Of(s, first[0]));
        Assert.Equal(CellRules.MobilizeTargets(s, s.Cells[Immune0]).Count, first.Count - 1);
        Assert.All(first.Skip(1), d => Assert.IsType<MoveDecision>(d));
        var move = first.OfType<MoveDecision>().Single(m => m.TargetPosition == P(-3, 0));
        Assert.Equal("k=free_move|g=全身免疫动员|act=move|to=-3,0", SemanticKey.Of(s, move));
        Assert.Empty(Engine.GetAvailableDecisions(s, 2));
        var cost = RulePolicies.QuoteMove(s, s.Cells[Immune0], P(-3, 0))!.Value;
        var moved = Do(s, move).NewState;
        Assert.Equal(P(-3, 0), moved.Cells[Immune0].Position);
        Assert.Equal(s.Cells[Immune0].Energy - cost, moved.Cells[Immune0].Energy);              // 费用照付（GD `_do_move(c, to, cost)`）

        // 第二只：问的是席位 2（队友）
        Assert.Empty(Engine.GetAvailableDecisions(moved, 0));
        var second = Engine.GetAvailableDecisions(moved, 2);
        Assert.Equal(new StopChemotaxisDecision(2, Immune2), second[0]);
        var skipped = Do(moved, second[0]);
        Assert.DoesNotContain(Logs(skipped), l => l.Contains("提前停止"));
        Assert.Null(skipped.NewState.Turn.PendingChemotaxisCell);
        Assert.Contains(Engine.GetAvailableDecisions(skipped.NewState, 0), d => d is EndTurnDecision);   // 回到席位 0 的行动栏
    }

    /// <summary>GD cw_card_fx.gd:739-741：轮到那一只时现算 `immune_move_options`，一格都走不了就 `continue` —— 不问、不报。</summary>
    [Fact]
    public void 全身免疫动员_轮到时没有可走的格就静默跳过()
    {
        var w = MobilizationWorld();
        // 迁移起价拧到 5.0：席位 2 那只（3.0 + 1.5）一格都付不起；席位 0 那只给足能量
        w = w.WithTuning(w.Tuning with { ImmuneMoveHealthy = [50, 50, 50, 50], ImmuneMoveCancerous = [50, 50, 50, 50] });
        w = w.UpdateCell(Immune0, w.Cells[Immune0].WithEnergy(300));
        var s = Do(w, new DrawDecision(0, Immune0)).NewState;
        Assert.NotEmpty(Engine.GetAvailableDecisions(s, 0).OfType<MoveDecision>());

        var after = Do(s, new StopChemotaxisDecision(0, Immune0));
        Assert.Null(after.NewState.Turn.PendingChemotaxisCell);
        Assert.Empty(Engine.GetAvailableDecisions(after.NewState, 2));
        Assert.DoesNotContain(Logs(after), l => l.Contains("提前结束") || l.Contains("提前停止"));
    }

    /// <summary>宿主那一侧：GD `game.ask(c["pid"], …)` 把这一问送到**细胞的主人**。C# 的 RuleFlow 此前只问行动席 ——
    /// 问不出去就转去推阶段，等于替席位 0 结束回合。这里走真的 MatchSession：队友那一问答完，席位 0 的回合还在。</summary>
    [Fact]
    public void 全身免疫动员_宿主把追问送到细胞的主人_队友答完回到行动席()
    {
        using var session = MatchSession.Resume(MobilizationWorld(), new Xoshiro256StarStar(5));
        ObsAsk Ask() => session.ObserveV1(ObservationV1Codec.ViewerOmniscient).Ask!;
        void Answer(string key)
        {
            var a = Ask();
            Assert.True(session.SubmitByKey(a.Seat, a.AskId, key, -1).IsValid, key);
        }

        Answer("k=action|act=draw");
        Assert.Equal((0, "free_move", "全身免疫动员"), (Ask().Seat, Ask().Kind, Ask().Tag));
        Answer("k=free_move|g=全身免疫动员|stop=1");

        var teammate = Ask();
        Assert.Equal(2, teammate.Seat);
        Assert.Equal("放弃迁移", teammate.Options[teammate.StopIndex].Label);                   // GD cw_card_fx.gd:742
        Answer("k=free_move|g=全身免疫动员|act=move|to=4,-1");

        var back = Ask();
        Assert.Equal((0, "action"), (back.Seat, back.Kind));
        var cells = session.ObserveV1(ObservationV1Codec.ViewerOmniscient).State.Cells;
        Assert.Equal(new ObsPos(4, -1), cells.Single(c => c.Pid == 2).Pos);
    }

    // ---------- ③ 效应应答扣阵营共用的记忆 ----------

    /// <summary>GD `spend_effector` → `reduce_memory(20)`（cw_game.gd:1014-1019 / 1032-1033）：`memory` 是阵营一个数，日志「余」读扣完的它。</summary>
    [Fact]
    public void 效应应答扣的是阵营共用的效应记忆_队友那一份一起扣()
    {
        var s = Turn(2);
        foreach (var seat in new[] { 0, 2 })
            s = s.UpdatePlayer(seat, s.Players[seat].WithImmuneLevel(ImmuneLevel.X).WithAntigenMemory(25));
        s = s.UpdateCell(Immune2, s.Cells[Immune2].Copy(type: CellType.BCell, differentiated: true));

        var r = Do(s, new TypeSkillDecision(2, Immune2, "中和抗体"));
        Assert.Equal(5, r.NewState.Players[0].AntigenMemory);
        Assert.Equal(5, r.NewState.Players[2].AntigenMemory);
        Assert.Contains("★【效应应答·中和抗体】免疫B(B细胞) 发动（消耗 20 效应记忆，余 5）", Logs(r));
    }

    // ---------- ④ 阶段推进里抽到无路可走的连走卡 ----------

    /// <summary>GD `_free_walk` 第一步就判（cw_card_fx.gd:628-630）：没有可进入的相邻格喊一声就 return，不问 —— `_tissue_production` 接着产、传送、开打。</summary>
    [Fact]
    public void S阶段骨髓抽到无路可走的连走卡_喊一声就退_一路走到开打()
    {
        var s = DemoScenario.Create();
        s = Tissue(s, P(-4, 0), t => t.WithType(TissueType.BoneMarrow).WithCharge(1));       // 免疫站在存着一张卡的骨髓上
        s = OnlyDrawable(BoxIn(s, P(-4, 0)), Immune0, CardPool.ImmuneI, "趋化募集");
        s = s.WithTurn(s.Turn.Copy(phase: Phase.S, round: 2, startStep: 0));

        var r = Engine.AdvancePhase(s, new Xoshiro256StarStar(5));
        Assert.Null(r.NewState.Turn.PendingChemotaxisCell);
        Assert.Equal(Phase.PlayerAction, r.NewState.Turn.Phase);
        var logs = Logs(r);
        var drew = Array.FindIndex(logs, l => l.Contains("经由「骨髓」抽到【事件】趋化募集"));
        Assert.True(drew >= 0 && logs[drew + 1] == "　【趋化募集】没有可进入的相邻格，提前结束", string.Join("\n", logs));
    }

    /// <summary>E 阶段 4.9 蹲守净化 →【免疫记忆库】抽到同一张：同一个 `_free_walk`，同样不问，E 阶段接着做完、翻到下一回合 S。</summary>
    [Fact]
    public void E阶段蹲守净化抽到无路可走的连走卡_同样不问_接着做完E阶段()
    {
        var s = DemoScenario.Create();
        s = BoxIn(Tissue(s, P(-4, 0), t => t.WithState(TissueState.Cancer)), P(-4, 0));      // 免疫蹲在一格癌组织上
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(energy: 300, campRound: 1, campPosition: P(-4, 0), equipped: ["免疫记忆库"]));
        s = OnlyDrawable(s, Immune0, CardPool.ImmuneI, "趋化募集");
        s = s.WithTurn(s.Turn.Copy(phase: Phase.E));

        var r = Engine.AdvancePhase(s, new Xoshiro256StarStar(5));
        Assert.Null(r.NewState.Turn.PendingChemotaxisCell);
        Assert.Equal(Phase.S, r.NewState.Turn.Phase);
        Assert.Contains("　【趋化募集】没有可进入的相邻格，提前结束", Logs(r));
    }

    // ---------- ⑤ 【补体调理】叠两张 ----------

    private static WorldState OpsoninTwice()
    {
        var s = Turn(0);
        var c = s.Cells[Cancer1];
        s = s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(P(-3, 0), Cancer1).UpdateCell(Cancer1, c.Copy(position: P(-3, 0)));   // 目标挪到隔壁
        for (var i = 0; i < 2; i++)
            s = CellRules.AddModifier(s, s.Cells[Immune0], new ActiveModifier("补体调理", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 5, null, 1, ModifierDuration.Turn));
        return s;
    }

    private static ScriptedRng Rolls(params int[] d6) => new(d6.Select(v => (IReadOnlyList<long>)new long[] { 1, 6, v }));

    /// <summary>GD cw_actions.gd:815-819：`rerolls := opsonin`（spend_mods 的条数），`while outcome == "fail" and rerolls > 0` —— 两张就最多重掷两次，命中额外 +0.5 × 2。</summary>
    [Fact]
    public void 补体调理叠两张_无效最多重掷两次_命中额外加两份()
    {
        var rng = Rolls(1, 2, 4);   // 无效 → 无效 → 成功
        var r = Do(OpsoninTwice(), new MoveDecision(0, Immune0, P(-3, 0)), rng);
        Assert.Equal(3, rng.Consumed);
        Assert.Equal(2, Logs(r).Count(l => l == "　【补体调理】攻击无效：重新判定一次，以第二次结果为准"));
        Assert.Equal(60 - r.NewState.Tuning.AttackDmgSuccess - 10, r.NewState.Cells[Cancer1].Energy);
    }

    /// <summary>同上：第一次重掷就中了，`while` 不再转 —— 第二张不多掷一发。</summary>
    [Fact]
    public void 补体调理叠两张_第一次重掷就中了不再多掷()
    {
        var rng = Rolls(1, 4, 1);
        Do(OpsoninTwice(), new MoveDecision(0, Immune0, P(-3, 0)), rng);
        Assert.Equal(2, rng.Consumed);
    }
}
