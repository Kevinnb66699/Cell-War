using System.Reflection;
using System.Text.Json.Nodes;
using CellWar.Ai;
using CellWar.Core.Observation;

namespace CellWar.Sidecar;

/// <summary>
/// 一条连接上的报文分派。请求 `{"id":n,"op":"…","sid":会话,…}` → 回应 `{"re":n,"ok":true,…}` 或 `{"re":n,"ok":false,"error":"…"}`。
/// sidecar 从不主动推送：条目由句柄每帧 `pull`。
///
/// 会话 `sid` 从第一版就带（桌面只有一局；服务器一个进程跑所有房间，计划 §3.1）。
/// 报文一览（P1）：
///   version{}                                       → {host_abi, rules_build, ruleset_digest, core_build}
///   open{cfg:{factions[], seed, observe_viewer?, open_hands?, names?[], cancer_types?[], ai?: {"席位": "normal"|"intent"|"search"}, ai_delay_ms?, ai_paced?}} → {sid}
///     （ai 里的席位由 sidecar 内的 CellWar.Ai 在后台线程作答：不出 ask 条目，句柄照常 pull，见 SessionHost 头注；
///      ai_paced = AI 想好了也等 ai_step 才交 —— 服务器用，见 SessionHost 头注「服务器那条路」）
///   set_ai{sid, seat, tier: "normal"|"intent"|"search"|null, once?} → {withdrawn}（中途换作答方；withdrawn = 收回的真人询问的 ask id，-1 = 没有）
///   ai_step{sid}                                    → {stepped}（ai_paced：交 AI 想好了的那一问）
///   open{cfg:{world: cwxworld/3, rolls?: [[from,to,value]…], seed?, observe_viewer?, open_hands?, names?[]}} → {sid}（新手教程：从装载世界续跑）
///   dump_world{sid}                                 → {world}（活局面导成 cwxworld/3）
///   tape{sid}                                       → {size, at, overrun, bad_range}（教程骰子带子的账；只有从关卡世界开的局有）
///   pull{sid, viewer, since, limit?}                → {entries[], last_seq}
///   discard_before{sid, seq}                        → {}
///   answer{sid, ask_id, key?, index?}               → {accepted}
///   observe{sid, viewer, logs_from?}                → {envelope}
///   query{sid, kind, args, seat?}                   → {result}（观测协议 §5.3 四条；坐标 {q,r}）
///   mark_player{sid, pid, suffix}                   → {ok_mark}
///   surrender{sid, faction}                         → {ended}
///   log_msg{sid, text, secret_pid?, public_text?}   → {logged}（宿主插一行日志 = GD log_msg）
///   can_save{sid} → {can_save} · save{sid} → {checkpoint|null} · restore{checkpoint, observe_viewer?, open_hands?, ai?, ai_delay_ms?, seed?} → {sid}
///   abort{sid} / close{sid}                         → {}
///   ping{}                                          → {}
/// </summary>
internal sealed class Dispatcher : IDisposable
{
    private readonly Dictionary<int, SessionHost> sessions = [];
    private int nextSid = 1;

    /// <summary>测试用：按 op 当场抛一个异常（模拟规则 / 宿主的 bug）。产品路径恒为 null。</summary>
    internal Func<string, Exception?>? InjectFault { get; set; }

    /// <summary>只读的 op：出了异常也不坏会话（读的时候在锁里、不改状态），回一条普通的错误。
    /// `query` 的参数是客户端发来的（观众也能发）—— 让它能把一局判坏，等于谁都能逼房间回退重起（10-01 复核）。
    /// `observe` / `save` 失败由 Godot 那边自己认（拿不到 envelope / 检查点久不更新，见 cw_net_pump.gd）。</summary>
    private static readonly HashSet<string> ReadOnlyOps = ["query", "observe", "save", "can_save", "tape", "dump_world", "version", "ping"];

