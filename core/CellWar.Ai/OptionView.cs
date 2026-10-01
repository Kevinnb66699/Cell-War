using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// 一条选项的 **GD 形状**（GD `options[i]["data"]` 的十三个键 + <c>cost</c>）。
/// GD 的策略代码读的就是这些字段，搬过来的策略照读 —— 一个字段一个属性，没有的就是 null。
/// <c>cid</c> / <c>from</c> / <c>to_cid</c> 是**席位**（SemanticKey 规矩 2，GD 的 cells 下标 = 席位）。
/// </summary>
public sealed class AiOption
{
    /// <summary>规范视图里的键：普通选项 = 语义键；组键（趋化源 / 免疫猎杀 / Excalibur）折成 GD 顶层那一问的「发动」键。</summary>
    public required string Key { get; init; }
    public string? Act { get; init; }
    public string? Card { get; init; }
    public int? Type { get; init; }
    public HexPosition? To { get; init; }
    public int? Cid { get; init; }
    public int? Dir { get; init; }
    public int? R { get; init; }
    public int? Pay { get; init; }
    public int? Get { get; init; }
    public int? From { get; init; }
    public int? ToCid { get; init; }
    public bool Stop { get; init; }
    public bool Skip { get; init; }
    /// <summary>GD data 里的 <c>cost</c>（引擎算好的报价；GD 那条选项没有这个键时为 null，策略按 0 读，同 GD <c>d.get("cost", 0)</c>）。</summary>
    public int? Cost { get; init; }
    /// <summary>这条选项对应的内核决策；折叠的组选项为 null（真决策在 <see cref="Children"/> 里）。</summary>
    public IDecision? Decision { get; init; }
    /// <summary>
    /// 组选项的「第二问」：GD 先问「发动」、再在结算里追问落点 / 目标（<c>chemo_target</c> / <c>effector_target</c>），
    /// C# 是一个决策。子项的 <see cref="Key"/> 是完整组键，<see cref="SubKey"/> 是 GD 那一问的键（规范序按它排）。
    /// </summary>
    public IReadOnlyList<AiOption> Children { get; init; } = [];
    public string? SubKey { get; init; }

    public int CostOr0 => Cost ?? 0;
}

/// <summary>
/// 一问的**规范视图**（GD 侧 <c>agree_rng.gd:canon_req</c> 的镜像，两边必须逐条同序）：
/// ① 去掉 C# 独有的 <c>pass</c>；② 组键折叠成 GD 顶层的「发动」那一条；③ 键相同只留第一条；
/// ④ 「停 / 放弃」（stop / skip）排最前 —— GD「可以不做的询问下标 0」约定，策略里 <c>range(1, n)</c> 跳过下标 0 靠它；
/// ⑤ 其余按语义键的字典序（Ordinal = GD String 的码点序，键里只有 BMP 字符）。
///
/// 为什么要规范序：两个内核的选项生成次序不同（C# 按坐标枚举、GD 按 DIRS 方向 / 手牌序），
/// 策略里「并列取第一个」的地方全都依赖次序。按键排之后答案只是局面的函数，与哪个内核生成选项无关。
/// </summary>
public sealed class AskView
{
    public required int Seat { get; init; }
    /// <summary>GD 的问答种类：action / setup_place / immune_revive / revive / free_move / pick / pick_cell / pick_tile。</summary>
    public required string Kind { get; init; }
    public string? Tag { get; init; }
    public required IReadOnlyList<AiOption> Options { get; init; }

    /// <summary>顶层问答（GD 的 <c>pending()</c> 会停下来的那四种）。其余是结算中途的追问，推演里由陪练当场答掉。</summary>
    public bool TopLevel => Kind is "action" or "setup_place" or "immune_revive" or "revive";

    public static string KindOf(WorldState s, IReadOnlyList<IDecision> decisions)
    {
        foreach (var d in decisions)
        {
            if (d is PassDecision) return "action";
            var kind = SemanticKey.Describe(s, d).Kind;
            return kind.StartsWith("action", StringComparison.Ordinal) ? "action" : kind;
        }
        return "";
    }

