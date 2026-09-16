namespace CellWar.Core;

/// <summary>
/// 六边形坐标（立方体坐标系）
/// 满足约束：q + r + s = 0
/// </summary>
public readonly record struct HexPosition(int Q, int R, int S)
{
    /// <summary>
    /// 验证六边形坐标是否有效
    /// </summary>
    public bool IsValid => Q + R + S == 0;
    
    /// <summary>
    /// 创建并验证六边形坐标
    /// </summary>
    public static HexPosition Create(int q, int r, int s)
    {
        if (q + r + s != 0)
        {
            throw new ArgumentException($"Invalid hex coordinates: {q}, {r}, {s} (must sum to 0)");
        }
        return new HexPosition(q, r, s);
    }
    
    /// <summary>
    /// 计算到另一个位置的曼哈顿距离
    /// </summary>
    public int DistanceTo(HexPosition other)
    {
        return (Math.Abs(Q - other.Q) + Math.Abs(R - other.R) + Math.Abs(S - other.S)) / 2;
    }
    
    /// <summary>
    /// 获取相邻的六个位置
    /// </summary>
    public IEnumerable<HexPosition> GetNeighbors()
    {
        return new[]
        {
            new HexPosition(Q + 1, R - 1, S),
            new HexPosition(Q + 1, R, S - 1),
            new HexPosition(Q, R + 1, S - 1),
            new HexPosition(Q - 1, R + 1, S),
            new HexPosition(Q - 1, R, S + 1),
            new HexPosition(Q, R - 1, S + 1)
        };
    }
    
    public override string ToString() => $"({Q}, {R}, {S})";
}
