using System.Text.Json.Nodes;
using CellWar.Sidecar;

namespace CellWar.Core.Tests.Sidecar;

/// <summary>
/// 换内核 P3：sidecar 里的 AI 席（docs/内核替换_重启计划.md §3.1「AI 在 sidecar 里」）。
/// `open` 的 `ai: {"席位": 档名}` 那几席由宿主后台线程作答、不过网；节拍照 GD InProc 有 decider 的席位 ——
/// 不出 ask 条目，问之前 step_end → sync、答下之后 step_begin（ask id 单调），组键补两问的那一段。
/// 单独一个类：整局 AI 对局最慢（搜索档 Debug 下一问一两百毫秒），与 SidecarHostTests 并行跑。
/// </summary>
public class SidecarAiSeatTests
{
    [Theory]
    [InlineData(2, 2222, "{\"1\":\"intent\"}")]
    [InlineData(4, 4242, "{\"0\":\"intent\",\"1\":\"normal\",\"3\":\"search\"}")]
    public void AI席后台作答_打到终局且节拍零违例(int players, int seed, string ai)
    {
        var factions = new JsonArray(Enumerable.Range(0, players).Select(i => (JsonNode)(i % 2)).ToArray());
        var cfg = new JsonObject { ["factions"] = factions, ["seed"] = seed, ["observe_viewer"] = -2, ["ai"] = JsonNode.Parse(ai) };
        var walk = SelfTest.Drive(cfg, maxAnswers: 6000, lcgSeed: (ulong)seed);

        Assert.True(walk.GameOver, $"{players} 人局 {walk.Answers} 次人类作答后还没终局：{string.Join(" / ", walk.Violations.Take(3))}");
        Assert.Empty(walk.Violations);
        var aiSeats = JsonNode.Parse(ai)!.AsObject().Select(kv => int.Parse(kv.Key)).ToHashSet();
        var begun = walk.Entries.Where(e => J.Str(e["t"]) == "step_begin").Select(e => J.Int(e["seat"])).ToList();
        Assert.All(aiSeats, s => Assert.Contains(s, begun));   // 每个 AI 席都真出过手
        Assert.DoesNotContain(walk.Entries, e => J.Str(e["t"]) == "ask" && aiSeats.Contains(J.Int(e["req"]!["pid"])));
    }

    [Fact]
    public void 全AI席_没人作答也自己打到终局_同种子两遍同一局()
    {
        static (bool Over, string Last) Play()
        {
            var cfg = new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 77, ["ai"] = new JsonObject { ["0"] = "normal", ["1"] = "intent" } };
            using var host = SessionHost.Open(1, cfg);
            var deadline = DateTime.UtcNow.AddSeconds(60);
            while (!host.Over && DateTime.UtcNow < deadline) Thread.Sleep(2);
            var last = host.Pull(-2, 0, int.MaxValue).Select(n => n!.AsObject()).Last();
            return (host.Over, last.ToJsonString());
        }
        var a = Play();
        var b = Play();
        Assert.True(a.Over, "两席 AI 60 秒内没打完");
        Assert.Equal(a.Last, b.Last);   // 推演种子由会话种子 + 修订号派生：同种子同一局
    }

    [Fact]
    public void AI席想的时候abort_它收手不再交答案()
    {
        var cfg = new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 5, ["ai"] = new JsonObject { ["0"] = "search", ["1"] = "search" }, ["ai_delay_ms"] = 200 };
        using var host = SessionHost.Open(1, cfg);
        Thread.Sleep(50);
        host.Abort();
        var seq = host.LastSeq;
        Thread.Sleep(400);
        Assert.Equal(seq, host.LastSeq);   // abort 之后一条条目都不再长
        Assert.False(host.Over);
    }

    /// <summary>换内核 P4：单机对 AI 的存档 → 读档。检查点不记 AI 配置，读档时再给一遍 `ai`；读回来之后 AI 席照样自己作答、不出 ask。</summary>
    [Fact]
    public void 读档时再给ai_AI席照样自己作答()
    {
        var ai = new JsonObject { ["1"] = "normal" };
        using var host = SessionHost.Open(1, new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 31, ["observe_viewer"] = -2, ["ai"] = ai.DeepClone() });
        // 真人那一席（0）答几问：每次都等到它被问（AI 在后台线程想）
        var lcg = 31UL;
        void AnswerHuman(SessionHost h, int times)
        {
            for (var i = 0; i < times && !h.Over; i++)
            {
                var deadline = DateTime.UtcNow.AddSeconds(20);
                JsonObject? ask = null;
                while (ask is null && !h.Over && DateTime.UtcNow < deadline)
                {
                    // 先判「停在真人的顶层问答上」再拉条目：那一问的 ask 条目与它同一把锁里推出来，判到了就一定拉得到
                    //（反过来先拉再判，AI 线程可能夹在中间交了答案、新的一问出来了，拿到的却是上一问）
                    if (h.CanSave) ask = h.Pull(-2, 0, int.MaxValue).Select(n => n!.AsObject()).LastOrDefault(e => J.Str(e["t"]) == "ask");
                    if (ask is null) Thread.Sleep(2);
                }
                Assert.NotNull(ask);
                Assert.Equal(0, J.Int(ask!["req"]!["pid"]));   // 只有真人席出 ask
                var keys = ask["req"]!["options"]!.AsArray().Select(o => J.Str(o!["key"])).Distinct().Order(StringComparer.Ordinal).ToArray();
                lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
                Assert.True(h.Answer(J.Int(ask["ask_id"]), keys[(int)(lcg % (ulong)keys.Length)], -1));
            }
        }
        AnswerHuman(host, 30);
        var deadline2 = DateTime.UtcNow.AddSeconds(20);
        while (!host.CanSave && DateTime.UtcNow < deadline2) Thread.Sleep(2);
        var json = host.Save()!;
        var round = J.Int(host.Envelope(-2)["state"]!["g"]!["round_no"]);

        using var back = SessionHost.Restore(2, new JsonObject { ["checkpoint"] = json, ["observe_viewer"] = -2, ["ai"] = ai.DeepClone(), ["seed"] = 31 });
        AnswerHuman(back, 40);
        var after = back.Pull(-2, 0, int.MaxValue).Select(n => n!.AsObject()).ToArray();
        Assert.Contains(after, e => J.Str(e["t"]) == "step_begin" && J.Int(e["seat"]) == 1);   // 读回来之后 AI 席真的出过手
        Assert.DoesNotContain(after, e => J.Str(e["t"]) == "ask" && J.Int(e["req"]!["pid"]) == 1);
        Assert.True(back.Over || J.Int(back.Envelope(-2)["state"]!["g"]!["round_no"]) > round, "读档之后对局往前走了");
    }

    [Fact]
    public void open里AI档名写错当场拒()
        => Assert.Throws<ArgumentException>(() => SessionHost.Open(1, new JsonObject { ["factions"] = new JsonArray(0, 1), ["ai"] = new JsonObject { ["1"] = "mcts" } }));
}
