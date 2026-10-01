using System.Text.Json.Nodes;
using CellWar.Core.Observation;
using CellWar.Sidecar;

namespace CellWar.Core.Tests;

/// <summary>
/// 换内核 P2 · 日志原文的底座（docs/内核替换_重启计划.md §四 P2）。行文本本身由 L1 四条夹具逐行对拍（EnvelopeParityTests 不再剥 `logs`），
/// 这里钉通道的五条性质：
/// ① 秘密行（抽到的牌名）按观看者换公开替身 —— envelope 照 GD `_logs` / `CWNet.logs_for`（观众全见看原文），条目流照 InProc `_crop`（不看 open_hands）；
/// ② `log_run` 合并 = 同一个下标再发一次，中间插进别的行就断；
/// ③ 下标是绝对的：过了 128 行（原 Outbox 的上限）、过了演出队列的 256 条上限都不漂；
/// ④ 推演（Fork）静音：原文不留、游标照走，主线不受影响；
/// ⑤ 终局那一行排在 step_end / sync / game_over 之前（同 InProc `_run`）；
/// ⑥ 为了行序补的三个挂起字段（产出游标 / 推迟的复活通报 / 连续吞噬连了几格）随存档往返。
/// </summary>
public class LogTests
{
    private sealed class Handler(string type, Action<IEventContext> action) : IRuleHandler
    {
        public string EventType => type;
        public void Handle(IEventContext context) => action(context);
    }

    private static Runtime Create(params IRuleHandler[] handlers)
    {
        var store = new InMemoryStateStore();
        return new(store, store.Allocate(new(DemoScenario.Create())), handlers, new Xoshiro256StarStar(123));
    }

    private static LogLine Line(string text, int secret = -1, string? pub = null) => new(1, Phase.PlayerAction, text, secret, pub);
    private static LogRun Run(string key, string item) => new(1, Phase.PlayerAction, key, item, "　【定殖】", " 转为癌组织");

    // ---- ① 秘密行 ----

    /// <summary>纯观测层：一行席位 1 的秘密行 + 两行公开行，五种观看者各看到什么（GD `cw_obs_codec.gd:_logs` → `CWNet.logs_for(open)`）。</summary>
    [Fact]
    public void 秘密行_envelope里主人与全知看原文_别人与普通观众看替身_观众全见看原文()
    {
        var sim = new SimulationState()
            .Emit(Line("公开 A"))
            .Emit(Line("　癌症A(恶性黑色素瘤) 经由「基因表达」抽到【即时】PD-L1表达（手牌 1）", 1, "　癌症A(恶性黑色素瘤) 经由「基因表达」抽到 1 张卡（手牌 1）"))
            .Emit(Line("公开 B"));
        var full = ObservationV1Codec.Encode(new WorldImage(DemoScenario.Create()) { Simulation = sim }, new Revision(1));
        string[] Lines(int viewer, bool openHands = false) => SeatFilter.Crop(full, viewer, openHands).Logs.Lines;

        var secret = "　癌症A(恶性黑色素瘤) 经由「基因表达」抽到【即时】PD-L1表达（手牌 1）";
        var cover = "　癌症A(恶性黑色素瘤) 经由「基因表达」抽到 1 张卡（手牌 1）";
        Assert.Equal(["公开 A", secret, "公开 B"], Lines(ObservationV1Codec.ViewerOmniscient));
        Assert.Equal(["公开 A", secret, "公开 B"], Lines(1));                                   // 主人
        Assert.Equal(["公开 A", cover, "公开 B"], Lines(0));                                    // 别的席位
        Assert.Equal(["公开 A", cover, "公开 B"], Lines(ObservationV1Codec.ViewerWatcher));     // 普通观众
        Assert.Equal(["公开 A", secret, "公开 B"], Lines(ObservationV1Codec.ViewerWatcher, openHands: true));   // 观众全见：手牌都看得见了，日志也给原文
        // 秘密信息只活在进程里：序列化出去的 envelope 没有它，也装得回来
        var json = ObservationV1Codec.Serialize(SeatFilter.Crop(full, 0));
        Assert.DoesNotContain("PD-L1", json);
        Assert.Null(ObservationV1Codec.Deserialize(json).Logs.Secret);
    }

