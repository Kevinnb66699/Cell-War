using System.Text.RegularExpressions;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests;

/// <summary>
/// 组织翻面单一入口 + 巨噬回能三态 + 净化链顺序（2026-09-17 晚，口径一第三批的第 1～3 步）：
/// ① GD `CWTissue.to_cancer / to_healthy` 是整体赋值（solid / newborn / necrosis / ossify 一起清），C# `WithState` 只按目标状态选择性清、从不碰 necrosis，
///    Move / Teleport 两条定殖路此前都是裸 `UpdateTissueState` → 造出 GD `is_valid` 明令不存在的「癌组织 + 坏死」；
/// ② 巨噬【I-吞噬】的回能看 GD `enter_tile` 的 paid 三态：-1 不回、0（付费迁移被【组织巡航】盖成 0）回满、>0 封顶实付 −0.1；C# 此前 `Math.Min(2, cost-1)` 把 0 压成 0；
/// ③ `purify_here` 的 `_on_purify` 顺序是 模式识别增强 → 效应记忆形成 → 免疫记忆库抽卡；C# 此前先抽卡再加记忆，记忆抬等级、等级决定卡池。
/// </summary>
public class TissueFlipTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，站 (-4,0)，能量 30
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，站 (-1,0)，能量 60
    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static WorldState World(int seat)
    {
        var s = DemoScenario.Create();
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: seat, startStep: 2));
    }

    private static WorldState MoveTo(WorldState s, EntityId id, HexPosition to)
    {
        var c = s.Cells[id];
        return s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(to, id).UpdateCell(id, c.Copy(position: to));
    }

    private static WorldState Tissue(WorldState s, HexPosition p, Func<Tissue, Tissue> f) => s.WithBoard(s.Board.UpdateTissue(p, f(s.Board.Tissues[p])));
    private static RecordingRng Rng(int seed = 5) => new(new Xoshiro256StarStar((ulong)seed));

    private static void AssertPlainCancer(Tissue t)
    {
        Assert.Equal(TissueState.Cancer, t.State);
        Assert.Equal(0, t.NecrosisRounds);
        Assert.True(t.Newborn);
        Assert.Equal(0, t.SolidificationCount);
        Assert.Equal(0, t.OssifyAtRound);
    }

    // ---------- ① 翻面单一入口 ----------

    [Fact]
    public void 迁移定殖走to_cancer_坏死一起清()
    {
        var s = MoveTo(World(1), Cancer1, P(-3, 0));
        s = Tissue(s, P(-4, 1), t => t.WithNecrosis(2));                  // 坏死的健康格照样能被【定殖】（cw_data.gd:464）
        var r = CellRules.Move(s, new MoveDecision(1, Cancer1, P(-4, 1)), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        AssertPlainCancer(r.NewState.Board.Tissues[P(-4, 1)]);
        Assert.Contains(r.Events, e => e is TissueStateChangedEvent);
    }

    [Fact]
    public void 传送落地定殖走to_cancer_坏死一起清()
    {
        var s = MoveTo(World(1), Cancer1, P(-3, 0));
        s = Tissue(s, P(-5, 2), t => t.WithNecrosis(2));
        var done = CellRules.EnterTile(s, Cancer1, P(-5, 2), Rng());     // 跃进 / 传送卡 / 免费连走都走它
        AssertPlainCancer(done.Board.Tissues[P(-5, 2)]);
        Assert.Equal(P(-5, 2), done.Cells[Cancer1].Position);
    }

    [Fact]
    public void 净化走to_healthy_坏死一起清()
    {
        var s = World(0);
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer).WithNecrosis(1));   // GD 里不存在的状态，模拟历史存档
        var r = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var t = r.NewState.Board.Tissues[P(-3, 0)];
        Assert.Equal(TissueState.Healthy, t.State);
        Assert.Equal(0, t.NecrosisRounds);
    }

    [Fact]
    public void 传送落到骨样硬化标记格_登记蹲守不净化()
    {
        var s = World(0);
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer).WithOssifyAt(s.Turn.WorldRound + 2));
        var done = CellRules.EnterTile(s, Immune0, P(-3, 0), Rng());
        Assert.Equal(TissueState.Cancer, done.Board.Tissues[P(-3, 0)].State);
        Assert.Equal(done.Turn.WorldRound, done.Cells[Immune0].CampRound);
        Assert.Equal(P(-3, 0), done.Cells[Immune0].CampPosition);
    }

    [Fact]
    public void 早期血行转移的扩散格是新生癌组织_坏死一起清()
    {
        var s = MoveTo(World(1), Cancer1, P(-1, 0));
        s = Tissue(s, P(-1, 0), t => t.WithType(TissueType.BloodVessel));
        foreach (var n in P(-3, 0).GetNeighbors()) s = Tissue(s, n, t => t.WithNecrosis(1));
        var r = Engine.ExecuteDecision(s, new TypeSkillDecision(1, Cancer1, "早期血行转移", P(-3, 0)), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var spread = P(-3, 0).GetNeighbors().Select(n => r.NewState.Board.Tissues[n]).Where(t => t.State == TissueState.Cancer && s.Board.Tissues[t.Position].State == TissueState.Healthy).ToList();
        Assert.Equal(3, spread.Count);
        Assert.All(spread, t => { Assert.True(t.Newborn); Assert.Equal(0, t.NecrosisRounds); });
    }

    [Fact]
    public void 细胞毒素走to_necrotic_坏死取max_库存与产出进度清零()
    {
        var s = World(0);
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.TCell));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer).WithType(TissueType.MetabolicCore).WithCharge(30).WithProductionCounter(2).WithNecrosis(3));
        var r = Engine.ExecuteDecision(s, new TypeSkillDecision(0, Immune0, "细胞毒素", null), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        var t = r.NewState.Board.Tissues[P(-3, 0)];
        Assert.Equal(TissueState.Healthy, t.State);
        Assert.Equal(3, t.NecrosisRounds);                              // maxi(before, NECROSIS_TOXIN)
        Assert.Equal(0, t.Charge);
        Assert.Equal(0, t.ProductionCounter);
        Assert.Equal(0, t.ToxinRound);                                             // toxin_round 只落在施法者脚下那一格（GD _do_toxin）
        Assert.Equal(r.NewState.Turn.WorldRound, r.NewState.Board.Tissues[P(-4, 0)].ToxinRound);
    }

    [Theory]
    [InlineData(7ul)]
    [InlineData(42ul)]
    [InlineData(97ul)]
    [InlineData(313ul)]
    public void 全盘不变量_癌性组织不带坏死_健康组织不带固化新生硬化标记(ulong seed)
    {
        // GD cw_tissue.gd:62-67 `is_valid` 的 C# 版：任何绕开 ToCancer / ToHealthy 的新路径都会在这里红
        KeyWalk.Walk(MatchSetup.Create(4, 20260917), 600, seed, s =>
        {
            foreach (var t in s.Board.Tissues.Values)
            {
                if (t.State is TissueState.Cancer or TissueState.SolidifiedCancer)
                    Assert.True(t.NecrosisRounds == 0, $"第 {s.Turn.WorldRound} 回合 {t.Position} 癌性组织带坏死 {t.NecrosisRounds}");
                if (t.State == TissueState.Healthy)
                    Assert.True(t.SolidificationCount == 0 && !t.Newborn && t.OssifyAtRound == 0, $"第 {s.Turn.WorldRound} 回合 {t.Position} 健康组织带 solid/newborn/ossify");
            }
        });
    }

    // ---------- ② 巨噬回能三态 ----------

    [Theory]
    [InlineData(-1, 0)]
    [InlineData(0, 2)]
    [InlineData(1, 0)]
    [InlineData(2, 1)]
    [InlineData(3, 2)]
    [InlineData(30, 2)]
    public void 巨噬回能按实付三态(int paid, int heal)
        => Assert.Equal(heal, CellRules.MacroPurifyHeal(World(0), paid));

    [Fact]
    public void 旋钮与常量的默认值等于GDScript()
    {
        var gd = File.ReadAllText(Path.Combine(RepoRoot(), "game", "scripts", "core", "cw_data.gd"));
        Assert.Equal(int.Parse(Regex.Match(gd, @"const MACRO_HEAL_PURIFY := (\d+)").Groups[1].Value), RuleTuning.Default.MacroHealPurify);
        Assert.Equal(int.Parse(Regex.Match(gd, @"const MACRO_MOVE_NET_MIN := (\d+)").Groups[1].Value), CellRules.MacroMoveNetMin);
        Assert.Equal(0, CellRules.MacroPurifyHeal(World(0).WithTuning(RuleTuning.Default with { MacroHealPurify = 0 }), 0));   // mheal=0：净化不回能
    }

    private static WorldState Macrophage(WorldState s) => s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.Macrophage));

    [Fact]
    public void 组织巡航盖成免费的迁移进癌组织_巨噬回满0_2()
    {
        var s = Macrophage(World(0));
        s = CellRules.AddModifier(s, s.Cells[Immune0], new ActiveModifier("组织巡航", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Passive, 0, 0, null, 1, ModifierDuration.Turn));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));
        Assert.Equal(0, RulePolicies.QuoteMove(s, s.Cells[Immune0], P(-3, 0), null));
        var first = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng()).NewState;
        Assert.Equal(TissueState.Healthy, first.Board.Tissues[P(-3, 0)].State);
        Assert.Equal(30 + 2, first.Cells[Immune0].Energy);              // 此前是 ±0

        // 同回合第二步没有免费额度：实付封顶 —— 回 min(0.2, 实付 − 0.1)
        var cost = RulePolicies.QuoteMove(first, first.Cells[Immune0], P(-2, 0), null)!.Value;
        Assert.True(cost > 0);
        var second = CellRules.Move(first, new MoveDecision(0, Immune0, P(-2, 0)), Rng()).NewState;
        Assert.Equal(32 - cost + Math.Min(2, Math.Max(cost - 1, 0)), second.Cells[Immune0].Energy);
    }

    [Fact]
    public void 连续吞噬的连锁跳不回能()
    {
        var s = Macrophage(World(0));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(chainLeft: 2));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));
        var r = CellRules.ChainMove(s, new ChainMoveDecision(0, Immune0, P(-3, 0)), Rng());
        Assert.True(r.Success, r.ErrorMessage);
        Assert.Equal(TissueState.Healthy, r.NewState.Board.Tissues[P(-3, 0)].State);
        Assert.Equal(30, r.NewState.Cells[Immune0].Energy);              // GD enter_tile 不传 paid（-1）
    }

    [Fact]
    public void 免费连走与传送落在癌组织上_巨噬不回能()
    {
        var s = Macrophage(World(0));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));
        var done = CellRules.EnterTile(s, Immune0, P(-3, 0), Rng());
        Assert.Equal(TissueState.Healthy, done.Board.Tissues[P(-3, 0)].State);
        Assert.Equal(30, done.Cells[Immune0].Energy);
    }

    // ---------- ③ 净化链 ----------

    [Fact]
    public void 蹲守净化走整条purify_here_模式识别增强照给()
    {
        var s = World(0);
        s = MoveTo(s, Immune0, P(-3, 0));
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer).WithOssifyAt(s.Turn.WorldRound + 2));
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(campRound: s.Turn.WorldRound, campPosition: P(-3, 0)));
        var plain = BoardRules.EvolveEndOfRound(s, Rng());
        var skilled = BoardRules.EvolveEndOfRound(s.UpdateCell(Immune0, s.Cells[Immune0].Copy(equipped: ["模式识别增强"])), Rng());
        Assert.Equal(TissueState.Healthy, plain.Board.Tissues[P(-3, 0)].State);
        Assert.Equal(0, plain.Board.Tissues[P(-3, 0)].NecrosisRounds);
        Assert.Equal(plain.Cells[Immune0].Energy + 5, skilled.Cells[Immune0].Energy);   // 此前蹲守净化是裸翻面，技能链一条都不走
    }

    [Fact]
    public void 净化链先加记忆再抽卡_免疫记忆库抽的是抬过等级之后的池()
    {
        var s = World(0);
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(equipped: ["效应记忆形成", "免疫记忆库"]));
        foreach (var seat in new[] { 0, 2 }) s = s.UpdatePlayer(seat, s.Players[seat].WithAntigenMemory(8));   // 净化 +1 → 9（I 级）；效应记忆形成 +1 → 10（II 级）
        s = Tissue(s, P(-3, 0), t => t.WithState(TissueState.Cancer));

        var levelOne = CellRules.AddMemory(s, 1);          // 旧顺序抽卡时看到的盘面
        var levelTwo = CellRules.AddMemory(levelOne, 1);   // GD 顺序抽卡时看到的盘面
        Assert.Equal(ImmuneLevel.I, levelOne.Players[0].ImmuneLevel);
        Assert.Equal(ImmuneLevel.II, levelTwo.Players[0].ImmuneLevel);

        for (var seed = 1; seed <= 40; seed++)
        {
            var oldOrder = Rng(seed); CardRules.DrawOne(levelOne, levelOne.Cells[Immune0], oldOrder);
            var gdOrder = Rng(seed); CardRules.DrawOne(levelTwo, levelTwo.Cells[Immune0], gdOrder);
            if (oldOrder.Ranges.SequenceEqual(gdOrder.Ranges)) continue;   // 这颗种子两个池抽法一样，换一颗

            var rng = Rng(seed);
            var done = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), rng).NewState;
            Assert.Equal(ImmuneLevel.II, done.Players[0].ImmuneLevel);
            Assert.Equal(gdOrder.Ranges, rng.Ranges);
            return;
        }
        Assert.Fail("40 颗种子里两个卡池的抽法全都一样，这条判据没法区分顺序");
    }

    private static string RepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !(Directory.Exists(Path.Combine(d, "game")) && Directory.Exists(Path.Combine(d, "core"))))
            d = Path.GetDirectoryName(d);
        return d ?? throw new InvalidOperationException("找不到仓库根");
    }
}
