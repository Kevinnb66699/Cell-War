using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// 意图评估器 = GD <c>MechIntent</c>（game/scripts/ai/mech/mech_intent.gd）：生成迁移候选路径 → 在推演游标上试走 → 读「做完之后的地图和能量」→ 复原。
/// 意图档（<see cref="IntentPolicy"/>）与搜索档（<see cref="SearchPolicy"/>）共用。
///
/// 对拍模式下 GD 参照与这里逐条相同的三件事：候选按规范序展开（「取前 3 个二步」不跟引擎枚举序）、
/// 并列稳定排序（GD <c>sort_custom</c> 不稳定）、读数记进 trace。
/// </summary>
internal sealed class MechIntent
{
    private readonly AiConfig config;
    private readonly AiTrace? trace;

    public MechIntent(AiConfig config, AiTrace? trace)
    {
        this.config = config;
        this.trace = trace;
    }

    /// <summary>GD <c>evaluate_path</c>：按序执行 pid 的迁移路径、读数、复原。换人 / 换阶段 = 路径执行完（不算失败）；找不到选项 = 失败。</summary>
    public MechMetrics EvaluatePath(RolloutCursor g, int pid, IReadOnlyList<HexPosition> path)
    {
        var snap = g.Save();
        var steps = 0;
        var ok = true;
        foreach (var to in path)
        {
            var req = g.Pending();
            if (req == null) { ok = false; break; }
            if (req.Seat != pid) break;
            var opt = RolloutCursor.FindMove(req.View, to);
            if (opt == null) { ok = false; break; }
            g.Step(opt);
            steps++;
        }
        var m = MechMetrics.Read(g.State, pid) with { Ok = ok, StepsDone = steps };
        g.Restore(snap);
        return m;
    }

    /// <summary>
    /// GD <c>candidates</c>：第一项永远是「不动」（空路径）；1 步 = 每个合法迁移落点；
    /// 2 步 = 对每个 1 步落点试走一步、取下一步可达落点的前 <see cref="AiConfig.SecondStepMax"/> 个。
    /// </summary>
    public List<IReadOnlyList<HexPosition>> Candidates(RolloutCursor g, int pid, int maxSteps = 2)
    {
        var req = g.Pending();
        if (req == null || req.Seat != pid) return [];
        var output = new List<IReadOnlyList<HexPosition>> { Array.Empty<HexPosition>() };
        var oneStep = RolloutCursor.MoveTargets(req.View);
        foreach (var t in oneStep) output.Add([t]);
        if (maxSteps < 2) return output;
        foreach (var to1 in oneStep)
        {
            var opt = RolloutCursor.FindMove(req.View, to1);
            if (opt == null) continue;
            var snap = g.Save();
            g.Step(opt);
            var req2 = g.Pending();
            var second = req2 != null && req2.Seat == pid ? RolloutCursor.MoveTargets(req2.View) : [];
            g.Restore(snap);
            foreach (var to2 in second.Take(config.SecondStepMax)) output.Add([to1, to2]);
        }
        return output;
    }

    /// <summary>GD <c>best_by</c>：评估全部候选，按 scorer 取最高（并列取第一个 = 「不动」优先）。返回 null = 没有候选。</summary>
    public IReadOnlyList<HexPosition>? BestBy(RolloutCursor g, int pid, Func<MechMetrics, double> scorer)
    {
        IReadOnlyList<HexPosition>? best = null;
        var bestScore = double.NegativeInfinity;
        foreach (var path in Candidates(g, pid))
        {
            var m = EvaluatePath(g, pid, path);
            var s = scorer(m);
            trace?.Cands.Add((path, m, s));
            if (s > bestScore) { bestScore = s; best = path; }
        }
        return best;
    }

    /// <summary>搜索档一问的结果：最优根路径、计划第一手、评完了几个根、是否被预算 / 取消截断。</summary>
    public sealed record SearchResult(IReadOnlyList<HexPosition>? Path, AiOption? Plan0, int Evaluated, bool Truncated);

