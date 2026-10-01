using System.Text.Json;
using System.Text.Json.Nodes;
using CellWar.Ai;
using CellWar.Core;
using CellWar.Core.Observation;

namespace CellWar.Sidecar;

/// <summary>
/// 一局的宿主：包住 <see cref="MatchSession"/>，对外吐一条与 GD `CWKernelInProc` **同节拍、同字段**的条目流
/// （`cw_kernel.gd` 头注的 15 种；条目带 `seq` 单调、`barrier` 只有 roll 为 true）。
///
/// 节拍照 InProc：
///   一步收尾 → `step_end{rev}` →（设了 observe_viewer）`sync{envelope}` → 下一问 `ask{ask_id, req, left_ms}`；
///   终局 → `step_end` → `sync` → `game_over{winner, reason, kind, round, replay}`；
///   答下 → `step_begin{ask_id, seat}`，这一步的演出都排在它后面。
/// `step_begin` / `step_end` 与演出条目是 C# Runtime 自己发的（批 0），这里只把 `step_begin.ask_id` 从 C# 的 RequestId 换成本宿主的 ask id；
/// sync / ask / game_over 由宿主合成。C# 独有的 `attack` 条目不上线（GD 的播放队列没有它的分支）。
///
/// ask id 是宿主自己的序号（与 InProc 的 `_ask_serial` 同义）：拆问时一个 C# 询问对应两个宿主 ask（见 <see cref="HostAsk"/>）。
/// 日志条目（`log`）P1 不发 —— C# 的 Outbox 只有调试串，原文日志是 P2。
///
/// **AI 席**（换内核 P3）：`open` 的 `ai: {"席位": "normal"|"intent"|"search"}` 里的席位由 sidecar 里的 CellWar.Ai 作答，不过网。
/// 节拍照 InProc 有 decider 的席位：问之前照样 step_end（Runtime 发）→ sync，**不出 ask 条目**，答下之后 step_begin（ask id 是宿主的）；
/// AI 选了组键（建源 / 免疫猎杀 / Excalibur）就照 GD 的两问补一段 step_begin → step_end → sync。AI 在后台线程想（搜索档一问几十到几百毫秒），
/// 想完回到锁里交答案 —— 句柄照常每帧 pull；所以本类所有公开方法都进同一把锁（<see cref="gate"/>）。
/// </summary>
internal sealed class SessionHost : IDisposable
{
    public int Sid { get; }
    public int? ObserveViewer { get; set; }
    public bool OpenHands { get; set; }
    public bool Aborted { get; private set; }
    public bool Over { get; private set; }

    private readonly MatchSession session;
    private readonly List<JsonObject> entries = [];
    private long nextSeq = 1;
    private long presentationSeen;
    private int askSerial;
    private HostAsk? open;
    /// <summary>C# RequestId → 最后作答的那个宿主 ask id（拆问时是第二问的 id，与 GD「第二问答下才开步」同义）。</summary>
    private readonly Dictionary<long, int> answeredBy = [];
    private string lastKind = "";

    // ---- AI 席（换内核 P3）----
    /// <summary>后台 AI 线程与连接线程（pull / answer / observe）共用这一把锁；Monitor 可重入，Pump 里调 Envelope 不会自锁。</summary>
    private readonly object gate = new();
    private readonly Dictionary<int, IPolicy> aiSeats;
    private readonly int aiDelayMs;
    /// <summary>会话种子：AI 每一问的推演种子由它 + 内核修订号派生（同一局同一问同一答案，也不碰真局的骰子）。</summary>
    private readonly ulong seed;
    private readonly CancellationTokenSource lifetime = new();
    /// <summary>AI 正在想的那一问（折叠成 GD 形状，只给 envelope 的 ask 段用；<see cref="Answer"/> 不收它的答案）。</summary>
    private HostAsk? aiOpen;
    private bool disposed;

    /// <summary>产品路径给搜索档的单问预算（毫秒）：到点不再开新的根，已评完的根里取最好的。GD 参照 6 人局最慢一问 2.1 秒，C# 同一问约百毫秒，正常碰不到 —— 只防卡死。</summary>
    public const int SearchBudgetMs = 2500;

    /// <summary>AI 最近一次出错（兜底作答了），排查用。</summary>
    public string? LastAiError { get; private set; }

