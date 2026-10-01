using System.Text.Json;
using System.Text.Json.Nodes;
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
/// 日志条目 `log{index, text, secret_pid, public_text}`（换内核 P2）：内核在结算那一刻投的 GD 原文行，和演出条目同一条队列、按结算顺序搬过来；
/// 就地合并（GD `log_run`）= 同一个 index 再发一次，消费者按 index 覆盖。终局那一行（「=== 对局结束 ===」）排在 step_end / sync / game_over 之前，同 InProc `_run`。
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

    public SessionHost(int sid, MatchSession session, int? observeViewer, bool openHands) : this(sid, session, observeViewer, openHands, restored: false) { }

    private SessionHost(int sid, MatchSession session, int? observeViewer, bool openHands, bool restored)
    {
        Sid = sid;
        this.session = session;
        ObserveViewer = observeViewer;
        OpenHands = openHands;
        if (restored)
        {
            // 读档：检查点里留着上一局缓冲的演出条目 —— 别再播一遍；第一问之前照 InProc 的节拍先收一步（GD 读档后 run_game 重问时也是 step_end → sync → ask）
            presentationSeen = session.PullPresentation(ObservationV1Codec.ViewerOmniscient, 0, 0).NextSeq - 1;
            Push(new JsonObject { ["t"] = "step_end", ["rev"] = session.Peek().Revision.Value });
        }
        Pump();
    }

    // ---- 存读档（换内核 P4 前置，2026-10-01）----

    /// <summary>GD `can_save`：停在**顶层**问答边界且没终局。拆问的第二问里不能存 —— 检查点里只有 C# 那一问，第二问是宿主自己的状态。</summary>
    public bool CanSave => !Aborted && !Over && open is { IsSub: false };

    /// <summary>★ 检查点含 rng 与全部明文手牌：宿主专用、绝不过网（同 MatchSession.Save）。不能存时返回 null。</summary>
    public string? Save() => CanSave ? session.Save().Json : null;

    /// <summary>从检查点接着打：挂着的那一问会重新问出来（宿主泵一次就看见 Input）。</summary>
    public static SessionHost Restore(int sid, string checkpointJson, int? observeViewer, bool openHands)
        => new(sid, MatchSession.Restore(new Checkpoint(checkpointJson)), observeViewer, openHands, restored: true);

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
        // GD `tune.cancer_types`（按癌席顺序钉死，值是 GD ctype）与 `players[].name`（宿主注入的显示名；空串 = 用默认名）
        var cancerTypes = cfg["cancer_types"]?.AsArray().Select(J.Int).ToArray() ?? [];
        // MatchSession.Start(seed, 建世界)：开局那几行日志（「初始癌组织：…」）写在建世界的时候，要它收进条目流
        return new(sid, MatchSession.Start(seed, () => WithNames(MatchSetup.Create(factions.Length, seed, cancerTypes), cfg, factions.Length)), viewer, openHands);
    }

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
        var out_ = new JsonArray();
        foreach (var e in entries)
        {
            if (J.Long(e["seq"]) <= since) continue;
            out_.Add(Crop(viewer, e));
            if (out_.Count >= limit) break;
        }
        return out_;
    }

    public long LastSeq => nextSeq - 1;

    /// <summary>消费者播完一批：丢掉 seq &lt;= 给定值的条目（同 InProc.discard_before）。</summary>
    public void DiscardBefore(long seq) => entries.RemoveAll(e => J.Long(e["seq"]) <= seq);

    // ---- 作答 ----

    /// <summary>键为准、下标兜底（同 InProc.answer）。选中组入口 = 开第二问，不碰内核。</summary>
    public bool Answer(int askId, string? key, int index)
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
        var s = session.Peek().State;
        if (!s.Players.ContainsKey(seat) || suffix == "") return false;
        var cur = Stage.SeatName(s, seat);
        if (!cur.EndsWith(suffix, StringComparison.Ordinal)) session.Rename(seat, cur + suffix);
        return true;
    }

    /// <summary>GD `surrender(faction)`：对方阵营直接获胜。之后马上泵一次 —— 收步、sync、game_over 条目这就出来了。</summary>
    public bool Surrender(int faction)
    {
        if (Aborted || Over || faction is not (0 or 1)) return false;
        if (!session.Surrender((Faction)faction)) return false;
        open = null;
        Pump();
        return true;
    }

    /// <summary>GD `log_msg`：宿主往日志里插一行（服务器投降投票那两行）。之后泵一次，`log` 条目这就出来。</summary>
    public bool LogMessage(string text, int secretSeat, string? publicText)
    {
        if (Aborted) return false;
        session.LogMessage(text, secretSeat, publicText);
        Pump();
        return true;
    }

    /// <summary>= InProc.abort()：对局作废，正在等的那一问不再收答案；之后不再推任何条目。</summary>
    public void Abort()
    {
        Aborted = true;
        open = null;
    }

    // ---- 观测 ----

    /// <summary>按 viewer 裁过的 envelope；ask 段换成本宿主折叠过的那一问（GD 的 envelope 本来就是折叠形状）。</summary>
    public JsonNode Envelope(int viewer, long logsFrom = 0)
    {
        var env = JsonSerializer.SerializeToNode(session.ObserveV1(viewer, OpenHands, logsFrom), ObservationV1Codec.Json)!.AsObject();
        var rev = J.Long(env["rev"]);
        env["ask"] = open is null ? null
            : open.ToObsAsk(rev, viewer == ObservationV1Codec.ViewerOmniscient || (viewer >= 0 && viewer == open.Seat));
        return env;
    }

    public HostSnapshot Peek() => session.Peek();

    /// <summary>
    /// 观测协议 §5.3 的查询式（plan_next_dests / quote_path / cost_effects_for / move_block_reason），转给 <see cref="MatchSession.QueryV1"/>。
    /// `seat` 不给就取这只细胞的主人 —— 本机宿主是全知的（桌面 / 热座），服务器那条路由它自己传请求方的席位（P6）。
    /// </summary>
    public JsonNode? Query(string kind, JsonObject args, int? seat)
    {
        var cid = J.IntOr(args["cid"]);
        var owner = seat ?? (cid is { } id && session.Peek().State.Cells.TryGetValue(new EntityId((ulong)(id + 1)), out var c) ? c.OwnerSeat : -1);
        var result = session.QueryV1(owner, kind, JsonSerializer.SerializeToElement(args));
        return result is { } r ? JsonNode.Parse(r.GetRawText()) : null;
    }

    public void Dispose() => session.Dispose();

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
            open = HostAsk.Top(++askSerial, CsAsk(), snap.State);
            EmitSyncAndAsk();
        }
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
