using static CellWar.Core.RulePolicies;

namespace CellWar.Core.Tests;

/// <summary>
/// 带目标的卡跟 GD 的形状（2026-09-17，对照 cw_card_fx.gd `hand_options` 与各自的结算函数）：
/// 一个目标一条选项、没有候选就不出这张牌、目标必须在候选表里、结算用玩家选的目标 —— 此前 C# 只出一条无目标的打出，
/// 结算要么自己随机挑（带子多一发）、要么什么也不做（卡白扔）。L1 对拍第 33 步就分叉在【基质硬化】那一问。
/// </summary>
public class TargetedCardTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，站 (-4,0,4)
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，站 (-1,0,1)
    private static readonly EntityId Immune2 = new(3);   // 席位 2：免疫，站 (4,0,-4)
    private static readonly EntityId Cancer3 = new(4);   // 席位 3：印戒，站 (1,0,-1)

    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    /// <summary>行动阶段、某席位手里一张卡；DemoScenario 的中央 15 格是普通癌组织。</summary>
    private static WorldState World(int seat, string card)
    {
        var s = DemoScenario.Create();
        var id = new EntityId((ulong)(seat + 1));
        s = s.UpdateCell(id, s.Cells[id].Copy(hand: [card]));
        return s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: seat, startStep: 2));
    }

    private static WorldState MoveTo(WorldState s, EntityId id, HexPosition to)
    {
        var c = s.Cells[id];
        return s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(to, id).UpdateCell(id, c.Copy(position: to));
    }

    private static WorldState Tile(WorldState s, HexPosition p, TissueState state, int solid = 0)
        => s.UpdateTissueState(p, state).UpdateTissueSolidification(p, solid);

    private static List<PlayCardDecision> Plays(WorldState s, int seat, string card)
        => Engine.GetAvailableDecisions(s, seat).OfType<PlayCardDecision>().Where(p => p.Card == card).ToList();

    private static (WorldState State, RecordingRng Rng) Do(WorldState s, IDecision d, int seed = 7)
    {
        var rng = new RecordingRng(new Xoshiro256StarStar((ulong)seed));
        var r = Engine.ExecuteDecision(s, d, rng);
        Assert.True(r.Success, r.ErrorMessage);
        return (r.NewState, rng);
    }

    // ---------- 共用件 ----------

    [Fact]
    public void Tiles的顺序是Q升R升_与GD的all_coords插入序逐格一致()
    {
        // 所有「按下标抽格」的卡能对上带子的前提；改任何一边的排序都会静默换落点
        var order = Tiles(DemoScenario.Create()).Select(t => (t.Position.Q, t.Position.R)).ToList();
        Assert.Equal(order.OrderBy(x => x.Q).ThenBy(x => x.R).ToList(), order);
    }

    [Fact]
    public void GdNeighbors按DIRS序_并裁掉板外()
    {
        var s = DemoScenario.Create();
        Assert.Equal(new[] { P(1, 0), P(1, -1), P(0, -1), P(-1, 0), P(-1, 1), P(0, 1) }, GdNeighbors(s, P(0, 0)));
        Assert.Equal(3, GdNeighbors(s, P(6, 0)).Count());   // 角上只剩板内那三个
    }

    [Fact]
    public void 没给目标或目标不在候选表里_一律驳回()
    {
        var s = World(0, "基质降解");
        s = Tile(s, P(-3, 0), TissueState.SolidifiedCancer, 30);
        Assert.False(Engine.ValidateDecision(s, new PlayCardDecision(0, Immune0, "基质降解")).IsValid);
        Assert.False(Engine.ValidateDecision(s, new PlayCardDecision(0, Immune0, "基质降解", P(0, 0))).IsValid);
        Assert.True(Engine.ValidateDecision(s, new PlayCardDecision(0, Immune0, "基质降解", P(-3, 0))).IsValid);

        var acid = World(1, "乳酸酸化");
        Assert.False(Engine.ValidateDecision(acid, new PlayCardDecision(1, Cancer1, "乳酸酸化")).IsValid);
        Assert.False(Engine.ValidateDecision(acid, new PlayCardDecision(1, Cancer1, "乳酸酸化", null, Immune0)).IsValid);   // 不相邻
    }

    // ---------- 格目标 ----------

    [Fact]
    public void 基质降解_相邻固化格逐格一条_玩家选格_零随机()
    {
        var s = World(0, "基质降解");
        s = Tile(s, P(-3, 0), TissueState.SolidifiedCancer, 30);
        s = Tile(s, P(-4, 1), TissueState.SolidifiedCancer, 30);
        s = Tile(s, P(-2, 0), TissueState.SolidifiedCancer, 30);   // 距离 2：不算

        var plays = Plays(s, 0, "基质降解");
        Assert.Equal(new[] { P(-3, 0), P(-4, 1) }.OrderBy(p => p.Q).ThenBy(p => p.R), plays.Select(p => p.Target!.Value).OrderBy(p => p.Q).ThenBy(p => p.R));

        var (done, rng) = Do(s, plays.Single(p => p.Target == P(-4, 1)));
        Assert.Equal(TissueState.Cancer, done.Board.Tissues[P(-4, 1)].State);
        Assert.Equal(0, done.Board.Tissues[P(-4, 1)].SolidificationCount);
        Assert.Equal(TissueState.SolidifiedCancer, done.Board.Tissues[P(-3, 0)].State);   // 另一格不动
        Assert.Empty(rng.Ranges);   // GD 这张卡零随机，带子上不该多一发
        Assert.DoesNotContain("基质降解", done.Cells[Immune0].Hand);
    }

    [Fact]
    public void 基质降解_相邻没有固化格就不出这张牌()
    {
        Assert.Empty(Plays(World(0, "基质降解"), 0, "基质降解"));
    }

    [Fact]
    public void 基质硬化_脚下加相邻的普通癌组织_三道闸在选项层拦()
    {
        var s = World(1, "基质硬化");   // 黑色素瘤站 (-1,0,1)，中央 15 格是癌组织
        var frozen = P(0, 0);
        s = s.InstallEffect("TNF-α局部炎症", 1, 1, new Dictionary<string, int> { [WorldEffects.TileKey(frozen)] = 1 });   // TNF-α 冻结（事件容器里的名单）
        var vessel = P(-2, 0);
        s = s.WithBoard(s.Board.UpdateTissue(vessel, s.Board.Tissues[vessel].WithType(TissueType.BloodVessel)));   // (-2,0) 本来就是癌组织

        var targets = Plays(s, 1, "基质硬化").Select(p => p.Target!.Value).ToHashSet();
        Assert.Contains(P(-1, 0), targets);   // 脚下那格也算（GD cands 第一项）
        Assert.DoesNotContain(frozen, targets);
        Assert.DoesNotContain(vessel, targets);
        Assert.All(targets, p => Assert.True(p.DistanceTo(P(-1, 0)) <= 1 && s.Board.Tissues[p].State == TissueState.Cancer));

        var (done, rng) = Do(s, new PlayCardDecision(1, Cancer1, "基质硬化", P(-1, 1)));
        Assert.Equal(10, done.Board.Tissues[P(-1, 1)].SolidificationCount);   // I 期 +1.0
        Assert.Empty(rng.Ranges);
    }

    [Fact]
    public void 放疗_起点在全盘癌性组织里选_区域按GD一轮一发地长_整格坏死并清库存()
    {
        var s = World(0, "放疗");
        var marrow = P(0, 1);
        s = s.WithBoard(s.Board.UpdateTissue(marrow, s.Board.Tissues[marrow].WithType(TissueType.BoneMarrow).WithCharge(1).WithProductionCounter(3)));

        var plays = Plays(s, 0, "放疗");
        Assert.Equal(Tiles(s).Count(Cancerous), plays.Count);   // 不限范围：免疫站在 (-4,0,4)，起点照样可以在中央
        Assert.All(plays, p => Assert.True(Cancerous(s.Board.Tissues[p.Target!.Value])));

        var (done, rng) = Do(s, new PlayCardDecision(0, Immune0, "放疗", P(0, 0)));
        var region = Tiles(done).Where(t => t.NecrosisRounds > 0).ToList();
        Assert.InRange(region.Count, 2, 10);
        Assert.All(region, t => Assert.Equal(TissueState.Healthy, t.State));
        Assert.Contains(region, t => t.Position == P(0, 0));
        // 带子形状：每轮只掷一发、都是 NextInt(|frontier|)；第一发跨度恒为 6（起点在板内）
        Assert.NotEmpty(rng.Ranges);
        Assert.All(rng.Ranges, r => Assert.Equal(0, r.Min));
        Assert.Equal(6, rng.Ranges[0].Max);
        if (done.Board.Tissues[marrow].NecrosisRounds > 0)
        {
            Assert.Equal(0, done.Board.Tissues[marrow].Charge);           // 库存一起没（issue #31）
            Assert.Equal(0, done.Board.Tissues[marrow].ProductionCounter);
        }
    }

    [Fact]
    public void 放疗_坏死时长取较长的那个_不会被缩短()
    {
        var s = World(0, "放疗");
        s = s.WithBoard(s.Board.UpdateTissue(P(0, 0), s.Board.Tissues[P(0, 0)].WithNecrosis(5)));
        var (done, _) = Do(s, new PlayCardDecision(0, Immune0, "放疗", P(0, 0)));
        Assert.Equal(5, done.Board.Tissues[P(0, 0)].NecrosisRounds);   // GD maxi(before, 2)
    }

    // ---------- 细胞目标 ----------

    [Fact]
    public void 交叉呈递_射程树突4其余2_已标记的不出_结算走ApplyMark()
    {
        var s = World(0, "交叉呈递");
        s = MoveTo(s, Cancer1, P(-2, 0));   // 距离 2
        s = MoveTo(s, Cancer3, P(-1, 0));   // 距离 3

        Assert.Equal(new[] { Cancer1 }, Plays(s, 0, "交叉呈递").Select(p => p.TargetCell!.Value));
        var dendritic = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.Dendritic));
        Assert.Equal(new[] { Cancer1, Cancer3 }, Plays(dendritic, 0, "交叉呈递").Select(p => p.TargetCell!.Value).OrderBy(x => x.Value));

        var (done, rng) = Do(s, new PlayCardDecision(0, Immune0, "交叉呈递", null, Cancer1));
        var marked = done.Cells[Cancer1];
        Assert.True(marked.Marked);
        Assert.Equal(done.Turn.WorldRound, marked.MarkRound);   // 记施加回合：寿命从本回合起算
        Assert.Equal(1, marked.MarkLeft);                        // 普通免疫细胞给 1 层
        Assert.Empty(rng.Ranges);
        Assert.Empty(Plays(done.UpdateCell(Immune0, done.Cells[Immune0].Copy(hand: ["交叉呈递"])), 0, "交叉呈递"));   // 已标记 → 不出

        // 树突带【抗原呈递强化】：2 层
        var enhanced = dendritic.UpdateCell(Immune0, dendritic.Cells[Immune0].Copy(equipped: ["抗原呈递强化"]));
        var (twice, _) = Do(enhanced, new PlayCardDecision(0, Immune0, "交叉呈递", null, Cancer1));
        Assert.Equal(2, twice.Cells[Cancer1].MarkLeft);

        // 同回合被伤害吃掉标记的目标：ApplyMark 会直接 return，所以选项层就不出（空打拦在选项层）
        var eaten = done.UpdateCell(Cancer1, done.Cells[Cancer1].Copy(marked: false, markLeft: 0))
                        .UpdateCell(Immune0, done.Cells[Immune0].Copy(hand: ["交叉呈递"]));
        Assert.Empty(Plays(eaten, 0, "交叉呈递"));
        var nextRound = eaten.WithTurn(eaten.Turn.Copy(round: eaten.Turn.WorldRound + 1));
        Assert.Equal(new[] { Cancer1 }, Plays(nextRound, 0, "交叉呈递").Select(p => p.TargetCell!.Value));
    }

    [Fact]
    public void 抗体依赖细胞毒作用_两环内且与健康组织相邻_B细胞打15其余10()
    {
        var s = World(0, "抗体依赖细胞毒作用");
        s = MoveTo(s, Cancer1, P(-2, 0));            // 距离 2，四周有健康格
        Assert.Equal(new[] { Cancer1 }, Plays(s, 0, "抗体依赖细胞毒作用").Select(p => p.TargetCell!.Value));

        var (done, rng) = Do(s, new PlayCardDecision(0, Immune0, "抗体依赖细胞毒作用", null, Cancer1));
        Assert.Equal(50, done.Cells[Cancer1].Energy);
        Assert.Empty(rng.Ranges);

        var bcell = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.BCell));
        Assert.Equal(45, Do(bcell, new PlayCardDecision(0, Immune0, "抗体依赖细胞毒作用", null, Cancer1)).State.Cells[Cancer1].Energy);
    }

    [Fact]
    public void IFNγ高峰_目标是任意免疫细胞含自己_两环内没得打的不出_圆心是所选细胞()
    {
        var s = World(0, "IFN-γ高峰");
        s = MoveTo(s, Cancer1, P(-2, 0));   // 离席位 0 两格，离席位 2（(4,0,-4)）很远
        var plays = Plays(s, 0, "IFN-γ高峰");
        Assert.Equal(new[] { Immune0 }, plays.Select(p => p.TargetCell!.Value));   // 席位 2 那只 2 环内没东西 → 不出

        var (done, rng) = Do(s, new PlayCardDecision(0, Immune0, "IFN-γ高峰", null, Immune0));
        Assert.Equal(50, done.Cells[Cancer1].Energy);   // -1.0
        Assert.Empty(rng.Ranges);

        // 没有一个免疫细胞 2 环内有癌细胞或可降固化的癌组织 → 这张牌不出现
        var quiet = MoveTo(World(0, "IFN-γ高峰"), Cancer1, P(0, 6));   // 离两只免疫都 ≥ 5 格
        quiet = MoveTo(quiet, Cancer3, P(1, 5));
        Assert.Empty(Plays(quiet, 0, "IFN-γ高峰"));
    }

    [Fact]
    public void 免疫增援_只认别的席位_落点以队友为心抽一发_落地走EnterTile()
    {
        var s = World(0, "免疫增援");
        var plays = Plays(s, 0, "免疫增援");
        Assert.Equal(new[] { Immune2 }, plays.Select(p => p.TargetCell!.Value));   // 自己不算

        var cands = EmptyHealthyWithin(s, s.Cells[Immune2].Position, 2);
        var (done, rng) = Do(s, plays.Single());
        Assert.Contains(done.Cells[Immune0].Position, cands);
        Assert.Equal(Immune0, done.Board.Tissues[done.Cells[Immune0].Position].OccupyingCell!.Value);
        Assert.Null(done.Board.Tissues[P(-4, 0)].OccupyingCell);
        Assert.Equal(new[] { (0, cands.Count) }, rng.Ranges);   // 恰好一发，跨度 = 候选数
    }

    [Fact]
    public void 乳酸酸化_只认相邻一格的免疫细胞_三格癌性相邻多扣半点()
    {
        var s = World(1, "乳酸酸化");                 // 黑色素瘤站 (-1,0,1)
        s = MoveTo(s, Immune0, P(-2, 0));            // 相邻
        Assert.Equal(new[] { Immune0 }, Plays(s, 1, "乳酸酸化").Select(p => p.TargetCell!.Value));
        Assert.Empty(Plays(MoveTo(World(1, "乳酸酸化"), Immune0, P(-3, 0)), 1, "乳酸酸化"));   // 距离 2 不算

        var (done, rng) = Do(s, new PlayCardDecision(1, Cancer1, "乳酸酸化", null, Immune0));
        // (-2,0) 的邻格里 (-1,0) 站着癌细胞的癌组织、(-2,1)、(-1,-1) 都在中央 15 格之内 → ≥3 格癌性相邻 → 8 + 5
        var cancerousAround = GdNeighbors(s, P(-2, 0)).Count(n => Cancerous(s.Board.Tissues[n]));
        Assert.Equal(30 - (cancerousAround >= 3 ? 13 : 8), done.Cells[Immune0].Energy);
        Assert.Empty(rng.Ranges);
    }

    [Fact]
    public void 肿瘤细胞募集_以施法者为心判一次落点_目标是别席位的癌细胞_落点抽一发()
    {
        var s = World(1, "肿瘤细胞募集");   // 黑色素瘤站 (-1,0,1)，周围 3 环内有空癌组织
        var plays = Plays(s, 1, "肿瘤细胞募集");
        Assert.Equal(new[] { Cancer3 }, plays.Select(p => p.TargetCell!.Value));

        var dests = CancerousLandings(s, P(-1, 0), 3);
        var (done, rng) = Do(s, plays.Single());
        Assert.Contains(done.Cells[Cancer3].Position, dests);
        Assert.Equal(new[] { (0, dests.Count) }, rng.Ranges);

        // 施法者周围一格空癌组织都没有 → 整张牌不出（不是「有目标但落空」）
        var boxed = World(1, "肿瘤细胞募集");
        foreach (var t in Tiles(boxed).Where(t => Cancerous(t) && t.OccupyingCell == null).ToArray())
            boxed = boxed.UpdateTissueState(t.Position, TissueState.Healthy);
        Assert.Empty(Plays(boxed, 1, "肿瘤细胞募集"));
    }

    [Fact]
    public void 肿瘤增援_落点以目标为心逐个判_自己送过去()
    {
        var s = World(1, "肿瘤增援");
        var plays = Plays(s, 1, "肿瘤增援");
        Assert.Equal(new[] { Cancer3 }, plays.Select(p => p.TargetCell!.Value));

        var dests = CancerousLandings(s, s.Cells[Cancer3].Position, 3);
        var (done, rng) = Do(s, plays.Single());
        Assert.Contains(done.Cells[Cancer1].Position, dests);
        Assert.Equal(new[] { (0, dests.Count) }, rng.Ranges);

        // 目标周围没落点 → 这个目标不出（逐目标判，与【肿瘤细胞募集】的一次全局闸互为镜像）
        var far = MoveTo(World(1, "肿瘤增援"), Cancer3, P(6, -6));
        Assert.Empty(Plays(far, 1, "肿瘤增援"));
    }

    [Fact]
    public void EnterTile_落到有卡的骨髓格上抽一张_带子多一发()
    {
        var s = World(0, "免疫增援");
        var marrow = P(3, 0);
        s = s.WithBoard(s.Board.UpdateTissue(marrow, s.Board.Tissues[marrow].WithType(TissueType.BoneMarrow).WithCharge(1)));
        var rng = new RecordingRng(new Xoshiro256StarStar(3));
        var handBefore = s.Cells[Immune0].Hand.Count;

        var done = CellRules.EnterTile(s, Immune0, marrow, rng);

        Assert.Equal(marrow, done.Cells[Immune0].Position);
        Assert.Equal(0, done.Board.Tissues[marrow].Charge);
        Assert.NotEmpty(rng.Ranges);   // 抽那一张是带子上的一发（GD collect_special → draw）
        Assert.True(done.Cells[Immune0].Hand.Count >= handBefore);   // 抽到事件卡会当场结算而不进手
    }

    [Fact]
    public void 语义键带上目标_格用to_细胞用席位()
    {
        var s = World(0, "基质降解");
        Assert.Equal("k=action|act=play|card=基质降解|to=-3,0", SemanticKey.Of(s, new PlayCardDecision(0, Immune0, "基质降解", P(-3, 0))));
        Assert.Equal("k=action|act=play|card=免疫增援|cid=2", SemanticKey.Of(s, new PlayCardDecision(0, Immune0, "免疫增援", null, Immune2)));
    }
}
