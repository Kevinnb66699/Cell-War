using Xunit;

namespace CellWar.Core.Tests;

public class BasicRulesEngineTests
{
    private readonly BasicRulesEngine _engine = new();
    
    private WorldState CreateTestWorld(int worldRound = 1, Phase phase = Phase.PlayerAction, int activeSeat = 0)
    {
        var board = new Board
        {
            Radius = 5,
            Tissues = new Dictionary<HexPosition, Tissue>
            {
                [new HexPosition(0, 0, 0)] = new Tissue
                {
                    Position = new HexPosition(0, 0, 0),
                    Type = TissueType.Normal,
                    State = TissueState.Healthy,
                    SolidificationCount = 0,
                    OccupyingCell = null,
                    Charge = null
                }
            }
        };
        
        var players = new Dictionary<int, Player>
        {
            [0] = new Player
            {
                Seat = 0,
                Faction = Faction.Immune,
                IsAlive = true,
                DrawCount = 0,
                AntigenMemory = 0,
                ImmuneLevel = ImmuneLevel.I
            },
            [1] = new Player
            {
                Seat = 1,
                Faction = Faction.Cancer,
                IsAlive = true,
                DrawCount = 0,
                AntigenMemory = 0,
                ImmuneLevel = ImmuneLevel.I
            }
        };
        
        return new WorldState
        {
            Board = board,
            Cells = new Dictionary<EntityId, Cell>(),
            Turn = new TurnState
            {
                WorldRound = worldRound,
                Phase = phase,
                ActivePlayerSeat = activeSeat
            },
            Players = players
        };
    }
    
    [Fact]
    public void ValidateDecision_WrongPhase_ReturnsInvalid()
    {
        var state = CreateTestWorld(phase: Phase.S);
        var decision = new PassDecision(0);
        
        var result = _engine.ValidateDecision(state, decision);
        
        Assert.False(result.IsValid);
        Assert.Contains("不允许玩家操作", result.ErrorMessage);
    }
    
    [Fact]
    public void ValidateDecision_WrongPlayer_ReturnsInvalid()
    {
        var state = CreateTestWorld(activeSeat: 0);
        var decision = new PassDecision(1);
        
        var result = _engine.ValidateDecision(state, decision);
        
        Assert.False(result.IsValid);
        Assert.Contains("不是该玩家的回合", result.ErrorMessage);
    }
    
    [Fact]
    public void ValidateDecision_DeadPlayer_ReturnsInvalid()
    {
        var state = CreateTestWorld();
        var deadPlayer = new Player
        {
            Seat = 0,
            Faction = Faction.Immune,
            IsAlive = false,
            DrawCount = 0,
            AntigenMemory = 0,
            ImmuneLevel = ImmuneLevel.I
        };
        var deadPlayers = new Dictionary<int, Player>(state.Players) { [0] = deadPlayer };
        var newState = new WorldState
        {
            Board = state.Board,
            Cells = state.Cells,
            Turn = state.Turn,
            Players = deadPlayers
        };
        
        var decision = new PassDecision(0);
        var result = _engine.ValidateDecision(newState, decision);
        
        Assert.False(result.IsValid);
        Assert.Contains("已死亡", result.ErrorMessage);
    }
    
    [Fact]
    public void ValidateDecision_ValidDecision_ReturnsValid()
    {
        var state = CreateTestWorld();
        var decision = new PassDecision(0);
        
        var result = _engine.ValidateDecision(state, decision);
        
        Assert.True(result.IsValid);
        Assert.Null(result.ErrorMessage);
    }
    
    [Fact]
    public void ExecuteDecision_Pass_DoesNothing()
    {
        var state = CreateTestWorld(worldRound: 5, activeSeat: 1);
        var decision = new PassDecision(1);
        var rng = new Xoshiro256StarStar(42);
        
        var result = _engine.ExecuteDecision(state, decision, rng);
        
        Assert.True(result.Success);
        Assert.Equal(5, result.NewState.Turn.WorldRound);
        Assert.Equal(Phase.PlayerAction, result.NewState.Turn.Phase);
        Assert.Equal(1, result.NewState.Turn.ActivePlayerSeat);
        Assert.Empty(result.Events);
    }
    
    [Fact]
    public void ExecuteDecision_EndTurn_AdvancesPhase()
    {
        var state = CreateTestWorld(worldRound: 3, phase: Phase.PlayerAction, activeSeat: 0);
        var decision = new EndTurnDecision(0);
        var rng = new Xoshiro256StarStar(42);
        
        var result = _engine.ExecuteDecision(state, decision, rng);
        
        Assert.True(result.Success);
        Assert.Equal(3, result.NewState.Turn.WorldRound);
        Assert.Equal(Phase.PlayerAction, result.NewState.Turn.Phase);
        Assert.Equal(1, result.NewState.Turn.ActivePlayerSeat);
    }
    
