using System.Reflection;
using System.Text.Json.Nodes;
using CellWar.Core.Observation;

namespace CellWar.Sidecar;

/// <summary>
/// 一条连接上的报文分派。请求 `{"id":n,"op":"…","sid":会话,…}` → 回应 `{"re":n,"ok":true,…}` 或 `{"re":n,"ok":false,"error":"…"}`。
/// sidecar 从不主动推送：条目由句柄每帧 `pull`。
///
/// 会话 `sid` 从第一版就带（桌面只有一局；服务器一个进程跑所有房间，计划 §3.1）。
/// 报文一览（P1）：
///   version{}                                       → {host_abi, rules_build, ruleset_digest, core_build}
///   open{cfg:{factions[], seed, observe_viewer?, open_hands?, names?[], cancer_types?[], ai?: {"席位": "normal"|"intent"|"search"}, ai_delay_ms?}} → {sid}
///     （ai 里的席位由 sidecar 内的 CellWar.Ai 在后台线程作答：不出 ask 条目，句柄照常 pull，见 SessionHost 头注）
///   open{cfg:{world: cwxworld/3, rolls?: [[from,to,value]…], seed?, observe_viewer?, open_hands?, names?[]}} → {sid}（新手教程：从装载世界续跑）
///   dump_world{sid}                                 → {world}（活局面导成 cwxworld/3）
///   pull{sid, viewer, since, limit?}                → {entries[], last_seq}
///   discard_before{sid, seq}                        → {}
///   answer{sid, ask_id, key?, index?}               → {accepted}
///   observe{sid, viewer, logs_from?}                → {envelope}
///   query{sid, kind, args, seat?}                   → {result}（观测协议 §5.3 四条；坐标 {q,r}）
///   mark_player{sid, pid, suffix}                   → {ok_mark}
///   surrender{sid, faction}                         → {ended}
///   log_msg{sid, text, secret_pid?, public_text?}   → {logged}（宿主插一行日志 = GD log_msg）
///   can_save{sid} → {can_save} · save{sid} → {checkpoint|null} · restore{checkpoint, observe_viewer?, open_hands?} → {sid}
///   abort{sid} / close{sid}                         → {}
///   ping{}                                          → {}
/// </summary>
internal sealed class Dispatcher : IDisposable
{
    private readonly Dictionary<int, SessionHost> sessions = [];
    private int nextSid = 1;

    public JsonObject Handle(JsonObject req)
    {
        var id = req["id"]?.DeepClone();
        try
        {
            var reply = Route(J.StrOr(req["op"]) ?? "", req);
            reply["re"] = id;
            reply["ok"] = true;
            return reply;
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or KeyNotFoundException or FormatException)
        {
            return new JsonObject { ["re"] = id, ["ok"] = false, ["error"] = ex.Message };
        }
    }

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
        "dump_world" => new JsonObject { ["world"] = Session(req).DumpWorld() },
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
        var json = J.Str(req["checkpoint"]);
        var sid = nextSid++;
        sessions[sid] = SessionHost.Restore(sid, json, J.IntOr(req["observe_viewer"]), req["open_hands"] is { } oh && J.Bool(oh));
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