    public SessionHost(int sid, MatchSession session, int? observeViewer, bool openHands,
        IReadOnlyDictionary<int, AiTier>? ai = null, int aiDelayMs = 0, ulong seed = 1)
    {
        Sid = sid;
        this.session = session;
        ObserveViewer = observeViewer;
        OpenHands = openHands;
        aiSeats = (ai ?? new Dictionary<int, AiTier>()).ToDictionary(kv => kv.Key,
            kv => AiPolicies.Create(new AiConfig { Tier = kv.Value, BudgetMs = kv.Value == AiTier.Search ? SearchBudgetMs : 0 }));
        this.aiDelayMs = Math.Max(0, aiDelayMs);
        this.seed = seed;
        lock (gate) Pump();
    }

    /// <summary>`open` 报文 → 一局。P1 只认 GD 的标准座次（`CWMatch.FACTION_ORDER`：免疫 / 癌交替，与 C# <see cref="MatchSetup"/> 同一套）。</summary>
    public static SessionHost Open(int sid, JsonObject cfg)
    {
        var factions = cfg["factions"]?.AsArray().Select(J.Int).ToArray()
            ?? throw new ArgumentException("open 缺 factions");
        for (var i = 0; i < factions.Length; i++)
            if (factions[i] != i % 2)
                throw new ArgumentException($"P1 只支持免疫 / 癌交替的座次，第 {i} 席是 {factions[i]}");
        var seed = cfg["seed"] is { } sv ? unchecked((ulong)J.Long(sv)) : 1UL;
        var viewer = J.IntOr(cfg["observe_viewer"]);
        var openHands = cfg["open_hands"] is { } oh && J.Bool(oh);
        // AI 席：{"席位": "normal" | "intent" | "search"}（JSON 的键只能是字符串）
        var ai = new Dictionary<int, AiTier>();
        foreach (var (k, v) in cfg["ai"]?.AsObject() ?? [])
        {
            if (!int.TryParse(k, out var seat) || seat < 0 || seat >= factions.Length)
                throw new ArgumentException($"ai 里的席位「{k}」不在 0..{factions.Length - 1}");
            ai[seat] = AiConfig.ParseTier(J.Str(v));
        }
        var delay = J.IntOr(cfg["ai_delay_ms"]) ?? 0;
        return new(sid, MatchSession.Start(factions.Length, seed), viewer, openHands, ai, delay, seed);
    }

    // ---- 条目 ----

    public JsonArray Pull(int viewer, long since, int limit)
    {
        lock (gate) return PullLocked(viewer, since, limit);
    }

    private JsonArray PullLocked(int viewer, long since, int limit)
    {
        var out_ = new JsonArray();
        foreach (var e in entries)
        {
            if (J.Long(e["seq"]) <= since) continue;
            out_.Add(Crop(viewer, e));
            if (out_.Count >= limit) break;
        }
        return out_;
    }

    public long LastSeq { get { lock (gate) return nextSeq - 1; } }

    /// <summary>消费者播完一批：丢掉 seq &lt;= 给定值的条目（同 InProc.discard_before）。</summary>
    public void DiscardBefore(long seq) { lock (gate) entries.RemoveAll(e => J.Long(e["seq"]) <= seq); }

    // ---- 作答 ----

    /// <summary>键为准、下标兜底（同 InProc.answer）。选中组入口 = 开第二问，不碰内核。</summary>
    public bool Answer(int askId, string? key, int index)
    {
        lock (gate) return AnswerLocked(askId, key, index);
    }

    private bool AnswerLocked(int askId, string? key, int index)
    {
        if (Aborted || Over || open is null || open.AskId != askId) return false;
        var i = string.IsNullOrEmpty(key) ? -1 : open.IndexOfKey(key);
        if (i < 0 && index >= 0 && index < open.Options.Count) i = index;
        if (i < 0) return false;
        var chosen = open.Options[i];

        if (chosen.Group is { } group)
        {
            var snap = session.Peek();
            // GD：顶层那问答下即开步，进 `_do_chemo` / `_effector_*` 再问之前又收步（InProc._on_ask 的 _close_step）
            Push(new JsonObject { ["t"] = "step_begin", ["ask_id"] = open.AskId, ["seat"] = open.Seat });
            Push(new JsonObject { ["t"] = "step_end", ["rev"] = snap.Revision.Value });
            open = HostAsk.Sub(++askSerial, open, group, CsAsk(), snap.State);
            EmitSyncAndAsk();
            return true;
        }

        answeredBy[open.RequestId] = open.AskId;
        var result = session.SubmitByKey(open.Seat, open.RequestId, chosen.SubmitKey, -1);
        if (!result.IsValid) return false;
        open = null;
        Pump();
        return true;
    }

