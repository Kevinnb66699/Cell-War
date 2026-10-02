using System.Text.Json.Nodes;
using CellWar.Sidecar;

namespace CellWar.Core.Tests.Sidecar;

/// <summary>
/// 换内核 P8 复核（10-01）：规则 / 宿主的 bug 只坏出事的那一局。以前 Dispatcher 只接四种「拒绝」异常，
/// 别的异常（空引用、越界…）冲出读写循环、整个进程退出 —— 服务器一个进程扛所有房间，一处 bug 断掉全服的 C# 局。
/// 现在：那一局记成 Broken、回 `broken:true`，之后除了 close 一律 broken；同一进程里别的会话照常。
/// </summary>
public class SidecarDispatcherFaultTests
{
    private static JsonObject Cfg(int seed)
        => new() { ["factions"] = new JsonArray(0, 1), ["seed"] = seed };

    private static int Open(Dispatcher d, int seed)
        => J.Int(d.Handle(new JsonObject { ["id"] = 1, ["op"] = "open", ["cfg"] = Cfg(seed) })["sid"]);

    private static JsonObject Pull(Dispatcher d, int sid)
        => d.Handle(new JsonObject { ["id"] = 9, ["op"] = "pull", ["sid"] = sid, ["viewer"] = -2, ["since"] = 0 });

    [Fact]
    public void 一局里抛出内部异常_只坏这一局_别的会话照常()
    {
        using var d = new Dispatcher();
        var a = Open(d, 2222);
        var b = Open(d, 4444);
        var askA = Pull(d, a)["entries"]!.AsArray().Select(n => n!.AsObject()).Last(e => J.Str(e["t"]) == "ask");

        d.InjectFault = op => op == "answer" ? new NullReferenceException("测试注入") : null;
        var r = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "answer", ["sid"] = a, ["ask_id"] = J.Int(askA["ask_id"]), ["index"] = 0 });
        d.InjectFault = null;
        Assert.False(J.Bool(r["ok"]));
        Assert.True(J.Bool(r["broken"]));
        Assert.Contains("NullReferenceException", J.Str(r["error"]));

        // 坏掉的那一局：之后的请求一律 broken（状态可能只改了一半）
        var again = Pull(d, a);
        Assert.False(J.Bool(again["ok"]));
        Assert.True(J.Bool(again["broken"]));
        // 同一进程里的另一局照常
        var pb = Pull(d, b);
        Assert.True(J.Bool(pb["ok"]));
        Assert.Contains(pb["entries"]!.AsArray(), e => J.Str(e!["t"]) == "ask");
        // 坏掉的那一局还能 close（句柄转 FAULTED 时发的就是它），close 之后会话就没了
        Assert.True(J.Bool(d.Handle(new JsonObject { ["id"] = 3, ["op"] = "close", ["sid"] = a })["ok"]));
        var gone = Pull(d, a);
        Assert.False(J.Bool(gone["ok"]));
        Assert.Null(gone["broken"]);   // 没有这个会话 = 普通拒绝，不是 broken
    }

    [Fact]
    public void 宿主自己的op抛白名单异常也算内部错误_不然ai_step被拒就悄悄停住()
    {
        using var d = new Dispatcher();
        var a = Open(d, 2222);
        d.InjectFault = op => op == "ai_step" ? new InvalidOperationException("测试注入：规则 bug 恰好抛了白名单里的类型") : null;
        var r = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "ai_step", ["sid"] = a });
        d.InjectFault = null;
        Assert.False(J.Bool(r["ok"]));
        Assert.True(J.Bool(r["broken"]));
        Assert.True(J.Bool(Pull(d, a)["broken"]));
    }

    [Fact]
    public void 只读op出了内部错误不判坏_观众的query逼不了房间重起()
    {
        using var d = new Dispatcher();
        var a = Open(d, 2222);
        d.InjectFault = op => op == "query" ? new NullReferenceException("测试注入") : null;
        var r = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "query", ["sid"] = a, ["kind"] = "reachable", ["args"] = new JsonObject() });
        d.InjectFault = null;
        Assert.False(J.Bool(r["ok"]));
        Assert.Null(r["broken"]);
        Assert.Contains("NullReferenceException", J.Str(r["error"]));
        Assert.True(J.Bool(Pull(d, a)["ok"]));   // 会话照常
    }

    [Fact]
    public void 报文头格式坏了只回错误_不把进程带走()
    {
        using var d = new Dispatcher();
        var a = Open(d, 2222);
        var r = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "pull", ["sid"] = "不是数字", ["viewer"] = -2 });
        Assert.False(J.Bool(r["ok"]));
        Assert.Null(r["broken"]);
        var r2 = d.Handle(new JsonObject { ["id"] = 3, ["op"] = new JsonArray(1, 2), ["sid"] = a });
        Assert.False(J.Bool(r2["ok"]));
        Assert.True(J.Bool(Pull(d, a)["ok"]));
    }

    [Fact]
    public void 拒绝不算内部错误_会话照常能用()
    {
        using var d = new Dispatcher();
        var a = Open(d, 2222);
        var bad = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "set_ai", ["sid"] = a, ["seat"] = 1, ["tier"] = "mcts" });
        Assert.False(J.Bool(bad["ok"]));
        Assert.Null(bad["broken"]);
        Assert.True(J.Bool(Pull(d, a)["ok"]));
    }

    [Fact]
    public void 没有会话的请求出了内部错误_不连累别的会话()
    {
        using var d = new Dispatcher();
        var a = Open(d, 2222);
        d.InjectFault = op => op == "version" ? new IndexOutOfRangeException("测试注入") : null;
        var r = d.Handle(new JsonObject { ["id"] = 2, ["op"] = "version" });
        d.InjectFault = null;
        Assert.False(J.Bool(r["ok"]));
        Assert.Null(r["broken"]);
        Assert.True(J.Bool(Pull(d, a)["ok"]));
    }
}
