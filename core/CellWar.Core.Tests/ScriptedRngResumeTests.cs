namespace CellWar.Core.Tests;

/// <summary>
/// 换内核 P5 的两块地基（2026-10-01）：
/// ① <see cref="ScriptedRng"/> —— 产品版脚本骰子，口径照 GD `cw_roll_tape.gd`（退化区间零消耗、区间不符记账照样用值、念完回落），
///    外加宽度相同时的基数平移（C# 0..5 ↔ GD 1..6）与状态往返（Runtime 每个事件都 Fork + SetState）；
/// ② <see cref="MatchSession.Resume"/> —— 从装载好的世界续跑，停在世界里写好的那一席，不经 TurnStart 把它的回合推掉。
/// </summary>
public class ScriptedRngResumeTests
{
    private static ScriptedRng Tape(params int[][] rows) => new(rows.Select(r => (IReadOnlyList<long>)r.Select(x => (long)x).ToArray()));

    [Fact]
    public void 带子按序念_退化区间零消耗_宽度相同只平移基数()
    {
        var rng = Tape([1, 6, 4], [1, 6, 2]);
        Assert.Equal(0, rng.NextInt(1));   // 退化区间：不碰带子
        Assert.Equal(0, rng.Consumed);
        Assert.Equal(3, rng.NextInt(6));   // GD 1..6 掷 4 ⇒ C# 0..5 是 3
        Assert.Equal(1, rng.NextInt(6));
        Assert.Equal((2, 0, 0), (rng.Consumed, rng.Overrun, rng.BadRange));
    }

    [Fact]
    public void 区间宽度对不上_记一笔照样用带子上的值()
    {
        var rng = Tape([1, 3, 3]);
        Assert.Equal(3, rng.NextInt(6));   // 带子是 [1,3]、要的是 [0,5]：宽度不同，不平移，夹进范围
        Assert.Equal(1, rng.BadRange);
    }

    [Fact]
    public void 念完回落_记Overrun_同种子同序列()
    {
        var a = new ScriptedRng([], 7);
        var b = new ScriptedRng([], 7);
        var xs = Enumerable.Range(0, 20).Select(_ => a.NextInt(6)).ToArray();
        Assert.Equal(xs, Enumerable.Range(0, 20).Select(_ => b.NextInt(6)).ToArray());
        Assert.Equal(20, a.Overrun);
        Assert.All(xs, x => Assert.InRange(x, 0, 5));
        Assert.True(xs.Distinct().Count() > 2, "回落流该是随机的，不是常数");
        var c = new ScriptedRng([], 8);
        Assert.NotEqual(xs, Enumerable.Range(0, 20).Select(_ => c.NextInt(6)).ToArray());
    }

    /// <summary>
    /// 回落流 = Godot 4.5 `RandomNumberGenerator`（PCG32）逐位照抄（换内核 P5（三））。金值是 Godot 4.5-stable 实测：
    /// `var r := RandomNumberGenerator.new(); r.seed = 1; r.randi_range(1, 6)` 连掷 16 颗。GD 侧 `t_tutor_sidecar_rng` 钉同一串 ——
    /// 哪天升引擎改了 PCG，两边一起红，而不是 C# 这份悄悄跟线上分家。
    /// </summary>
    [Fact]
    public void 回落流与Godot的RandomNumberGenerator逐颗相同()
    {
        var d6 = new[] { 4, 1, 2, 5, 4, 6, 2, 6, 4, 6, 2, 5, 3, 4, 4, 4 };
        var rng = new ScriptedRng([], 1);
        Assert.Equal(d6, Enumerable.Range(0, 16).Select(_ => rng.NextInt(6) + 1).ToArray());   // C# 掷 0..5，GD 掷 1..6：同一个偏移量

        // 区间宽度各异 + 退化区间零消耗：randi_range(0,4) (1,6) (0,0) (3,3) (0,9) (1,2) (0,126) (-5,5)
        var mix = new ScriptedRng([], 1);
        Assert.Equal(new[] { 2, 1, 0, 3, 9, 1, 115, -1 }, new[]
        {
            mix.NextIntRange(0, 5), mix.NextIntRange(1, 7), mix.NextIntRange(0, 1), mix.NextIntRange(3, 4),
            mix.NextIntRange(0, 10), mix.NextIntRange(1, 3), mix.NextIntRange(0, 127), mix.NextIntRange(-5, 6),
        });
        Assert.Equal(unchecked((ulong)-3865055664179818387L), mix.GetState().Counter);   // GD `r.state` 读出来的同一个数

        var seven = new ScriptedRng([], 7);
        Assert.Equal(new[] { 6, 2, 5, 6, 4, 6, 1, 6 }, Enumerable.Range(0, 8).Select(_ => seven.NextInt(6) + 1).ToArray());
    }

    /// <summary>GD `cw_roll_tape.gd` 念带子时照样 `inner.randi_range` 推一步：带子念完，回落流接着的是第 3 颗，不是第 1 颗。</summary>
    [Fact]
    public void 念带子也推回落流_念完接着Godot那一串的下一颗()
    {
        var rng = Tape([1, 6, 6], [1, 6, 6]);
        Assert.Equal(new[] { 6, 6, 2, 5 }, Enumerable.Range(0, 4).Select(_ => rng.NextInt(6) + 1).ToArray());   // 金值第 3、4 颗 = 2、5
        Assert.Equal((2, 2, 0), (rng.Consumed, rng.Overrun, rng.BadRange));
    }

    [Fact]
    public void 状态往返_Fork后SetState接着念同一串()
    {
        var rng = Tape([1, 6, 5], [1, 6, 1], [1, 6, 6]);
        rng.NextInt(6);
        var state = rng.GetState();
        var rest = new[] { rng.NextInt(6), rng.NextInt(6), rng.NextInt(6), rng.NextInt(6) };   // 两条带子 + 两次回落

        var again = rng.Fork();
        again.SetState(state);
        Assert.Equal(rest, new[] { again.NextInt(6), again.NextInt(6), again.NextInt(6), again.NextInt(6) });
    }

    [Fact]
    public void Resume_停在世界写好的那一席_不经TurnStart()
    {
        var world = DemoScenario.Create();
        world = world.WithTurn(world.Turn.Copy(phase: Phase.PlayerAction, seat: 1));

        using var resumed = MatchSession.Resume(world, new Xoshiro256StarStar(1));
        var snap = resumed.Peek();
        Assert.Equal(Phase.PlayerAction, snap.State.Turn.Phase);
        Assert.Equal(1, snap.State.Turn.ActivePlayerSeat);
        Assert.Equal(1, snap.Input?.PlayerSeat);
        Assert.Equal(world.Turn.WorldRound, snap.State.Turn.WorldRound);

        // 对照：走 TurnStart 的老构造会先推一格阶段 —— 第 1 席的这一回合就没了
        using var started = new MatchSession(world, 1);
        var other = started.Peek();
        Assert.False(other.State.Turn.Phase == Phase.PlayerAction && other.State.Turn.ActivePlayerSeat == 1 && other.Input?.PlayerSeat == 1,
            "TurnStart 那条路不该还停在第 1 席的行动回合 —— 否则 Resume 这个入口就没有存在的理由");
    }
}