    /// <summary>= InProc.abort()：对局作废，正在等的那一问不再收答案；之后不再推任何条目。</summary>
    public void Abort()
    {
        lock (gate)
        {
            Aborted = true;
            open = null;
            aiOpen = null;
            lifetime.Cancel();   // 正在想的 AI 收手（搜索档在根之间查令牌）
        }
    }

    // ---- 观测 ----

    /// <summary>按 viewer 裁过的 envelope；ask 段换成本宿主折叠过的那一问（GD 的 envelope 本来就是折叠形状）。</summary>
    public JsonNode Envelope(int viewer, long logsFrom = 0)
    {
        lock (gate)
        {
            var env = JsonSerializer.SerializeToNode(session.ObserveV1(viewer, OpenHands, logsFrom), ObservationV1Codec.Json)!.AsObject();
            var rev = J.Long(env["rev"]);
            // AI 正在想的那一问也进 ask 段（InProc 的 decider 路同样写 _open_ask，observe 带得出它）
            var asking = open ?? aiOpen;
            env["ask"] = asking is null ? null
                : asking.ToObsAsk(rev, viewer == ObservationV1Codec.ViewerOmniscient || (viewer >= 0 && viewer == asking.Seat));
            return env;
        }
    }

    public HostSnapshot Peek() => session.Peek();

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            lifetime.Cancel();
            session.Dispose();
        }
    }

    // ---- 内部 ----

    /// <summary>把内核新产的演出条目搬进来，然后看该问人还是该收局。</summary>
    private void Pump()
    {
        if (Aborted) return;
        var page = session.PullPresentation(ObservationV1Codec.ViewerOmniscient, presentationSeen, int.MaxValue);
        foreach (var raw in page.Entries)
        {
            presentationSeen = raw["seq"].GetInt64();
            var e = new JsonObject();
            foreach (var (k, v) in raw)
                if (k is not ("seq" or "barrier")) e[k] = JsonNode.Parse(v.GetRawText());
            var t = J.Str(e["t"]);
            if (t == "attack") continue;
            if (t == "step_begin")
            {
                var rid = J.Long(e["ask_id"]);
                e["ask_id"] = answeredBy.TryGetValue(rid, out var hid) ? hid : checked((int)rid);
            }
            Push(e, barrier: t == "roll");
        }

        var snap = session.Peek();
        if (snap.State.Turn.Winner is not null)
        {
            if (!Over) EmitGameOver(snap);
            return;
        }
        if (snap.Input is { } input && (open is null || open.RequestId != input.RequestId))
        {
            if (aiSeats.TryGetValue(input.PlayerSeat, out var policy))
            {
                if (aiOpen?.RequestId != input.RequestId) StartAi(policy, input, snap);
                return;
            }
            open = HostAsk.Top(++askSerial, CsAsk(), snap.State);
            EmitSyncAndAsk();
        }
    }

    /// <summary>
    /// AI 席的一问：sync（不出 ask 条目）→ 后台线程想 → 回到锁里 <see cref="CompleteAi"/>。
    /// 想的时候只读这一刻的世界（不可变），不碰会话；推演种子 = 会话种子 + 修订号派生。
    /// </summary>
    private void StartAi(IPolicy policy, PendingInput input, HostSnapshot snap)
    {
        aiOpen = HostAsk.Top(++askSerial, CsAsk(), snap.State);
        if (ObserveViewer is { } v) Push(new JsonObject { ["t"] = "sync", ["envelope"] = Envelope(v) });
        var askId = aiOpen.AskId;
        var state = snap.State;
        var rngSeed = SplitMix64Rng.DecisionSeed(seed, snap.Revision.Value);
        var token = lifetime.Token;
        Task.Run(() =>
        {
            string? key = null;
            string? error = null;
            try
            {
                // 观战节奏（同 GD 桥的 delay_ms：先等再想）；取消令牌一响立刻醒
                if (aiDelayMs > 0) token.WaitHandle.WaitOne(aiDelayMs);
                if (!token.IsCancellationRequested)
                    key = policy.Choose(state, input.PlayerSeat, input.Options, new SplitMix64Rng(rngSeed), token);
            }
            catch (Exception ex) { error = $"{ex.GetType().Name}: {ex.Message}"; }
            lock (gate) CompleteAi(input, askId, key, error);
        });
    }

    /// <summary>
    /// 交 AI 的答案（锁里）。局面已经变了（abort / close / 那一问不在了）就作废。AI 出错（不该发生）兜底走普通档，再不行取第一条 ——
    /// 一席卡死整局比答得差更糟。组键照 GD 两问补一段 step_begin → step_end → sync（同 <see cref="AnswerLocked"/> 的人类路）。
    /// </summary>
    private void CompleteAi(PendingInput input, int askId, string? key, string? error)
    {
        if (disposed || Aborted || Over || aiOpen is null || aiOpen.AskId != askId) return;
        var snap = session.Peek();
        if (snap.Input?.RequestId != input.RequestId) return;
        if (error != null) LastAiError = error;
        key ??= Fallback(snap.State, input);
        var group = key.StartsWith("k=action+chemo_target|", StringComparison.Ordinal) ? "chemo_target"
            : key.StartsWith("k=action+effector_target|", StringComparison.Ordinal) ? "effector_target" : null;
        if (group != null)
        {
            Push(new JsonObject { ["t"] = "step_begin", ["ask_id"] = askId, ["seat"] = input.PlayerSeat });
            Push(new JsonObject { ["t"] = "step_end", ["rev"] = snap.Revision.Value });
            aiOpen = HostAsk.Sub(++askSerial, aiOpen, group, CsAsk(), snap.State);
            if (ObserveViewer is { } v) Push(new JsonObject { ["t"] = "sync", ["envelope"] = Envelope(v) });
        }
        answeredBy[input.RequestId] = aiOpen.AskId;
        aiOpen = null;
        var result = session.SubmitByKey(input.PlayerSeat, input.RequestId, key, -1);
        if (!result.IsValid)
        {
            LastAiError = $"AI 的答案「{key}」被内核拒了：{result.ErrorMessage}";
            session.SubmitByKey(input.PlayerSeat, input.RequestId, Fallback(snap.State, input), -1);
        }
        Pump();
    }

    private static string Fallback(WorldState state, PendingInput input)
    {
        try { return AiPolicies.Create(AiConfig.For(AiTier.Normal)).Choose(state, input.PlayerSeat, input.Options, new SplitMix64Rng(1)); }
        catch (Exception) { return SemanticKey.Of(state, input.Options.First(d => d is not PassDecision)); }
    }

    private ObsAsk CsAsk() => session.ObserveV1(ObservationV1Codec.ViewerOmniscient).Ask
        ?? throw new InvalidOperationException("内核有挂起询问，全知 envelope 却没有 ask");

    private void EmitSyncAndAsk()
    {
        if (ObserveViewer is { } v) Push(new JsonObject { ["t"] = "sync", ["envelope"] = Envelope(v) });
        Push(new JsonObject { ["t"] = "ask", ["ask_id"] = open!.AskId, ["req"] = open.ToReq(), ["left_ms"] = -1 });
    }

    private void EmitGameOver(HostSnapshot snap)
    {
        Over = true;
        open = null;
        if (lastKind != "step_end")   // InProc._run：终局之前 _close_step()（这一步是开着的）
            Push(new JsonObject { ["t"] = "step_end", ["rev"] = snap.Revision.Value });
        if (ObserveViewer is { } v) Push(new JsonObject { ["t"] = "sync", ["envelope"] = Envelope(v) });
        var g = Envelope(ObservationV1Codec.ViewerOmniscient)["state"]!["g"]!;
        Push(new JsonObject
        {
            ["t"] = "game_over", ["winner"] = g["winner"]!.DeepClone(), ["reason"] = g["win_reason"]!.DeepClone(),
            ["kind"] = g["win_kind"]!.DeepClone(), ["round"] = g["round_no"]!.DeepClone(), ["replay"] = new JsonObject(),
        });
    }

    private void Push(JsonObject e, bool barrier = false)
    {
        e["seq"] = nextSeq++;
        e["barrier"] = barrier;
        lastKind = J.Str(e["t"]);
        entries.Add(e);
    }

    /// <summary>同 InProc._crop：ask 只给主人完整选项，别人只留 kind / tag / seat / prompt。日志 P1 不发，没有秘密行要换。</summary>
    private static JsonObject Crop(int viewer, JsonObject e)
    {
        if (viewer == ObservationV1Codec.ViewerOmniscient || J.Str(e["t"]) != "ask") return (JsonObject)e.DeepClone();
        var req = e["req"]!.AsObject();
        if (J.Int(req["pid"]) == viewer) return (JsonObject)e.DeepClone();
        var c = (JsonObject)e.DeepClone();
        c["req"]!["options"] = new JsonArray();
        return c;
    }
}
