namespace CellWar.Core.Tests;

public class WorldStateTests
{
    [Fact]
    public void WorldState_Creation_ShouldSucceed()
    {
        // Arrange & Act
        var world = CreateSimpleWorld();
        
        // Assert
        Assert.NotNull(world);
        Assert.Equal(2, world.Board.Radius);
        Assert.Equal(1, world.Turn.WorldRound);
        Assert.Equal(Phase.S, world.Turn.Phase);
        Assert.Equal(2, world.Players.Count);
    }
    
    [Fact]
    public void WorldState_DeepClone_ShouldCreateIndependentCopy()
    {
        // Arrange
        var original = CreateSimpleWorld();
        
        // Act
        var cloned = original.DeepClone();
        
        // Assert - 验证独立�?        Assert.NotSame(original, cloned);
        Assert.NotSame(original.Board, cloned.Board);
        Assert.NotSame(original.Cells, cloned.Cells);
        Assert.NotSame(original.Turn, cloned.Turn);
        Assert.NotSame(original.Players, cloned.Players);
        
        // 验证内容相等
        Assert.Equal(original.Board.Radius, cloned.Board.Radius);
        Assert.Equal(original.Turn.WorldRound, cloned.Turn.WorldRound);
        Assert.Equal(original.Cells.Count, cloned.Cells.Count);
    }
    
    [Fact]
    public void WorldState_DeepClone_Mutation_ShouldNotAffectOriginal()
    {
        // Arrange
        var original = CreateSimpleWorld();
        var cloned = original.DeepClone();
        var cellId = original.Cells.Keys.First();
        
        // Act - 修改克隆的细胞
        var origCell = original.Cells[cellId];
        var modifiedCell = new Cell
        {
            Id = origCell.Id,
            OwnerSeat = origCell.OwnerSeat,
            Faction = origCell.Faction,
            Type = origCell.Type,
            Position = origCell.Position,
            Energy = 9990,
            IsAlive = origCell.IsAlive,
            StatusEffects = origCell.StatusEffects
        };
        cloned = cloned.UpdateCell(cellId, modifiedCell);
        
        // Assert - 原始世界未受影响
        Assert.Equal(50, original.Cells[cellId].Energy);
        Assert.Equal(9990, cloned.Cells[cellId].Energy);
    }
    
    [Fact]
    public void Board_Creation_ShouldContainCorrectTissues()
    {
        // Arrange & Act
        var board = CreateStandardBoard();
        
        // Assert
        Assert.Equal(2, board.Radius);
        Assert.True(board.Tissues.Count >= 7); // 至少中心�?+ 第一�?        
        // 验证中心位置存在
        var center = new HexPosition(0, 0, 0);
        Assert.True(board.Tissues.ContainsKey(center));
    }
    
    [Fact]
    public void Cell_Creation_WithStatusEffects_ShouldSucceed()
    {
        // Arrange
        var cellId = new EntityId(1);
        var position = new HexPosition(0, 0, 0);
        
        // Act
        var cell = new Cell
        {
            Id = cellId,
            OwnerSeat = 0,
            Faction = Faction.Immune,
            Type = CellType.ImmuneBasic,
            Position = position,
            Energy = 100,
            IsAlive = true,
            StatusEffects = new List<StatusEffect>
            {
                new StatusEffect
                {
                    EffectType = "Poisoned",
                    Duration = 2,
                    Parameters = new Dictionary<string, object> { ["damage"] = 1.0 }
                }
            }
        };
        
        // Assert
        Assert.Equal(cellId, cell.Id);
        Assert.Equal(100, cell.Energy);
        Assert.Single(cell.StatusEffects);
        Assert.Equal("Poisoned", cell.StatusEffects[0].EffectType);
    }
    
