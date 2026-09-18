using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using CellWar.Core.Observation;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>三类 expect（规格 A-1 / §0.6.2 第 2 条）。</summary>
public enum ExpectKind
{
    /// <summary>**裸整数**。45 条老用例一字不改，`{"kind":"scalar"}` 这种写法两侧都不接受。</summary>
    Scalar,

    /// <summary>一棵字面 JSON 树，逐字段比（`quote_path` 的 `{ok,stop,total,left,gained,steps[]}` 这类）。</summary>
    Tree,

    /// <summary>envelope 的差分集合，**整集合比**（S 族全部）。</summary>
    Delta,
}

/// <summary>
/// 用例的期望值：`scalar` / `tree` / `delta` 三类的联合体（schema `cwxcase/2`）。
///
/// JSON 上的三种写法：
/// * 裸整数 `"expect": 45`（= scalar）；
/// * `{ "kind": "tree", "value": &lt;树&gt; }`；
/// * `{ "kind": "delta", "changed": { 路径: 值 }, "ignore": [ 路径 ] }`。
///
/// **`{"kind":"scalar"}` 拒收**（§0.6.2 第 2 条）—— 两种写法并存就会出现「一侧收一侧不收」的分叉。
///
/// **`delta` 用整集合比、不用包含比**：包含比只钉「该变的变了」，钉不住「不该变的没变」。
/// 这是录制路线上唯一能机制性证明「搬的不是空气」的证据（规格 A-1）。
/// </summary>
[JsonConverter(typeof(L0ExpectConverter))]
public sealed record L0Expect
{
    public required ExpectKind Kind { get; init; }

    /// <summary>`scalar`：单位一律是**十分能量 / 千分率**的整数 —— 与内核内部同一套单位。</summary>
    public long Scalar { get; init; }

    /// <summary>`tree`：一棵字面 JSON 树。</summary>
    public JsonNode? Tree { get; init; }

    /// <summary>`delta`：路径 → 变成了什么（整条消失记 `null`）。路径文法见 <see cref="Subset"/>。</summary>
    public IReadOnlyDictionary<string, JsonNode?> Changed { get; init; }
        = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);

    /// <summary>`delta` 的**单条**豁免。全局豁免表只许有一份，在 <see cref="Subset"/> 的调用点上。</summary>
    public IReadOnlyList<string> Ignore { get; init; } = [];

    /// <summary>
    /// `scalar` 与 `tree` 的判定：**null = 过**，否则一句差异。
    /// （`delta` 要 pre / post 两份 envelope，判定在 runner 里走 <see cref="Subset"/>。）
    /// </summary>
    public static string? Judge(object actual, L0Expect e)
    {
        switch (e.Kind)
        {
            case ExpectKind.Scalar:
                var got = Convert.ToInt64(actual);
                return got == e.Scalar ? null : $"期望 {e.Scalar}，C# 算出 {got}";
            case ExpectKind.Tree:
                var diffs = DeepDiff.Compare(Plain(e.Tree), Plain(actual), "$", 20);
                return diffs.Count == 0 ? null : $"树不一样（{diffs.Count} 处）：{string.Join("；", diffs.Take(4))}";
            default:
                throw new InvalidOperationException("delta 的判定要 pre / post 两份 envelope —— 走 Subset.Diff，不走 L0Expect.Judge");
        }
    }

    /// <summary>JSON 树 → 与 <see cref="L1View.Plain"/> 同型的字典 / 列表 / long / bool / string 树。</summary>
    internal static object? Plain(JsonNode? node)
        => node is null ? null : L1View.Plain(JsonDocument.Parse(node.ToJsonString()).RootElement);

    /// <summary>探针返回的对象 → 同一套 plain 树（`quote_path` 那类记录直接序列化）。</summary>
    internal static object? Plain(object? actual)
        => actual is null ? null : L1View.Plain(JsonSerializer.SerializeToElement(actual, ObservationV1Codec.Json));
}

/// <summary>裸整数 / 带 kind 的对象两种写法（未知键当场炸 —— 手写转换器不吃 `UnmappedMemberHandling`，得自己查）。</summary>
public sealed class L0ExpectConverter : JsonConverter<L0Expect>
{
    private static readonly string[] TreeKeys = ["kind", "value"];
    private static readonly string[] DeltaKeys = ["kind", "changed", "ignore"];

    public override L0Expect Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.ValueKind == JsonValueKind.Number)
            return new L0Expect { Kind = ExpectKind.Scalar, Scalar = root.GetInt64() };
        if (root.ValueKind != JsonValueKind.Object)
            throw new JsonException($"expect 只认裸整数或带 kind 的对象，拿到的是 {root.ValueKind}");

        var kind = root.TryGetProperty("kind", out var k) ? k.GetString() : throw new JsonException("expect 对象缺 kind");
        switch (kind)
        {
            case "scalar":
                throw new JsonException("expect 的 scalar 只写**裸整数**（§0.6.2 第 2 条）—— `{\"kind\":\"scalar\"}` 两侧都不接受");
            case "tree":
                Only(root, TreeKeys);
                if (!root.TryGetProperty("value", out var v)) throw new JsonException("expect.kind=tree 缺 value");
                return new L0Expect { Kind = ExpectKind.Tree, Tree = JsonNode.Parse(v.GetRawText()) };
            case "delta":
                Only(root, DeltaKeys);
                var changed = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
                if (root.TryGetProperty("changed", out var ch))
                {
                    if (ch.ValueKind != JsonValueKind.Object) throw new JsonException("expect.changed 要是「路径 → 值」的对象");
                    foreach (var p in ch.EnumerateObject()) changed[p.Name] = JsonNode.Parse(p.Value.GetRawText());
                }
                var ignore = new List<string>();
                if (root.TryGetProperty("ignore", out var ig))
                    foreach (var x in ig.EnumerateArray())
                        ignore.Add(x.GetString() ?? throw new JsonException("expect.ignore 里有不是字符串的条目"));
                return new L0Expect { Kind = ExpectKind.Delta, Changed = changed, Ignore = ignore };
            default:
                throw new JsonException($"不认识的 expect.kind：{kind}（只认 tree / delta；scalar 写裸整数）");
        }
    }

    private static void Only(JsonElement obj, string[] allowed)
    {
        foreach (var p in obj.EnumerateObject())
            if (!allowed.Contains(p.Name, StringComparer.Ordinal))
                throw new JsonException($"expect 里有不认识的键「{p.Name}」（许可：{string.Join(" / ", allowed)}）");
    }

    public override void Write(Utf8JsonWriter writer, L0Expect value, JsonSerializerOptions options)
        => throw new NotSupportedException("用例是人写的，runner 不回写 expect");
}
