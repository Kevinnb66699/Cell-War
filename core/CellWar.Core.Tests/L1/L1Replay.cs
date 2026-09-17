using System.Text.Json;
using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>一步的结局。Code 取对拍规格的词：PASS / OPTION_DIFF / PICK_MISSING / EXEC_FAIL / NO_ASK / RNG_* / STATE_MISMATCH / BADFIXTURE。</summary>
public sealed record StepOutcome(int N, string Code, string Detail);

public sealed record ReplayReport(int Agreed, IReadOnlyList<StepOutcome> Steps, IReadOnlyList<string> BaseNotes)
{
    public StepOutcome? FirstDivergence => Steps.FirstOrDefault(x => x.Code != "PASS");

    public IEnumerable<string> Lines()
    {
        yield return $"L1 重放：分叉前一致 {Agreed} 步；第一处分叉：{(FirstDivergence is { } d ? $"#{d.N} {d.Code}" : "无")}";
        foreach (var s in Steps) yield return $"#{s.N,4} {s.Code,-14} {s.Detail}";
        if (BaseNotes.Count > 0) yield return $"RNG_BASE（跨度同、基数不同，良性）{BaseNotes.Count} 条，首条：{BaseNotes[0]}";
    }
}

/// <summary>
/// **教师强制重放**：GD 录的轨迹当老师，C# 每一步都按老师的答案走、掷老师掷出的骰，然后比状态。
///
/// 每步三道判据，按顺序，哪道不过这一步就停在哪道（后面的都是这一步之内的因果，不再往下比）：
/// 1. **选项集合**：C# 在同一席位给出的语义键集合 = GD 那一问的选项键集合（比集合不比顺序）。
///    固定差异先减掉：C# 每个 action 问答多一条 `pass`；GD 癌方复活多一条「放弃本回合复活」。
/// 2. **选到的那一项 C# 也有**，执行成功；GD 两问（发动 + 选目标）并成 C# 的一个组键决策。
/// 3. **状态视图逐字段相同**（<see cref="L1View"/>），带子恰好念完（有剩 = `RNG_UNUSED`）。
///
/// 分叉之后不再往下比：状态已经不是同一个世界，往下每一步都是这一处分叉的回声。
/// </summary>
public static class L1Replay
{
    /// <summary>C# 侧固定多出来的：每个 action 问答一条 `pass`（GD 没有这个动作）。</summary>
    private static readonly HashSet<string> CsKnownExtra = new(StringComparer.Ordinal) { SemanticKey.PassKey };

    /// <summary>GD 侧固定多出来的选项。2026-09-16 起为空 —— 「放弃本回合复活」已补进 C#；留着这个口子给下一条形状差异。</summary>
    private static readonly HashSet<string> GdKnownExtra = new(StringComparer.Ordinal);

