using System.IO.Compression;
using System.Text.Json;
using CellWar.Ai;
using CellWar.Core.Tests.L0;

namespace CellWar.Core.Tests.Ai;

/// <summary>
/// AI 对拍语料（cwxagree/1，game/tests/ai_agree_export.gd 录）的 C# 重放器：GD 三档当老师，C# 三档逐问作答、逐项比。
///
/// 一段 = 从一条带 <c>world</c> 的顶层问答（行动 / 落子）起，到下一条带 world 的为止：
/// 装世界（WorldLoader）+ 真局随机流状态（SplitMix64）→ 每问先推阶段到有人能动 → 比「谁在被问、选项集合、GD 形状字段」
/// → 三档各答一遍、和 GD 的答案比（意图 / 搜索档再比候选读数 / 叶值）→ 按 GD 真走的那一手执行，接着下一问。
/// 段尾（下一个起点）顺带比一次 C# 推出来的世界与 GD 导出的世界、随机流状态 —— 内核逐步对齐的旁证。
///
/// 分叉（谁被问 / 选项集合 / 执行失败对不上）只作废**这一段**余下的问答，下一段重新装世界；每一条都要归因，测试要求零条。
/// </summary>
public static class AgreeReplay
{
    public sealed class Report
    {
        public int Asks, Segments, Compared;
        public Dictionary<string, int> Agree { get; } = new() { ["normal"] = 0, ["intent"] = 0, ["search"] = 0 };
        public Dictionary<string, int> Total { get; } = new() { ["normal"] = 0, ["intent"] = 0, ["search"] = 0 };
        public int IntentTraced, SearchTraced, IntentTraceEqual, SearchTraceEqual;
        public int DataChecked, BoundaryChecked;
        public List<string> Divergences { get; } = [];
        public List<string> Mismatches { get; } = [];
        public List<string> DataDiffs { get; } = [];
        public List<string> BoundaryDiffs { get; } = [];
        public Dictionary<string, List<long>> Micros { get; } = new() { ["normal"] = [], ["intent"] = [], ["search"] = [] };

        public IEnumerable<string> Lines(string name)
        {
            yield return $"# {name}：{Asks} 问 / {Segments} 段，比了 {Compared} 问；分叉 {Divergences.Count}";
            foreach (var t in Total.Keys)
                yield return $"  {t,-7} 答案一致 {Agree[t]}/{Total[t]}";
            yield return $"  意图读数逐字段相等 {IntentTraceEqual}/{IntentTraced}；搜索读数相等 {SearchTraceEqual}/{SearchTraced}";
            yield return $"  GD 形状字段（含 cost）比了 {DataChecked} 问，差 {DataDiffs.Count}；段界世界比了 {BoundaryChecked} 次，差 {BoundaryDiffs.Count}";
            foreach (var l in Divergences.Take(20)) yield return "  [分叉] " + l;
            foreach (var l in Mismatches.Take(40)) yield return "  [不一致] " + l;
            foreach (var l in DataDiffs.Take(20)) yield return "  [字段] " + l;
            foreach (var l in BoundaryDiffs.Take(10)) yield return "  [段界] " + l;
        }
    }

    private static readonly BasicRulesEngine Engine = new();

    public static IEnumerable<JsonElement> ReadRows(string path)
    {
        using var file = File.OpenRead(path);
        Stream stream = path.EndsWith(".gz", StringComparison.Ordinal) ? new GZipStream(file, CompressionMode.Decompress) : file;
        using var reader = new StreamReader(stream);
        while (reader.ReadLine() is { } line)
            if (line.Length > 0) yield return JsonDocument.Parse(line).RootElement.Clone();
    }

