using System.Text.RegularExpressions;
using CellWar.Core;

namespace CellWar.Core.Tests;

/// <summary>
/// 【炎症风暴】/【免疫风暴】是**抽到即发**的事件卡，GD 先问一句「选 1 个免疫细胞」当风暴中心
/// （`cw_card_fx.gd:727 _pick_immune`，`kind: pick_cell` / tag = 卡名），选完才以它为圆心结算。
///
/// 2026-09-19 之前 C# 把两张写成「要 `targetCell` 才做事」，而抽卡即发那条路（`DrawOne` → `Resolve`）
/// 根本没人给目标 —— 效果**静默跳过**、一句询问都没有。树突建源夹具 `trace_4p_chemo_4242` 第 238 步
/// 撞上它（`OPTION_DIFF pick_cell@0`），水位线因此钉在 237。
///
/// 这一组盯三件事：**问出来了**（挂起态 + 选项表 + 语义键）、**答得对**（只有抽卡那一席能答、
/// 选得到全场免疫细胞）、**结算的数是 GD 的数**（0.5 / 1.0，去读 `cw_card_fx.gd`，不写字面量）。
/// </summary>
public class StormPickCellTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，站 (-4,0)
    private static readonly EntityId Immune2 = new(3);   // 席位 2：免疫，站 (4,0)
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，站 (-1,0)。**不用印戒**：它的【囊性护甲】每世界回合首次损失 −0.5，会把风暴的数吃掉一半
    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    /// <summary>抽卡的是席位 0，中心挑在席位 2 那只身上 —— 圆心周围摆好料：两格空的普通癌组织 + 一只贴着的癌细胞。</summary>
    private static WorldState World()
    {
        var s = DemoScenario.Create().WithTurn(DemoScenario.Create().Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        s = s.UpdateTissueState(P(3, 1), TissueState.Cancer);    // (4,0) 的邻格，空着 → 转健康
        s = s.UpdateTissueState(P(4, -1), TissueState.Cancer);   // 同上
        s = s.UpdateTissueState(P(5, -1), TissueState.Cancer);   // 这一格待会儿站人 → 不转
        // 把黑色素瘤挪到 (5,-1)：相邻 → 吃【炎症风暴】的 0.5；2 格内 → 吃【免疫风暴】的 1.0
        s = s.UpdateTissueOccupant(P(-1, 0), null);
        s = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(position: P(5, -1)));
        s = s.UpdateTissueOccupant(P(5, -1), Cancer1);
        return s;
    }

    private static IDeterministicRng Rng() => new Xoshiro256StarStar(5);

    private static WorldState Do(WorldState s, IDecision d)
    {
        var r = Engine.ExecuteDecision(s, d, Rng());
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    [Fact]
    public void 炎症风暴_抽到即挂起选中心_只有抽卡那一席能答_候选是全场免疫细胞()
    {
        var s = CardRules.Resolve(World(), World().Cells[Immune0], "炎症风暴", Rng());

        Assert.Equal(0, s.Turn.PendingPickCellSeat);
        Assert.Equal("炎症风暴", s.Turn.PendingPickCellCard);
        Assert.Equal(Immune0, s.Turn.PendingPickCellChooser);

        // 候选 = 全场活着的免疫细胞（别人的也选得到），按细胞 id 升序 —— GD `living_cells(IMMUNE)` 就是 cells 数组序
        var opts = Engine.GetAvailableDecisions(s, 0);
        Assert.Equal([Immune0, Immune2], opts.Cast<PickCellDecision>().Select(d => d.TargetCellId).ToArray());
        // 问的是抽卡那一席：别的席位（哪怕它的细胞在候选里）此刻没有任何选项
        Assert.Empty(Engine.GetAvailableDecisions(s, 2));
        Assert.False(Engine.ValidateDecision(s, new PickCellDecision(2, Immune0, Immune2)).IsValid);
        Assert.False(Engine.ValidateDecision(s, new PickCellDecision(0, Immune0, Cancer1)).IsValid);   // 癌细胞不是候选
        // 键与 GD 逐字同（夹具第 238 步的形状）：tag = 卡名，`to` 在前、`cid` 是席位
        Assert.Equal("k=pick_cell|g=炎症风暴|to=4,0|cid=2", SemanticKey.Of(s, new PickCellDecision(0, Immune0, Immune2)));
    }

    [Fact]
    public void 炎症风暴_选定中心后_相邻空的普通癌组织转健康_相邻癌细胞各扣GD那个数()
    {
        var s = CardRules.Resolve(World(), World().Cells[Immune0], "炎症风暴", Rng());
        var before = s.Cells[Cancer1].Energy;

        var after = Do(s, new PickCellDecision(0, Immune0, Immune2));

        Assert.Null(after.Turn.PendingPickCellSeat);
        Assert.Equal(0, after.Turn.CardResolveDepth);                                  // 决策点上深度永远归零
        Assert.Equal(TissueState.Healthy, after.Board.Tissues[P(3, 1)].State);
        Assert.Equal(TissueState.Healthy, after.Board.Tissues[P(4, -1)].State);
        Assert.Equal(TissueState.Cancer, after.Board.Tissues[P(5, -1)].State);          // 有细胞占着：GD storm_inflammation_tiles 不收
        Assert.Equal(before - GdStormDamage("_inflammation_storm"), after.Cells[Cancer1].Energy);
        Assert.NotEmpty(Engine.GetAvailableDecisions(after, 0).OfType<MoveDecision>()); // 摘干净了，回到行动栏
    }

    [Fact]
    public void 免疫风暴_2格内癌细胞扣GD那个数_范围内无癌细胞占据的普通癌组织转健康()
    {
        var s = CardRules.Resolve(World(), World().Cells[Immune0], "免疫风暴", Rng());
        Assert.Equal("免疫风暴", s.Turn.PendingPickCellCard);
        var before = s.Cells[Cancer1].Energy;

        var after = Do(s, new PickCellDecision(0, Immune0, Immune2));

        Assert.Equal(before - GdStormDamage("_immune_storm"), after.Cells[Cancer1].Energy);
        Assert.Equal(TissueState.Healthy, after.Board.Tissues[P(3, 1)].State);
        Assert.Equal(TissueState.Healthy, after.Board.Tissues[P(4, -1)].State);
        // (5,-1) 站着癌细胞 ⇒ 不转；它没被这一发打死（还有能量），所以伤害之后重算也仍占着
        Assert.True(after.Cells[Cancer1].IsAlive);
        Assert.Equal(TissueState.Cancer, after.Board.Tissues[P(5, -1)].State);
    }

    /// <summary>GD 那两个数（`game.immune_hit_area(victims, _amp(N), …)`）是真相源，别在 C# 这边写字面量。</summary>
    private static int GdStormDamage(string func)
    {
        var src = File.ReadAllText(Path.Combine(RepoRoot(), "game", "scripts", "core", "cw_card_fx.gd"));
        var m = Regex.Match(src, $@"func {func}\(.*?immune_hit_area\(victims, _amp\((\d+)\)", RegexOptions.Singleline);
        Assert.True(m.Success, $"cw_card_fx.gd 里找不到 {func} 的 immune_hit_area 基数");
        return int.Parse(m.Groups[1].Value);
    }

    private static string RepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !(Directory.Exists(Path.Combine(d, "game")) && Directory.Exists(Path.Combine(d, "core"))))
            d = Path.GetDirectoryName(d);
        return d ?? throw new InvalidOperationException("找不到仓库根");
    }

    /// <summary>
    /// 骨髓 / 免疫记忆库那一抽抽到风暴时，两道闸都要认得这个挂起态：换回合前 `PhaseRules.AskPending` 为真、
    /// 落地后半截 `CellRules.LandBlocked` 为真。四条夹具都没走到这条路，这里直接挂上挂起态钉住闸门本身 ——
    /// 谁以后改了 LandBlocked 的条件表，这条就红。
    /// </summary>
    [Fact]
    public void 风暴选中心挂着时_换回合与落地后半截两道闸都拦住()
    {
        var s = World();
        var pending = s.WithTurn(s.Turn.WithPendingPickCell(0, "炎症风暴", Immune0));
        Assert.False(PhaseRules.AskPending(s));
        Assert.True(PhaseRules.AskPending(pending));
        Assert.False(CellRules.LandBlocked(s, CellRules.WalkDepth(s)));
        Assert.True(CellRules.LandBlocked(pending, CellRules.WalkDepth(pending)));
    }
}