    /// <summary>
    /// GD <c>search_best</c>（alpha-beta v2，叶 = 回合边界）：根候选只取**单步**，按快评分（阵营 scorer）稳定排序取前 TopK，
    /// 每个根走 <see cref="AbLine"/>；值统一在搜索方视角（叶 = 拟合估值按搜索方阵营翻号一次）。
    ///
    /// 计划第一手：根路径非空时就是那一步迁移；空路径（「不动」最好）时 GD 再跑一条「计划捕获线」
    /// （<c>_ab_line(..., record)</c>）、取录到的第一手 —— 那一手就是陪练在**根局面、根随机流状态**上的作答
    /// （路径为空，捕获线的第一问就是根问答本身），后面整回合的模拟对答案没有影响。所以这里直接问陪练，省一整回合推演。
    ///
    /// <paramref name="stop"/> 返回 true 就不再开新的根；正在评的根被取消（OperationCanceledException）则丢掉它。
    /// 已评完的根里取最好的；一个都没评完 Path 为 null（调用方回落普通档）。
    /// </summary>
    public SearchResult SearchBest(RolloutCursor g, int pid, Func<bool> stop)
    {
        var myFac = g.State.Players[pid].Faction;
        Func<MechMetrics, double> quick = myFac == Faction.Cancer ? m => MechScores.Cancer(m, config) : MechScores.Immune;
        var scored = new List<(IReadOnlyList<HexPosition> Path, double Q)>();
        foreach (var path in Candidates(g, pid, 1))
        {
            var m = EvaluatePath(g, pid, path);
            var q = quick(m);
            scored.Add((path, q));
            trace?.Cands.Add((path, m, q));
        }
        var roots = scored.OrderByDescending(x => x.Q).Take(config.TopK).ToList();   // OrderBy 稳定：并列保持候选原序
        var alpha = double.NegativeInfinity;
        IReadOnlyList<HexPosition>? best = null;
        var evaluated = 0;
        var truncated = false;
        var rootSnap = g.Save();
        foreach (var (path, _) in roots)
        {
            if (stop()) { truncated = true; break; }
            double v;
            try { v = AbLine(g, pid, path, myFac, config.SearchDepth, alpha, double.PositiveInfinity); }
            catch (OperationCanceledException) { g.Restore(rootSnap); truncated = true; break; }
            g.Restore(rootSnap);
            evaluated++;
            trace?.Roots.Add((path, v));
            if (v > alpha || best == null) { alpha = v; best = path; }
        }
        if (best == null) return new SearchResult(null, null, evaluated, truncated);
        var rootAsk = g.Pending()!;
        var plan0 = best.Count > 0 ? RolloutCursor.FindMove(rootAsk.View, best[0]) : g.SimDecide(rootAsk);
        if (trace != null) { trace.Best = best; trace.Plan0 = plan0; }
        return new SearchResult(best, plan0, evaluated, truncated);
    }

    /// <summary>
    /// GD <c>_ab_line</c>：落地 path → 推进到回合边界（其余席位 + E 阶段全结算）→ depth &gt; 1 则边界上的下一席再选计划再推进 → 叶读数。
    /// 同阵营节点也取 max（6 人交错序必需）；对手节点只看快评分前 <see cref="AiConfig.OppTopK"/> 个。
    /// </summary>
    private double AbLine(RolloutCursor g, int actor, IReadOnlyList<HexPosition> path, Faction myFac, int depth,
        double alpha, double beta)
    {
        PlayPath(g, actor, path);
        var req = DriveToRoundEnd(g);
        if (depth <= 1 || req == null)
        {
            var leafM = MechMetrics.Read(g.State, req?.Seat ?? actor);
            var ev = MechScores.PositionEval(leafM);
            var v = myFac == Faction.Immune ? ev : -ev;
            trace?.Leaves.Add(v);
            return v;
        }
        var nxt = req.Seat;
        var nxtFac = g.State.Players[nxt].Faction;
        var maximizing = nxtFac == myFac;
        Func<MechMetrics, double> quick = nxtFac == Faction.Cancer ? m => MechScores.Cancer(m, config) : MechScores.Immune;
        var subs = new List<(IReadOnlyList<HexPosition> Path, double Q)>();
        foreach (var p in Candidates(g, nxt))
            subs.Add((p, quick(EvaluatePath(g, nxt, p))));
        subs = maximizing ? subs.OrderByDescending(x => x.Q).ToList() : subs.OrderBy(x => x.Q).ToList();
        trace?.Nodes.Add((nxt, subs.ToList()));
        var bestV = maximizing ? double.NegativeInfinity : double.PositiveInfinity;
        foreach (var (p, _) in subs.Take(config.OppTopK))
        {
            var snap = g.Save();
            var v = AbLine(g, nxt, p, myFac, depth - 1, alpha, beta);
            g.Restore(snap);
            if (maximizing) { bestV = Math.Max(bestV, v); alpha = Math.Max(alpha, v); }
            else { bestV = Math.Min(bestV, v); beta = Math.Min(beta, v); }
            if (beta <= alpha) break;
        }
        return bestV;
    }

    /// <summary>GD <c>_play_path</c>：按序落地一条迁移路径（局面变了就地停，不视为失败）。</summary>
    private static void PlayPath(RolloutCursor g, int pid, IReadOnlyList<HexPosition> path)
    {
        foreach (var to in path)
        {
            var req = g.Pending();
            if (req == null || req.Seat != pid) return;
            var opt = RolloutCursor.FindMove(req.View, to);
            if (opt == null) return;
            g.Step(opt);
        }
    }

    /// <summary>GD <c>_drive_to_round_end</c> 的护栏：一条线最多推 240 问（防桥实现异常死循环）。</summary>
    private const int DriveGuard = 240;

    /// <summary>
    /// GD <c>_drive_to_round_end</c>：陪练逐问作答，推到**跨入下一世界回合后的第一个顶层问答**（= 回合边界，叶读数点）；终局 / 护栏耗尽返回 null。
    /// </summary>
    private static PendingAsk? DriveToRoundEnd(RolloutCursor g)
    {
        var r0 = g.Round;
        for (var guard = 0; guard < DriveGuard; guard++)
        {
            var req = g.Pending();
            if (req == null) return null;
            if (g.Round != r0) return req;
            g.Step(g.SimResolve(g.SimDecide(req)));
        }
        return null;
    }
}
