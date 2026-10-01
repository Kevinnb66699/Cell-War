using System.Text.Json.Nodes;
using CellWar.Ai;
using CellWar.Sidecar;

namespace CellWar.Core.Tests.Sidecar;

/// <summary>
/// 换内核 P6（服务器那半）：sidecar 会话中途换作答方（`set_ai`）与 AI 交答案的节拍交给消费者（`ai_paced` + `ai_step`）。
///   · paced：AI 想好了也不交，等 ai_step —— 服务器在 step_end 那一拍现取每人的 envelope，靠的就是「两次推之间会话不动」
///   · set_ai 接管：真人正被问着的那一问改由 AI 答，AI 的 step_begin 带原来那一问的号（客户端 #44 收界面、服务器换号都认它）
///   · once：只代答一问（计时到点），下一问照旧问人
///   · 交还：AI 想到一半 / 想好了还没交，都作废，这一问改问人
/// 都按服务器的用法开：消费者模式（不设 observe_viewer）、全知拉条目。
/// </summary>
public class SidecarSeatControlTests
{
    private static JsonObject Cfg(int players, int seed, JsonObject? ai = null, bool paced = true, int delayMs = 0)
    {
        var cfg = new JsonObject
        {
            ["factions"] = new JsonArray(Enumerable.Range(0, players).Select(i => (JsonNode)(i % 2)).ToArray()),
            ["seed"] = seed, ["ai_paced"] = paced,
        };
        if (ai is not null) cfg["ai"] = ai;
        if (delayMs > 0) cfg["ai_delay_ms"] = delayMs;
        return cfg;
    }

    private static List<JsonObject> Entries(SessionHost host, long since = 0)
        => host.Pull(-2, since, int.MaxValue).Select(n => n!.AsObject()).ToList();

    /// <summary>流里最后一条若是 ask 就返回它（消费者模式下 ask 是一步的最后一条）。</summary>
    private static JsonObject? OpenAsk(SessionHost host)
        => Entries(host).LastOrDefault() is { } last && J.Str(last["t"]) == "ask" ? last : null;

    /// <summary>与 SelfTest.Drive 同一条 LCG 挑键作答。</summary>
    private static void AnswerLcg(SessionHost host, JsonObject ask, ref ulong lcg)
    {
        var keys = ask["req"]!["options"]!.AsArray().Select(o => J.Str(o!["key"])).Distinct().Order(StringComparer.Ordinal).ToArray();
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        Assert.True(host.Answer(J.Int(ask["ask_id"]), keys[(int)(lcg % (ulong)keys.Length)], -1));
    }