    public static ReplayReport Run(string tracePath, int maxSteps = int.MaxValue)
    {
        var lines = File.ReadLines(tracePath).Where(l => l.Length > 0).Select(l => JsonDocument.Parse(l).RootElement).ToList();
        var header = lines[0];
        var steps = lines.Where(l => l.GetProperty("t").GetString() == "step").ToList();
        var engine = new BasicRulesEngine();
        var outcomes = new List<StepOutcome>();
        var notes = new List<string>();

        var firstAsk = steps[0].GetProperty("asks")[0];
        var s = L1View.Load(header.GetProperty("pre"), firstAsk.GetProperty("pid").GetInt32());

        // 装载自证：装出来的世界导回视图必须与 pre 一字不差 —— 这一步不过，后面全是假清单
        var boot = DeepDiff.Compare(L1View.Plain(header.GetProperty("pre")), L1View.Of(s), "$", 8);
        if (boot.Count > 0)
        {
            outcomes.Add(new StepOutcome(0, "BADFIXTURE", "装载后视图与 pre 不同：" + string.Join("；", boot)));
            return new ReplayReport(0, outcomes, notes);
        }

        var agreed = 0;
        foreach (var step in steps.Take(maxSteps))
        {
            var n = step.GetProperty("n").GetInt32();
            var rng = new TapeRng(step.GetProperty("rng").EnumerateArray()
                .Select(r => (IReadOnlyList<long>)r.EnumerateArray().Select(x => x.GetInt64()).ToList()));
            var asks = step.GetProperty("asks").EnumerateArray().ToList();
            string? code = null;
            var detail = "";
            try
            {
                for (var i = 0; i < asks.Count && code == null; i++)
                {
                    var ask = asks[i];
                    var kind = ask.GetProperty("kind").GetString()!;
                    var pid = ask.GetProperty("pid").GetInt32();
                    if (kind is "chemo_target" or "effector_target") continue;   // 子问：已并进上一问的组键

                    var options = engine.GetAvailableDecisions(s, pid);
                    if (options.Count == 0)
                    {
                        code = "NO_ASK";
                        detail = $"GD 在问席位 {pid}（{kind}），C# 这时没有任何选项（阶段 {s.Turn.Phase}，轮到 {s.Turn.ActivePlayerSeat}）";
                        break;
                    }
                    var keyed = options.Select(d => (Key: SemanticKey.Of(s, d), D: d)).ToList();
                    var gdOpts = ask.GetProperty("opts").EnumerateArray().Select(x => x.GetString()!).ToHashSet(StringComparer.Ordinal);
                    var csOpts = keyed.Select(k => Collapse(kind, k.Key)).ToHashSet(StringComparer.Ordinal);
                    var missing = gdOpts.Except(csOpts).Where(k => !GdKnownExtra.Contains(k)).OrderBy(x => x, StringComparer.Ordinal).ToList();
                    var extra = csOpts.Except(gdOpts).Where(k => !CsKnownExtra.Contains(k)).OrderBy(x => x, StringComparer.Ordinal).ToList();
                    if (missing.Count + extra.Count > 0)
                    {
                        code = "OPTION_DIFF";
                        detail = $"{kind}@{pid}｜C# 缺 {missing.Count}：{Head(missing)}｜C# 多 {extra.Count}：{Head(extra)}";
                        break;
                    }

                    var pick = Merge(kind, ask.GetProperty("pick").GetString()!, i + 1 < asks.Count ? asks[i + 1] : null, ref i);
                    var chosen = keyed.FirstOrDefault(k => k.Key == pick).D;
                    if (chosen == null) { code = "PICK_MISSING"; detail = $"GD 选了 {pick}，C# 的选项表里没有"; break; }

                    var result = engine.ExecuteDecision(s, chosen, rng);
                    if (!result.Success) { code = "EXEC_FAIL"; detail = $"{pick}：{result.ErrorMessage}"; break; }
                    s = result.NewState;
                }
                if (code == null)
                {
                    // GD 的 step() 末尾 advance() 到下一个决策点；C# 没人能动就推阶段 —— E 阶段的抽取也在这一步的带子上
                    while (s.Turn.Phase != Phase.Finished && !AnyoneCanAct(engine, s))
                        s = engine.AdvancePhase(s, rng).NewState;
                    if (rng.Unused > 0) { code = "RNG_UNUSED"; detail = $"这一步的带子还剩 {rng.Unused} 条没念（C# 少掷了）"; }
                }
            }
            catch (TapeException e) { code = e.Code; detail = e.Message; }
            notes.AddRange(rng.BaseNotes.Select(x => $"#{n} {x}"));

            if (code == null)
            {
                var diffs = DeepDiff.Compare(L1View.Plain(step.GetProperty("post")), L1View.Of(s), "$", 8);
                if (diffs.Count > 0) { code = "STATE_MISMATCH"; detail = string.Join("；", diffs); }
            }
            outcomes.Add(new StepOutcome(n, code ?? "PASS", detail));
            if (code != null) break;
            agreed++;
        }
        return new ReplayReport(agreed, outcomes, notes);
    }

    private static bool AnyoneCanAct(BasicRulesEngine engine, WorldState s)
        => s.Players.Keys.Any(seat => engine.GetAvailableDecisions(s, seat).Count > 0);

    /// <summary>C# 的组键在 GD 的顶层问答里只有「发动」那一半：`k=action+chemo_target|act=chemo|to=…` → `k=action|act=chemo`。</summary>
    private static string Collapse(string kind, string key)
    {
        if (kind != "action") return key;
        if (key.StartsWith("k=action+chemo_target|", StringComparison.Ordinal)) return "k=action|act=chemo";
        if (key.StartsWith("k=action+effector_target|", StringComparison.Ordinal)) return "k=action|act=effector";
        return key;
    }

    /// <summary>GD 两问 ↔ C# 一决策：把紧跟着的那一问（选目标）的 pick 并进组键，并跳过它。</summary>
    private static string Merge(string kind, string pick, JsonElement? next, ref int i)
    {
        if (kind != "action" || next is not { } nx) return pick;
        var nextKind = nx.GetProperty("kind").GetString();
        var nextPick = nx.GetProperty("pick").GetString()!;
        if (pick == "k=action|act=chemo" && nextKind == "chemo_target")
        {
            i++;
            return "k=action+chemo_target|act=chemo|" + nextPick["k=chemo_target|".Length..];
        }
        if (pick == "k=action|act=effector" && nextKind == "effector_target")
        {
            i++;
            return "k=action+effector_target|act=effector|" + nextPick["k=effector_target|".Length..];
        }
        return pick;
    }

    private static string Head(IReadOnlyList<string> xs) => string.Join(" ", xs.Take(4)) + (xs.Count > 4 ? " …" : "");
}
