using CellWar.Core.Tests.L0;

namespace CellWar.Core.Tests.Ai;

/// <summary>
/// AI 对拍语料（2026-10-01）在**推演**里揪出的四处 C# 内核与 GD 的时序 / 护栏差（真局轨迹 L1 没走到过）。
/// 各钉一条最小用例；完整的回归由三份对拍语料兜（任何一处退回去，搜索档的叶值当场对不上）。
/// ① GD 每个伤害批结算完都 `update_marks()`（cw_damage.gd:141）：被吃掉标记的癌细胞若还在树突光环里、本回合没得过标记，当场补回；
/// ② 【RAS持续激活】排在整个 `enter_tile` 之后（落地追出的问答问完才回血）—— 语料覆盖，见 agree_2p 第 91 问；
/// ③ 【突变】第 2 点的记忆 -1 在 `await draw` 之后（抽到的卡追出的问答问完才扣）—— 语料覆盖，见 agree_4p；
/// ④ 一个行动回合满 80 次行动替这一席结束回合（GD `CWTurn.MAX_ACTIONS_PER_TURN`）。
/// </summary>
public class KernelParityFromAiTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId BCell = new(1), Melanoma = new(2), Dendritic = new(3);

    /// <summary>席位 0 B 细胞 (0,0)、席位 1 黑色素瘤 (1,0)（上一回合被标记过）、席位 2 树突 (2,0)：黑色素瘤在树突光环内、邻接健康组织。</summary>
    private static WorldState Board() => WorldLoader.Load(new L0World
    {
        Round = 2,
        Seat = 0,
        Players = [new L0Player(0, "immune", "III"), new L0Player(1, "cancer", CancerType: "Melanoma"), new L0Player(2, "immune", "III")],
        Tiles = [new L0Tile("1,0", "cancer")],
        Cells =
        [
            new L0Cell { Seat = 0, Type = "BCell", At = "0,0", Differentiated = true },
            new L0Cell { Seat = 1, Type = "Melanoma", At = "1,0", Marked = true, MarkLeft = 1, MarkRound = 1 },
            new L0Cell { Seat = 2, Type = "Dendritic", At = "2,0", Differentiated = true },
        ],
    });

    [Fact]
    public void 抗体吃掉标记之后光环当场补回_第二发照样翻倍()
    {
        var s = Board();
        var antibody = new TypeSkillDecision(0, BCell, "抗体");
        var rng = new Xoshiro256StarStar(1);
        var e0 = s.Cells[Melanoma].Energy;
        s = Engine.ExecuteDecision(s, antibody, rng).NewState;
        Assert.Equal(e0 - 15 * 2, s.Cells[Melanoma].Energy);          // 第一发 1.5 ×2（标记）
        Assert.True(s.Cells[Melanoma].Marked);                        // 批末刷标记：本回合还没得过 → 补回
        Assert.Equal(2, s.Cells[Melanoma].MarkRound);
        var e1 = s.Cells[Melanoma].Energy;
        s = Engine.ExecuteDecision(s, antibody, rng).NewState;
        Assert.Equal(e1 - 7 * 2, s.Cells[Melanoma].Energy);           // 第二发 0.7 照样 ×2（此前 C# 不刷，只打 0.7）
        Assert.False(s.Cells[Melanoma].Marked);                       // 本回合已经得过一次，这次吃掉就不再补
    }

    [Fact]
    public void 第80次行动做完替这一席结束回合()
    {
        var s = Board();
        s = s.WithTurn(s.Turn.Copy(actionsThisTurn: 78));
        var rng = new Xoshiro256StarStar(1);
        s = Engine.ExecuteDecision(s, new MoveDecision(0, BCell, new HexPosition(-1, 0, 1)), rng).NewState;
        Assert.Equal((0, 79), (s.Turn.ActivePlayerSeat, s.Turn.ActionsThisTurn));   // 第 79 次：照常
        s = Engine.ExecuteDecision(s, new MoveDecision(0, BCell, new HexPosition(-2, 0, 2)), rng).NewState;
        Assert.NotEqual(0, s.Turn.ActivePlayerSeat);                                // 第 80 次：GD `_advance_turn` 替它 `_end_turn`
        Assert.Equal(0, s.Turn.ActionsThisTurn);                                     // 下一席开打时归零（GD `flow["acts"] = 0`）
    }

    [Fact]
    public void 结束回合与追问的作答不算行动()
    {
        var s = Board();
        var rng = new Xoshiro256StarStar(1);
        s = Engine.ExecuteDecision(s, new PassDecision(0), rng).NewState;
        Assert.Equal(0, s.Turn.ActionsThisTurn);
        s = Engine.ExecuteDecision(s, new MoveDecision(0, BCell, new HexPosition(-1, 0, 1)), rng).NewState;
        Assert.Equal(1, s.Turn.ActionsThisTurn);
    }
}