    /// <summary>宿主自己发的、推进或交付对局的 op：没有「输入不合法」这一说，抛什么都是 bug ——
    /// 白名单里的四种异常在这里也算内部错误。以前它们回成普通拒绝：`ai_step` 被拒在 Godot 那边就是「AI 还没想好」，这一局悄悄停住（10-01 复核）</summary>
    private static readonly HashSet<string> InternalOps = ["ai_step", "pull", "discard_before", "abort"];

    /// <summary>
    /// 一条请求 → 一条回应。失败分三种：
    ///   · 拒绝（参数不对、问号对不上、没有这个会话…）：`ok:false` + error，会话照常能用 —— 只有带输入的 op 会拒；
    ///   · **内部错误**（规则 / 宿主的 bug 抛出来的异常）：这一局记成 <see cref="SessionHost.Broken"/>，回 `ok:false, broken:true`；
    ///     以前这种异常冲出读写循环、整个进程退出 —— 服务器一个进程扛所有房间，一处 bug 断掉全服的 C# 局（换内核 P8 复核，10-01）。
    ///     只读的 op（<see cref="ReadOnlyOps"/>）不判坏、回普通错误；宿主自己的 op（<see cref="InternalOps"/>）抛什么都判坏；
    ///   · 已经坏了的会话：除了 close 一律回 broken（状态可能只改了一半，别再往下走）。
    /// 报文头（op / sid）也在 try 里读：格式坏了只回一条错误，不能把进程带走。
    /// 进程级的崩溃（栈溢出、内存耗尽）接不住，那归 Godot 那边从检查点重起（cw_net_pump.gd:recover）。
    /// </summary>
    public JsonObject Handle(JsonObject req)
    {
        JsonNode? id = null;
        var op = "";
        SessionHost? target = null;
        try
        {
            id = req["id"]?.DeepClone();
            op = J.StrOr(req["op"]) ?? "";
            target = J.IntOr(req["sid"]) is { } sid ? sessions.GetValueOrDefault(sid) : null;
            if (op != "close" && target?.Broken is { } already)
                return BrokenReply(id, already);
            if (InjectFault?.Invoke(op) is { } injected) throw injected;
            var reply = Route(op, req);
            reply["re"] = id;
            reply["ok"] = true;
            return reply;
        }
        catch (Exception ex) when (target is null || ReadOnlyOps.Contains(op)
            || (!InternalOps.Contains(op) && ex is ArgumentException or InvalidOperationException or KeyNotFoundException or FormatException))
        {
            var known = ex is ArgumentException or InvalidOperationException or KeyNotFoundException or FormatException;
            return new JsonObject { ["re"] = id?.DeepClone(), ["ok"] = false, ["error"] = known ? ex.Message : $"sidecar 内部错误：{op} 时出错：{ex.GetType().Name}: {ex.Message}" };
        }
        catch (Exception ex)
        {
            target!.MarkBroken($"{op} 时出错：{ex.GetType().Name}: {ex.Message}");
            return BrokenReply(id, target.Broken!);
        }
    }

    private static JsonObject BrokenReply(JsonNode? id, string why)
        => new() { ["re"] = id?.DeepClone(), ["ok"] = false, ["error"] = $"这一局出了内部错误，已停用：{why}", ["broken"] = true };