    /// <summary>反复 ai_step 直到交出去一次（AI 还在想就等一毫秒再推）。</summary>
    private static void StepUntilApplied(SessionHost host, int timeoutMs = 30_000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!host.StepAi())
        {
            Assert.True(DateTime.UtcNow < deadline, "AI 一直没想好");
            Thread.Sleep(1);
        }
    }

    [Theory]
    [InlineData(4, 4242, "{\"1\":\"normal\",\"3\":\"intent\"}")]
    [InlineData(2, 2222, "{\"0\":\"intent\"}")]
    public void paced_消费者推AI_整局打完且节拍零违例(int players, int seed, string ai)
    {
        var cfg = Cfg(players, seed, JsonNode.Parse(ai)!.AsObject());
        cfg["observe_viewer"] = -2;   // 节拍检查要看 sync
        var walk = SelfTest.Drive(cfg, maxAnswers: 6000, lcgSeed: (ulong)seed);
        Assert.True(walk.GameOver, $"{walk.Answers} 次人类作答后还没终局：{string.Join(" / ", walk.Violations.Take(3))}");
        Assert.Empty(walk.Violations);
    }

    [Fact]
    public void paced_AI想好了也不交_两次ai_step之间会话一动不动()
    {
        using var host = SessionHost.Open(1, Cfg(2, 7, new JsonObject { ["0"] = "normal" }));
        var seq = host.LastSeq;
        var rev = host.Peek().Revision;
        Thread.Sleep(300);   // 普通档一问不到一毫秒：这会儿早想好了
        Assert.Equal(seq, host.LastSeq);
        Assert.Equal(rev, host.Peek().Revision);
        Assert.DoesNotContain(Entries(host), e => J.Str(e["t"]) == "step_begin");

        Assert.True(host.StepAi());
        var after = Entries(host, seq);
        Assert.Equal("step_begin", J.Str(after[0]["t"]));
        Assert.Equal(0, J.Int(after[0]["seat"]));
        Assert.NotEqual(rev, host.Peek().Revision);
    }

    [Fact]
    public void set_ai接管真人那一问_AI的step_begin带原来的号_之后不再问他()
    {
        using var host = SessionHost.Open(1, Cfg(2, 2222));
        var ask = OpenAsk(host)!;
        Assert.Equal(0, J.Int(ask["req"]!["pid"]));   // 第一问是席位 0 落子
        var id = J.Int(ask["ask_id"]);
        var since = host.LastSeq;

        Assert.Equal(id, host.SetAi(0, AiTier.Normal, once: false));
        Assert.False(host.Answer(id, null, 0));   // 收回了：真人那头的答案不再收
        StepUntilApplied(host);
        var begin = Entries(host, since).First(e => J.Str(e["t"]) == "step_begin");
        Assert.Equal(id, J.Int(begin["ask_id"]));
        Assert.Equal(0, J.Int(begin["seat"]));

        // 之后席位 0 一直归 AI：只答席位 1 的问，再走一段也见不到问席位 0 的 ask
        var lcg = 2222UL & 0x7FFFFFFF;
        for (var i = 0; i < 40 && !host.Over; i++)
        {
            if (OpenAsk(host) is { } a) AnswerLcg(host, a, ref lcg);
            else StepUntilApplied(host);
        }
        Assert.DoesNotContain(Entries(host, since), e => J.Str(e["t"]) == "ask" && J.Int(e["req"]!["pid"]) == 0);
    }

    [Fact]
    public void once只代答一问_下一问照旧问人()
    {
        using var host = SessionHost.Open(1, Cfg(2, 2222));
        var id = J.Int(OpenAsk(host)!["ask_id"]);
        var since = host.LastSeq;
        Assert.Equal(id, host.SetAi(0, AiTier.Normal, once: true));
        StepUntilApplied(host);

        var lcg = 2222UL & 0x7FFFFFFF;
        for (var i = 0; i < 40 && !host.Over; i++)
        {
            var a = OpenAsk(host);
            Assert.NotNull(a);   // 席位 0 交还真人了：每一步都停在问人上，没有 AI 要推
            if (J.Int(a!["req"]!["pid"]) == 0) break;
            AnswerLcg(host, a, ref lcg);
        }
        var back = OpenAsk(host)!;
        Assert.Equal(0, J.Int(back["req"]!["pid"]));
        Assert.True(J.Int(back["ask_id"]) > id);
        Assert.Single(Entries(host, since), e => J.Str(e["t"]) == "step_begin" && J.Int(e["seat"]) == 0 && J.Int(e["ask_id"]) == id);
    }

    [Fact]
    public void 交还真人_AI想到一半作废_这一问改问人()
    {
        // 不 paced、AI 先等 2 秒再想：交还时它一定还「在想」
        using var host = SessionHost.Open(1, Cfg(2, 9, new JsonObject { ["0"] = "normal" }, paced: false, delayMs: 2000));
        Assert.Null(OpenAsk(host));
        Assert.Equal(-1, host.SetAi(0, null, once: false));
        var ask = OpenAsk(host);
        Assert.NotNull(ask);
        Assert.Equal(0, J.Int(ask!["req"]!["pid"]));
        var seq = host.LastSeq;
        Thread.Sleep(2300);   // 那一次的延时早过了：它要是没被掐掉，这会儿已经把答案交了
        Assert.Equal(seq, host.LastSeq);
        var key = J.Str(ask["req"]!["options"]![0]!["key"]);
        Assert.True(host.Answer(J.Int(ask["ask_id"]), key, -1));   // 这一问照常归人答
    }

    [Fact]
    public void paced下想好了还没交就交还_那个答案作废()
    {
        using var host = SessionHost.Open(1, Cfg(2, 9, new JsonObject { ["0"] = "normal" }));
        Thread.Sleep(200);   // 想好了，等 ai_step
        Assert.Equal(-1, host.SetAi(0, null, once: false));
        Assert.False(host.StepAi());
        var ask = OpenAsk(host);
        Assert.NotNull(ask);
        Assert.Equal(0, J.Int(ask!["req"]!["pid"]));
        Assert.DoesNotContain(Entries(host), e => J.Str(e["t"]) == "step_begin");
    }

    [Fact]
    public void set_ai席位不存在或档名写错_当场拒()
    {
        using var host = SessionHost.Open(1, Cfg(2, 1));
        Assert.Throws<ArgumentException>(() => host.SetAi(9, AiTier.Normal, once: false));
        using var d = new Dispatcher();
        var sid = J.Int(d.Handle(new JsonObject { ["id"] = 1, ["op"] = "open", ["cfg"] = Cfg(2, 1) })["sid"]);
        var bad = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "set_ai", ["sid"] = sid, ["seat"] = 1, ["tier"] = "mcts" });
        Assert.False(J.Bool(bad["ok"]));
    }

    [Fact]
    public void 报文_set_ai与ai_step往返_交还时tier给null()
    {
        using var d = new Dispatcher();
        var sid = J.Int(d.Handle(new JsonObject { ["id"] = 1, ["op"] = "open", ["cfg"] = Cfg(2, 2222) })["sid"]);
        var pulled = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "pull", ["sid"] = sid, ["viewer"] = -2, ["since"] = 0 });
        var ask = pulled["entries"]!.AsArray().Select(n => n!.AsObject()).Last();
        var since = J.Long(pulled["last_seq"]);
        var set = d.Handle(new JsonObject { ["id"] = 3, ["op"] = "set_ai", ["sid"] = sid, ["seat"] = 0, ["tier"] = "normal" });
        Assert.True(J.Bool(set["ok"]));
        Assert.Equal(J.Int(ask["ask_id"]), J.Int(set["withdrawn"]));
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!J.Bool(d.Handle(new JsonObject { ["id"] = 4, ["op"] = "ai_step", ["sid"] = sid })["stepped"]))
        {
            Assert.True(DateTime.UtcNow < deadline);
            Thread.Sleep(1);
        }
        var after = d.Handle(new JsonObject { ["id"] = 5, ["op"] = "pull", ["sid"] = sid, ["viewer"] = -2, ["since"] = since });
        Assert.Contains(after["entries"]!.AsArray(), e => J.Str(e!["t"]) == "step_begin" && J.Int(e["ask_id"]) == J.Int(ask["ask_id"]));
        var back = d.Handle(new JsonObject { ["id"] = 6, ["op"] = "set_ai", ["sid"] = sid, ["seat"] = 0, ["tier"] = null });
        Assert.True(J.Bool(back["ok"]));
        Assert.Equal(-1, J.Int(back["withdrawn"]));
    }
}
