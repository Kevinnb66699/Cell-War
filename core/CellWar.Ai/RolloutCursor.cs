using CellWar.Core;

namespace CellWar.Ai;

/// <summary>顶层问答：谁、问什么（规范视图）。GD <c>pending()</c> 的返回值。</summary>
internal sealed record PendingAsk(int Seat, AskView View);

/// <summary>
/// **推演游标** = GD 意图 / 搜索档的 image（<c>CWMonteCarloBridge._build_image_static</c>）：
/// 从一个世界出发、用自己的随机流往前推，所有席位都由同一个普通档陪练作答，真局一行不动。
///
/// 语义逐条对齐 GD 的 <c>pending()</c> / <c>step()</c>：
/// · <see cref="Pending"/> 只停在**顶层**问答（落子 / 复活 / 行动），结算中途的追问（连走、弃置、二选一、风暴选中心……）
///   由陪练当场答掉 —— GD 里它们在 <c>step()</c> 内经 <c>game.ask</c> 送到 image 的桥；没人能动就推阶段（RuleFlow.Continue 同式）；
/// · <see cref="Step"/> = 执行 + 推进到下一个顶层问答（GD <c>step()</c> 末尾的 <c>advance()</c>）—— 读数一律在那之后读；
/// · 快照 = 世界引用 + 随机流状态，O(1)（WorldState 不可变）。
/// </summary>
internal sealed class RolloutCursor
{
    private static readonly BasicRulesEngine Engine = new();
    private readonly NormalPolicy sim;
    private PendingAsk? pending;
    private bool pendingValid;

    /// <summary>
    /// 排查用：陪练每答一问记一条（席位、规范视图里的键、作答时随机流状态），与 GD 侧 <c>agree_rng.gd</c> 的
    /// <c>step_log</c> 逐条比，定位试走在哪一步分叉。线程本地、默认 null（产品路径零开销）。
    /// </summary>
    [ThreadStatic] internal static Action<int, string, ulong, WorldState>? DebugStep;

    public WorldState State { get; private set; }
    public SplitMix64Rng Rng { get; }
    public CancellationToken Cancellation { get; init; }

    public RolloutCursor(WorldState state, ulong rngState, NormalPolicy sim)
    {
        State = state;
        Rng = new SplitMix64Rng(rngState);
        this.sim = sim;
    }

    public readonly record struct Snapshot(WorldState State, ulong Rng, PendingAsk? Pending, bool PendingValid);

    public Snapshot Save() => new(State, Rng.State, pending, pendingValid);

    public void Restore(Snapshot snap)
    {
        State = snap.State;
        Rng.SetState(new RngState(1, snap.Rng));
        pending = snap.Pending;
        pendingValid = snap.PendingValid;
    }

    public int Round => State.Turn.WorldRound;

    /// <summary>当前顶层问答；null = 对局结束（GD <c>pending()</c> 返回空字典）。</summary>
    public PendingAsk? Pending()
    {
        if (pendingValid) return pending;
        while (true)
        {
            Cancellation.ThrowIfCancellationRequested();
            if (State.Turn.Phase == Phase.Finished) { pending = null; break; }
            var (seat, options) = NextAsked(State);
            if (options.Count == 0)
            {
                State = Engine.AdvancePhase(State, Rng).NewState;
                continue;
            }
            var view = AskView.Build(State, seat, options);
            if (view.TopLevel) { pending = new PendingAsk(seat, view); break; }
            // 结算中途的追问：陪练当场答
            var picked = sim.Decide(new AiView(State), view, Rng.State);
            DebugStep?.Invoke(seat, picked.Key, Rng.State, State);
            Execute(picked.Children.Count > 0 ? sim.ResolveGroup(new AiView(State), picked) : picked);
        }
        pendingValid = true;
        return pending;
    }

    /// <summary>对当前顶层问答作答，并推进到下一个顶层问答（GD <c>step()</c>）。</summary>
    public void Step(AiOption option)
    {
        Execute(option);
        Pending();
    }

    private void Execute(AiOption option)
    {
        var decision = option.Decision ?? throw new InvalidOperationException($"折叠的组选项 {option.Key} 不能直接执行（先 ResolveGroup）");
        var result = Engine.ExecuteDecision(State, decision, Rng);
        if (!result.Success) throw new InvalidOperationException($"推演里选项表给出的 {option.Key} 执行失败：{result.ErrorMessage}");
        State = result.NewState;
        pendingValid = false;
    }

    /// <summary>陪练答一问（GD image 的桥）：返回它在**规范视图**里选的那条（组选项还没落到子项，录计划时要的就是这一层）。</summary>
    public AiOption SimDecide(PendingAsk ask)
    {
        var picked = sim.Decide(new AiView(State), ask.View, Rng.State);
        DebugStep?.Invoke(ask.Seat, picked.Key, Rng.State, State);
        return picked;
    }

    public AiOption SimResolve(AiOption chosen)
    {
        if (chosen.Children.Count == 0) return chosen;
        var child = sim.ResolveGroup(new AiView(State), chosen);
        DebugStep?.Invoke(-1, child.SubKey!, Rng.State, State);   // GD 的第二问（chemo_target / effector_target）是单独一问
        return child;
    }

    /// <summary>
    /// 这一刻该谁作答（L1 KeyWalk 同口径）：同一时刻只有一个席位有选项（挂起态各自只放主人进来），
    /// 先看行动席位省一圈枚举。
    /// </summary>
    internal static (int Seat, IReadOnlyList<IDecision> Options) NextAsked(WorldState s)
    {
        var active = s.Turn.ActivePlayerSeat;
        var first = Engine.GetAvailableDecisions(s, active);
        if (first.Count > 0) return (active, first);
        foreach (var seat in s.Players.Keys.OrderBy(x => x))
        {
            if (seat == active) continue;
            var options = Engine.GetAvailableDecisions(s, seat);
            if (options.Count > 0) return (seat, options);
        }
        return (-1, Array.Empty<IDecision>());
    }

    /// <summary>GD <c>_find_move</c>：这一问里「迁移到 to」的那一条。</summary>
    public static AiOption? FindMove(AskView view, HexPosition to)
    {
        foreach (var o in view.Options)
            if (o.Act == "move" && o.To == to) return o;
        return null;
    }

    /// <summary>这一问的全部迁移落点，按规范序（GD 对拍模式 <c>_move_targets</c>）。</summary>
    public static List<HexPosition> MoveTargets(AskView view)
    {
        var list = new List<HexPosition>();
        foreach (var o in view.Options)
            if (o.Act == "move") list.Add(o.To!.Value);
        return list;
    }
}