    private JsonObject Route(string op, JsonObject req) => op switch
    {
        "ping" => [],
        "version" => Version(),
        "open" => Open(req),
        "pull" => Pull(req),
        "discard_before" => Do(req, s => s.DiscardBefore(J.Long(req["seq"]))),
        "answer" => new JsonObject { ["accepted"] = Session(req).Answer(J.Int(req["ask_id"]), J.StrOr(req["key"]), J.IntOr(req["index"]) ?? -1) },
        "observe" => new JsonObject { ["envelope"] = Session(req).Envelope(J.Int(req["viewer"]), J.LongOr(req["logs_from"]) ?? 0) },
        "query" => new JsonObject { ["result"] = Session(req).Query(J.Str(req["kind"]), req["args"]?.AsObject() ?? [], J.IntOr(req["seat"])) },
        "mark_player" => new JsonObject { ["ok_mark"] = Session(req).MarkPlayer(J.Int(req["pid"]), J.Str(req["suffix"])) },
        "surrender" => new JsonObject { ["ended"] = Session(req).Surrender(J.Int(req["faction"])) },
        "set_ai" => new JsonObject { ["withdrawn"] = Session(req).SetAi(J.Int(req["seat"]),
            req["tier"] is { } tier ? AiConfig.ParseTier(J.Str(tier)) : null, req["once"] is { } once && J.Bool(once)) },
        "ai_step" => new JsonObject { ["stepped"] = Session(req).StepAi() },
        "dump_world" => new JsonObject { ["world"] = Session(req).DumpWorld() },
        "tape" => Session(req).TapeStats(),
        "log_msg" => new JsonObject { ["logged"] = Session(req).LogMessage(J.Str(req["text"]), J.IntOr(req["secret_pid"]) ?? -1, J.StrOr(req["public_text"])) },
        "can_save" => new JsonObject { ["can_save"] = Session(req).CanSave },
        "save" => new JsonObject { ["checkpoint"] = Session(req).Save() },
        "restore" => Restore(req),
        "abort" => Do(req, s => s.Abort()),
        "close" => Close(req),
        _ => throw new ArgumentException($"未知 op「{op}」"),
    };

    public static JsonObject Version() => new()
    {
        ["host_abi"] = ObservationV1Codec.HostAbi,
        ["rules_build"] = ObservationV1Codec.RulesBuild,
        ["ruleset_digest"] = ObservationV1Codec.RulesBuild,   // 规则指纹定稿前与 rules_build 同值（与 MatchSession.Version 同口径）
        ["core_build"] = CoreBuild,
    };

    /// <summary>
    /// 这一份规则 dll 是哪次打的（P7）：`tools/build_sidecar.sh` 用 `-p:InformationalVersion=&lt;BUILD_ID&gt;` 烧进去
    ///（发版 = 提交号，补丁 = 补丁号），补丁探针挂上补丁、解包、起进程后读回它 —— 对不上就是压进了旧 dll。
    /// 开发期没烧，是 SDK 缺省的 1.0.0。
    /// </summary>
    public static readonly string CoreBuild =
        typeof(CellWar.Core.MatchSession).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";

    private JsonObject Open(JsonObject req)
    {
        var cfg = req["cfg"]?.AsObject() ?? throw new ArgumentException("open 缺 cfg");
        var sid = nextSid++;
        sessions[sid] = SessionHost.Open(sid, cfg);
        return new JsonObject { ["sid"] = sid };
    }

    private JsonObject Restore(JsonObject req)
    {
        var sid = nextSid++;
        sessions[sid] = SessionHost.Restore(sid, req);
        return new JsonObject { ["sid"] = sid };
    }

    private JsonObject Pull(JsonObject req)
    {
        var s = Session(req);
        return new JsonObject
        {
            ["entries"] = s.Pull(J.Int(req["viewer"]), J.LongOr(req["since"]) ?? 0, J.IntOr(req["limit"]) ?? 256),
            ["last_seq"] = s.LastSeq,
        };
    }

    private JsonObject Close(JsonObject req)
    {
        var sid = J.Int(req["sid"]);
        if (sessions.Remove(sid, out var s)) s.Dispose();
        return [];
    }

    private JsonObject Do(JsonObject req, Action<SessionHost> act)
    {
        act(Session(req));
        return [];
    }

    private SessionHost Session(JsonObject req)
    {
        var sid = J.IntOr(req["sid"]) ?? throw new ArgumentException("缺 sid");
        return sessions.TryGetValue(sid, out var s) ? s : throw new KeyNotFoundException($"没有会话 {sid}");
    }

    public void Dispose()
    {
        foreach (var s in sessions.Values) s.Dispose();
        sessions.Clear();
    }
}