    /// <summary>真打：Demo 局一直【基因表达】直到抽到一张进手的牌（GD cw_cards.gd:57，全仓唯一的秘密行）—— envelope、旧版 Observe、PullPresentation 三条口一个口径。</summary>
    [Fact]
    public void 秘密行_真抽到进手的牌_三条读口都按席位换替身()
    {
        using var session = new MatchSession(DemoScenario.Create(), 7);
        LogEntry? drawn = null;
        for (var i = 0; i < 40 && drawn is null; i++)
        {
            var ask = session.ObserveV1(ObservationV1Codec.ViewerOmniscient).Ask!;
            var key = ask.Options.Any(o => o.Key == "k=action|act=draw") ? "k=action|act=draw"
                : ask.Options.Any(o => o.Key == "k=action|act=end") ? "k=action|act=end" : ask.Options[0].Key;
            Assert.True(session.SubmitByKey(ask.Seat, ask.AskId, key, -1).IsValid);
            drawn = PulledLogs(session).FirstOrDefault(l => l.SecretSeat >= 0);
        }
        Assert.NotNull(drawn);
        var owner = drawn.SecretSeat;
        var other = owner == 0 ? 1 : 0;
        Assert.Contains("经由「基因表达」抽到【", drawn.Text);
        Assert.Contains("经由「基因表达」抽到 1 张卡（手牌", drawn.PublicText);

        string LineFor(int viewer, bool openHands = false) => session.ObserveV1(viewer, openHands).Logs.Lines[drawn.Index];
        Assert.Equal(drawn.Text, LineFor(owner));
        Assert.Equal(drawn.PublicText, LineFor(other));
        Assert.Equal(drawn.PublicText, LineFor(ObservationV1Codec.ViewerWatcher));
        Assert.Equal(drawn.Text, LineFor(ObservationV1Codec.ViewerWatcher, openHands: true));
        Assert.Equal(drawn.Text, LineFor(ObservationV1Codec.ViewerOmniscient));
        Assert.Equal(drawn.Text, session.Observe(owner).Messages.Single(m => m.Cursor == drawn.Index).Text);
        Assert.Equal(drawn.PublicText, session.Observe(other).Messages.Single(m => m.Cursor == drawn.Index).Text);

        string PulledFor(int viewer) => session.PullPresentation(viewer, 0, int.MaxValue).Entries
            .Single(e => e["t"].GetString() == "log" && e["index"].GetInt64() == drawn.Index)["text"].GetString()!;
        Assert.Equal(drawn.Text, PulledFor(owner));
        Assert.Equal(drawn.PublicText, PulledFor(other));
        Assert.Equal(drawn.Text, PulledFor(ObservationV1Codec.ViewerOmniscient));
    }

    /// <summary>会话不对外露 SimulationState：从全知的条目流还原每一行（同一下标取最后一次，即合并后的那份）—— 宿主读的就是这一份。</summary>
    private static IReadOnlyList<LogEntry> PulledLogs(MatchSession session)
    {
        var byIndex = new SortedDictionary<long, LogEntry>();
        foreach (var e in session.PullPresentation(ObservationV1Codec.ViewerOmniscient, 0, int.MaxValue).Entries.Where(e => e["t"].GetString() == "log"))
            byIndex[e["index"].GetInt64()] = new LogEntry(e["index"].GetInt64(), e["text"].GetString()!, e["secret_pid"].GetInt32(), e["public_text"].GetString()!);
        return byIndex.Values.ToList();
    }

