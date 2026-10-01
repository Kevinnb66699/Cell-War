using System.Text.Json;
using System.Text.Json.Nodes;
using CellWar.Ai;
using CellWar.Core;
using CellWar.Core.Observation;
using CellWar.Core.Worlds;

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
/// 日志条目 `log{index, text, secret_pid, public_text}`（换内核 P2）：内核在结算那一刻投的 GD 原文行，和演出条目同一条队列、按结算顺序搬过来；
/// 就地合并（GD `log_run`）= 同一个 index 再发一次，消费者按 index 覆盖。终局那一行（「=== 对局结束 ===」）排在 step_end / sync / game_over 之前，同 InProc `_run`。
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
        : this(sid, session, observeViewer, openHands, ai, aiDelayMs, seed, restored: false) { }

    private SessionHost(int sid, MatchSession session, int? observeViewer, bool openHands,
        IReadOnlyDictionary<int, AiTier>? ai, int aiDelayMs, ulong seed, bool restored)
    {
        Sid = sid;
        this.session = session;
        ObserveViewer = observeViewer;
        OpenHands = openHands;
        aiSeats = (ai ?? new Dictionary<int, AiTier>()).ToDictionary(kv => kv.Key,
            kv => AiPolicies.Create(new AiConfig { Tier = kv.Value, BudgetMs = kv.Value == AiTier.Search ? SearchBudgetMs : 0 }));
        this.aiDelayMs = Math.Max(0, aiDelayMs);
        this.seed = seed;
        lock (gate)
        {
            if (restored)
            {
                // 读档：检查点里留着上一局缓冲的演出条目 —— 别再播一遍；第一问之前照 InProc 的节拍先收一步（GD 读档后 run_game 重问时也是 step_end → sync → ask）
                presentationSeen = session.PullPresentation(ObservationV1Codec.ViewerOmniscient, 0, 0).NextSeq - 1;
                Push(new JsonObject { ["t"] = "step_end", ["rev"] = session.Peek().Revision.Value });
            }
            Pump();
        }
    }

    // ---- 存读档（换内核 P4 前置，2026-10-01）----

    /// <summary>GD `can_save`：停在**顶层**问答边界且没终局。拆问的第二问里不能存 —— 检查点里只有 C# 那一问，第二问是宿主自己的状态。</summary>
    public bool CanSave { get { lock (gate) return !Aborted && !Over && open is { IsSub: false }; } }   // AI 正在想（aiOpen）时 open 是空的 ⇒ 不能存

    /// <summary>★ 检查点含 rng 与全部明文手牌：宿主专用、绝不过网（同 MatchSession.Save）。不能存时返回 null。</summary>
    public string? Save() { lock (gate) return CanSave ? session.Save().Json : null; }

    /// <summary>从检查点接着打：挂着的那一问会重新问出来（宿主泵一次就看见 Input）。</summary>
    public static SessionHost Restore(int sid, string checkpointJson, int? observeViewer, bool openHands)
        => new(sid, MatchSession.Restore(new Checkpoint(checkpointJson)), observeViewer, openHands, null, 0, 1, restored: true);   // AI 席随 P4 桌面切换一起接（检查点里不记 AI 配置）

    /// <summary>`open` 报文 → 一局。P1 只认 GD 的标准座次（`CWMatch.FACTION_ORDER`：免疫 / 癌交替，与 C# <see cref="MatchSetup"/> 同一套）。</summary>
    public static SessionHost Open(int sid, JsonObject cfg)
    {
        if (cfg["world"] is JsonObject world) return OpenWorld(sid, cfg, world);
        var factions = cfg["factions"]?.AsArray().Select(J.Int).ToArray()
            ?? throw new ArgumentException("open 缺 factions");
        for (var i = 0; i < factions.Length; i++)
            if (factions[i] != i % 2)
                throw new ArgumentException($"P1 只支持免疫 / 癌交替的座次，第 {i} 席是 {factions[i]}");
        var seed = cfg["seed"] is { } sv ? unchecked((ulong)J.Long(sv)) : 1UL;
        var viewer = J.IntOr(cfg["observe_viewer"]);
        var openHands = cfg["open_hands"] is { } oh && J.Bool(oh);
        // GD `tune.cancer_types`（按癌席顺序钉死，值是 GD ctype）与 `players[].name`（宿主注入的显示名；空串 = 用默认名）
        var cancerTypes = cfg["cancer_types"]?.AsArray().Select(J.Int).ToArray() ?? [];
        // MatchSession.Start(seed, 建世界)：开局那几行日志（「初始癌组织：…」）写在建世界的时候，要它收进条目流
        // AI 席：{"席位": "normal" | "intent" | "search"}（JSON 的键只能是字符串）
        var ai = new Dictionary<int, AiTier>();
        foreach (var (k, v) in cfg["ai"]?.AsObject() ?? [])
        {
            if (!int.TryParse(k, out var seat) || seat < 0 || seat >= factions.Length)
                throw new ArgumentException($"ai 里的席位「{k}」不在 0..{factions.Length - 1}");
            ai[seat] = AiConfig.ParseTier(J.Str(v));
        }
        var delay = J.IntOr(cfg["ai_delay_ms"]) ?? 0;
        return new(sid, MatchSession.Start(seed, () => WithNames(MatchSetup.Create(factions.Length, seed, cancerTypes), cfg, factions.Length)), viewer, openHands, ai, delay, seed);
    }

    /// <summary>
    /// 新手教程（换内核 P5）：GD 舞台 resolve 好的一份 cwxworld/3 + 这一关的骰子带子 `rolls`（`[[from, to, value], …]`）→ 从这份世界续跑。
    /// 同 GD `cw_tutorial_stage.gd:_open_spec`：装载器装盘、带子挂在开局之前、念完回落到按 `seed` 的随机流（GD 装载器的种子恒为 1）；
    /// 世界里写的 `seat` 读成「正在这一席的回合中」（`MatchSession.Resume`，GD 侧是 `_point_cursor`）。
    /// </summary>
    private static SessionHost OpenWorld(int sid, JsonObject cfg, JsonObject worldNode)
    {
        var world = WorldLoader.Load(WorldJson.Parse(worldNode.ToJsonString()));
        var rolls = cfg["rolls"]?.AsArray().Select(r => (IReadOnlyList<long>)r!.AsArray().Select(J.Long).ToArray()).ToList() ?? [];
        var seed = cfg["seed"] is { } sv ? unchecked((ulong)J.Long(sv)) : 1UL;
        var viewer = J.IntOr(cfg["observe_viewer"]);
        var openHands = cfg["open_hands"] is { } oh && J.Bool(oh);
        world = WithNames(world, cfg, world.Players.Count);
        return new(sid, MatchSession.Resume(world, new ScriptedRng(rolls, seed)), viewer, openHands, null, 0, seed);
    }

    /// <summary>GD `cw_world_loader.gd:dump_world`：把活局面导成一份 cwxworld/3（教程间章「重心平移」要先导出、平移、再装回来）。</summary>
    public JsonNode DumpWorld() { lock (gate) return JsonSerializer.SerializeToNode(WorldLoader.Dump(session.Peek().State), WorldJson.Options)!; }

    private static WorldState WithNames(WorldState world, JsonObject cfg, int seats)
    {
        if (cfg["names"]?.AsArray() is { } names)
            for (var i = 0; i < names.Count && i < seats; i++)
                if (J.StrOr(names[i]) is { Length: > 0 } name)
                    world = world.UpdatePlayer(i, new Player
                    {
                        Seat = world.Players[i].Seat, Faction = world.Players[i].Faction, IsAlive = world.Players[i].IsAlive,
                        DrawCount = world.Players[i].DrawCount, AntigenMemory = world.Players[i].AntigenMemory,
                        ImmuneLevel = world.Players[i].ImmuneLevel, CancerType = world.Players[i].CancerType, Name = name,
                    });
        return world;
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

    /// <summary>GD `mark_player`：给一席的名字加后缀（单机真人席的「(我)」），已经带了就不重复加。纯装饰，不进规则。</summary>
    public bool MarkPlayer(int seat, string suffix)
    {
        lock (gate)
        {
            var s = session.Peek().State;
            if (!s.Players.ContainsKey(seat) || suffix == "") return false;
            var cur = Stage.SeatName(s, seat);
            if (!cur.EndsWith(suffix, StringComparison.Ordinal)) session.Rename(seat, cur + suffix);
            return true;
        }
    }

    /// <summary>GD `surrender(faction)`：对方阵营直接获胜。之后马上泵一次 —— 收步、sync、game_over 条目这就出来了。</summary>
    public bool Surrender(int faction)
    {
        lock (gate)
        {
            if (Aborted || Over || faction is not (0 or 1)) return false;
            if (!session.Surrender((Faction)faction)) return false;
            open = null;
            aiOpen = null;   // AI 正在想的那一问作废（它回来时 CompleteAi 看 Input 已经没了，自己丢掉）
            Pump();
            return true;
        }
    }

    /// <summary>GD `log_msg`：宿主往日志里插一行（服务器投降投票那两行）。之后泵一次，`log` 条目这就出来。</summary>
    public bool LogMessage(string text, int secretSeat, string? publicText)
    {
        lock (gate)
        {
            if (Aborted) return false;
            session.LogMessage(text, secretSeat, publicText);
            Pump();
            return true;
        }
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

    /// <summary>
    /// 观测协议 §5.3 的查询式（plan_next_dests / quote_path / cost_effects_for / move_block_reason），转给 <see cref="MatchSession.QueryV1"/>。
    /// `seat` 不给就取这只细胞的主人 —— 本机宿主是全知的（桌面 / 热座），服务器那条路由它自己传请求方的席位（P6）。
    /// </summary>
    public JsonNode? Query(string kind, JsonObject args, int? seat)
    {
        lock (gate)
        {
            var cid = J.IntOr(args["cid"]);
            var owner = seat ?? (cid is { } id && session.Peek().State.Cells.TryGetValue(new EntityId((ulong)(id + 1)), out var c) ? c.OwnerSeat : -1);
            var result = session.QueryV1(owner, kind, JsonSerializer.SerializeToElement(args));
            return result is { } r ? JsonNode.Parse(r.GetRawText()) : null;
        }
    }

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

    /// <summary>同 InProc._crop：ask 只给主人完整选项，别人只留 kind / tag / seat / prompt；日志的秘密行（别人抽到的牌名）把 text 换成 public_text。
    /// 照 GD 那份逐字：条目流这一层**不看 open_hands**（观众全见只在 observe 的 envelope.logs 里给原文，cw_obs_codec.gd:_logs）。</summary>
    private static JsonObject Crop(int viewer, JsonObject e)
    {
        if (viewer == ObservationV1Codec.ViewerOmniscient) return (JsonObject)e.DeepClone();
        if (J.Str(e["t"]) == "log")
        {
            var line = (JsonObject)e.DeepClone();
            var secret = J.Int(e["secret_pid"]);
            if (secret >= 0 && secret != viewer) line["text"] = e["public_text"]!.DeepClone();
            return line;
        }
        if (J.Str(e["t"]) != "ask") return (JsonObject)e.DeepClone();
        var req = e["req"]!.AsObject();
        if (J.Int(req["pid"]) == viewer) return (JsonObject)e.DeepClone();
        var c = (JsonObject)e.DeepClone();
        c["req"]!["options"] = new JsonArray();
        return c;
    }
}
