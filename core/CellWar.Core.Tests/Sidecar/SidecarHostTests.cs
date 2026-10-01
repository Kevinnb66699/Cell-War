using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CellWar.Core.Observation;
using CellWar.Sidecar;

namespace CellWar.Core.Tests.Sidecar;

/// <summary>
/// 换内核 P1 的 C# 半边验收（docs/内核替换_重启计划.md §四 P1）：
/// ① 宿主条目流与 GD `CWKernelInProc` 同节拍（step_end → sync → ask；终局前 step_end → sync → game_over；step_begin 带刚答的 ask id）；
/// ② C# 的组键折回 GD 的两问（顶层一个入口 + 第二问），Pass 不上线；
/// ③ 报文层：回环连接上 hello 带回 token，open / pull / answer / observe / close 往返；
/// ④ 真进程：`--selftest` 退 0、缺参数退 65、连不上退 64。
/// </summary>
public class SidecarHostTests
{
    [Theory]
    [InlineData(2, 2222)]
    [InlineData(4, 4242)]
    [InlineData(6, 6666)]
    public void 整局打到终局_条目流与InProc同节拍(int players, int seed)
    {
        var factions = new JsonArray(Enumerable.Range(0, players).Select(i => (JsonNode)(i % 2)).ToArray());
        var walk = SelfTest.Drive(new JsonObject { ["factions"] = factions, ["seed"] = seed, ["observe_viewer"] = -2 }, maxAnswers: 6000, lcgSeed: (ulong)seed);

        Assert.True(walk.GameOver, $"{players} 人局 {walk.Answers} 次作答后还没终局");
        Assert.Empty(walk.Violations);
        Assert.Contains("setup_place", walk.Kinds);
        Assert.Contains("action", walk.Kinds);
        // 每一份 sync 都装得回观测协议的记录（与 GD CWMirror 读的是同一份 JSON）
        foreach (var e in walk.Entries.Where(e => J.Str(e["t"]) == "sync"))
            ObservationV1Codec.Deserialize(e["envelope"]!.ToJsonString());
    }