    [Fact]
    public void Player_Creation_ShouldHaveCorrectInitialState()
    {
        // Arrange & Act
        var player = new Player
        {
            Seat = 0,
            Faction = Faction.Immune,
            IsAlive = true,
            DrawCount = 3,
            AntigenMemory = 0,
            ImmuneLevel = ImmuneLevel.I
        };
        
        // Assert
        Assert.Equal(0, player.Seat);
        Assert.Equal(Faction.Immune, player.Faction);
        Assert.True(player.IsAlive);
        Assert.Equal(3, player.DrawCount);
        Assert.Equal(ImmuneLevel.I, player.ImmuneLevel);
    }
    
    [Fact]
    public void Tissue_Clone_ShouldCreateIndependentCopy()
    {
        // Arrange
        var tissue = new Tissue
        {
            Position = new HexPosition(0, 0, 0),
            Type = TissueType.MetabolicCore,
            State = TissueState.Healthy,
            SolidificationCount = 0,
            OccupyingCell = new EntityId(1),
            Charge = 3
        };
        
        // Act
        var cloned = tissue.Clone();
        
        // Assert
        Assert.NotSame(tissue, cloned);
        Assert.Equal(tissue.Type, cloned.Type);
        Assert.Equal(tissue.Charge, cloned.Charge);
        Assert.Equal(tissue.OccupyingCell, cloned.OccupyingCell);
    }
    
    // 辅助方法
    
    private static WorldState CreateSimpleWorld()
    {
        var board = CreateStandardBoard();
        var cells = CreateInitialCells();
        
        return new WorldState
        {
            Board = board,
            Cells = cells,
            Turn = new TurnState
            {
                WorldRound = 1,
                Phase = Phase.S,
                ActivePlayerSeat = 0
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new Player
                {
                    Seat = 0,
                    Faction = Faction.Immune,
                    IsAlive = true,
                    DrawCount = 3,
                    AntigenMemory = 0,
                    ImmuneLevel = ImmuneLevel.I
                },
                [1] = new Player
                {
                    Seat = 1,
                    Faction = Faction.Cancer,
                    IsAlive = true,
                    DrawCount = 3,
                    AntigenMemory = 0,
                    ImmuneLevel = ImmuneLevel.I // 癌症方不使用
                }
            }
        };
    }
    
    private static Board CreateStandardBoard()
    {
        var tissues = new Dictionary<HexPosition, Tissue>();
        
        // 创建半径�?的六边形棋盘
        for (int q = -2; q <= 2; q++)
        {
            for (int r = -2; r <= 2; r++)
            {
                int s = -q - r;
                if (Math.Abs(s) <= 2)
                {
                    var pos = new HexPosition(q, r, s);
                    tissues[pos] = new Tissue
                    {
                        Position = pos,
                        Type = TissueType.Normal,
                        State = TissueState.Healthy,
                        SolidificationCount = 0,
                        OccupyingCell = null,
                        Charge = null
                    };
                }
            }
        }
        
        // 中心设置为代谢核心
        var centerPos = new HexPosition(0, 0, 0);
        tissues[centerPos] = new Tissue
        {
            Position = centerPos,
            Type = TissueType.MetabolicCore,
            State = TissueState.Healthy,
            SolidificationCount = 0,
            OccupyingCell = null,
            Charge = 3
        };
        
        return new Board
        {
            Radius = 2,
            Tissues = tissues
        };
    }
    
    private static Dictionary<EntityId, Cell> CreateInitialCells()
    {
        return new Dictionary<EntityId, Cell>
        {
            [new EntityId(1)] = new Cell
            {
                Id = new EntityId(1),
                OwnerSeat = 0,
                Faction = Faction.Immune,
                Type = CellType.ImmuneBasic,
                Position = new HexPosition(1, 0, -1),
                Energy = 50,
                IsAlive = true,
                StatusEffects = new List<StatusEffect>()
            },
            [new EntityId(2)] = new Cell
            {
                Id = new EntityId(2),
                OwnerSeat = 1,
                Faction = Faction.Cancer,
                Type = CellType.Melanoma,
                Position = new HexPosition(-1, 0, 1),
                Energy = 50,
                IsAlive = true,
                StatusEffects = new List<StatusEffect>()
            }
        };
    }
}

