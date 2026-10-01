using System.Text.Json;
using System.Text.Json.Nodes;
using CellWar.Core;
using CellWar.Core.Observation;

namespace CellWar.Sidecar;

/// <summary>
/// 宿主对外的一问 —— 把 C# 的挂起询问折成 **GD 形状**（`cw_game.gd ask(pid, req)` 的 req），消费者（界面桥、教程闸、服务器）一行不用改。
///
/// 为什么要折：C# 把 GD 的「两问」并成了一条决策（语义键组键 `k=action+chemo_target|…` / `k=action+effector_target|…`，
/// 见 <see cref="SemanticKey"/> 头注规矩 3）。原样发出去，行动栏会冒出 127 个「趋化源→某格」按钮，
/// 教程闸按 `k=action|act=chemo` 前缀放行也对不上。所以这里照 GD 的问法分两次：
///   顶层只给一个入口（`act=chemo` / `act=effector`，标签照 `cw_actions.gd` 原文）→ 选了再开第二问（`chemo_target` / `effector_target`）
///   → 第二问答完才把**完整组键**交给内核。
/// C# 每问固定多出的 `PassDecision`（GD 没有）一并剔掉。
/// </summary>
internal sealed record HostAsk(int AskId, long RequestId, int Seat, string Kind, string? Tag, string Prompt,
    IReadOnlyList<HostOption> Options, bool IsSub)
{
    /// <summary>GD `CWData.CHEMO_COST`（十分能量）—— C# 观测编码器的价签也写死了这个数（ObservationV1Codec.Price）。</summary>
    private const int ChemoCost = 30;
    /// <summary>GD `CWData.EFFECTOR_COST`：效应应答的价钱是**效应记忆**点数，不是能量。</summary>
    private const int EffectorCost = 20;

    private const string ChemoGroup = "chemo_target";
    private const string EffectorGroup = "effector_target";

    /// <summary>从 C# 的全知 ask（<see cref="MatchSession.ObserveV1"/> 的 viewer = -2）折出顶层一问。</summary>
    public static HostAsk Top(int askId, ObsAsk cs, WorldState s)
    {
        var options = new List<HostOption>();
        var folded = new HashSet<string>(StringComparer.Ordinal);
        foreach (var o in cs.Options)
        {
            if (o.Key == SemanticKey.PassKey) continue;
            var group = GroupOf(o.Key);
            if (group is null)
            {
                options.Add(HostOption.From(o));
                continue;
            }
            if (!folded.Add(group)) continue;   // 同一组只出一个入口
            options.Add(group == ChemoGroup
                ? HostOption.Entry("k=action|act=chemo", $"趋化源（{Stage.Fmt(ChemoCost)} 能量）", "chemo", group)
                : HostOption.Entry("k=action|act=effector", $"效应应答·{EffectorName(o)}（{EffectorCost} 效应记忆）", "effector", group));
        }
        return new(askId, cs.AskId, cs.Seat, cs.Kind, cs.Tag, cs.Prompt, options, false);
    }

    /// <summary>选了组入口之后的第二问：成员照 GD `_do_chemo` / `_effector_hunt` / `_effector_excalibur` 的选项形状与文案。</summary>
    public static HostAsk Sub(int askId, HostAsk top, string group, ObsAsk cs, WorldState s)
    {
        var members = cs.Options.Where(o => GroupOf(o.Key) == group).ToArray();
        var options = new List<HostOption>();
        string prompt;
        if (group == ChemoGroup)
        {
            prompt = "选择趋化源的位置（全局任意一格）";
            foreach (var m in members)
            {
                var to = m.Data["to"];
                options.Add(HostOption.Member(group, Fields(("to", to)), $"趋化源→{P(to)}", m.Key));
            }
        }
        else if (members.Length > 0 && members[0].Data.ContainsKey("cid"))
        {
            prompt = "【免疫猎杀】选择一个癌细胞（全局任意）";
            foreach (var m in members)
            {
                var cid = m.Data["cid"];
                var cell = s.Cells[new EntityId((ulong)(cid.GetInt32() + 1))];
                options.Add(HostOption.Member(group, Fields(("cid", cid)), $"猎杀→{Stage.CellName(s, cell)}", m.Key));
            }
        }
        else
        {
            prompt = "【Excalibur】选择释放方向";
            foreach (var m in members)
                options.Add(HostOption.Member(group, Fields(("dir", m.Data["dir"]), ("to", m.Data["to"])), $"Excalibur→{P(m.Data["to"])}", m.Key));
        }
        return new(askId, top.RequestId, top.Seat, group, null, prompt, options, true);
    }

    public int IndexOfKey(string key)
    {
        for (var i = 0; i < Options.Count; i++)
            if (Options[i].Key == key) return i;
        return -1;
    }

    /// <summary>GD 的 req 形状（`ask` 条目的 `req`）：`{kind, tag?, pid, prompt, options:[{label, data, key}]}`。`key` 是给作答方省一次拼键（GD `CWSemKey.key(req, data)` 拼出来是同一个串）。</summary>
    public JsonObject ToReq()
    {
        var req = new JsonObject { ["kind"] = Kind, ["pid"] = Seat, ["prompt"] = Prompt };
        if (Tag is not null) req["tag"] = Tag;
        var arr = new JsonArray();
        foreach (var o in Options)
            arr.Add(new JsonObject { ["label"] = o.Label, ["data"] = o.Data.DeepClone(), ["key"] = o.Key });
        req["options"] = arr;
        return req;
    }

    /// <summary>观测协议 §6 的 ask 段（`sync` 里的 envelope 用它换掉 C# 未折叠的那份）。不是本人就只留 kind / tag / seat / prompt。</summary>
    public JsonObject ToObsAsk(long rev, bool mine)
    {
        var options = new JsonArray();
        var stop = -1;
        for (var i = 0; i < Options.Count; i++)
        {
            var o = Options[i];
            if (o.IsStop && stop < 0) stop = i;
            if (!mine) continue;
            options.Add(new JsonObject
            {
                ["index"] = i, ["key"] = o.Key, ["label"] = o.Label, ["data"] = o.Data.DeepClone(),
                ["cost"] = o.Cost, ["cost_rows"] = o.CostRows.DeepClone(), ["anchor"] = o.Anchor?.DeepClone(),
                ["is_stop"] = o.IsStop, ["is_attack"] = o.IsAttack, ["blocked"] = null,
            });
        }
        return new JsonObject
        {
            ["ask_id"] = AskId, ["rev"] = rev, ["kind"] = Kind, ["tag"] = Tag, ["seat"] = Seat, ["prompt"] = Prompt,
            ["mine"] = mine, ["stop_index"] = stop, ["options"] = options,
        };
    }

    /// <summary>组键 `k=action+chemo_target|…` → `chemo_target`；不是组键返回 null。</summary>
    private static string? GroupOf(string key)
    {
        var head = key.Split('|')[0];
        var plus = head.IndexOf('+');
        return plus < 0 ? null : head[(plus + 1)..];
    }

    /// <summary>【效应应答】入口的名字：带 `cid` 的是树突【免疫猎杀】，带方向的是 T【Excalibur】（另两种不选目标，不走组键）。</summary>
    private static string EffectorName(ObsOption o) => o.Data.ContainsKey("cid") ? "免疫猎杀" : "Excalibur";

    private static JsonObject Fields(params (string Name, JsonElement Value)[] fields)
    {
        var d = new JsonObject();
        foreach (var (name, value) in fields) d[name] = JsonNode.Parse(value.GetRawText());
        return d;
    }

    /// <summary>GD `str(Vector2i)`：`(q, r)`，逗号后带空格。</summary>
    private static string P(JsonElement pos) => $"({pos.GetProperty("q").GetInt32()}, {pos.GetProperty("r").GetInt32()})";
}

