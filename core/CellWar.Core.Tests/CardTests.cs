namespace CellWar.Core.Tests;

public class CardTests
{
    private static WorldState World(CellType type, Faction faction, int energy = 30,
        ImmuneLevel level = ImmuneLevel.I, IReadOnlyList<string>? hand = null, int draws = 0, bool mutateUsed = false, int? pendingDiscard = null)
    {
        var pos = new HexPosition(0, 0, 0);
        var id = new EntityId(1);
        var tissues = new Dictionary<HexPosition, Tissue>
        {
            [pos] = new Tissue { Position = pos, Type = TissueType.Normal, State = TissueState.Healthy, SolidificationCount = 0, OccupyingCell = id, Charge = 0 }
        };
        var cells = new Dictionary<EntityId, Cell>
        {
            [id] = new Cell { Id = id, OwnerSeat = 0, Faction = faction, Type = type, Position = pos, Energy = energy,
                IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(), Hand = hand ?? [], DrawsThisTurn = draws, MutateUsedThisRound = mutateUsed }
        };
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = faction, IsAlive = true, DrawCount = 0, AntigenMemory = 0,
                ImmuneLevel = faction == Faction.Immune ? level : ImmuneLevel.I, CancerType = faction == Faction.Cancer ? CellType.Melanoma : null },
            [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.SignetRing }
        };
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tissues }, Cells = cells, Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0, PendingDiscardSeat = pendingDiscard }
        };
    }

    [Fact]
    public void DrawRejectedWhenNoLegalCardInPool()
    {
        var engine = new BasicRulesEngine();
        // I 级池中已实现的全部在手 → 已无可抽
        var implementedI = CardCatalog.Pool(CardPool.ImmuneI).Where(CardImplementation.IsImplemented).Select(c => c.Name).ToArray();
        var world = World(CellType.ImmuneBasic, Faction.Immune, hand: implementedI);
        var id = world.Cells.Keys.Single();
        Assert.False(engine.ValidateDecision(world, new DrawDecision(0, id)).IsValid);
    }

    [Fact]
    public void DrawRejectedWhenTurnQuotaUsedOrEnergyTooLow()
    {
        var engine = new BasicRulesEngine();
        var id = new EntityId(1);
        var quota = World(CellType.ImmuneBasic, Faction.Immune, draws: 3);
        Assert.False(engine.ValidateDecision(quota, new DrawDecision(0, id)).IsValid);
        var broke = World(CellType.ImmuneBasic, Faction.Immune, energy: 5);
        Assert.False(engine.ValidateDecision(broke, new DrawDecision(0, id)).IsValid);
    }

    [Fact]
    public void DrawChargesEnergyAndConsumesQuota()
    {
        var engine = new BasicRulesEngine();
        // 排掉已实现的事件卡，只剩【细胞膜修复】可抽，隔离事件即时结算的影响
        var world = World(CellType.ImmuneBasic, Faction.Immune, energy: 30,
            hand: ["急性炎症反应", "抗原摄取", "局部吞噬"]);
        var id = world.Cells.Keys.Single();
        Assert.True(engine.ValidateDecision(world, new DrawDecision(0, id)).IsValid);
        var after = engine.ExecuteDecision(world, new DrawDecision(0, id), new Xoshiro256StarStar(5)).NewState;
        Assert.Equal(25, after.Cells[id].Energy);
        Assert.Equal(1, after.Cells[id].DrawsThisTurn);
        Assert.Equal(4, after.Cells[id].Hand.Count);
    }

    [Fact]
    public void OverflowHandForcesDiscardUntilWithinLimit()
    {
        var engine = new BasicRulesEngine();
        var nine = new[] { "a", "b", "c", "d", "e", "f", "g", "h", "i" };
        var world = World(CellType.ImmuneBasic, Faction.Immune, hand: nine, pendingDiscard: 0);
        var id = world.Cells.Keys.Single();

        var options = engine.GetAvailableDecisions(world, 0);
        Assert.Equal(9, options.Count);
        Assert.All(options, o => Assert.IsType<DiscardDecision>(o));
        Assert.Empty(engine.GetAvailableDecisions(world, 1));

        var after = engine.ExecuteDecision(world, new DiscardDecision(0, id, "a"), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(8, after.Cells[id].Hand.Count);
        Assert.Null(after.Turn.PendingDiscardSeat);
    }

    [Fact]
    public void MutateCostsHalfOncePerWorldRound()
    {
        var engine = new BasicRulesEngine();
        var world = World(CellType.Melanoma, Faction.Cancer, energy: 30);
        var id = world.Cells.Keys.Single();
        Assert.True(engine.ValidateDecision(world, new MutateDecision(0, id)).IsValid);
        var after = engine.ExecuteDecision(world, new MutateDecision(0, id), new Xoshiro256StarStar(2)).NewState;
        Assert.True(after.Cells[id].MutateUsedThisRound);
        Assert.True(after.Cells[id].Energy <= 25);
        Assert.False(engine.ValidateDecision(after, new MutateDecision(0, id)).IsValid);
    }

    [Fact]
    public void PlayingMembraneRepairAddsEnergyLossModifier()
    {
        var engine = new BasicRulesEngine();
        var world = World(CellType.ImmuneBasic, Faction.Immune, hand: ["细胞膜修复"]);
        var id = world.Cells.Keys.Single();
        Assert.True(engine.ValidateDecision(world, new PlayCardDecision(0, id, "细胞膜修复")).IsValid);
        var after = engine.ExecuteDecision(world, new PlayCardDecision(0, id, "细胞膜修复"), new Xoshiro256StarStar(1)).NewState;
        Assert.DoesNotContain("细胞膜修复", after.Cells[id].Hand);
        var mod = Assert.Single(after.Cells[id].Modifiers);
        Assert.Equal(ModifierTarget.EnergyLoss, mod.Target);
        Assert.Equal(15, mod.Value);
    }

    [Fact]
    public void EquippedAerobicPermanentsIncreaseRespiration()
    {
        var engine = new BasicRulesEngine();
        var world = World(CellType.ImmuneBasic, Faction.Immune, energy: 0);
        var id = world.Cells.Keys.Single();
        world = world.UpdateCell(id, world.Cells[id].Copy(equipped: ["代谢适应", "自分泌生存信号"]));
        world = world.WithTurn(world.Turn.Copy(phase: Phase.S, startStep: 1));
        var after = engine.AdvancePhase(world, new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(33, after.Cells[id].Energy); // I 级 20 + 5 + 8
    }

    [Fact]
    public void EveryCatalogCardHasImplementation()
    {
        var missing = CardCatalog.All.Where(c => !CardImplementation.IsImplemented(c)).Select(c => c.Name).Distinct().ToArray();
        Assert.True(missing.Length == 0, "未实现效果的卡牌: " + string.Join(", ", missing));
    }

    [Fact]
    public void CardCatalogMatchesPrdPools()
    {
        Assert.Equal(11, CardCatalog.Pool(CardPool.ImmuneI).Count());
        Assert.Equal(14, CardCatalog.Pool(CardPool.ImmuneII).Count());
        Assert.Equal(17, CardCatalog.Pool(CardPool.ImmuneIII).Count());
        Assert.Equal(22, CardCatalog.Pool(CardPool.ImmuneX).Count());
        Assert.Equal(18, CardCatalog.Pool(CardPool.Cancer).Count());
        // 癌症卡按肿瘤分期三档权重
        var glycolysis = CardCatalog.ByCardName("糖酵解爆发").Single();
        Assert.Equal(3, glycolysis.Weight(0));
        Assert.Equal(4, glycolysis.Weight(1));
        Assert.Equal(6, glycolysis.Weight(2));
    }

    // 事件卡抽取即结算、即时卡打出即结算：已实现的这两类卡都必须在 CardRules 注册表里有独立效果，
    // 否则会像旧 switch 的 default 一样被静默跳过。永久技能可为纯被动（如组织驻留），不强制登记。
    [Fact]
    public void EveryImplementedEventAndInstantCardHasRegisteredEffect()
    {
        var missing = CardCatalog.All
            .Where(c => c.Category is CardCategory.Event or CardCategory.Instant)
            .Where(CardImplementation.IsImplemented)
            .Where(c => !CardRules.IsRegistered(c.Name))
            .Select(c => c.Name).Distinct().ToArray();
        Assert.True(missing.Length == 0, "缺少卡牌效果登记: " + string.Join(", ", missing));
    }

    [Fact]
    public void RegisteredCardNamesExistInCatalog()
    {
        var unknown = CardRules.RegisteredNames.Where(n => !CardCatalog.ByCardName(n).Any()).ToArray();
        Assert.True(unknown.Length == 0, "注册表含目录外卡名: " + string.Join(", ", unknown));
    }
}


