using System.IO.Compression;
using System.Text.Json;
using CellWar.Core.Observation;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// 口径二 · 批 0 步 10（Kevin 拍 E-6）：**跨生产者 envelope 对拍** —— 每条 L1 夹具的每一步，GD 生产者（`cw_obs_codec.gd`，
/// 由 `xcheck_export.gd env_out=` 顺带导出到 `game/tests/l1/env_*.jsonl.gz`）与 C# 生产者（`ObservationV1Codec`）各产一份
/// `viewer = -2` 的 envelope，剥掉 envelope 元数据后逐字段 diff，MISMATCH 即红。
///
/// 例外只有 docs/观测协议_v1.md §八 那张表（只许减不许加）：hand / equipped / fx_round 排序后比；`cancer_alarm.streak` 排除；
/// tier B 按 produced_tiers 跳过；`players[].name` 排除；文案（label / prompt / phase_text / win_reason）不比；
/// **日志 `logs` 逐行比原文**（换内核 P2，2026-10-01；GD 这边是 `logs_from = 0` 的全知 envelope，每步都是从开局起的整卷）；
/// options 按 key 配对、index 不比、C# 的 Pass 剔除、组键只比存在；`differentiated` 两侧升序。
///
/// C# 这边没有 Runtime（L1Replay 直接驱动 BasicRulesEngine），所以 SimulationState 在这里**照 Runtime 的规矩自己攒**：
/// 每条结算结果的演出事件（含日志原文）按序 `Emit`（出牌流水、演出序号、日志下标与合并都跟着走），规则事实不进日志（同 `RuleFlow.Publish`）；
/// 开局那一行（GD `setup.begin()` 的「初始癌组织：…」）发生在夹具的 `pre` 之前、C# 重放走不到 —— 拿装好的 `pre` 喂 `MatchSetup.LogInitialCancer` 铺进去，顺带钉住那句文案；
/// `Input` = 下一步 GD 问的那一席在 C# 这边的可选决策（GD 的 `_pending` 在 post 时刻已经是下一问）。
/// </summary>
public class EnvelopeParityTests
{
    /// <summary>每条夹具比到第几步（前三条录到 200 步 / 终局；第四条 `4p_chemo_4242` 是 `policy=chemo` 的树突建源局）。
    /// 2026-09-19 issue #55 / #56 重录后：2p 终局 172 步、树突局 343 步里前 282 步一致（见 L1ReplayTests.RatchetChemo）。</summary>
    [Theory]
    [InlineData("4p_4242", 200)]
    [InlineData("2p_2222", 200)]
    [InlineData("6p_6666", 200)]
    [InlineData("4p_chemo_4246", 279)]   // pick_cell + 借道起价合上（chemo-move-quote）后 L1 与 envelope 一致到 282 步（#283 是黏附标记的老分叉） `chemo-move-quote`（趋化源在场时的迁移报价 / cost_rows 与 GD 不同，盘面本身逐字一致）
    public void 每条夹具逐步_GD与CSharp的envelope逐字段相同(string fixture, int maxSteps)
    {
        var root = RepoRoot();
        var tracePath = Path.Combine(root, "game", "tests", "l1", $"trace_{fixture}.jsonl");
        var envPath = Path.Combine(root, "game", "tests", "l1", $"env_{fixture}.jsonl.gz");
        Assert.True(File.Exists(envPath), $"缺 GD 侧 envelope 夹具 {envPath}（用 xcheck_export.gd 加 env_out= 录，gzip 后放进仓库）");
        var envLines = ReadGz(envPath).Where(l => l.Length > 0).Select(l => JsonDocument.Parse(l).RootElement).ToList();
        var gd = envLines.ToDictionary(e => e.GetProperty("n").GetInt32(), e => e.GetProperty("env"));
        // 观测协议 §5.3 两条查询（P2，2026-10-01）：GD 导出在行动问答那一步顺带录了 {cid, effects, block}，C# 同一步现算比
        var gdQueries = envLines.Where(e => e.TryGetProperty("q", out _)).ToDictionary(e => e.GetProperty("n").GetInt32(), e => e.GetProperty("q"));
        var mismatches = new List<(int N, IReadOnlyList<string> Diffs)>();
        var sizes = new List<(int N, int Gd, int Cs, long Round)>();
        var compared = 0;
        var report = ReplayEnvelopes(tracePath, gd, maxSteps, (n, gdEnv, csJson, s) =>
        {
            sizes.Add((n, gdEnv.GetRawText().Length, csJson.Length, s.Turn.WorldRound));
            var a = EnvelopeNormalize.Normalize(L1View.Plain(gdEnv), gdSide: true);
            var b = EnvelopeNormalize.Normalize(L1View.Plain(JsonDocument.Parse(csJson).RootElement), gdSide: false);
            var diffs = DeepDiff.Compare(a, b, "$", 400).ToList();
            if (gdQueries.TryGetValue(n, out var gq))
                diffs.AddRange(DeepDiff.Compare(L1View.Plain(gq), L1View.Plain(CsQueries(s, gq.GetProperty("cid").GetInt32())), "$q", 400));
            compared++;
            if (diffs.Count > 0) mismatches.Add((n, diffs));
        });

        var lines = new List<string>
        {
            $"# envelope 对拍 {fixture}：L1 一致 {report.Agreed} 步；比了 {compared} 步的 envelope，{mismatches.Count} 步有差异",
            "# 体积（字节，未压缩）：步 / 回合 / GD / C#",
        };
        foreach (var x in sizes.Where(x => x.N == 1 || x.N % 50 == 0 || x.N == sizes.Count))
            lines.Add($"  {x.N,4} / R{x.Round,2} / {x.Gd,7} / {x.Cs,7}");
        // 差异模式汇总：路径里的下标抹成 [*]，按出现次数排 —— 一眼看出是哪几类字段在漂
        var patterns = mismatches.SelectMany(m => m.Diffs).Select(d => System.Text.RegularExpressions.Regex.Replace(d.Split('：')[0], @"\[\d+\]", "[*]"))
            .GroupBy(x => x).OrderByDescending(g => g.Count()).Select(g => $"  {g.Count(),6} × {g.Key}").ToList();
        lines.Add($"# 差异模式（{patterns.Count} 种）");
        lines.AddRange(patterns.Take(40));
        foreach (var (n, diffs) in mismatches.Take(10))
        {
            lines.Add($"## 第 {n} 步");
            lines.AddRange(diffs.Select(d => "  " + d));
        }
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, $"envelope_parity_{fixture}.txt"), lines);

        Assert.True(report.FirstDivergence is null || report.FirstDivergence.Code == "PASS", "L1 本身先要一致：" + report.FirstDivergence?.Detail);
        Assert.True(compared > 0, "一步都没比到：GD 侧 env 夹具的步号与轨迹对不上");
        Assert.True(mismatches.Count == 0, mismatches.Count == 0 ? "" :
            $"{mismatches.Count} 步的 envelope 不一致（首个第 {mismatches[0].N} 步）：" + Environment.NewLine
            + string.Join(Environment.NewLine, mismatches[0].Diffs.Take(12)) + Environment.NewLine + "（全文见 envelope_parity_*.txt）");
    }

    /// <summary>与 GD `xcheck_export.gd queries()` 同形：这只细胞的行动栏每个按钮的 cost_effects_for + 两环内非空的 move_block_reason（键 "q,r"）。</summary>
    private static JsonElement CsQueries(WorldState s, int cid)
    {
        var cell = s.Cells[new EntityId((ulong)(cid + 1))];
        var effects = TierB.ActionKinds(s, cell).ToDictionary(act => act, act => (object)Queries.CostEffectsFor(s, cell, act), StringComparer.Ordinal);
        var block = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var to in s.Board.Tissues.Keys)
        {
            if (to == cell.Position || to.DistanceTo(cell.Position) > 2) continue;
            var why = Queries.MoveBlockReason(s, cell, to);
            if (why != "") block[$"{to.Q},{to.R}"] = why;
        }
        return JsonSerializer.SerializeToElement(new Dictionary<string, object> { ["cid"] = cid, ["effects"] = effects, ["block"] = block }, ObservationV1Codec.Json);
    }

    /// <summary>
    /// 一条轨迹教师强制重放，每一步（GD 侧有 envelope 的那几步）交出 (n, GD envelope, C# envelope JSON, C# 状态)。
    /// C# 的 SimulationState 照 Runtime 的规矩自己攒（见类注释）；对拍正式夹具与 <see cref="批扫目录里的每条轨迹_日志逐行对拍"/> 共用这一份。
    /// </summary>
    internal static ReplayReport ReplayEnvelopes(string tracePath, IReadOnlyDictionary<int, JsonElement> gd, int maxSteps, Action<int, JsonElement, string, WorldState> onPair)
    {
        var steps = File.ReadLines(tracePath).Where(l => l.Length > 0).Select(l => JsonDocument.Parse(l).RootElement)
            .Where(l => l.GetProperty("t").GetString() == "step").ToList();
        var engine = new BasicRulesEngine();
        // 第 n 步之后谁被问：轨迹里第 n+1 步的第一问（steps 是 0 基列表，steps[n] 就是第 n+1 步）；
        // 轨迹截断在第 200 步时没有「下一问」，就按 C# 自己的规矩找能动的那一席（GD 的 _pending 这时照样挂着）
        int? NextPid(int n, WorldState s) => n < steps.Count ? steps[n].GetProperty("asks")[0].GetProperty("pid").GetInt32()
            : s.Players.Keys.OrderBy(x => x).Where(seat => engine.GetAvailableDecisions(s, seat).Count > 0).Select(seat => (int?)seat).FirstOrDefault();

        var header = JsonDocument.Parse(File.ReadLines(tracePath).First(l => l.Length > 0)).RootElement;
        var sim = new SimulationState();
        using (var boot = Stage.Open())
        {
            MatchSetup.LogInitialCancer(L1View.Load(header.GetProperty("pre"), steps[0].GetProperty("asks")[0].GetProperty("pid").GetInt32()));
            foreach (var ev in boot.Drain()) sim = sim.Emit(ev);
        }
        return L1Replay.Run(tracePath, maxSteps,
            onResult: r =>
            {
                foreach (var ev in r.Events)
                    if (ev is IPresentationEvent p) sim = sim.Emit(p);
            },
            inspect: (n, s) =>
            {
                if (!gd.TryGetValue(n, out var gdEnv)) return;
                PendingInput? input = null;
                if (NextPid(n, s) is { } pid && s.Turn.Phase != Phase.Finished)
                {
                    var options = engine.GetAvailableDecisions(s, pid);
                    if (options.Count > 0) input = new PendingInput(n, pid, [.. options]);
                }
                var image = new WorldImage(s) { Simulation = sim with { Input = input } };
                onPair(n, gdEnv, ObservationV1Codec.Serialize(ObservationV1Codec.Encode(image, new Revision(n))), s);
            });
    }

    /// <summary>
    /// 换内核 P2 的发现器（同 <see cref="L1ScanTests"/> 的口径：不进日常套件、不断言）：目录 `CWX_ENV_SCAN_DIR` 里每条 `X.jsonl` 轨迹配同名的 `X.env.jsonl`
    /// （`xcheck_export.gd … out=X.jsonl env_out=X.env.jsonl` 一次录出），逐步只比 `logs`，比到 L1 第一处分叉之前为止，汇总写 `env_log_scan_summary.txt`。
    /// 四条正式夹具只走到 77 种日志句式；这里拿随手录的几十局去撞剩下那些（攻击链、卡牌、死亡…）。轨迹不进 git。
    /// </summary>
    [Fact]
    public void 批扫目录里的每条轨迹_日志逐行对拍()
    {
        var dir = Environment.GetEnvironmentVariable("CWX_ENV_SCAN_DIR");
        if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;
        var rows = new List<string>();
        foreach (var trace in Directory.GetFiles(dir, "*.jsonl").Where(f => !f.EndsWith(".env.jsonl", StringComparison.Ordinal)).OrderBy(f => f, StringComparer.Ordinal))
        {
            var envPath = trace[..^".jsonl".Length] + ".env.jsonl";
            if (!File.Exists(envPath)) continue;
            try
            {
                var gd = File.ReadLines(envPath).Where(l => l.Length > 0).Select(l => JsonDocument.Parse(l).RootElement)
                    .ToDictionary(e => e.GetProperty("n").GetInt32(), e => e.GetProperty("env"));
                var first = new List<(int N, IReadOnlyList<string> Diffs)>();
                var compared = 0;
                var report = ReplayEnvelopes(trace, gd, int.MaxValue, (n, gdEnv, csJson, _) =>
                {
                    var a = L1View.Plain(gdEnv.GetProperty("logs"));
                    var b = L1View.Plain(JsonDocument.Parse(csJson).RootElement.GetProperty("logs"));
                    compared++;
                    var diffs = DeepDiff.Compare(a, b, "$", 6);
                    if (diffs.Count > 0) first.Add((n, diffs));
                });
                // 分叉那一步起盘面已经不是同一个世界，日志差异都是它的回声 —— 只认分叉之前的
                var stop = report.FirstDivergence?.N ?? int.MaxValue;
                var real = first.Where(m => m.N < stop).ToList();
                rows.Add($"{Path.GetFileName(trace),-28} L1 一致 {report.Agreed,4} 步｜比了 {compared,4} 步｜日志差异 {real.Count,4} 步"
                    + (real.Count > 0 ? $"｜首个第 {real[0].N} 步：{string.Join(" / ", real[0].Diffs)}" : ""));
            }
            catch (Exception e)
            {
                rows.Add($"{Path.GetFileName(trace),-28} EXCEPTION {e.GetType().Name}: {e.Message.Split('\n')[0]}");
            }
        }
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "env_log_scan_summary.txt"), rows);
    }

    private static IEnumerable<string> ReadGz(string path)
    {
        using var file = File.OpenRead(path);
        using var gz = new GZipStream(file, CompressionMode.Decompress);
        using var reader = new StreamReader(gz);
        while (reader.ReadLine() is { } line) yield return line;
    }

    private static string RepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !(Directory.Exists(Path.Combine(d, "game")) && Directory.Exists(Path.Combine(d, "core"))))
            d = Path.GetDirectoryName(d);
        return d ?? throw new InvalidOperationException("找不到仓库根");
    }
}
