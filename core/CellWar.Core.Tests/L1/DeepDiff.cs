using System.Collections;
using System.Reflection;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// 递归比两个对象，把**不一样的地方**连同路径一条条报出来。
///
/// 为什么不拿 JSON 比：`WorldState` 的全量序列化要 `CheckpointCodec` 那套自定义转换器
/// （`HexPosition` 当字典键），而它是 private。更要紧的是 —— **反射比 JSON 强**：
/// 转换器要是悄悄跳过某个属性，JSON 两边都缺那一项、照样逐字节相同，
/// 而这里是照着**类型自己的属性表**走的，跳不过去。
///
/// 这正是对拍规格要的那种「全量比」：不比「我列出来的字段」，比**所有**字段。
/// 只覆盖自己列的字段，在缺失的字段上必然空过 —— 原型就是这么漏掉 15 个的。
/// </summary>
public static class DeepDiff
{
    public static IReadOnlyList<string> Compare(object? a, object? b, string path = "$", int max = 20)
    {
        var diffs = new List<string>();
        Walk(a, b, path, diffs, max);
        return diffs;
    }

    private static void Walk(object? a, object? b, string path, List<string> diffs, int max)
    {
        if (diffs.Count >= max) return;

        if (a is null || b is null)
        {
            if (!ReferenceEquals(a, b)) diffs.Add($"{path}：{Show(a)} → {Show(b)}");
            return;
        }

        // ⚠ 类型相等**只对非集合成立**。
        // `IReadOnlyList<T>` 的实现方到处都是（`ImmutableArray` / `List` / 编译器生成的只读数组），
        // 而 canon 往返之后落到哪一种是**实现细节**，不是状态的一部分 ——
        // 拿具体类型当判据的话，这条闸会天天报「类型变了」而值其实一模一样，
        // 真正的缺字段反而被淹在噪音里（第一版就是这样，三条用例全红、一个真问题都没有）。
        var bothSequences = a is IEnumerable && b is IEnumerable && a is not string;
        if (!bothSequences && a.GetType() != b.GetType())
        {
            diffs.Add($"{path}：类型变了 {a.GetType().Name} → {b.GetType().Name}");
            return;
        }

        // 值类型与字符串当叶子：HexPosition / EntityId 这类比整体比拆开更好读。
        // ⚠ **要排掉集合**：`ImmutableArray<T>` 也是结构体，被这一条抢先拦下的话
        // 会拿它去和 `List<T>` 做 `Equals` —— 值一模一样也判不等（第二版就栽在这里）。
        if (a is string || (a.GetType().IsValueType && !bothSequences))
        {
            if (!a.Equals(b)) diffs.Add($"{path}：{Show(a)} → {Show(b)}");
            return;
        }

        if (a is IDictionary dictA && b is IDictionary dictB)
        {
            CompareDictionaries(dictA, dictB, path, diffs, max);
            return;
        }

        // PagedMap / IReadOnlyDictionary 走泛型接口
        var readOnlyDict = a.GetType().GetInterfaces().FirstOrDefault(i =>
            i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IReadOnlyDictionary<,>));
        if (readOnlyDict != null)
        {
            CompareKeyed(a, b, readOnlyDict, path, diffs, max);
            return;
        }

        if (a is IEnumerable seqA && b is IEnumerable seqB)
        {
            var listA = seqA.Cast<object?>().ToList();
            var listB = seqB.Cast<object?>().ToList();
            if (listA.Count != listB.Count)
            {
                diffs.Add($"{path}：条数 {listA.Count} → {listB.Count}");
                return;
            }
            for (var i = 0; i < listA.Count && diffs.Count < max; i++)
                Walk(listA[i], listB[i], $"{path}[{i}]", diffs, max);
            return;
        }

        foreach (var p in a.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance)
                     .Where(p => p.CanRead && p.GetIndexParameters().Length == 0))
        {
            if (diffs.Count >= max) return;
            Walk(p.GetValue(a), p.GetValue(b), $"{path}.{p.Name}", diffs, max);
        }
    }

    private static void CompareDictionaries(IDictionary a, IDictionary b, string path, List<string> diffs, int max)
    {
        foreach (var key in a.Keys.Cast<object>().OrderBy(k => k?.ToString(), StringComparer.Ordinal))
        {
            if (diffs.Count >= max) return;
            if (!b.Contains(key)) { diffs.Add($"{path}[{key}]：丢了"); continue; }
            Walk(a[key], b[key], $"{path}[{key}]", diffs, max);
        }
        foreach (var key in b.Keys.Cast<object>().Where(k => !a.Contains(k)))
        {
            if (diffs.Count >= max) return;
            diffs.Add($"{path}[{key}]：凭空多出来");
        }
    }

    /// <summary>`IReadOnlyDictionary&lt;,&gt;`（含 `PagedMap`）—— 非泛型的 `IDictionary` 接不住它。</summary>
    private static void CompareKeyed(object a, object b, Type dictInterface, string path, List<string> diffs, int max)
    {
        var keysProp = dictInterface.GetProperty("Keys")!;
        var indexer = dictInterface.GetProperty("Item")!;
        if (!dictInterface.IsInstanceOfType(b))   // 一边是字典、另一边不是：报形状差异，别让反射炸掉整条对拍
        {
            diffs.Add($"{path}：{Show(a)} → {Show(b)}");
            return;
        }
        var keysA = ((IEnumerable)keysProp.GetValue(a)!).Cast<object>().ToList();
        var keysB = ((IEnumerable)keysProp.GetValue(b)!).Cast<object>().ToHashSet();

        foreach (var key in keysA.OrderBy(k => k.ToString(), StringComparer.Ordinal))
        {
            if (diffs.Count >= max) return;
            if (!keysB.Contains(key)) { diffs.Add($"{path}[{key}]：丢了"); continue; }
            Walk(indexer.GetValue(a, [key]), indexer.GetValue(b, [key]), $"{path}[{key}]", diffs, max);
        }
        foreach (var key in keysB.Where(k => !keysA.Contains(k)))
        {
            if (diffs.Count >= max) return;
            diffs.Add($"{path}[{key}]：凭空多出来");
        }
    }

    private static string Show(object? v) => v switch
    {
        null => "(null)",
        string s => $"\"{s}\"",
        IEnumerable e and not string => $"[{string.Join(", ", e.Cast<object?>().Take(6).Select(Show))}]",
        _ => v.ToString() ?? "",
    };
}
