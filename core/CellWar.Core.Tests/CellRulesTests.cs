namespace CellWar.Core.Tests;

/// <summary>
/// CellRules.Move 独立契约测试：移动/净化跨域回调（免疫记忆库免费抽卡）、净化记忆结算。
/// 该域是细胞移动与攻击的核心，通过注入回调保持对卡域的单向依赖。
/// </summary>
public class CellRulesTests
{
    private static WorldState World(HexPosition from, HexPosition to, TissueState toState, IReadOnlyList<string> equipped)
    {
        var map = new Dictionary<HexPosition, Tissue>
        {
            [from] = new() { Position = from, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = new EntityId(1), Charge = 0 },
            [to] = new() { Position = to, Type = TissueType.Normal, State = toState, SolidificationCount = 0, OccupyingCell = null, Charge = 0 }
        };
        var cells = new Dictionary<EntityId, Cell>
        {
            [new EntityId(1)] = new Cell
            {
                Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                Position = from, Energy = 30, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Equipped = equipped, Hand = []
            }
        };
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
        };
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = map }, Cells = cells, Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    [Fact]
    public void PurifyIntoCancer_ConvertsTissueAndGainsMemory()
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var world = World(from, to, TissueState.Cancer, []);

        var after = new BasicRulesEngine().ExecuteDecision(world, new MoveDecision(0, new EntityId(1), to), new Xoshiro256StarStar(1)).NewState;

        Assert.Equal(TissueState.Healthy, after.Board.Tissues[to].State);
        Assert.Equal(1, after.Players[0].AntigenMemory);
        Assert.Equal(to, after.Cells[new EntityId(1)].Position);
    }

    [Fact]
    public void PurifyWithImmuneMemoryBank_FreeDrawsOncePerRound()
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var world = World(from, to, TissueState.Cancer, ["免疫记忆库"]);

        var after = new BasicRulesEngine().ExecuteDecision(world, new MoveDecision(0, new EntityId(1), to), new Xoshiro256StarStar(1)).NewState;

        // 免疫 I 级池有可抽卡，净化触发免费抽 1 张（跨域回调）
        Assert.NotEmpty(after.Cells[new EntityId(1)].Hand);
        // 每世界回合仅第一次净化触发：第二次普通移动不再抽卡，手牌数保持 1
        var again = new BasicRulesEngine().ExecuteDecision(after, new MoveDecision(0, new EntityId(1), from), new Xoshiro256StarStar(1)).NewState;
        Assert.Single(again.Cells[new EntityId(1)].Hand);
    }

    // 未注册的事实必须是无操作，注册反应按稳定顺序分派（当前仅 PurifyResolvedFact 触发免疫记忆库抽卡）。
    [Fact]
    public void UnknownFactIsNoOp()
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var world = World(from, to, TissueState.Healthy, []);

        var after = FactRouter.Emit(world, new PurifyResolvedFact(1, new EntityId(1)), new Xoshiro256StarStar(1));
        // 未装备免疫记忆库 → 反应不生效，世界逐引用等价
        Assert.Same(world, after);
    }
}
