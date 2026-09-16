namespace CellWar.Core.Pathfinding;

/// <summary>
/// 六边形网格的 A* 寻路算法实现
/// </summary>
public class HexPathfinder
{
    private readonly Func<HexPosition, bool> _isWalkable;
    
    public HexPathfinder(Func<HexPosition, bool> isWalkable)
    {
        _isWalkable = isWalkable ?? throw new ArgumentNullException(nameof(isWalkable));
    }
    
    /// <summary>
    /// 使用 A* 算法寻找从起点到终点的最短路径
    /// </summary>
    /// <returns>路径（包含起点和终点），如果无法到达则返回 null</returns>
    public List<HexPosition>? FindPath(HexPosition start, HexPosition goal)
    {
        if (!_isWalkable(start) || !_isWalkable(goal))
        {
            return null;
        }
        
        if (start == goal)
        {
            return new List<HexPosition> { start };
        }
        
        var openSet = new PriorityQueue<HexPosition, int>();
        var cameFrom = new Dictionary<HexPosition, HexPosition>();
        var gScore = new Dictionary<HexPosition, int> { [start] = 0 };
        var fScore = new Dictionary<HexPosition, int> { [start] = start.DistanceTo(goal) };
        
        openSet.Enqueue(start, fScore[start]);
        
        while (openSet.Count > 0)
        {
            var current = openSet.Dequeue();
            
            if (current == goal)
            {
                return ReconstructPath(cameFrom, current);
            }
            
            var currentGScore = gScore[current];
            
            foreach (var neighbor in current.GetNeighbors())
            {
                if (!_isWalkable(neighbor))
                {
                    continue;
                }
                
                var tentativeGScore = currentGScore + 1;
                
                if (!gScore.TryGetValue(neighbor, out var neighborGScore) || tentativeGScore < neighborGScore)
                {
                    cameFrom[neighbor] = current;
                    gScore[neighbor] = tentativeGScore;
                    var f = tentativeGScore + neighbor.DistanceTo(goal);
                    fScore[neighbor] = f;
                    openSet.Enqueue(neighbor, f);
                }
            }
        }
        
        return null; // 无法到达
    }
    
    /// <summary>
    /// 计算从起点出发，在指定移动力内可到达的所有位置
    /// </summary>
    public HashSet<HexPosition> FindReachablePositions(HexPosition start, int moveRange)
    {
        if (moveRange < 0 || !_isWalkable(start))
        {
            return new HashSet<HexPosition>();
        }
        
        var reachable = new HashSet<HexPosition> { start };
        var visited = new HashSet<HexPosition> { start };
        var frontier = new Queue<(HexPosition pos, int distance)>();
        frontier.Enqueue((start, 0));
        
        while (frontier.Count > 0)
        {
            var (current, distance) = frontier.Dequeue();
            
            if (distance >= moveRange)
            {
                continue;
            }
            
            foreach (var neighbor in current.GetNeighbors())
            {
                if (visited.Contains(neighbor) || !_isWalkable(neighbor))
                {
                    continue;
                }
                
                visited.Add(neighbor);
                reachable.Add(neighbor);
                frontier.Enqueue((neighbor, distance + 1));
            }
        }
        
        return reachable;
    }
    
    /// <summary>
    /// 获取从起点到目标的所有位置（不考虑障碍，纯几何距离）
    /// </summary>
    public HashSet<HexPosition> GetPositionsInRange(HexPosition center, int range)
    {
        var positions = new HashSet<HexPosition>();
        
        for (int q = -range; q <= range; q++)
        {
            for (int r = Math.Max(-range, -q - range); r <= Math.Min(range, -q + range); r++)
            {
                var s = -q - r;
                var pos = new HexPosition(center.Q + q, center.R + r, center.S + s);
                if (pos.IsValid && center.DistanceTo(pos) <= range)
                {
                    positions.Add(pos);
                }
            }
        }
        
        return positions;
    }
    
    private List<HexPosition> ReconstructPath(Dictionary<HexPosition, HexPosition> cameFrom, HexPosition current)
    {
        var path = new List<HexPosition> { current };
        
        while (cameFrom.TryGetValue(current, out var previous))
        {
            path.Add(previous);
            current = previous;
        }
        
        path.Reverse();
        return path;
    }
}