    /// <param name="tiers">要比哪几档（搜索档最慢，迭代时可以只比 normal）。</param>
    /// <param name="mutate">变异检验用：把被测的策略换一份。</param>
    /// <param name="onAsk">排查用：每一问比之前回调 (序号, 世界, 席位, 选项, 推演种子)。</param>
    /// <param name="stopAtFirst">变异检验用：出现第一处答案 / 读数不一致就收（不必把整份语料跑完）。</param>
    public static Report Run(string path, IReadOnlyCollection<string> tiers, Func<string, IPolicy>? policies = null,
        Action<int, WorldState, int, IReadOnlyList<IDecision>, ulong>? onAsk = null, bool stopAtFirst = false)
    {
        var report = new Report();
        policies ??= t => AiPolicies.Create(AiConfig.For(AiConfig.ParseTier(t)));
        var cache = tiers.ToDictionary(t => t, policies);
        var rows = ReadRows(path).Where(r => r.GetProperty("t").GetString() == "ask").ToList();
        report.Asks = rows.Count;

        WorldState? s = null;
        SplitMix64Rng? rng = null;
        var alive = false;   // 这一段还在跟 GD 同步
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var n = row.GetProperty("i").GetInt32();
            var kind = row.GetProperty("kind").GetString()!;
            if (row.TryGetProperty("world", out var world))
            {
                var spec = JsonSerializer.Deserialize<L0World>(world.GetRawText(), L0RunnerTests.Json)!;
                var gdRng = (ulong)long.Parse(row.GetProperty("rng").GetString()!);
                if (alive && s != null && rng != null) CheckBoundary(report, n, s, rng, spec, gdRng);
                s = WorldLoader.Load(spec);
                // cwxworld/3 不带 GD 的 `flow["acts"]`（行动次数护栏的计数），语料单记一份
                if (row.TryGetProperty("acts", out var acts)) s = s.WithTurn(s.Turn.Copy(actionsThisTurn: acts.GetInt32()));
                rng = new SplitMix64Rng(gdRng);
                alive = true;
                report.Segments++;
            }
            if (!alive || s == null || rng == null) continue;
            if (kind is "chemo_target" or "effector_target") continue;   // 组键的第二问：已在上一问里并进去

            // 推到有人能动（GD 的 step() 末尾 advance() 到下一问；中间的 E / S 阶段在这里推）
            while (s.Turn.Phase != Phase.Finished && RolloutCursorProbe.NextAsked(s).Options.Count == 0)
                s = Engine.AdvancePhase(s, rng).NewState;
            var (seat, options) = RolloutCursorProbe.NextAsked(s);
            var gdSeat = row.GetProperty("seat").GetInt32();
            if (seat != gdSeat || options.Count == 0)
            {
                report.Divergences.Add($"#{n} {kind}：GD 问席位 {gdSeat}，C# 此刻问的是 {seat}（{options.Count} 条选项，阶段 {s.Turn.Phase}）");
                alive = false;
                continue;
            }
            var view = AskView.Build(s, seat, options);
            var gdKeys = CanonKeys(row.GetProperty("opts"));
            var csKeys = view.Options.Select(o => o.Key).ToList();
            if (!gdKeys.SequenceEqual(csKeys))
            {
                var missing = gdKeys.Except(csKeys).Take(4);
                var extra = csKeys.Except(gdKeys).Take(4);
                report.Divergences.Add($"#{n} {kind}@{seat}：规范选项表不同 —— C# 缺 [{string.Join(" ", missing)}]，C# 多 [{string.Join(" ", extra)}]"
                    + (gdKeys.ToHashSet().SetEquals(csKeys) ? "（集合相同、次序不同）" : ""));
                alive = false;
                continue;
            }
            CheckData(report, n, row.GetProperty("opts"), view);

            var next = i + 1 < rows.Count ? rows[i + 1] : (JsonElement?)null;
            var subRow = next is { } nx && nx.GetProperty("kind").GetString() is "chemo_target" or "effector_target" ? nx : (JsonElement?)null;
            var seed = (ulong)long.Parse(row.GetProperty("seed").GetString()!);
            onAsk?.Invoke(n, s, seat, options, seed);
            report.Compared++;
            foreach (var tier in tiers)
            {
                var trace = tier == "normal" || kind != "action" ? null : new AiTrace();
                var clock = System.Diagnostics.Stopwatch.StartNew();
                var cs = cache[tier].Choose(s, seat, options, new SplitMix64Rng(seed), default, trace);
                report.Micros[tier].Add(clock.ElapsedTicks * 1_000_000 / System.Diagnostics.Stopwatch.Frequency);
                var gd = row.GetProperty("ans").GetProperty(tier).GetString()!;
                // GD 顶层这一问只答到「发动」；它若真走了这一档，第二问的答案在下一行 —— 并成完整组键比
                var gdFull = row.GetProperty("tier").GetString() == tier && subRow is { } sr ? Merge(gd, sr) : gd;
                var csCmp = gdFull == gd ? Collapse(cs) : cs;
                report.Total[tier]++;
                if (csCmp == gdFull) report.Agree[tier]++;
                else report.Mismatches.Add($"#{n} {kind}@{seat} {tier}：GD {gdFull} ／ C# {cs}");
                if (trace != null && row.TryGetProperty(tier + "_trace", out var gdTrace))
                {
                    var diff = TraceDiff(gdTrace, trace);
                    if (tier == "intent") { report.IntentTraced++; if (diff == null) report.IntentTraceEqual++; }
                    else { report.SearchTraced++; if (diff == null) report.SearchTraceEqual++; }
                    if (diff != null) report.Mismatches.Add($"#{n} {kind}@{seat} {tier} 读数：{diff}");
                }
            }

            if (stopAtFirst && report.Mismatches.Count > 0) break;

            // 按 GD 真走的那一手执行
            var taken = row.GetProperty("taken").GetString()!;
            if (subRow is { } sub) { taken = Merge(taken, sub); i++; }
            var decision = options.FirstOrDefault(d => SemanticKey.Of(s, d) == taken);
            if (decision == null) { report.Divergences.Add($"#{n} {kind}@{seat}：GD 走了 {taken}，C# 的选项表里没有"); alive = false; continue; }
            var result = Engine.ExecuteDecision(s, decision, rng);
            if (!result.Success) { report.Divergences.Add($"#{n} {kind}@{seat}：{taken} 执行失败 {result.ErrorMessage}"); alive = false; continue; }
            s = result.NewState;
        }
        return report;
    }

    /// <summary>GD 原序选项 → 规范序键（与 agree_rng.gd:canon_req / AskView 同一把尺：去重、停 / 放弃在前、其余按键）。</summary>
    private static List<string> CanonKeys(JsonElement opts)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var rows = new List<(int First, string Key)>();
        foreach (var o in opts.EnumerateArray())
        {
            var k = o.GetProperty("k").GetString()!;
            if (!seen.Add(k)) continue;
            var d = o.GetProperty("d");
            var first = Flag(d, "stop") || Flag(d, "skip") ? 0 : 1;
            rows.Add((first, k));
        }
        return rows.OrderBy(r => r.First).ThenBy(r => r.Key, StringComparer.Ordinal).Select(r => r.Key).ToList();
    }

    private static bool Flag(JsonElement d, string name) => d.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static string Collapse(string key)
    {
        if (key.StartsWith("k=action+chemo_target|", StringComparison.Ordinal)) return "k=action|act=chemo";
        if (key.StartsWith("k=action+effector_target|", StringComparison.Ordinal)) return "k=action|act=effector";
        return key;
    }

    private static string Merge(string top, JsonElement sub)
    {
        var subKind = sub.GetProperty("kind").GetString()!;
        var pick = sub.GetProperty("taken").GetString()!;
        var rest = pick[$"k={subKind}|".Length..];
        return top switch
        {
            "k=action|act=chemo" when subKind == "chemo_target" => "k=action+chemo_target|act=chemo|" + rest,
            "k=action|act=effector" when subKind == "effector_target" => "k=action+effector_target|act=effector|" + rest,
            _ => top,
        };
    }

    /// <summary>GD data（含 cost）逐字段对 C# 的 <see cref="AiOption"/>：策略读的就是这些字段，差一个就是两份不同的局面。</summary>
    private static void CheckData(Report report, int n, JsonElement opts, AskView view)
    {
        report.DataChecked++;
        var byKey = view.Options.ToDictionary(o => o.Key, StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var o in opts.EnumerateArray())
        {
            var k = o.GetProperty("k").GetString()!;
            if (!seen.Add(k) || !byKey.TryGetValue(k, out var cs)) continue;
            var d = o.GetProperty("d");
            foreach (var p in d.EnumerateObject())
            {
                var want = p.Value.ValueKind switch
                {
                    JsonValueKind.String => p.Value.GetString(),
                    JsonValueKind.True => "1",
                    JsonValueKind.False => "0",
                    _ => p.Value.GetRawText(),
                };
                var got = p.Name switch
                {
                    "act" => cs.Act, "card" => cs.Card, "type" => cs.Type?.ToString(),
                    "to" => cs.To is { } t ? $"{t.Q},{t.R}" : null, "cid" => cs.Cid?.ToString(), "dir" => cs.Dir?.ToString(),
                    "r" => cs.R?.ToString(), "pay" => cs.Pay?.ToString(), "get" => cs.Get?.ToString(),
                    "from" => cs.From?.ToString(), "to_cid" => cs.ToCid?.ToString(),
                    "stop" => cs.Stop ? "1" : "0", "skip" => cs.Skip ? "1" : "0",
                    "cost" => cs.Cost?.ToString(),
                    _ => "<不比>",
                };
                if (got == "<不比>") continue;   // anchor：引擎算出来的依托，键里就剔掉了（SemanticKey 规矩 1），策略不读
                if (got != want) report.DataDiffs.Add($"#{n} {k}.{p.Name}：GD {want} ／ C# {got ?? "（无）"}");
            }
        }
    }

    private static void CheckBoundary(Report report, int n, WorldState s, SplitMix64Rng rng, L0World gdSpec, ulong gdRng)
    {
        report.BoundaryChecked++;
        // GD 导世界时已经 advance() 到了这一问；C# 这边先推到同一处再比（中间的 E / S 阶段会掷骰）
        while (s.Turn.Phase != Phase.Finished && RolloutCursorProbe.NextAsked(s).Options.Count == 0)
            s = Engine.AdvancePhase(s, rng).NewState;
        if (rng.State != gdRng) report.BoundaryDiffs.Add($"#{n}：随机流状态 GD {gdRng} ／ C# {rng.State}（这一段两边掷骰的次数不同）");
        var cs = WorldLoader.Dump(s);
        var gd = WorldLoader.Dump(WorldLoader.Load(gdSpec));
        // 落子阶段 GD 的 dump 不写 seat（cw_world_loader.gd 只在 turn 阶段写）：装回来恒为 0，那一项不比
        if (cs.Phase == "Setup" && gd.Phase == "Setup") cs = cs with { Seat = gd.Seat };
        var diffs = L1.DeepDiff.Compare(gd, cs, "$", 6);
        if (diffs.Count > 0) report.BoundaryDiffs.Add($"#{n}：{string.Join("；", diffs)}");
    }

    private const double Eps = 1e-9;

    /// <summary>GD AGREE.trace（JSON）对 C# <see cref="AiTrace"/>；一致返回 null，否则返回第一处差异。</summary>
    private static string? TraceDiff(JsonElement gd, AiTrace cs)
    {
        static string P(IReadOnlyList<HexPosition> path) => string.Join(" ", path.Select(p => $"{p.Q},{p.R}"));
        static string GP(JsonElement path) => string.Join(" ", path.EnumerateArray().Select(x => x.GetString()));
        var cands = gd.TryGetProperty("cands", out var c) ? c.EnumerateArray().ToList() : [];
        if (cands.Count != cs.Cands.Count) return $"候选数 GD {cands.Count} ／ C# {cs.Cands.Count}";
        for (var i = 0; i < cands.Count; i++)
        {
            var (path, m, score) = cs.Cands[i];
            if (GP(cands[i].GetProperty("path")) != P(path)) return $"候选 {i} 路径 GD [{GP(cands[i].GetProperty("path"))}] ／ C# [{P(path)}]";
            var fields = m.Fields();
            foreach (var f in cands[i].GetProperty("m").EnumerateObject())
            {
                var want = f.Value.ValueKind switch { JsonValueKind.True => 1, JsonValueKind.False => 0, _ => f.Value.GetInt64() };
                if (!fields.TryGetValue(f.Name, out var got)) return $"候选 {i} 读数缺字段 {f.Name}";
                if (got != want) return $"候选 {i}[{P(path)}] 读数 {f.Name}：GD {want} ／ C# {got}";
            }
            if (Math.Abs(cands[i].GetProperty("score").GetDouble() - score) > Eps)
                return $"候选 {i}[{P(path)}] 分：GD {cands[i].GetProperty("score").GetDouble():R} ／ C# {score:R}";
        }
        var roots = gd.TryGetProperty("roots", out var r) ? r.EnumerateArray().ToList() : [];
        if (roots.Count != cs.Roots.Count) return $"根数 GD {roots.Count} ／ C# {cs.Roots.Count}";
        for (var i = 0; i < roots.Count; i++)
        {
            if (GP(roots[i].GetProperty("path")) != P(cs.Roots[i].Path)) return $"根 {i} 路径 GD [{GP(roots[i].GetProperty("path"))}] ／ C# [{P(cs.Roots[i].Path)}]";
            if (Math.Abs(roots[i].GetProperty("v").GetDouble() - cs.Roots[i].V) > Eps) return $"根 {i} 线值 GD {roots[i].GetProperty("v").GetDouble():R} ／ C# {cs.Roots[i].V:R}";
        }
        var nodes = gd.TryGetProperty("nodes", out var nd) ? nd.EnumerateArray().ToList() : [];
        if (nodes.Count != cs.Nodes.Count) return $"节点数 GD {nodes.Count} ／ C# {cs.Nodes.Count}";
        for (var i = 0; i < nodes.Count; i++)
        {
            if (nodes[i].GetProperty("pid").GetInt32() != cs.Nodes[i].Seat) return $"节点 {i} 席位不同";
            var subs = nodes[i].GetProperty("subs").EnumerateArray().ToList();
            if (subs.Count != cs.Nodes[i].Subs.Count) return $"节点 {i} 子候选数 GD {subs.Count} ／ C# {cs.Nodes[i].Subs.Count}";
            for (var j = 0; j < subs.Count; j++)
            {
                if (GP(subs[j].GetProperty("path")) != P(cs.Nodes[i].Subs[j].Path)) return $"节点 {i} 子 {j} 路径 GD [{GP(subs[j].GetProperty("path"))}] ／ C# [{P(cs.Nodes[i].Subs[j].Path)}]";
                if (Math.Abs(subs[j].GetProperty("q").GetDouble() - cs.Nodes[i].Subs[j].Q) > Eps) return $"节点 {i} 子 {j} 快评 GD {subs[j].GetProperty("q").GetDouble():R} ／ C# {cs.Nodes[i].Subs[j].Q:R}";
            }
        }
        var leaves = gd.TryGetProperty("leaves", out var lv) ? lv.EnumerateArray().Select(x => x.GetDouble()).ToList() : [];
        if (leaves.Count != cs.Leaves.Count) return $"叶数 GD {leaves.Count} ／ C# {cs.Leaves.Count}";
        for (var i = 0; i < leaves.Count; i++)
            if (Math.Abs(leaves[i] - cs.Leaves[i]) > Eps) return $"叶 {i}：GD {leaves[i]:R} ／ C# {cs.Leaves[i]:R}";
        if (gd.TryGetProperty("best", out var best) && cs.Best != null && GP(best) != P(cs.Best)) return $"最优根 GD [{GP(best)}] ／ C# [{P(cs.Best)}]";
        if (gd.TryGetProperty("plan0", out var plan0) && plan0.ValueKind == JsonValueKind.Object && plan0.TryGetProperty("act", out var act))
        {
            if (cs.Plan0 == null) return "计划第一手：C# 没有";
            if (act.GetString() != cs.Plan0.Act) return $"计划第一手 act：GD {act.GetString()} ／ C# {cs.Plan0.Act}";
            if (plan0.TryGetProperty("to", out var to) && cs.Plan0.To is { } t && to.GetString() != $"{t.Q},{t.R}") return $"计划第一手 to：GD {to.GetString()} ／ C# {t.Q},{t.R}";
        }
        return null;
    }
}

/// <summary>测试侧借用推演游标的「这一刻该谁作答」（与产品同一份）。</summary>
internal static class RolloutCursorProbe
{
    public static (int Seat, IReadOnlyList<IDecision> Options) NextAsked(WorldState s) => RolloutCursor.NextAsked(s);
}
