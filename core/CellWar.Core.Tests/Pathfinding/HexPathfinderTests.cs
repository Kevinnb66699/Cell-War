using CellWar.Core.Pathfinding;
using Xunit;

namespace CellWar.Core.Tests.Pathfinding;

public class HexPathfinderTests
{
    [Fact]
    public void FindPath_SamePosition_ReturnsSingletonPath()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var start = new HexPosition(0, 0, 0);
        
        var path = pathfinder.FindPath(start, start);
        
        Assert.NotNull(path);
        Assert.Single(path);
        Assert.Equal(start, path[0]);
    }
    
    [Fact]
    public void FindPath_AdjacentPositions_ReturnsShortestPath()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var start = new HexPosition(0, 0, 0);
        var goal = new HexPosition(1, -1, 0);
        
        var path = pathfinder.FindPath(start, goal);
        
        Assert.NotNull(path);
        Assert.Equal(2, path.Count);
        Assert.Equal(start, path[0]);
        Assert.Equal(goal, path[1]);
    }
    
    [Fact]
    public void FindPath_WithObstacles_FindsAlternatePath()
    {
        var blocked = new HexPosition(1, -1, 0);
        bool IsWalkable(HexPosition pos) => pos != blocked;
        
        var pathfinder = new HexPathfinder(IsWalkable);
        var start = new HexPosition(0, 0, 0);
        var goal = new HexPosition(2, -2, 0);
        
        var path = pathfinder.FindPath(start, goal);
        
        Assert.NotNull(path);
        Assert.DoesNotContain(blocked, path);
        Assert.Equal(start, path[0]);
        Assert.Equal(goal, path[^1]);
    }
    
    [Fact]
    public void FindPath_Unreachable_ReturnsNull()
    {
        var blocked = new HashSet<HexPosition>
        {
            new(1, -1, 0), new(1, 0, -1), new(0, 1, -1),
            new(-1, 1, 0), new(-1, 0, 1), new(0, -1, 1)
        };
        bool IsWalkable(HexPosition pos) => !blocked.Contains(pos);
        
        var pathfinder = new HexPathfinder(IsWalkable);
        var start = new HexPosition(0, 0, 0);
        var goal = new HexPosition(2, -2, 0);
        
        var path = pathfinder.FindPath(start, goal);
        
        Assert.Null(path);
    }
    
    [Fact]
    public void FindPath_UnwalkableStart_ReturnsNull()
    {
        var pathfinder = new HexPathfinder(_ => false);
        var start = new HexPosition(0, 0, 0);
        var goal = new HexPosition(1, -1, 0);
        
        var path = pathfinder.FindPath(start, goal);
        
        Assert.Null(path);
    }
    
    [Fact]
    public void FindReachablePositions_Range0_ReturnsOnlyStart()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var start = new HexPosition(0, 0, 0);
        
        var reachable = pathfinder.FindReachablePositions(start, 0);
        
        Assert.Single(reachable);
        Assert.Contains(start, reachable);
    }
    
    [Fact]
    public void FindReachablePositions_Range1_ReturnsStartAndNeighbors()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var start = new HexPosition(0, 0, 0);
        
        var reachable = pathfinder.FindReachablePositions(start, 1);
        
        Assert.Equal(7, reachable.Count); // start + 6 neighbors
        Assert.Contains(start, reachable);
    }
    
    [Fact]
    public void FindReachablePositions_WithObstacles_ExcludesBlockedAreas()
    {
        var blocked = new HexPosition(1, -1, 0);
        bool IsWalkable(HexPosition pos) => pos != blocked;
        
        var pathfinder = new HexPathfinder(IsWalkable);
        var start = new HexPosition(0, 0, 0);
        
        var reachable = pathfinder.FindReachablePositions(start, 2);
        
        Assert.DoesNotContain(blocked, reachable);
        // 被阻挡位置后面的位置也无法到达
        Assert.DoesNotContain(new HexPosition(2, -2, 0), reachable);
    }
    
    [Fact]
    public void FindReachablePositions_NegativeRange_ReturnsEmpty()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var start = new HexPosition(0, 0, 0);
        
        var reachable = pathfinder.FindReachablePositions(start, -1);
        
        Assert.Empty(reachable);
    }
    
    [Fact]
    public void GetPositionsInRange_Range0_ReturnsOnlyCenter()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var center = new HexPosition(0, 0, 0);
        
        var positions = pathfinder.GetPositionsInRange(center, 0);
        
        Assert.Single(positions);
        Assert.Contains(center, positions);
    }
    
    [Fact]
    public void GetPositionsInRange_Range1_Returns7Positions()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var center = new HexPosition(0, 0, 0);
        
        var positions = pathfinder.GetPositionsInRange(center, 1);
        
        Assert.Equal(7, positions.Count);
        Assert.Contains(center, positions);
        Assert.All(positions, pos => Assert.True(center.DistanceTo(pos) <= 1));
    }
    
    [Fact]
    public void GetPositionsInRange_Range2_Returns19Positions()
    {
        var pathfinder = new HexPathfinder(_ => true);
        var center = new HexPosition(0, 0, 0);
        
        var positions = pathfinder.GetPositionsInRange(center, 2);
        
        Assert.Equal(19, positions.Count);
        Assert.All(positions, pos => Assert.True(center.DistanceTo(pos) <= 2));
    }
}
