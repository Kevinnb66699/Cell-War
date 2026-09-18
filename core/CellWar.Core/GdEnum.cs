namespace CellWar.Core;

/// <summary>
/// C# 枚举 → GD 整数值的唯一换算处（观测协议附录 A）。协议与演出条目里**只许出现 GD 的值**：
/// `itype` 0..4（癌细胞 -1）、`ctype` 0..3（免疫 -1）。C# 把癌种排在免疫种类之后（<see cref="CellType.Melanoma"/> = 5），
/// 直接 `(int)Type` 漏出去就是错值 —— `fx: immune_attack` 的 `ctype` 曾经就是这么塞的。
/// </summary>
public static class GdEnum
{
    public const int CancerTypeBase = (int)CellType.Melanoma;

    public static int Itype(CellType t) => t < CellType.Melanoma ? (int)t : -1;

    public static int Ctype(CellType t) => t >= CellType.Melanoma ? (int)t - CancerTypeBase : -1;
}
