using System.Text.Json.Nodes;
using CellWar.Core;

namespace CellWar.Sidecar;

/// <summary>
/// 按语义键走子 + 条目流节拍检查。`--selftest` 用它打一小局；单测（SessionHostTests）用它打整局。
///
/// 挑选项与 L1 的 <c>KeyWalk</c> / GD `xcheck_bridge` 同一条 LCG（`lcg = lcg × 1103515245 + 12345 &amp; 0x7FFFFFFF`，键去重排序后取 `lcg % n`），
/// 与引擎的 rng 无关 —— 走法可复现、也不会因为改了选项生成次序整串错位。
/// </summary>
internal static class SelfTest
{
    public sealed record Walk(int Answers, bool GameOver, IReadOnlyList<string> Violations, IReadOnlyList<JsonObject> Entries, IReadOnlyList<string> Kinds);

    public static JsonObject Run()
    {
        var walk = Drive(new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 2222, ["observe_viewer"] = -2 }, maxAnswers: 60);
        return new JsonObject
        {
            ["ok"] = walk.Violations.Count == 0 && walk.Answers > 0,
            ["answers"] = walk.Answers,
            ["entries"] = walk.Entries.Count,
            ["violations"] = new JsonArray(walk.Violations.Take(5).Select(v => (JsonNode)v).ToArray()),
            ["rules_build"] = Dispatcher.Version()["rules_build"]!.DeepClone(),
        };
    }

    /// <summary>开一局，一直答到终局或 <paramref name="maxAnswers"/>；每答一次都把新条目过一遍节拍检查。</summary>
    public static Walk Drive(JsonObject cfg, int maxAnswers, ulong lcgSeed = 2222)
    {
        using var host = SessionHost.Open(1, cfg);
        var viewerSet = cfg["observe_viewer"] is not null;
        var all = new List<JsonObject>();
        var violations = new List<string>();
        var kinds = new List<string>();
        var lcg = lcgSeed & 0x7FFFFFFF;
        long since = 0;
        var answers = 0;
        var lastAnswered = 0;
        var over = false;

        while (true)
        {
            var batch = host.Pull(-2, since, int.MaxValue).Select(n => n!.AsObject()).ToList();
            foreach (var e in batch)
            {
                var seq = J.Long(e["seq"]);
                if (seq != since + 1) violations.Add($"seq 跳号：{since} → {seq}");
                since = seq;
                Check(e, all, viewerSet, lastAnswered, violations);
                all.Add(e);
            }
            var ask = all.LastOrDefault();
            if (ask is not null && J.Str(ask["t"]) == "game_over") { over = true; break; }
            if (answers >= maxAnswers || ask is null || J.Str(ask["t"]) != "ask") break;

            var req = ask["req"]!.AsObject();
            kinds.Add(J.Str(req["kind"]));
            var keys = req["options"]!.AsArray().Select(o => J.Str(o!["key"])).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
            lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
            var pick = keys[(int)(lcg % (ulong)keys.Length)];
            var askId = J.Int(ask["ask_id"]);
            if (!host.Answer(askId, pick, -1)) { violations.Add($"ask {askId} 答「{pick}」被拒"); break; }
            lastAnswered = askId;
            answers++;
        }
        if (over && J.Str(all[^1]["t"]) != "game_over") violations.Add("game_over 之后还有条目");
        return new(answers, over, violations, all, kinds);
    }

    /// <summary>InProc 的节拍：ask 之前紧挨着 step_end（+ sync）；step_begin 的 ask_id = 刚答的那问；不上线 C# 独有的 attack；选项键唯一、没有 Pass。</summary>
    private static void Check(JsonObject e, List<JsonObject> before, bool viewerSet, int lastAnswered, List<string> v)
    {
        var t = J.Str(e["t"]);
        var seq = J.Long(e["seq"]);
        string Prev(int back) => before.Count >= back ? J.Str(before[^back]["t"]) : "";
        switch (t)
        {
            case "attack":
                v.Add($"#{seq} 出现 C# 独有的 attack 条目");
                break;
            case "ask" or "game_over":
                if (viewerSet ? Prev(1) != "sync" || Prev(2) != "step_end" : Prev(1) != "step_end")
                    v.Add($"#{seq} {t} 之前不是 step_end{(viewerSet ? " + sync" : "")}（是 {Prev(2)} / {Prev(1)}）");
                if (t == "ask")
                {
                    var keys = e["req"]!["options"]!.AsArray().Select(o => J.Str(o!["key"])).ToArray();
                    if (keys.Length == 0) v.Add($"#{seq} ask 没有选项");
                    if (keys.Distinct().Count() != keys.Length) v.Add($"#{seq} ask 选项键重复");
                    if (keys.Contains(SemanticKey.PassKey)) v.Add($"#{seq} ask 里漏出了 C# 的 Pass");
                    if (keys.Any(k => k.Split('|')[0].Contains('+'))) v.Add($"#{seq} ask 里漏出了组键（没折叠）");
                }
                break;
            case "step_begin":
                if (J.Int(e["ask_id"]) != lastAnswered) v.Add($"#{seq} step_begin.ask_id = {e["ask_id"]}，刚答的是 {lastAnswered}");
                break;
        }
        if (J.Bool(e["barrier"]) != (t == "roll")) v.Add($"#{seq} {t} 的 barrier 标错了");
    }
}