    public static AskView Build(WorldState s, int seat, IReadOnlyList<IDecision> decisions)
    {
        var rows = new List<AiOption>();
        var groups = new Dictionary<string, List<AiOption>>(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        string kind = "";
        string? tag = null;
        foreach (var d in decisions)
        {
            if (d is PassDecision) { kind = "action"; continue; }
            var parts = SemanticKey.Describe(s, d);
            var groupKind = parts.Kind switch
            {
                "action+chemo_target" => "chemo_target",
                "action+effector_target" => "effector_target",
                _ => null,
            };
            if (kind == "") { kind = groupKind != null ? "action" : parts.Kind; tag = parts.Tag; }
            var key = parts.Key;
            if (!seen.Add(key)) continue;
            if (groupKind != null)
            {
                // 「发动」那一条在 GD 顶层只有一份；落点 / 目标是追问（键 = 把 `k=action+X|act=Y|` 换成 `k=X|`）
                var act = (string)parts.Fields[0].Value;
                var collapsed = $"k=action|act={act}";
                var rest = string.Join("|", parts.Fields.Skip(1).Select(f => $"{f.Field}={Text(f.Value)}"));
                var filled = Fill(s, d, parts, key);
                var child = new AiOption
                {
                    Key = key, Act = filled.Act, To = filled.To, Cid = filled.Cid, Dir = filled.Dir,
                    Decision = d, SubKey = $"k={groupKind}|{rest}",
                };
                if (!groups.TryGetValue(collapsed, out var list))
                {
                    groups[collapsed] = list = [];
                    rows.Add(new AiOption { Key = collapsed, Act = act, Children = list });
                }
                list.Add(child);
                continue;
            }
            rows.Add(Fill(s, d, parts, key));
        }
        foreach (var list in groups.Values) list.Sort((a, b) => string.CompareOrdinal(a.SubKey, b.SubKey));
        rows.Sort(Canonical);
        return new AskView { Seat = seat, Kind = kind, Tag = tag, Options = rows };
    }

    /// <summary>规范序：停 / 放弃在前，其余按键（GD canon_req 同一把尺）。</summary>
    private static int Canonical(AiOption a, AiOption b)
    {
        var fa = a.Stop || a.Skip ? 0 : 1;
        var fb = b.Stop || b.Skip ? 0 : 1;
        return fa != fb ? fa.CompareTo(fb) : string.CompareOrdinal(a.Key, b.Key);
    }

    private static AiOption Fill(WorldState s, IDecision d, SemanticKey.Parts parts, string key)
    {
        string? act = null, card = null;
        int? type = null, cid = null, dir = null, r = null, pay = null, get = null, from = null, toCid = null;
        HexPosition? to = null;
        bool stop = false, skip = false;
        foreach (var (field, value) in parts.Fields)
        {
            switch (field)
            {
                case "act": act = (string)value; break;
                case "card": card = (string)value; break;
                case "type": type = (int)value; break;
                case "to": to = (HexPosition)value; break;
                case "cid": cid = SeatOf(value); break;
                case "dir": dir = (int)value; break;
                case "r": r = (int)value; break;
                case "pay": pay = (int)value; break;
                case "get": get = (int)value; break;
                case "from": from = SeatOf(value); break;
                case "to_cid": toCid = SeatOf(value); break;
                case "stop": stop = (bool)value; break;
                case "skip": skip = (bool)value; break;
            }
        }
        return new AiOption
        {
            Key = key, Act = act, Card = card, Type = type, To = to, Cid = cid, Dir = dir, R = r,
            Pay = pay, Get = get, From = from, ToCid = toCid, Stop = stop, Skip = skip,
            Cost = CostOf(s, d), Decision = d,
        };
    }

    /// <summary>
    /// GD data 里的 <c>cost</c>：只有三类选项带它（迁移 / 【炎症性趋化】第一步 / 趋化的后两步）。
    /// 一律转调内核报价，不在 AI 里算费（对拍时逐条比 GD 的数）。
    /// </summary>
    private static int? CostOf(WorldState s, IDecision d) => d switch
    {
        MoveDecision m => RulePolicies.QuoteMove(s, s.Cells[m.CellId], m.TargetPosition),
        PlayCardDecision { Card: "炎症性趋化", Target: { } t } p
            => RulePolicies.BaseMoveCost(s, s.Cells[p.CellId], t, CellRules.ChemotaxisStepCost),
        ChemotaxisStepDecision cx when (s.Turn.PendingWalkCard ?? "炎症性趋化") == "炎症性趋化"
            => RulePolicies.BaseMoveCost(s, s.Cells[cx.CellId], cx.Target, CellRules.ChemotaxisStepCost),
        _ => null,
    };

    private static int SeatOf(object v) => v is EntityId id ? (int)id.Value - 1 : (int)v;

    private static string Text(object v) => v switch
    {
        HexPosition p => $"{p.Q},{p.R}",
        EntityId id => ((int)id.Value - 1).ToString(),
        bool b => b ? "1" : "0",
        _ => v.ToString()!,
    };
}