/// <summary>
/// 一个对外选项。<see cref="SubmitKey"/> = 选中后交给内核的语义键（C# 的完整键）；组入口没有（它只是开第二问的门），<see cref="Group"/> 记它开哪一问。
/// </summary>
internal sealed record HostOption(string Key, string Label, JsonObject Data, int? Cost, JsonArray CostRows, JsonNode? Anchor,
    bool IsStop, bool IsAttack, string? SubmitKey, string? Group)
{
    public static HostOption From(ObsOption o)
    {
        var data = new JsonObject();
        foreach (var (k, v) in o.Data) data[k] = JsonNode.Parse(v.GetRawText());
        var rows = JsonSerializer.SerializeToNode(o.CostRows, ObservationV1Codec.Json)!.AsArray();
        var anchor = o.Anchor is null ? null : JsonSerializer.SerializeToNode(o.Anchor, ObservationV1Codec.Json);
        return new(o.Key, o.Label, data, o.Cost, rows, anchor, o.IsStop, o.IsAttack, o.Key, null);
    }

    public static HostOption Entry(string key, string label, string act, string group)
        => new(key, label, new JsonObject { ["act"] = act }, null, [], null, false, false, null, group);

    /// <summary>第二问的成员：对外键按 GD 的问法拼（`k=chemo_target|to=q,r` 等），提交时换回 C# 的完整组键。</summary>
    public static HostOption Member(string kind, JsonObject data, string label, string submitKey)
        => new(KeyOf(kind, data), label, data, null, [], null, false, false, submitKey, null);

    /// <summary>
    /// 与 GD `CWSemKey.key(req, data)` 同一套文法（字段按 <see cref="SemanticKey.FieldOrder"/>、坐标 `q,r`、bool 1/0）。
    /// 第二问的数据只有 to / cid / dir 三种字段，这里只认得这三种值形。
    /// </summary>
    private static string KeyOf(string kind, JsonObject data)
    {
        var parts = new List<string> { $"k={kind}" };
        foreach (var f in SemanticKey.FieldOrder)
        {
            if (data[f] is not { } v) continue;
            parts.Add(v is JsonObject p ? $"{f}={J.Int(p["q"])},{J.Int(p["r"])}" : $"{f}={v.ToJsonString()}");
        }
        return string.Join("|", parts);
    }
}
