namespace CellWar.Core.Tests;

/// <summary>
/// 【炎症性趋化】：连走最多 3 步、每步起价 0.2。
///
/// 判据钉的是**形状**而不是某一局的数：决策点的个数与归属、三条退出路径、
/// 起价与修饰管线的关系、候选的三条门槛、以及选项表逐格摊开这件事。
/// 权威实现是 GDScript 的 `cw_card_fx.gd:798-837`，这里每条都注明它对的是哪一句。
/// </summary>
public class ChemotaxisTests
{
    private const string Card = "炎症性趋化";
    private static readonly EntityId Walker = new(1);
    private static readonly HexPosition Origin = new(0, 0, 0);

    /// <summary>半径 radius 的全健康棋盘，原点站着一只带牌的免疫细胞。</summary>
    private static WorldState World(int radius = 2, int energy = 30, CellType type = CellType.ImmuneBasic)
    {
        var tissues = new Dictionary<HexPosition, Tissue>();
        for (var q = -radius; q <= radius; q++)
            for (var r = Math.Max(-radius, -q - radius); r <= Math.Min(radius, -q + radius); r++)
            {
                var pos = new HexPosition(q, r, -q - r);
                tissues[pos] = new Tissue
                {
                    Position = pos, Type = TissueType.Normal, State = TissueState.Healthy,
                    SolidificationCount = 0, OccupyingCell = pos == Origin ? Walker : null, Charge = 0
                };
            }
        var cells = new Dictionary<EntityId, Cell>
        {
            [Walker] = new()
            {
                Id = Walker, OwnerSeat = 0, Faction = Faction.Immune, Type = type, Position = Origin,
                Energy = energy, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(), Hand = [Card]
            }
        };
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
        };
        return new WorldState
        {
            Board = new Board { Radius = radius, Tissues = tissues }, Cells = cells, Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    private static WorldState Place(WorldState s, EntityId id, Faction faction, CellType type, HexPosition pos, int energy = 30)
    {
        s = s.Copy(cells: s.Cells.SetItem(id, new Cell
        {
            Id = id, OwnerSeat = faction == Faction.Immune ? 0 : 1, Faction = faction, Type = type,
            Position = pos, Energy = energy, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(), Hand = []
        }));
        return s.UpdateTissueOccupant(pos, id);
    }

    private static WorldState WithMod(WorldState s, ActiveModifier m)
        => s.UpdateCell(Walker, s.Cells[Walker].Copy(modifiers: [.. s.Cells[Walker].Modifiers, m]));

    private static HexPosition North => new(0, -1, 1);
    private static HexPosition South => new(0, 1, -1);

    private static readonly BasicRulesEngine Engine = new();
    private static IDeterministicRng Rng() => new Xoshiro256StarStar(7);

    private static WorldState Play(WorldState s, HexPosition first)
    {
        var result = Engine.ExecuteDecision(s, new PlayCardDecision(0, Walker, Card, first), Rng());
        Assert.True(result.Success);
        return result.NewState;
    }

    private static WorldState Step(WorldState s, HexPosition to)
    {
        var result = Engine.ExecuteDecision(s, new ChemotaxisStepDecision(0, Walker, to), Rng());
        Assert.True(result.Success);
        return result.NewState;
    }

    // ── 挂起态：决策点的个数与归属 ─────────────────────────────

    [Fact]
    public void 打出之后挂起_第一步当场走掉且还剩两步()
    {
        var after = Play(World(), North);

        Assert.Equal(North, after.Cells[Walker].Position);
        Assert.Equal(Walker, after.Turn.PendingChemotaxisCell);
        Assert.Equal(2, after.Turn.ChemotaxisStepsLeft);   // GD 的 `for step_no in [2, 3]`
        // 牌**还在手上**：GD 是整段趋化 await 回来才 erase（cw_card_fx.gd:399），第 2/3 步那两问上两边手牌得一样
        Assert.Contains(Card, after.Cells[Walker].Hand);
    }

    [Fact]
    public void 挂起期间只接这只细胞的走或停()
    {
        var after = Play(World(), North);
        var elsewhere = new HexPosition(0, -2, 2);
        var other = new EntityId(2);
        after = Place(after, other, Faction.Immune, CellType.ImmuneBasic, new HexPosition(2, 0, -2));

        Assert.True(Engine.ValidateDecision(after, new StopChemotaxisDecision(0, Walker)).IsValid);
        Assert.True(Engine.ValidateDecision(after, new ChemotaxisStepDecision(0, Walker, Origin)).IsValid);
        // 别的细胞、别的动作、结束回合一律驳回 —— GD 那边玩家根本回不到顶层菜单
        Assert.False(Engine.ValidateDecision(after, new ChemotaxisStepDecision(0, other, elsewhere)).IsValid);
        Assert.False(Engine.ValidateDecision(after, new StopChemotaxisDecision(0, other)).IsValid);
        Assert.False(Engine.ValidateDecision(after, new MoveDecision(0, Walker, Origin)).IsValid);
        Assert.False(Engine.ValidateDecision(after, new EndTurnDecision(0)).IsValid);
        Assert.False(Engine.ValidateDecision(after, new PassDecision(0)).IsValid);
        // **同一只细胞、非法落点**也驳回 —— GD 玩家答的是选项下标，根本递不进候选之外的格。
        // 少了这条，AI / 对拍递来的落点会绕过候选直进 Move：固化格以 0.2 走进去、远格 QuoteMove 为 null 当场抛。
        var solid = new HexPosition(1, -1, 0);   // North 的邻格，钉成固化
        after = after.UpdateTissueState(solid, TissueState.SolidifiedCancer);
        var far = new HexPosition(0, 2, -2);      // 离 North 三格
        Assert.False(Engine.ValidateDecision(after, new ChemotaxisStepDecision(0, Walker, solid)).IsValid);
        Assert.False(Engine.ValidateDecision(after, new ChemotaxisStepDecision(0, Walker, far)).IsValid);
    }

    /// <summary>
    /// 挂起的那一问是问**这只细胞的主人**的。GD 的 `ask(pid)` 只送到那一个桥，别的席位根本答不到；
    /// C# 的决策带着 PlayerSeat 从网络进来，只查 CellId 不查主人，对手就能替你「停在这里」。
    /// 对抗复核的 agent 在一份树副本上跑出来的（C1），连锁那一对同一个洞，一起钉。
    /// </summary>
    [Fact]
    public void 挂起期间别的席位递进来的走或停一律驳回()
    {
        var after = Play(World(), North);
        Assert.False(Engine.ValidateDecision(after, new StopChemotaxisDecision(1, Walker)).IsValid);
        Assert.False(Engine.ValidateDecision(after, new ChemotaxisStepDecision(1, Walker, Origin)).IsValid);
        Assert.True(Engine.ValidateDecision(after, new StopChemotaxisDecision(0, Walker)).IsValid);

        var chain = World(type: CellType.Macrophage).UpdateTissueState(North, TissueState.Cancer);
        chain = chain.UpdateCell(Walker, chain.Cells[Walker].Copy(chainLeft: 3)).WithTurn(chain.Turn.WithPendingChain(Walker));
        Assert.False(Engine.ValidateDecision(chain, new StopChainDecision(1, Walker)).IsValid);
        Assert.False(Engine.ValidateDecision(chain, new ChainMoveDecision(1, Walker, North)).IsValid);
        Assert.True(Engine.ValidateDecision(chain, new StopChainDecision(0, Walker)).IsValid);
    }

    // ── 「结算完」的时机：离手与细胞因子链在整段走完之后 ─────────
    // GD `_resolve_played`：match 里 `await _chemotaxis(...)` 整段回来才 `cell["hand"].erase(card)`、才 `_cytokine_chain`
    // （cw_card_fx.gd:311 / :399-402）。C# 此前是打出那一刻就离手 —— 改成挂起态之后这一步差第一次变得可观测：
    // 第 2/3 步两边手牌差一张，手牌到上限时还少一个强制弃置决策点（对拍复核 2026-09-16 证实）。

    [Fact]
    public void 停下走满或走死之后牌才离手()
    {
        var stopped = Engine.ExecuteDecision(Play(World(), North), new StopChemotaxisDecision(0, Walker), Rng()).NewState;
        Assert.DoesNotContain(Card, stopped.Cells[Walker].Hand);

        var walked = Step(Step(Play(World(), North), Origin), South);
        Assert.Null(walked.Turn.PendingChemotaxisCell);
        Assert.DoesNotContain(Card, walked.Cells[Walker].Hand);

        var dead = Engine.ExecuteDecision(Place(World(energy: 6), new EntityId(2), Faction.Cancer, CellType.Melanoma, North),
            new PlayCardDecision(0, Walker, Card, North), new AlwaysFailRng(Rng())).NewState;
        Assert.False(dead.Cells[Walker].IsAlive);
        Assert.DoesNotContain(Card, dead.Cells[Walker].Hand);   // GD 对死细胞照样 erase
    }

    /// <summary>
    /// 复核给的最小复现：装备【免疫记忆库】、手牌正好 8 张（含这张）、第 1 步走进癌组织触发【净化】→ 免费抽 1 张。
    /// GD 手里仍是 8 张 → 抽到 9 张 > 上限 → **先弹「手牌上限」追问**，弃完才问第 2 步；
    /// 此前 C# 手里只有 7 张 → 8 张不超限 → 直接问第 2 步 —— 决策点数量差一。
    /// </summary>
    [Fact]
    public void 手牌满时第一步的净化抽卡先弹强制弃置_弃完再问下一步()
    {
        // 其余 7 张用癌方的牌名：免疫抽不到它们，卡池不会被手牌「排空」
        var world = World().UpdateTissueState(North, TissueState.Cancer);
        world = world.UpdateCell(Walker, world.Cells[Walker].Copy(
            equipped: ["免疫记忆库"],
            hand: [Card, "缺氧适应", "GLUT1高表达", "RAS持续激活", "癌症干性", "PD-L1表达", "DNA损伤修复", "BCL-2抗凋亡"]));
        Assert.Equal(8, world.Cells[Walker].HandMax);
        // 抽到事件卡是当场结算、不进手（两边一样），那样就弹不出弃置 —— 把骰子钉在候选表里第一张**非事件**卡上
        var eligible = CardRules.EligibleCards(world, world.Cells[Walker]);
        var roll = 0;
        foreach (var d in eligible) { if (d.Category != CardCategory.Event) break; roll += d.Weight(0); }
        Assert.True(roll < eligible.Sum(d => d.Weight(0)), "卡池里没有非事件卡，这条夹具搭不起来");

        var after = Engine.ExecuteDecision(world, new PlayCardDecision(0, Walker, Card, North), new RollRng(roll)).NewState;

        Assert.Equal(9, after.Cells[Walker].Hand.Count);           // 抽到了，还没弃
        Assert.Equal(0, after.Turn.PendingDiscardSeat);            // 先问弃置
        Assert.Equal(Walker, after.Turn.PendingChemotaxisCell);    // 趋化的挂起还在，等弃完
        Assert.All(Engine.GetAvailableDecisions(after, 0), o => Assert.IsType<DiscardDecision>(o));

        var tossed = Engine.ExecuteDecision(after, new DiscardDecision(0, Walker, "缺氧适应"), Rng()).NewState;
        Assert.Null(tossed.Turn.PendingDiscardSeat);
        Assert.Contains(Card, tossed.Cells[Walker].Hand);          // 这张还没「结算完」，仍在手上
        Assert.NotEmpty(Engine.GetAvailableDecisions(tossed, 0).OfType<ChemotaxisStepDecision>());
    }

    [Fact]
    public void 细胞因子网络在整段走完之后才上膛()
    {
        var world = World().UpdateCell(Walker, World().Cells[Walker].Copy(equipped: ["细胞因子网络"]));
        var pending = Play(world, North);
        Assert.Equal(-1, pending.Turn.CytokineNetworkSeat);        // 第 2/3 步之前还没算「发动完」

        var done = Engine.ExecuteDecision(pending, new StopChemotaxisDecision(0, Walker), Rng()).NewState;
        Assert.Equal(0, done.Turn.CytokineNetworkSeat);
    }

    /// <summary>
    /// 挂起态跨不出这一回合（GD 是 play() 里的一段 await，语法上出不了这次打牌）。
    /// 正常路径到不了：挂起时「结束回合」被驳回。这是防御 —— 谁绕开 Execute 直接推阶段，
    /// 也不能让原主人在别人的回合里把剩下的几步走完（对抗复核 E1/E2）。
    /// </summary>
    [Fact]
    public void 推阶段把两个挂起态一并清掉()
    {
        var walk = Engine.AdvancePhase(Play(World(), North), Rng()).NewState;
        Assert.Null(walk.Turn.PendingChemotaxisCell);
        Assert.Equal(0, walk.Turn.ChemotaxisStepsLeft);

        var chain = World(type: CellType.Macrophage).WithTurn(World().Turn.WithPendingChain(Walker));
        Assert.Null(Engine.AdvancePhase(chain, Rng()).NewState.Turn.PendingChainCell);
    }

    // ── 提交复验：候选给得出来、走不成、步数照减 ──────────────
    // GD 的树突【各司其职】与攻击上限只在 `_is_move_legal_now` 里查、候选生成里**没有**，
    // `commit` 返回空字典 = 整步静默作废（不移动、不扣能量、无日志），外层循环照常推进到下一步。
    // 这两条曾经从 CommitLegal 里丢过：树突那条少了不是「多打一下」，是 `QuoteMove` 返回 null、
    // `Move` 里 `!.Value` 当场抛，整局炸掉 —— 15 个种子的整局走子第 1 个种子就撞上了。

    [Theory]
    [InlineData(CellType.Dendritic, 0)]      // 【I-各司其职】：树突不能通过【迁移】攻击癌细胞
    [InlineData(CellType.ImmuneBasic, 3)]    // 本回合攻击次数已达上限
    public void 树突或攻击次数用完时走进癌细胞那一步静默作废_步数照减(CellType type, int attacks)
    {
        var enemy = new EntityId(2);
        var world = Place(World(type: type), enemy, Faction.Cancer, CellType.Melanoma, North);
        world = world.UpdateCell(Walker, world.Cells[Walker].Copy(attacks: attacks));
        Assert.Contains(North, CellRules.ChemotaxisSteps(world, world.Cells[Walker]));   // 选项层照 GD 不过滤

        var after = Play(world, North);

        Assert.Equal(Origin, after.Cells[Walker].Position);
        Assert.Equal(world.Cells[Walker].Energy, after.Cells[Walker].Energy);
        Assert.Equal(attacks, after.Cells[Walker].AttacksThisTurn);
        Assert.Equal(30, after.Cells[enemy].Energy);
        Assert.Equal(2, after.Turn.ChemotaxisStepsLeft);              // 作废的那一步也算一步
        Assert.Equal(Walker, after.Turn.PendingChemotaxisCell);        // 照常问第 2 步
        Assert.NotEmpty(Engine.GetAvailableDecisions(after, 0).OfType<ChemotaxisStepDecision>());
    }

    /// <summary>
    /// **已知取舍，钉住免得停在「不知道是取舍还是漏掉」**：卡牌效果表的签名只吐 WorldState（整张表都这样），
    /// 第 1 步的移动/攻击/净化事件到不了日志；第 2/3 步走 DecisionRouter，事件原样上浮。
    /// 要让三步一致得改效果表签名，属另一张单。
    /// </summary>
    [Fact]
    public void 第一步的事件被效果表吞掉_第二步的照常上浮()
    {
        var first = Engine.ExecuteDecision(World(), new PlayCardDecision(0, Walker, Card, North), Rng());
        Assert.True(first.Success);
        Assert.Empty(first.Events);

        var second = Engine.ExecuteDecision(first.NewState, new ChemotaxisStepDecision(0, Walker, Origin), Rng());
        Assert.True(second.Success);
        Assert.NotEmpty(second.Events);
    }

    [Fact]
    public void 挂起期间的选项是停在这里加上每个合法落点_停止排在最前()
    {
        var after = Play(World(), North);
        var options = Engine.GetAvailableDecisions(after, 0);

        Assert.IsType<StopChemotaxisDecision>(options[0]);   // GD `game.ask` 约定：可以不做的那条在下标 0
        var steps = options.Skip(1).Cast<ChemotaxisStepDecision>().ToArray();
        Assert.Equal(steps.Length, options.Count - 1);
        Assert.All(steps, x => Assert.Equal(Walker, x.CellId));
        Assert.Equal(
            CellRules.ChemotaxisSteps(after, after.Cells[Walker]).OrderBy(p => p.Q).ThenBy(p => p.R),
            steps.Select(x => x.Target).OrderBy(p => p.Q).ThenBy(p => p.R));
        // 挂起是这只细胞的主人的事，别的席位一条都看不到
        Assert.Empty(Engine.GetAvailableDecisions(after, 1));
    }

    // ── 四条退出路径 ────────────────────────────────────────

    [Fact]
    public void 走满三步之后不再追问()
    {
        var after = Play(World(), North);
        after = Step(after, Origin);
        Assert.Equal(Walker, after.Turn.PendingChemotaxisCell);   // 第 2 步走完还剩 1 步

        after = Step(after, South);

        Assert.Null(after.Turn.PendingChemotaxisCell);
        Assert.Equal(South, after.Cells[Walker].Position);
        Assert.Empty(Engine.GetAvailableDecisions(after, 0).OfType<ChemotaxisStepDecision>());
    }

    [Fact]
    public void 玩家选停就结束_细胞留在原地()
    {
        var after = Play(World(), North);
        var stopped = Engine.ExecuteDecision(after, new StopChemotaxisDecision(0, Walker), Rng()).NewState;

        Assert.Null(stopped.Turn.PendingChemotaxisCell);
        Assert.Equal(North, stopped.Cells[Walker].Position);
        Assert.Equal(after.Cells[Walker].Energy, stopped.Cells[Walker].Energy);
    }

    [Fact]
    public void 没有可走的下一步就直接结束_不会只剩一个停止选项()
    {
        // 只留原点与北边一格的棋盘，原点再钉成固化癌组织：走过去之后回不来，也没有别的邻格
        var world = World(radius: 1);
        var keep = new[] { Origin, North };
        world = world.Copy(board: new Board
        {
            Radius = world.Board.Radius,
            Tissues = world.Board.Tissues.Where(kv => keep.Contains(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value)
        });
        world = world.UpdateTissueState(Origin, TissueState.SolidifiedCancer);

        var after = Play(world, North);

        Assert.Null(after.Turn.PendingChemotaxisCell);
        Assert.Empty(Engine.GetAvailableDecisions(after, 0).OfType<StopChemotaxisDecision>());
    }

    [Fact]
    public void 细胞在途中死掉就结束()
    {
        // 攻击无效会反弹 0.5 —— 起价 0.2 + 反弹 0.5 正好打死一只 0.6 的细胞
        var world = Place(World(energy: 6), new EntityId(2), Faction.Cancer, CellType.Melanoma, North);
        var result = Engine.ExecuteDecision(world, new PlayCardDecision(0, Walker, Card, North), new AlwaysFailRng(Rng()));

        Assert.False(result.NewState.Cells[Walker].IsAlive);
        Assert.Null(result.NewState.Turn.PendingChemotaxisCell);
        Assert.Empty(Engine.GetAvailableDecisions(result.NewState, 0).OfType<StopChemotaxisDecision>());
    }

    [Fact]
    public void 连续吞噬的连锁没排干之前不问趋化的下一步()
    {
        // GD 那边连锁问答嵌在 `_do_move` 内部，整条 return 了外层循环才继续 ——
        // 两个挂起态可以同时存在（巨噬打这张卡、某一步净化又连上），次序不能反
        var world = World(type: CellType.Macrophage);
        world = world.UpdateTissueState(North, TissueState.Cancer);
        world = world.UpdateCell(Walker, world.Cells[Walker].Copy(chainLeft: 3));
        world = world.WithTurn(world.Turn.WithPendingChain(Walker).WithPendingChemotaxis(Walker, 2));

        var options = Engine.GetAvailableDecisions(world, 0);

        Assert.All(options, o => Assert.True(o is ChainMoveDecision or StopChainDecision));
        Assert.False(Engine.ValidateDecision(world, new ChemotaxisStepDecision(0, Walker, South)).IsValid);
        // 归一化也要让着连锁：步数还在，挂起不许被提前摘掉
        Assert.Equal(Walker, CellRules.NormalizeChemotaxis(world).Turn.PendingChemotaxisCell);
    }

    /// <summary>
    /// 连锁没排干时，**哪怕此刻一个候选都没有**，归一化也不许摘掉趋化的挂起。
    ///
    /// 上一条测试里候选本来就非空，所以「让着连锁」那行删了也绿（变异检验抓出来的）。
    /// 它不是等价变异：GD 是连锁在 `_do_move` 内部跑完**之后**才回到 `_chemotaxis` 重算候选 ——
    /// 连锁里的净化会让能量回来（【模式识别增强】【效应记忆形成】各 +0.5），
    /// 刚才付不起 0.2 的细胞排干连锁后就付得起了，GD 会照常问第 2 步。提前摘掉就少了一个决策点。
    /// 这里直接钉次序本身：连锁在 → 不动；连锁排干、仍付不起 → 才摘。
    /// </summary>
    [Fact]
    public void 连锁没排干时哪怕没有候选也不摘趋化_排干后才按候选判()
    {
        var world = World(type: CellType.Macrophage, energy: 2);   // 付不起 0.2（要留 0.1）
        world = world.UpdateTissueState(North, TissueState.Cancer);
        world = world.UpdateCell(Walker, world.Cells[Walker].Copy(chainLeft: 3));
        world = world.WithTurn(world.Turn.WithPendingChain(Walker).WithPendingChemotaxis(Walker, 1));
        Assert.Empty(CellRules.ChemotaxisSteps(world, world.Cells[Walker]));

        Assert.Equal(Walker, CellRules.NormalizeChemotaxis(world).Turn.PendingChemotaxisCell);

        var drained = Engine.ExecuteDecision(world, new StopChainDecision(0, Walker), Rng()).NewState;
        Assert.Null(drained.Turn.PendingChainCell);
        Assert.Null(drained.Turn.PendingChemotaxisCell);   // 排干了、还是付不起 → 这时才结束
    }

    // ── 费用：0.2 是**起价**，管线整条照跑 ───────────────────

    [Fact]
    public void 每步起价零点二并且过完整条修饰管线()
    {
        // 一条只剩 1 次的减费修饰：验它**确实参与了**这一步的计价，并且被这一步消耗掉
        var world = WithMod(World(),
            new ActiveModifier("LFA-1黏附", ModifierTarget.Move, ModifierStage.Subtract, SourceLayer.Card, 0, 1, 0, 1, ModifierDuration.Turn));
        var before = world.Cells[Walker].Energy;

        var after = Play(world, North);
        Assert.Equal(before - 1, after.Cells[Walker].Energy);                 // 0.2 − 0.1
        Assert.DoesNotContain(after.Cells[Walker].Modifiers, m => m.Card == "LFA-1黏附");

        after = Step(after, Origin);
        Assert.Equal(before - 1 - CellRules.ChemotaxisStepCost, after.Cells[Walker].Energy);   // 额度用完，回到 0.2
    }

    [Fact]
    public void 费用改为X的修饰会盖掉零点二的起价()
    {
        // GD 侧 0.2 进的是 `ctx.base_cost`，而 REPLACE 排在它之后 —— 覆盖方向是这一条
        var world = WithMod(World(), new ActiveModifier("炎症趋化", ModifierTarget.Move, ModifierStage.Replace,
            SourceLayer.Card, 0, 5, null, ActiveModifier.Unlimited, ModifierDuration.Turn, ModifierRequirement.MoveToCancerous));
        world = world.UpdateTissueState(North, TissueState.Cancer);
        var before = world.Cells[Walker].Energy;

        var after = Play(world, North);

        Assert.Equal(before - 5, after.Cells[Walker].Energy);
    }

    [Fact]
    public void 这张卡不给细胞挂任何改价修饰_本回合别的迁移照原价()
    {
        var world = World();
        var normalBefore = RulePolicies.BaseMoveCost(world, world.Cells[Walker], North);

        var after = Play(world, South);

        Assert.DoesNotContain(after.Cells[Walker].Modifiers, m => m.Card == Card);
        Assert.Equal(normalBefore, RulePolicies.BaseMoveCost(after, after.Cells[Walker], Origin));
        Assert.NotEqual(CellRules.ChemotaxisStepCost, normalBefore);   // 否则这条判据自己就失效了
    }

    // ── 候选的三条门槛 ──────────────────────────────────────

    [Fact]
    public void 固化癌组织与免疫细胞占着的格走不了_癌细胞占着的格走得了()
    {
        var solid = new HexPosition(1, -1, 0);
        var mate = new HexPosition(1, 0, -1);
        var enemy = North;
        var world = World();
        world = world.UpdateTissueState(solid, TissueState.SolidifiedCancer);
        world = Place(world, new EntityId(2), Faction.Immune, CellType.ImmuneBasic, mate);
        world = Place(world, new EntityId(3), Faction.Cancer, CellType.Melanoma, enemy);

        var steps = CellRules.ChemotaxisSteps(world, world.Cells[Walker]);

        Assert.DoesNotContain(solid, steps);
        Assert.DoesNotContain(mate, steps);
        Assert.Contains(enemy, steps);   // 走进去就是攻击，卡面明写「正常触发…攻击」
    }

    [Fact]
    public void 走进癌细胞占着的格是一次攻击_无效则留在原地但步数照减()
    {
        var enemy = new EntityId(2);
        var world = Place(World(), enemy, Faction.Cancer, CellType.Melanoma, North);
        var after = Engine.ExecuteDecision(world, new PlayCardDecision(0, Walker, Card, North), new AlwaysFailRng(Rng())).NewState;

        Assert.Equal(1, after.Cells[Walker].AttacksThisTurn);          // 发动即计数，不看判定结果
        Assert.Equal(Origin, after.Cells[Walker].Position);            // 攻击无效不位移
        Assert.Equal(30, after.Cells[enemy].Energy);
        Assert.Equal(30 - CellRules.ChemotaxisStepCost - 5, after.Cells[Walker].Energy);   // 起价 0.2 + 反弹 0.5
        Assert.Equal(2, after.Turn.ChemotaxisStepsLeft);               // 「这一步没走成」不等于少走一步
    }

    [Fact]
    public void 付不起零点二的格不进候选()
    {
        // can_pay 是「付完至少留 0.1」：0.2 的价钱要 0.3 才走得起
        Assert.Empty(CellRules.ChemotaxisSteps(World(energy: 2), World(energy: 2).Cells[Walker]));
        Assert.NotEmpty(CellRules.ChemotaxisSteps(World(energy: 3), World(energy: 3).Cells[Walker]));
    }

    // ── 选项表 ─────────────────────────────────────────────

    [Fact]
    public void 选项表里这张卡按合法第一步逐格摊开()
    {
        var world = World();
        var plays = Engine.GetAvailableDecisions(world, 0).OfType<PlayCardDecision>().Where(p => p.Card == Card).ToArray();

        Assert.Equal(CellRules.ChemotaxisSteps(world, world.Cells[Walker]).Count, plays.Length);
        Assert.All(plays, p => Assert.NotNull(p.Target));
        Assert.Equal(
            CellRules.ChemotaxisSteps(world, world.Cells[Walker]).OrderBy(p => p.Q).ThenBy(p => p.R),
            plays.Select(p => p.Target!.Value).OrderBy(p => p.Q).ThenBy(p => p.R));
    }

    [Fact]
    public void 一个合法落点都没有时这张卡不出现在选项表里()
    {
        // 六个邻格全钉成固化癌组织：落空的卡不该出现在行动栏（同【局部吞噬】【TNF-α局部炎症】的纪律）
        var world = World();
        foreach (var n in Origin.GetNeighbors()) world = world.UpdateTissueState(n, TissueState.SolidifiedCancer);

        Assert.DoesNotContain(Engine.GetAvailableDecisions(world, 0).OfType<PlayCardDecision>(), p => p.Card == Card);
    }

    [Fact]
    public void 没带落点或落点非法的打出一律驳回()
    {
        var world = World();
        var solid = new HexPosition(1, -1, 0);
        world = world.UpdateTissueState(solid, TissueState.SolidifiedCancer);

        Assert.False(Engine.ValidateDecision(world, new PlayCardDecision(0, Walker, Card)).IsValid);
        Assert.False(Engine.ValidateDecision(world, new PlayCardDecision(0, Walker, Card, solid)).IsValid);
        Assert.True(Engine.ValidateDecision(world, new PlayCardDecision(0, Walker, Card, North)).IsValid);
    }

    /// <summary>每次 `NextInt` 都给同一个数（钳在值域内）：用来把抽卡钉在候选表的某一张上。</summary>
    private sealed class RollRng(int roll) : IDeterministicRng
    {
        public double NextDouble() => 0;
        public int NextInt(int max) => Math.Min(roll, max - 1);
        public int NextIntRange(int min, int max) => min + Math.Min(roll, max - min - 1);
        public T Choose<T>(IReadOnlyList<T> items) => items[NextInt(items.Count)];
        public IReadOnlyList<T> PickRandom<T>(IReadOnlyList<T> items, int count) => items.Take(count).ToList();
        public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items) => items;
        public IDeterministicRng Fork() => this;
        public RngState GetState() => new(1, 0);
        public void SetState(RngState state) { }
    }

    /// <summary>把 d6 钉死成 1（`AttackOutcome` 里 roll ≤ 2 即无效），别的抽取照常委托。</summary>
    private sealed class AlwaysFailRng(IDeterministicRng inner) : IDeterministicRng
    {
        public double NextDouble() => inner.NextDouble();
        public int NextInt(int max) => inner.NextInt(max);
        public int NextIntRange(int min, int max) => min;
        public T Choose<T>(IReadOnlyList<T> items) => inner.Choose(items);
        public IReadOnlyList<T> PickRandom<T>(IReadOnlyList<T> items, int count) => inner.PickRandom(items, count);
        public IReadOnlyList<T> Shuffle<T>(IReadOnlyList<T> items) => inner.Shuffle(items);
        public IDeterministicRng Fork() => new AlwaysFailRng(inner.Fork());
        public RngState GetState() => inner.GetState();
        public void SetState(RngState state) => inner.SetState(state);
    }
}
