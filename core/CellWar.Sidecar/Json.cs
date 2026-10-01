using System.Text.Json;
using System.Text.Json.Nodes;

namespace CellWar.Sidecar;

/// <summary>
/// JsonNode 取数助手。`(long)node` 这类显式转换按节点的**原始 CLR 类型**严格匹配：
/// 从文本解析出来的数字节点什么都能转，程序里 `node["x"] = 3` 造的是 JsonValue&lt;int&gt;，转 long 当场抛异常。
/// 宿主里两种节点混着走（报文是解析的、条目是自己造的），一律经这里取。
/// </summary>
internal static class J
{
    public static long Long(JsonNode? n)
    {
        if (n is JsonValue v)
        {
            if (v.TryGetValue<long>(out var l)) return l;
            if (v.TryGetValue<int>(out var i)) return i;
            if (v.TryGetValue<ulong>(out var u)) return checked((long)u);
            if (v.TryGetValue<JsonElement>(out var e) && e.ValueKind == JsonValueKind.Number) return e.GetInt64();
            if (v.TryGetValue<double>(out var d) && d == Math.Floor(d)) return checked((long)d);
        }
        throw new FormatException($"要整数，拿到的是 {n?.ToJsonString() ?? "null"}");
    }

    public static int Int(JsonNode? n) => checked((int)Long(n));

    public static long? LongOr(JsonNode? n) => n is null ? null : Long(n);

    public static int? IntOr(JsonNode? n) => n is null ? null : Int(n);

    public static bool Bool(JsonNode? n) => n is JsonValue v && v.TryGetValue<bool>(out var b) ? b
        : throw new FormatException($"要布尔，拿到的是 {n?.ToJsonString() ?? "null"}");

    public static string Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s
        : throw new FormatException($"要字符串，拿到的是 {n?.ToJsonString() ?? "null"}");

    public static string? StrOr(JsonNode? n) => n is null ? null : Str(n);
}