    /// <summary>宿主条目流：照 InProc `_crop`（cw_kernel_inproc.gd:465-482）—— 别人的秘密行把 text 换成 public_text；**不看 open_hands**（那一档只在 envelope 里给原文）。</summary>
    [Fact]
    public void 秘密行_宿主条目流按观看者换替身_全知原样()
    {
        using var host = SessionHost.Open(1, new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 7, ["observe_viewer"] = -2, ["open_hands"] = true });
        JsonObject? secret = null;
        for (var i = 0; i < 60 && secret is null; i++)
        {
            var entries = host.Pull(ObservationV1Codec.ViewerOmniscient, 0, int.MaxValue).Select(n => n!.AsObject()).ToList();
            secret = entries.FirstOrDefault(e => J.Str(e["t"]) == "log" && J.Int(e["secret_pid"]) >= 0);
            if (secret is not null) break;
            var ask = entries.Last(e => J.Str(e["t"]) == "ask");
            var keys = ask["req"]!["options"]!.AsArray().Select(o => J.Str(o!["key"])).ToList();
            var key = keys.Contains("k=action|act=draw") ? "k=action|act=draw" : keys.Contains("k=action|act=end") ? "k=action|act=end" : keys[0];
            Assert.True(host.Answer(J.Int(ask["ask_id"]), key, -1));
        }
        Assert.NotNull(secret);
        var owner = J.Int(secret["secret_pid"]);
        var seq = J.Long(secret["seq"]);
        string TextFor(int viewer) => J.Str(host.Pull(viewer, seq - 1, 1)[0]!["text"]);
        Assert.Equal(J.Str(secret["text"]), TextFor(owner));
        Assert.Equal(J.Str(secret["public_text"]), TextFor(1 - owner));
        Assert.Equal(J.Str(secret["public_text"]), TextFor(ObservationV1Codec.ViewerWatcher));   // open_hands 开着也一样（GD _crop 不看它）
        Assert.NotEqual(J.Str(secret["text"]), J.Str(secret["public_text"]));
        Assert.Equal(J.Str(secret["text"]), host.Envelope(ObservationV1Codec.ViewerWatcher)["logs"]!["lines"]![J.Int(secret["index"])]!.GetValue<string>());   // 而 envelope 的观众全见给原文
    }

    // ---- ② log_run 合并 ----

    [Fact]
    public void 连续同类合并成末条_同一个下标再发一次_中间插别的行就断()
    {
        var sim = new SimulationState()
            .Emit(Run("定殖:1", "(0, 1)"))
            .Emit(Run("定殖:1", "(0, 2)"))
            .Emit(Run("定殖:3", "(4, 4)"))     // 别的主体：另起一条
            .Emit(Run("定殖:3", "(4, 5)"))
            .Emit(Line("　癌症B 结束回合（能量 1.0）"))
            .Emit(Run("定殖:3", "(4, 6)"));    // 中间插了别的行：另起一条
        Assert.Equal(["　【定殖】(0, 1)、(0, 2) 转为癌组织", "　【定殖】(4, 4)、(4, 5) 转为癌组织", "　癌症B 结束回合（能量 1.0）", "　【定殖】(4, 6) 转为癌组织"],
            sim.Logs.Select(l => l.Text));
        Assert.Equal([0L, 1, 2, 3], sim.Logs.Select(l => l.Index));
        var written = sim.Presentation.Select(p => p.Event).OfType<LogWritten>().ToList();
        Assert.Equal([0L, 0, 1, 1, 2, 3], written.Select(w => w.Index));   // 合并 = 同一个下标再发一次
        Assert.Equal("　【定殖】(0, 1) 转为癌组织", written[0].Text);
        Assert.Equal("　【定殖】(0, 1)、(0, 2) 转为癌组织", written[1].Text);
        // 句柄条目：同一个 index、新的 text（CWLogStore.apply 按 index 覆盖）
        var encoded = sim.Presentation.Where(p => p.Event is LogWritten).Select(PresentationCodec.Encode).ToList();
        Assert.All(encoded, e => Assert.Equal("log", e["t"].GetString()));
        Assert.Equal(encoded[0]["index"].GetInt64(), encoded[1]["index"].GetInt64());
        Assert.Equal("　【定殖】(0, 1)、(0, 2) 转为癌组织", encoded[1]["text"].GetString());
    }

    /// <summary>真走：一只癌细胞连迈两步进健康组织（GD enter_tile 的 `log_run("定殖:%d")`），两步是两个决策、两次提交，合并照样接得上。</summary>
    [Fact]
    public void 真走两步定殖_两个决策之间照样并成一条()
    {
        using var session = new MatchSession(DemoScenario.Create(), 3);
        for (var seat = 0; seat < 3; seat++)   // 前三席都结束，轮到癌症B（印戒，(1,0)：贴着健康组织）
        {
            var end = session.ObserveV1(seat).Ask!;
            Assert.True(session.SubmitByKey(seat, end.AskId, "k=action|act=end", -1).IsValid);
        }
        var colonized = new List<string>();
        for (var step = 0; step < 2; step++)
        {
            var ask = session.ObserveV1(3).Ask!;
            Assert.Equal(3, ask.Seat);
            var s = session.Peek().State;
            var at = s.Cells[new EntityId(4)].Position;
            // 相邻、健康、空着的一格（Demo 盘面全是普通组织，不会踩到代谢核心 / 骨髓多出别的行）
            var move = ask.Options.First(o => o.Key.StartsWith("k=action|act=move|to=", StringComparison.Ordinal)
                && ParsePos(o.Key) is var to && to.DistanceTo(at) == 1 && s.Board.Tissues[to].State == TissueState.Healthy && s.GetCellAt(to) is null);
            colonized.Add(Stage.P(ParsePos(move.Key)));
            Assert.True(session.SubmitByKey(3, ask.AskId, move.Key, -1).IsValid);
        }
        var logs = session.ObserveV1(ObservationV1Codec.ViewerOmniscient).Logs.Lines;
        Assert.Equal($"　【定殖】{colonized[0]}、{colonized[1]} 转为癌组织", logs.Last(l => l.Contains("【定殖】")));
        Assert.Single(logs, l => l.Contains("【定殖】"));
    }

    private static HexPosition ParsePos(string key)
    {
        var xy = key[(key.LastIndexOf('=') + 1)..].Split(',');
        var q = int.Parse(xy[0]);
        var r = int.Parse(xy[1]);
        return new HexPosition(q, r, -q - r);
    }

    // ---- ③ 绝对下标 ----

    [Fact]
    public void 下标是绝对的_过了128行与演出队列上限都不漂()
    {
        using var runtime = Create(new Handler("log", c => c.Log((string)c.CurrentEvent.Payload!)));
        for (var i = 0; i < 300; i++) runtime.Schedule(i + 1, "log", $"n{i}");
        while (runtime.Run() > 0) { }
        using var lease = runtime.Read();
        var sim = lease.Snapshot.Simulation;
        Assert.Equal(300, sim.Logs.Count);   // 全量保留（GD `logs` 也不裁）；原 Outbox 128 行溢出删头
        Assert.Equal(Enumerable.Range(0, 300).Select(i => (long)i), sim.Logs.Select(l => l.Index));
        Assert.Equal(300, sim.LogCursor.NextIndex);
        Assert.Equal(SimulationState.PresentationCap, sim.Presentation.Count);   // 演出队列照旧丢最旧 —— 日志不跟着丢

        var tail = ObservationV1Codec.Encode(lease.Snapshot, lease.Revision, logsFrom: 250).Logs;
        Assert.Equal(250, tail.From);
        Assert.Equal(Enumerable.Range(250, 50).Select(i => $"n{i}"), tail.Lines);
        var head = ObservationV1Codec.Encode(lease.Snapshot, lease.Revision, logsFrom: 0).Logs;
        Assert.Equal(0, head.From);
        Assert.Equal("n0", head.Lines[0]);
        var past = ObservationV1Codec.Encode(lease.Snapshot, lease.Revision, logsFrom: 999).Logs;
        Assert.Equal(999, past.From);
        Assert.Empty(past.Lines);
    }

    // ---- ④ 推演静音 ----

    [Fact]
    public void 推演里写的日志不留原文_游标照走_主线不受影响()
    {
        using var runtime = Create(new Handler("log", c => c.Log((string)c.CurrentEvent.Payload!)));
        runtime.Schedule(1, "log", "main-0");
        runtime.Run();
        using var branch = (Runtime)runtime.Fork();
        branch.Schedule(2, "log", "branch-only");
        branch.Run();
        runtime.Schedule(2, "log", "main-1");
        runtime.Run();
        using var b = branch.Read();
        using var m = runtime.Read();
        Assert.Equal(["main-0"], b.Snapshot.Simulation.Logs.Select(l => l.Text));                 // 分叉前那一行还在，分叉里写的不留
        Assert.DoesNotContain(b.Snapshot.Simulation.Presentation, p => p.Event is LogWritten { Text: "branch-only" });
        Assert.Equal(m.Snapshot.Simulation.LogCursor.NextIndex, b.Snapshot.Simulation.LogCursor.NextIndex);   // 游标照走：分支与主线的计数对得上
        Assert.Equal(["main-0", "main-1"], m.Snapshot.Simulation.Logs.Select(l => l.Text));
    }

    /// <summary>真推演：Demo 局 Fork 出来的会话打一步（结束回合会写「结束回合 / ▶」两行），主线与分支的存档照旧逐字相同，分支一行原文都不留。</summary>
    [Fact]
    public void 会话Fork打一步_分支不留日志_存档与主线逐字相同()
    {
        using var session = new MatchSession(DemoScenario.Create(), 11);
        using var fork = session.Fork();
        var before = session.ObserveV1(ObservationV1Codec.ViewerOmniscient).Logs.Lines.Length;
        foreach (var s in new[] { session, fork })
        {
            var ask = s.ObserveV1(0).Ask!;
            Assert.True(s.SubmitByKey(0, ask.AskId, "k=action|act=end", -1).IsValid);
        }
        var main = session.ObserveV1(ObservationV1Codec.ViewerOmniscient).Logs.Lines;
        Assert.Contains("　免疫A 结束回合（能量 5.0）", main);
        Assert.True(main.Length > before);
        Assert.Equal(before, fork.ObserveV1(ObservationV1Codec.ViewerOmniscient).Logs.Lines.Length);
        // 分叉前排进队列的那几条随存档复制过去了；分叉之后写的一条都不进队列
        Assert.DoesNotContain(fork.PullPresentation(ObservationV1Codec.ViewerOmniscient, 0, int.MaxValue).Entries, e => e["t"].GetString() == "log" && e["index"].GetInt64() >= before);
        Assert.Equal(session.Save().Json, fork.Save().Json);
    }

    /// <summary>为了日志行序补的三个挂起字段（S 阶段产出停在哪一格、推迟的复活通报、连续吞噬这一串连了几格）随存档往返 —— 续档之后还接得上。</summary>
    [Fact]
    public void 为行序补的挂起字段随存档往返()
    {
        var s = DemoScenario.Create();
        var notice = new RevivalNotice(new EntityId(2), new HexPosition(-3, 3, 0), new HexPosition(-2, 2, 0));
        s = s.WithTurn(s.Turn.WithProductionFrom(17).WithPendingRevival(notice).WithChainLinked(3));
        var (image, _) = CheckpointCodec.Decode(CheckpointCodec.Encode(new WorldImage(s), new Revision(1)));
        Assert.Equal(17, image.State.Turn.ProductionFrom);
        Assert.Equal(notice, image.State.Turn.PendingRevival);
        Assert.Equal(3, image.State.Turn.PendingChainLinked);
        Assert.Null(s.Turn.WithProductionFrom(null).WithPendingRevival(null).ProductionFrom);
    }

    // ---- ⑤ 终局那一行 ----

    [Fact]
    public void 终局那一行排在step_end_sync_game_over之前()
    {
        var walk = SelfTest.Drive(new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 2222, ["observe_viewer"] = -2 }, maxAnswers: 6000, lcgSeed: 2222);
        Assert.True(walk.GameOver);
        var tail = walk.Entries.TakeLast(4).ToList();
        Assert.Equal(["log", "step_end", "sync", "game_over"], tail.Select(e => J.Str(e["t"])));
        Assert.Equal($"=== 对局结束：{J.Str(tail[3]["reason"])} ===", J.Str(tail[0]["text"]));
        // 开局行在第一问之前（GD setup.begin() 写在 pending() 里）
        Assert.StartsWith("初始癌组织：自中央格随机长出 ", J.Str(walk.Entries.First(e => J.Str(e["t"]) == "log")["text"]));
        var kinds = walk.Entries.Select(e => J.Str(e["t"])).ToList();
        Assert.True(kinds.IndexOf("log") < kinds.IndexOf("ask"));
        // 每个下标第一次出现时都是「下一个」：绝对、连续，合并只会回头重发末条
        long next = 0;
        foreach (var e in walk.Entries.Where(e => J.Str(e["t"]) == "log"))
        {
            var index = J.Long(e["index"]);
            Assert.True(index == next || index == next - 1, $"日志下标 {index} 不连续（应为 {next} 或重发 {next - 1}）");
            if (index == next) next++;
        }
    }
}