    [Fact]
    public void 观众拿到的ask条目不带选项_本人拿到完整选项()
    {
        using var host = SessionHost.Open(1, new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 7, ["observe_viewer"] = 0 });
        var ask = host.Pull(-1, 0, 1000).Select(n => n!.AsObject()).Last(e => J.Str(e["t"]) == "ask");
        var seat = J.Int(ask["req"]!["pid"]);
        Assert.Empty(ask["req"]!["options"]!.AsArray());
        var mine = host.Pull(seat, 0, 1000).Select(n => n!.AsObject()).Last(e => J.Str(e["t"]) == "ask");
        Assert.NotEmpty(mine["req"]!["options"]!.AsArray());
    }

    // ---- 拆问 ----

    private static ObsOption Opt(int i, string key, string label, params (string, object)[] data)
        => new(i, key, label, data.ToDictionary(d => d.Item1, d => JsonSerializer.SerializeToElement(d.Item2, ObservationV1Codec.Json), StringComparer.Ordinal),
            null, [], null, false, false, null);

    private static ObsAsk ActionAsk(params ObsOption[] options) => new(5, 1, "action", null, 0, "选择行动", true, -1, options);

    [Fact]
    public void 趋化源组键折成一个入口_第二问按GD的键与文案()
    {
        var s = DemoScenario.Create();
        var cs = ActionAsk(
            Opt(0, SemanticKey.PassKey, "跳过", ("act", "pass")),
            Opt(1, "k=action|act=end", "结束回合", ("act", "end")),
            Opt(2, "k=action+chemo_target|act=chemo|to=0,1", "x", ("act", "chemo"), ("to", new ObsPos(0, 1))),
            Opt(3, "k=action+chemo_target|act=chemo|to=-2,3", "x", ("act", "chemo"), ("to", new ObsPos(-2, 3))));

        var top = HostAsk.Top(1, cs, s);
        Assert.Equal(["k=action|act=end", "k=action|act=chemo"], top.Options.Select(o => o.Key));
        var entry = top.Options[1];
        Assert.Equal("趋化源（3.0 能量）", entry.Label);
        Assert.Equal("chemo_target", entry.Group);
        Assert.Null(entry.SubmitKey);

        var sub = HostAsk.Sub(2, top, "chemo_target", cs, s);
        Assert.Equal("chemo_target", sub.Kind);
        Assert.Equal("选择趋化源的位置（全局任意一格）", sub.Prompt);
        Assert.Equal(["k=chemo_target|to=0,1", "k=chemo_target|to=-2,3"], sub.Options.Select(o => o.Key));
        Assert.Equal(["趋化源→(0, 1)", "趋化源→(-2, 3)"], sub.Options.Select(o => o.Label));
        Assert.Equal("k=action+chemo_target|act=chemo|to=-2,3", sub.Options[1].SubmitKey);
        Assert.Equal(cs.AskId, sub.RequestId);
    }

    [Fact]
    public void Excalibur组键的第二问带方向与落点_键照GD字段顺序()
    {
        var s = DemoScenario.Create();
        var cs = ActionAsk(
            Opt(0, "k=action+effector_target|act=effector|to=1,0|dir=0", "x", ("act", "effector"), ("to", new ObsPos(1, 0)), ("dir", 0)),
            Opt(1, "k=action+effector_target|act=effector|to=0,1|dir=5", "x", ("act", "effector"), ("to", new ObsPos(0, 1)), ("dir", 5)));
        var top = HostAsk.Top(1, cs, s);
        Assert.Equal("效应应答·Excalibur（20 效应记忆）", Assert.Single(top.Options).Label);
        var sub = HostAsk.Sub(2, top, "effector_target", cs, s);
        Assert.Equal("【Excalibur】选择释放方向", sub.Prompt);
        Assert.Equal("k=effector_target|to=0,1|dir=5", sub.Options[1].Key);
        Assert.Equal("Excalibur→(0, 1)", sub.Options[1].Label);
    }

    // ---- 报文层 ----

    [Fact]
    public async Task 回环连接_hello带回token_open_pull_answer_close往返()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var serve = Task.Run(() =>
        {
            using var c = new TcpClient();
            c.Connect(IPAddress.Loopback, port);
            Program.Serve(c.GetStream(), "tok-123");
        });
        using var server = await listener.AcceptTcpClientAsync();
        listener.Stop();
        var stream = server.GetStream();
        var reader = new StreamReader(stream, new UTF8Encoding(false));
        var writer = new StreamWriter(stream, new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
        async Task<JsonObject> Call(JsonObject req)
        {
            await writer.WriteLineAsync(req.ToJsonString());
            return JsonNode.Parse((await reader.ReadLineAsync())!)!.AsObject();
        }

        var hello = JsonNode.Parse((await reader.ReadLineAsync())!)!["hello"]!;
        Assert.Equal("tok-123", J.Str(hello["token"]));
        Assert.Equal(ObservationV1Codec.HostAbi, J.Int(hello["host_abi"]));

        var opened = await Call(new JsonObject { ["id"] = 1, ["op"] = "open", ["cfg"] = new JsonObject { ["factions"] = new JsonArray(0, 1), ["seed"] = 2222, ["observe_viewer"] = -2 } });
        Assert.True(J.Bool(opened["ok"]));
        var sid = J.Int(opened["sid"]);
        var pulled = await Call(new JsonObject { ["id"] = 2, ["op"] = "pull", ["sid"] = sid, ["viewer"] = -2, ["since"] = 0 });
        var ask = pulled["entries"]!.AsArray().Select(n => n!.AsObject()).Last(e => J.Str(e["t"]) == "ask");
        var key = J.Str(ask["req"]!["options"]![0]!["key"]);
        var answered = await Call(new JsonObject { ["id"] = 3, ["op"] = "answer", ["sid"] = sid, ["ask_id"] = ask["ask_id"]!.DeepClone(), ["key"] = key });
        Assert.True(J.Bool(answered["accepted"]));
        var stale = await Call(new JsonObject { ["id"] = 4, ["op"] = "answer", ["sid"] = sid, ["ask_id"] = ask["ask_id"]!.DeepClone(), ["key"] = key });
        Assert.False(J.Bool(stale["accepted"]));   // 同一问答两次：第二次拒
        var env = await Call(new JsonObject { ["id"] = 5, ["op"] = "observe", ["sid"] = sid, ["viewer"] = 0 });
        ObservationV1Codec.Deserialize(env["envelope"]!.ToJsonString());
        var bad = await Call(new JsonObject { ["id"] = 6, ["op"] = "nope" });
        Assert.False(J.Bool(bad["ok"]));
        Assert.Equal(6, J.Int(bad["re"]));
        Assert.True(J.Bool((await Call(new JsonObject { ["id"] = 7, ["op"] = "close", ["sid"] = sid }))["ok"]));

        server.Close();   // 对端关连接 = sidecar 正常退出
        await serve.WaitAsync(TimeSpan.FromSeconds(10));
    }

    // ---- 真进程 ----

    private static string SidecarDll()
    {
        var dir = AppContext.BaseDirectory;   // …/core/CellWar.Core.Tests/bin/<配置>/net10.0/
        var config = new DirectoryInfo(dir).Parent!.Name;
        var dll = Path.GetFullPath(Path.Combine(dir, "..", "..", "..", "..", "CellWar.Sidecar", "bin", config, "net10.0", "CellWar.Sidecar.dll"));
        Assert.True(File.Exists(dll), $"找不到 sidecar 产物：{dll}（先 dotnet build core/CellWar.Sidecar）");
        return dll;
    }

    private static (int Code, string Out) Run(params string[] args)
    {
        var dotnet = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet";
        var psi = new ProcessStartInfo(dotnet) { RedirectStandardOutput = true, RedirectStandardError = true };
        psi.ArgumentList.Add("exec");
        psi.ArgumentList.Add(SidecarDll());
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var out_ = p.StandardOutput.ReadToEnd();
        p.WaitForExit(30_000);
        return (p.ExitCode, out_);
    }

    [Fact]
    public void 真进程_自检退0_缺参数退65_连不上退64()
    {
        var (code, output) = Run("--selftest");
        Assert.Equal(0, code);
        Assert.True(J.Bool(JsonNode.Parse(output)!["ok"]));

        Assert.Equal(Program.ExitArgs, Run("--connect", "127.0.0.1:1").Code);   // 缺 --token

        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();   // 端口刚放掉，连过去必被拒
        Assert.Equal(Program.ExitConnect, Run("--connect", $"127.0.0.1:{port}", "--token", "t").Code);
    }
}
