using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CellWar.Sidecar;

/// <summary>
/// 进程入口。Godot 侧（`cw_kernel_sidecar.gd`）先在 127.0.0.1 上开一个临时端口，再起本进程：
/// <code>
///   dotnet CellWar.Sidecar.dll --connect 127.0.0.1:&lt;端口&gt; --token &lt;一次性随机串&gt;
/// </code>
/// 本进程连回去，第一行发 `{"hello":{token, host_abi, rules_build, ruleset_digest, pid}}`（Godot 核 token，防别的本机进程冒充），
/// 之后一行一个 JSON 请求 / 回应（见 <see cref="Dispatcher"/>）。对端关连接 = 正常退出。
///
/// 退出码（计划 §四 P1）：0 正常；64 连不上；65 参数错；66 自检失败。
/// 另两个独立入口：`--version`（打印版本 JSON）、`--selftest`（进程内打一小局，过了退 0）。
/// </summary>
public static class Program
{
    public const int ExitConnect = 64;
    public const int ExitArgs = 65;
    public const int ExitSelfTest = 66;

    public static int Main(string[] args)
    {
        if (args.Contains("--version"))
        {
            Console.WriteLine(Dispatcher.Version().ToJsonString(Wire));
            return 0;
        }
        if (args.Contains("--selftest"))
        {
            var report = SelfTest.Run();
            Console.WriteLine(report.ToJsonString(Wire));
            return J.Bool(report["ok"]) ? 0 : ExitSelfTest;
        }
        var connect = Arg(args, "--connect");
        var token = Arg(args, "--token");
        if (connect is null || token is null || !TrySplit(connect, out var host, out var port))
        {
            Console.Error.WriteLine("用法：CellWar.Sidecar --connect 127.0.0.1:<端口> --token <串> | --version | --selftest");
            return ExitArgs;
        }
        TcpClient client;
        try
        {
            client = new TcpClient();
            if (!client.ConnectAsync(host, port).Wait(TimeSpan.FromSeconds(5)))
                throw new SocketException((int)SocketError.TimedOut);
        }
        catch (Exception ex) when (ex is SocketException or AggregateException)
        {
            Console.Error.WriteLine($"连不上 {connect}：{ex.Message}");
            return ExitConnect;
        }
        using (client)
            Serve(client.GetStream(), token);
        return 0;
    }

    /// <summary>一条连接的读写循环（测试直接拿一对回环流调它）。读到 EOF 返回。</summary>
    public static void Serve(Stream stream, string token)
    {
        var utf8 = new UTF8Encoding(false);
        using var reader = new StreamReader(stream, utf8, false, 1 << 16, leaveOpen: true);
        using var writer = new StreamWriter(stream, utf8, 1 << 16, leaveOpen: true) { NewLine = "\n", AutoFlush = false };
        var hello = Dispatcher.Version();
        hello["token"] = token;
        hello["pid"] = Environment.ProcessId;
        Write(writer, new JsonObject { ["hello"] = hello });

        using var dispatcher = new Dispatcher();
        while (reader.ReadLine() is { } line)
        {
            if (line.Length == 0) continue;
            JsonObject reply;
            try
            {
                reply = JsonNode.Parse(line) is JsonObject req
                    ? dispatcher.Handle(req)
                    : new JsonObject { ["ok"] = false, ["error"] = "请求不是 JSON 对象" };
            }
            catch (JsonException ex)
            {
                reply = new JsonObject { ["ok"] = false, ["error"] = $"坏 JSON：{ex.Message}" };
                // 解析不了也要把号带回去：Godot 那边按 re 认回应，认不到就干等 5 秒、判卡死、杀进程 ——
                // 服务器上一个进程扛所有房间，一条坏报文（观众发来的 query 里有 inf / 嵌套太深）就能把全服的 C# 局带走（10-01 复核）
                if (IdField.Match(line) is { Success: true } m && long.TryParse(m.Groups[1].Value, out var rid))
                    reply["re"] = rid;
            }
            Write(writer, reply);
        }
    }

    private static void Write(StreamWriter w, JsonObject msg)
    {
        w.WriteLine(msg.ToJsonString(Wire));
        w.Flush();
    }

    /// <summary>坏报文里捞请求号（只认报文开头那个 `"id":数字`，Godot 那边的请求都是这么拼的）。</summary>
    private static readonly Regex IdField = new(@"^\{\s*""id""\s*:\s*(-?\d+)", RegexOptions.CultureInvariant);

    /// <summary>中文不转义（GD 的 JSON.parse_string 吃得下，日志里也好读）。</summary>
    internal static readonly JsonSerializerOptions Wire = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private static string? Arg(string[] args, string name)
    {
        var i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    private static bool TrySplit(string hostPort, out string host, out int port)
    {
        var colon = hostPort.LastIndexOf(':');
        host = colon > 0 ? hostPort[..colon] : "";
        port = 0;
        return colon > 0 && int.TryParse(hostPort[(colon + 1)..], out port) && port > 0;
    }
}
