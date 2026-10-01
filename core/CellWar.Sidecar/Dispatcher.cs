using System.Text.Json.Nodes;
using CellWar.Core.Observation;

namespace CellWar.Sidecar;

/// <summary>
/// 一条连接上的报文分派。请求 `{"id":n,"op":"…","sid":会话,…}` → 回应 `{"re":n,"ok":true,…}` 或 `{"re":n,"ok":false,"error":"…"}`。
/// sidecar 从不主动推送：条目由句柄每帧 `pull`。
///
/// 会话 `sid` 从第一版就带（桌面只有一局；服务器一个进程跑所有房间，计划 §3.1）。
/// 报文一览（P1）：
///   version{}                                       → {host_abi, rules_build, ruleset_digest}
///   open{factions[], seed, observe_viewer?, open_hands?} → {sid}
///   pull{sid, viewer, since, limit?}                → {entries[], last_seq}
///   discard_before{sid, seq}                        → {}
///   answer{sid, ask_id, key?, index?}               → {accepted}
///   observe{sid, viewer, logs_from?}                → {envelope}
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
        "abort" => Do(req, s => s.Abort()),
        "close" => Close(req),
        _ => throw new ArgumentException($"未知 op「{op}」"),
    };

    public static JsonObject Version() => new()
    {
        ["host_abi"] = ObservationV1Codec.HostAbi,
        ["rules_build"] = ObservationV1Codec.RulesBuild,
        ["ruleset_digest"] = ObservationV1Codec.RulesBuild,   // 规则指纹定稿前与 rules_build 同值（与 MatchSession.Version 同口径）
    };

    private JsonObject Open(JsonObject req)
    {
        var cfg = req["cfg"]?.AsObject() ?? throw new ArgumentException("open 缺 cfg");
        var sid = nextSid++;
        sessions[sid] = SessionHost.Open(sid, cfg);
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
