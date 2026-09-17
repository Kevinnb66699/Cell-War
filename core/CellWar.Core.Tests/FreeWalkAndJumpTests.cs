using System.Text.RegularExpressions;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core.Tests;

/// <summary>
/// 2p / 6p 轨迹一录出来就撞上的两处（2026-09-17，Kevin 要的两条新夹具）：
/// ① 【趋化募集】【效应细胞浸润】是抽到即走的免费连走，GD `_free_walk` 每步问一次「走哪 / 停」；C# 此前做成两条免费移动修饰。
/// ② 小细胞肺癌【转移】只能**朝六个方向直线跃进 5 格**（GD `_jump_targets`）；C# 此前给的是整个 5 环。
/// </summary>
public class FreeWalkAndJumpTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，站 (-4,0,4)，六邻全健康
    private static readonly EntityId Cancer3 = new(4);   // 席位 3：印戒，站 (1,0,-1)
    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    private static WorldState World(int seat)
    {
        var s = DemoScenario.Create();
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: seat, startStep: 2));
    }

    private static RecordingRng Rng() => new(new Xoshiro256StarStar(5));

    private static WorldState Do(WorldState s, IDecision d, RecordingRng? rng = null)
    {
        var r = Engine.ExecuteDecision(s, d, rng ?? Rng());
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    [Fact]
    public void 趋化募集_抽到即挂起两步免费连走_每步停在前_只进无细胞的健康格()
    {
        var s = World(0);
        s = s.UpdateTissueState(P(-3, 0), TissueState.Cancer);   // 一格普通癌组织：【趋化募集】不能进
        s = CardRules.Resolve(s, s.Cells[Immune0], "趋化募集", Rng());

        Assert.Equal(Immune0, s.Turn.PendingChemotaxisCell);
        Assert.Equal(CellRules.FreeWalkMaxSteps, s.Turn.ChemotaxisStepsLeft);
        Assert.Equal("趋化募集", s.Turn.PendingWalkCard);

        var opts = Engine.GetAvailableDecisions(s, 0);
        Assert.IsType<StopChemotaxisDecision>(opts[0]);
        var targets = opts.OfType<ChemotaxisStepDecision>().Select(d => d.Target).ToHashSet();
        Assert.Equal(5, targets.Count);                         // 六邻里五格健康
        Assert.DoesNotContain(P(-3, 0), targets);
        Assert.False(Engine.ValidateDecision(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0))).IsValid);
        Assert.Empty(Engine.GetAvailableDecisions(s, 2));       // 别的席位没有事
        Assert.Equal("k=free_move|g=趋化募集|stop=1", SemanticKey.Of(s, opts[0]));
        Assert.Equal("k=free_move|g=趋化募集|to=-5,1", SemanticKey.Of(s, new ChemotaxisStepDecision(0, Immune0, P(-5, 1))));
    }

    [Fact]
    public void 趋化募集_走一步不扣能量不掷骰_两步走满自动摘掉_停也摘掉()
    {
        var s = World(0);
        s = CardRules.Resolve(s, s.Cells[Immune0], "趋化募集", Rng());
        var rng = Rng();
        var one = Do(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0)), rng);
        Assert.Equal(P(-3, 0), one.Cells[Immune0].Position);
        Assert.Equal(30, one.Cells[Immune0].Energy);            // 免费：不进费用管线
        Assert.Empty(rng.Ranges);                               // 普通格落地零随机
        Assert.Equal(1, one.Turn.ChemotaxisStepsLeft);
        Assert.Equal("趋化募集", one.Turn.PendingWalkCard);

        var two = Do(one, new ChemotaxisStepDecision(0, Immune0, P(-3, -1)));   // (-2,0) 是癌组织，进不了
        Assert.Null(two.Turn.PendingChemotaxisCell);            // 两步走满：GD 循环结束，不再问
        Assert.Null(two.Turn.PendingWalkCard);
        Assert.NotEmpty(Engine.GetAvailableDecisions(two, 0).OfType<MoveDecision>());   // 回到行动栏

        var stopped = Do(s, new StopChemotaxisDecision(0, Immune0));
        Assert.Null(stopped.Turn.PendingChemotaxisCell);
        Assert.Equal(P(-4, 0), stopped.Cells[Immune0].Position);
    }

    [Fact]
    public void 没有可进入的相邻格就不问_当场摘掉()
    {
        var s = World(0);
        foreach (var n in GdNeighbors(s, P(-4, 0)))
            s = s.UpdateTissueState(n, TissueState.SolidifiedCancer);   // 六邻全固化：【趋化募集】一格都进不了
        s = CardRules.Resolve(s, s.Cells[Immune0], "趋化募集", Rng());
        Assert.Equal(Immune0, s.Turn.PendingChemotaxisCell);   // 结算只管挂上
        var normalized = CellRules.NormalizeChemotaxis(s);     // Execute 出口统一收口（GD「没有可进入的相邻格，提前结束」）
        Assert.Null(normalized.Turn.PendingChemotaxisCell);
        Assert.Null(normalized.Turn.PendingWalkCard);
    }

    [Fact]
    public void 效应细胞浸润_还可进普通癌组织_进去照常净化但不给记忆()
    {
        var s = World(0);
        s = s.UpdateTissueState(P(-3, 0), TissueState.Cancer);
        s = s.UpdateTissueState(P(-4, 1), TissueState.SolidifiedCancer);   // 固化不行
        s = CardRules.Resolve(s, s.Cells[Immune0], "效应细胞浸润", Rng());
        Assert.Equal("效应细胞浸润", s.Turn.PendingWalkCard);

        var targets = Engine.GetAvailableDecisions(s, 0).OfType<ChemotaxisStepDecision>().Select(d => d.Target).ToHashSet();
        Assert.Contains(P(-3, 0), targets);
        Assert.DoesNotContain(P(-4, 1), targets);

        var memoryBefore = s.Players[0].AntigenMemory;
        var done = Do(s, new ChemotaxisStepDecision(0, Immune0, P(-3, 0)));
        Assert.Equal(TissueState.Healthy, done.Board.Tissues[P(-3, 0)].State);   // enter_tile → 净化
        Assert.Equal(memoryBefore, done.Players[0].AntigenMemory);                // 卡牌引发的净化不给记忆（GD 嵌在 draw() 的深度里）
    }

    [Fact]
    public void 炎症性趋化的挂起态照旧带卡名_语义键不变()
    {
        var s = World(0);
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(hand: ["炎症性趋化"]));
        var first = Engine.GetAvailableDecisions(s, 0).OfType<PlayCardDecision>().First(p => p.Card == "炎症性趋化");
        var walking = Do(s, first);
        Assert.Equal("炎症性趋化", walking.Turn.PendingWalkCard);
        Assert.Equal("k=free_move|g=炎症性趋化|stop=1", SemanticKey.Of(walking, new StopChemotaxisDecision(0, Immune0)));
    }

    // ---------- 小细胞【转移】 ----------

    private static WorldState Sclc()
    {
        var s = World(3);
        return s.UpdateCell(Cancer3, s.Cells[Cancer3].Copy(type: CellType.SmallCellLung));
    }

    [Fact]
    public void 转移_只朝六个方向直线跃进5格_落在板内且无细胞()
    {
        var s = Sclc();   // 站 (1,0,-1)
        var jumps = Engine.GetAvailableDecisions(s, 3).OfType<TypeSkillDecision>().Where(d => d.Skill == "转移").Select(d => d.Target!.Value).ToHashSet();
        var rays = new[] { P(6, 0), P(6, -5), P(1, -5), P(-4, 0), P(-4, 5), P(1, 5) };
        Assert.Equal(rays.Where(p => p != P(-4, 0)).ToHashSet(), jumps);   // (-4,0) 站着席位 0 的免疫细胞
        // 5 环上不在直线上的格（(0,5) 离 (1,0) 也是 5 格）不行
        Assert.False(Engine.ValidateDecision(s, new TypeSkillDecision(3, Cancer3, "转移", P(0, 5))).IsValid);
        Assert.True(Engine.ValidateDecision(s, new TypeSkillDecision(3, Cancer3, "转移", P(6, 0))).IsValid);
    }

    [Fact]
    public void 转移_每世界回合次数走旋钮_默认2次_0为不限()
    {
        var s = Sclc();
        var used = s.UpdateCell(Cancer3, s.Cells[Cancer3].Copy(jump: 2));
        Assert.Empty(Engine.GetAvailableDecisions(used, 3).OfType<TypeSkillDecision>().Where(d => d.Skill == "转移"));
        var unlimited = used.WithTuning(used.Tuning with { MetastasisMaxPerRound = 0 });
        Assert.NotEmpty(Engine.GetAvailableDecisions(unlimited, 3).OfType<TypeSkillDecision>().Where(d => d.Skill == "转移"));
    }

    [Fact]
    public void 转移次数旋钮的默认值等于GDScript的cw_tuning()
    {
        var gd = File.ReadAllText(Path.Combine(RepoRoot(), "game", "scripts", "core", "cw_tuning.gd"));
        var m = Regex.Match(gd, @"var metastasis_max_per_round := (\d+)");
        Assert.True(m.Success, "cw_tuning.gd 里找不到 metastasis_max_per_round");
        Assert.Equal(int.Parse(m.Groups[1].Value), RuleTuning.Default.MetastasisMaxPerRound);
    }

    private static string RepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !(Directory.Exists(Path.Combine(d, "game")) && Directory.Exists(Path.Combine(d, "core"))))
            d = Path.GetDirectoryName(d);
        return d ?? throw new InvalidOperationException("找不到仓库根");
    }
}