    [Fact]
    public void AdvancePhase_FromS_ToPlayerAction()
    {
        var state = CreateTestWorld(worldRound: 2, phase: Phase.S, activeSeat: 1);
        var rng = new Xoshiro256StarStar(123);
        
        var result = _engine.AdvancePhase(state, rng);
        
        Assert.True(result.Success);
        Assert.Equal(2, result.NewState.Turn.WorldRound);
        Assert.Equal(Phase.PlayerAction, result.NewState.Turn.Phase);
        Assert.Equal(0, result.NewState.Turn.ActivePlayerSeat);
    }
    
    [Fact]
    public void AdvancePhase_FromPlayerAction_ToE()
    {
        var state = CreateTestWorld(worldRound: 4, phase: Phase.PlayerAction, activeSeat: 0);
        var rng = new Xoshiro256StarStar(456);
        
        var result = _engine.AdvancePhase(state, rng);
        
        Assert.True(result.Success);
        Assert.Equal(4, result.NewState.Turn.WorldRound);
        Assert.Equal(Phase.PlayerAction, result.NewState.Turn.Phase);
        Assert.Equal(1, result.NewState.Turn.ActivePlayerSeat);
    }
    
    [Fact]
    public void AdvancePhase_FromE_ToNextPlayerS()
    {
        var state = CreateTestWorld(worldRound: 5, phase: Phase.E, activeSeat: 0);
        var rng = new Xoshiro256StarStar(789);
        
        var result = _engine.AdvancePhase(state, rng);
        
        Assert.True(result.Success);
        Assert.Equal(6, result.NewState.Turn.WorldRound);
        Assert.Equal(Phase.S, result.NewState.Turn.Phase);
        Assert.Equal(0, result.NewState.Turn.ActivePlayerSeat);
    }
    
    [Fact]
    public void AdvancePhase_FromE_LastPlayer_ToNextWorldRound()
    {
        var state = CreateTestWorld(worldRound: 7, phase: Phase.E, activeSeat: 1);
        var rng = new Xoshiro256StarStar(999);
        
        var result = _engine.AdvancePhase(state, rng);
        
        Assert.True(result.Success);
        Assert.Equal(8, result.NewState.Turn.WorldRound); // 世界回合+1
        Assert.Equal(Phase.S, result.NewState.Turn.Phase);
        Assert.Equal(0, result.NewState.Turn.ActivePlayerSeat); // 回到第一个玩家
    }
    
    [Fact]
    public void GetAvailableDecisions_ActivePlayer_ReturnsPassAndEndTurn()
    {
        var state = CreateTestWorld(activeSeat: 0);
        
        var decisions = _engine.GetAvailableDecisions(state, 0);
        
        Assert.Equal(2, decisions.Count);
        Assert.Contains(decisions, d => d is PassDecision);
        Assert.Contains(decisions, d => d is EndTurnDecision);
    }
    
    [Fact]
    public void GetAvailableDecisions_InactivePlayer_ReturnsEmpty()
    {
        var state = CreateTestWorld(activeSeat: 0);
        
        var decisions = _engine.GetAvailableDecisions(state, 1);
        
        Assert.Empty(decisions);
    }
    
    [Fact]
    public void GetAvailableDecisions_WrongPhase_ReturnsEmpty()
    {
        var state = CreateTestWorld(phase: Phase.S, activeSeat: 0);
        
        var decisions = _engine.GetAvailableDecisions(state, 0);
        
        Assert.Empty(decisions);
    }
    
    [Fact]
    public void GetAvailableDecisions_DeadPlayer_ReturnsEmpty()
    {
        var state = CreateTestWorld(activeSeat: 0);
        var deadPlayer = new Player
        {
            Seat = 0,
            Faction = Faction.Immune,
            IsAlive = false,
            DrawCount = 0,
            AntigenMemory = 0,
            ImmuneLevel = ImmuneLevel.I
        };
        var deadPlayers = new Dictionary<int, Player>(state.Players) { [0] = deadPlayer };
        var newState = new WorldState
        {
            Board = state.Board,
            Cells = state.Cells,
            Turn = state.Turn,
            Players = deadPlayers
        };
        
        var decisions = _engine.GetAvailableDecisions(newState, 0);
        
        Assert.Empty(decisions);
    }
}
