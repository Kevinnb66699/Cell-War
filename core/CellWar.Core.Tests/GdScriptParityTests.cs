using System.Text.RegularExpressions;
using CellWar.Core;

namespace CellWar.Core.Tests;

/// <summary>
/// **拿 GDScript 的常量表当真相源**，逐条断言 C# 侧的数值与它一致。
///
/// 由来：2026-09-15 的单位核对在 C# 里查出 **16 处**把「1.0 能量」写成 `1`（= 0.1）的地方 ——
/// 整整 12 个效果只有应有强度的 1/10，而 141 个测试一条都没红。
/// 更糟的是有两条测试**名字叫 MatchPrd、断言的却是当时代码里的值**
/// （【糖酵解爆发】权重、III 级迁移费），于是它们非但没抓到偏离，反而把偏离钉住了。
///
/// 所以这一组不写字面量，而是**去读 `game/scripts/core/cw_data.gd`**。
/// 迁移期 GDScript 是权威实现（3506 项检查盯着），C# 是被测方 —— 这正是它们的关系。
/// 等 GDScript 内核退役，这一组连同它的真相源一起归档。
///
/// 每一条失败时都会打印「GD 说多少、C# 是多少」，不用去翻两个文件对。
/// </summary>
public class GdScriptParityTests
{
    // ---- 单位：能量与固化计数都是十分位整数 ----

    [Theory]
    [InlineData("HYPOXIA_CUT", 10)]            // 【缺氧适应】挡下 1.0
    [InlineData("IFN1_CUT", 10)]               // 【I型干扰素】挡下 1.0
    [InlineData("EXHAUST_FIRST_CUT", 10)]      // 【耗竭抵抗】每回合首次损失 -1.0
    [InlineData("AFFINITY_EXTRA", 10)]         // 【高亲和力克隆】额外 1.0
    [InlineData("CYTOTOX_EXTRA", 10)]          // 【细胞毒性增强】攻击成功额外 1.0
    [InlineData("EXCALIBUR_RAY_DMG", 20)]      // Excalibur 主射线 2.0
    [InlineData("EXCALIBUR_SPLASH_DMG", 10)]   // Excalibur 侧向 1.0
    [InlineData("CHEMO_COST", 30)]             // 【趋化源】3.0
    [InlineData("MUCUS_MIN_ENERGY", 20)]       // 【黏液破裂】门槛 2.0
    [InlineData("SOLIDIFY_STEP", 10)]          // 固化计数每回合 +1.0
    [InlineData("MACRO_HEAL_PURIFY", 2)]       // 巨噬【I-吞噬】迁移净化回 0.2
    [InlineData("ATTACK_DMG_SUCCESS", 10)]     // 攻击成功 1.0
    [InlineData("ATTACK_DMG_CRIT", 20)]        // 大成功 2.0
    public void GDScript常量就是我们期望的那个数(string name, int expected)
    {
        var actual = GdConst(name);
        Assert.True(actual == expected,
            $"GDScript 的 {name} 是 {actual}，而这条测试期望 {expected} —— " +
            "两边都要查：是 GDScript 改了规则（那 C# 要跟），还是这条期望写错了（那改期望，别改 GDScript）。");
    }

    // ---- ⚠ 上面那条只验了「GDScript 没变」，**没有验 C# 跟上了没有** ----
    //
    // 这是我 2026-09-15 当天第二次犯同一个错：早上写的骰面值域测试测到了 rng 助手、
    // 不是调用点；这里又只读了 cw_data.gd、没碰 C# 的行为。
    // 变异检验当场戳穿：把【趋化源】改回那个「不扣费还涨 10 倍」的漏洞版，**184 条全绿**。
    //
    // 所以下面每一条都**真的执行一次规则**，拿 C# 算出来的数和 GDScript 常量比。

    /// <summary>
    /// 【趋化源】扣 3.0。**这一条是那个无限能量漏洞的直接判据** ——
    /// 旧代码 `Round(cell.Energy - 2)` 会把 3.0 变成 28.0，所以除了「扣对」还要断言「能量确实变少了」。
    /// </summary>
    [Fact]
    public void 趋化源真的扣掉三点能量而不是凭空涨()
    {
        var world = DendriticWorld(energy: 300);
        var before = world.Cells[new EntityId(1)].Energy;

        var after = new BasicRulesEngine().ExecuteDecision(world,
            new TypeSkillDecision(0, new EntityId(1), "趋化源", new HexPosition(2, 0, -2)),
            new Xoshiro256StarStar(1)).NewState;
        var now = after.Cells[new EntityId(1)].Energy;

        Assert.True(now < before, $"能量不减反增：{before} → {now}（这正是那个无限能量漏洞的形状）");
        Assert.Equal(before - GdConst("CHEMO_COST"), now);
    }

    /// <summary>能量刚好不够时不许发动 —— 判据必须和实扣是同一个数（原来判 20、扣 30，对不上）。</summary>
    [Fact]
    public void 趋化源的合法性判据与实扣是同一个数()
    {
        var cost = GdConst("CHEMO_COST");
        var engine = new BasicRulesEngine();
        var decision = new TypeSkillDecision(0, new EntityId(1), "趋化源", new HexPosition(2, 0, -2));

        // CanPay 的语义是「付完还要剩下」，所以正好等于费用时不许发动
        Assert.False(engine.ValidateDecision(DendriticWorld(cost), decision).IsValid);
        Assert.True(engine.ValidateDecision(DendriticWorld(cost + 1), decision).IsValid);
    }

    /// <summary>【细胞毒素】对 1 环内每个癌细胞造成 1.0（原来写 1 = 0.1）。</summary>
    [Fact]
    public void 细胞毒素造成一点能量损失()
    {
        var world = TCellVersusCancer();
        var before = world.Cells[new EntityId(2)].Energy;

        var after = new BasicRulesEngine().ExecuteDecision(world,
            new TypeSkillDecision(0, new EntityId(1), "细胞毒素"),
            new Xoshiro256StarStar(1)).NewState;

        Assert.Equal(before - GdConst("ATTACK_DMG_SUCCESS"), after.Cells[new EntityId(2)].Energy);
    }

    /// <summary>
    /// 减伤类修饰挂上去的值必须是十分位的 1.0，不是 0.1。
    /// 直接读挂在细胞身上的 ActiveModifier，比「打一拳看少扣多少」更直接、也更难被别的规则干扰。
    /// </summary>
    [Theory]
    [InlineData("缺氧适应", "HYPOXIA_CUT")]
    [InlineData("I型干扰素", "IFN1_CUT")]
    public void 减伤卡挂上去的值是十分位(string card, string gdConst)
    {
        var world = ImmuneWithHand(card);
        var after = CardRules.Resolve(world, world.Cells[new EntityId(1)], card, new Xoshiro256StarStar(1), null, null);

        var mod = after.Cells[new EntityId(1)].Modifiers.SingleOrDefault(m => m.Card == card);
        Assert.NotNull(mod);
        Assert.Equal(GdConst(gdConst), mod!.Value);
    }

    /// <summary>【高亲和力克隆】额外 1.0 —— 同上，读修饰的值。</summary>
    [Fact]
    public void 高亲和力克隆的额外伤害是十分位()
    {
        var world = ImmuneWithHand("高亲和力克隆");
        var after = CardRules.Resolve(world, world.Cells[new EntityId(1)], "高亲和力克隆", new Xoshiro256StarStar(1), null, null);

        var mod = after.Cells[new EntityId(1)].Modifiers.Single(m => m.Card == "高亲和力克隆");
        Assert.Equal(GdConst("AFFINITY_EXTRA"), mod.Value);
    }

    /// <summary>
    /// 【抗体亲和力成熟】三条都要在（PRD:1325）。此前 C# 只实现了「攻击邻健康癌细胞 +0.5」那一条。
    /// 这里验另外两条：费用降 0.5、抗体初始伤害改 2.0。
    /// </summary>
    [Fact]
    public void 抗体亲和力成熟把费用降半点并把伤害抬到两点()
    {
        var plain = RulePolicies.AntibodyDamage(0, matured: false);
        var matured = RulePolicies.AntibodyDamage(0, matured: true);
        Assert.Equal(GdConst("ANTIBODY_DAMAGE"), plain);
        Assert.Equal(GdConst("MATURED_ANTIBODY_DMG"), matured);

        // 费用：装了之后实扣要少 MATURED_ANTIBODY_CUT，而且**合法性判据要跟着降**
        // （判与扣对不上正是【趋化源】那条 bug 的形状）
        var cut = GdConst("MATURED_ANTIBODY_CUT");
        var full = GdConst("ANTIBODY_COST");
        var world = BCellWorld(energy: full, matured: true);
        var decision = new TypeSkillDecision(0, new EntityId(1), "抗体");
        Assert.True(new BasicRulesEngine().ValidateDecision(world, decision).IsValid,
            $"装了【抗体亲和力成熟】之后费用应降到 {full - cut}，{full} 能量该发得动");

        var rich = BCellWorld(energy: 300, matured: true);
        var after = new BasicRulesEngine().ExecuteDecision(rich, decision, new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(300 - (full - cut), after.Cells[new EntityId(1)].Energy);
    }

    /// <summary>
    /// 【耗竭抵抗】是**两段**（PRD:1277）：每世界回合首次损失 -1.0 **＋ 微环境压迫额外 -0.5**。
    /// C# 此前只实现了第一段。
    /// </summary>
    [Fact]
    public void 耗竭抵抗在微环境压迫上额外减半点()
    {
        var withSkill = PressureWorld(exhaustion: true);
        var without = PressureWorld(exhaustion: false);
        var engine = new BasicRulesEngine();
        var rng = new Xoshiro256StarStar(9);

        var lossWith = 300 - engine.AdvancePhase(withSkill, rng).NewState.Cells[new EntityId(1)].Energy;
        var lossWithout = 300 - engine.AdvancePhase(without, new Xoshiro256StarStar(9)).NewState.Cells[new EntityId(1)].Energy;

        // 这条**只验第二段**：夹具直接从 E 阶段跑，而第一段（每世界回合首次损失 -1.0）
        // 是回合开始时由 PhaseRules.GrantTurnModifiers 挂上去的 EnergyLoss 修饰，这里没走到。
        // 想两段一起验就得连回合流程一起跑，那属于整局层面的测试，不该塞进这条。
        Assert.True(lossWithout > 0, "夹具本身要真的产生压迫损失，否则这条什么都证明不了");
        Assert.Equal(lossWithout - GdConst("EXHAUST_PRESSURE_CUT"), lossWith);
    }

    /// <summary>免疫→癌性迁移费按等级分档：PRD 只写了 II 级 0.8，III/X 沿用（Kevin 2026-09-15 裁定）。</summary>
    [Fact]
    public void 免疫迁移到癌性组织的四档与GDScript一致()
    {
        var gd = GdIntArray("IMMUNE_MOVE_CANCEROUS");
        Assert.Equal(4, gd.Count);

        var levels = new[] { ImmuneLevel.I, ImmuneLevel.II, ImmuneLevel.III, ImmuneLevel.X };
        for (var i = 0; i < 4; i++)
        {
            var world = MoveCostWorld(levels[i]);
            var cost = new BasicRulesEngine().QuoteMove(world, world.Cells[new EntityId(1)], new HexPosition(1, 0, -1));
            Assert.True(cost == gd[i],
                $"{levels[i]} 级迁移到癌性组织：GDScript {gd[i]}，C# {cost}");
        }
    }

    /// <summary>
    /// 【E-无氧呼吸】的系数与指数按人数分档。
    /// C# 原来写死 `six ? 2.8 : 2.0` / `six ? 0.35 : 0.3` —— **两处都和 GDScript 对不上**
    /// （2 人局系数应是 2.8；六人指数 0.35 只活了一个白天，issue #29 当晚改回 0.3）。
    /// 无氧每个世界回合都走，这两条不齐会让双内核对拍在 E 阶段直接分叉。
    /// </summary>
    [Theory]
    [InlineData(2)]
    [InlineData(4)]
    [InlineData(6)]
    public void 无氧系数与指数按人数分档与GDScript一致(int players)
    {
        var coef = GdIntDict("ANAEROBIC_BLOCK_COEF_BY_PLAYERS")[players];
        var exp = GdIntDict("ANAEROBIC_BLOCK_EXP_BY_PLAYERS")[players];

        // 单格连通块、块内一个癌细胞、全图零固化 ⇒ 池 = 1^(exp/100) × coef/10 = coef/10，
        // 再被 max{2.0, …} 兜底。取 coef=2.0/2.8 都大于 2.0，所以兜底不介入。
        var world = AnaerobicWorld(players);
        var share = RulePolicies.AnaerobicShare(world, world.Cells[new EntityId(1)]);

        Assert.True(share == coef,
            $"{players} 人局单格块的无氧份额：GDScript 系数 {coef}（指数 {exp}），C# 算出 {share}");
    }

    // ---- 读 GDScript 常量表 ----

    private static readonly Lazy<string> DataGd = new(() =>
    {
        var dir = AppContext.BaseDirectory;
        for (var i = 0; i < 12 && dir != null; i++)
        {
            var candidate = Path.Combine(dir, "game", "scripts", "core", "cw_data.gd");
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
            dir = Path.GetDirectoryName(dir);
        }
        throw new FileNotFoundException(
            "找不到 game/scripts/core/cw_data.gd —— 这一组测试拿它当真相源。" +
            "如果 GDScript 内核已经退役，请把这个文件归档并删掉这一组测试，而不是让它静默跳过。");
    });

    private static int GdConst(string name)
    {
        var m = Regex.Match(DataGd.Value, $@"^const {Regex.Escape(name)}\s*:?=\s*(-?\d+)", RegexOptions.Multiline);
        Assert.True(m.Success, $"cw_data.gd 里找不到 const {name}");
        return int.Parse(m.Groups[1].Value);
    }

    private static IReadOnlyList<int> GdIntArray(string name)
    {
        var m = Regex.Match(DataGd.Value, $@"^const {Regex.Escape(name)}[^=]*:?=\s*\[([\d,\s-]+)\]", RegexOptions.Multiline);
        Assert.True(m.Success, $"cw_data.gd 里找不到数组常量 {name}");
        return m.Groups[1].Value.Split(',').Select(x => int.Parse(x.Trim())).ToArray();
    }

    private static IReadOnlyDictionary<int, int> GdIntDict(string name)
    {
        var m = Regex.Match(DataGd.Value, $@"^const {Regex.Escape(name)}\s*:?=\s*\{{([^}}]+)\}}", RegexOptions.Multiline);
        Assert.True(m.Success, $"cw_data.gd 里找不到字典常量 {name}");
        return m.Groups[1].Value.Split(',')
            .Select(pair => pair.Split(':'))
            .ToDictionary(kv => int.Parse(kv[0].Trim()), kv => int.Parse(kv[1].Trim()));
    }

    // ---- 夹具 ----

    private static WorldState MoveCostWorld(ImmuneLevel level)
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [from] = Tile(from, TissueState.Healthy, new EntityId(1)),
                    [to] = Tile(to, TissueState.Cancer, null),
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = Immune(new EntityId(1), 0, from),
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = level },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    /// <summary>一格癌组织、上面站一个癌细胞、全图零固化；玩家数决定分档。</summary>
    private static WorldState AnaerobicWorld(int players)
    {
        var at = new HexPosition(0, 0, 0);
        var seats = new Dictionary<int, Player>();
        for (var i = 0; i < players; i++)
            seats[i] = i == 1
                ? new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
                : new() { Seat = i, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = new Dictionary<HexPosition, Tissue> { [at] = Tile(at, TissueState.Cancer, new EntityId(1)) } },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
                    Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = seats,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 1 }
        };
    }

    /// <summary>一只树突站在健康组织上，旁边一格癌组织可当趋化源落点。</summary>
    private static WorldState DendriticWorld(int energy)
    {
        var at = new HexPosition(0, 0, 0);
        var far = new HexPosition(2, 0, -2);
        var cell = Immune(new EntityId(1), 0, at).Copy(type: CellType.Dendritic, energy: energy, differentiated: true);
        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [at] = Tile(at, TissueState.Healthy, new EntityId(1)),
                    [far] = Tile(far, TissueState.Cancer, null),
                }
            },
            Cells = new Dictionary<EntityId, Cell> { [new EntityId(1)] = cell },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.III },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    /// <summary>一只 T 细胞紧邻一只癌细胞（癌细胞脚下是癌组织，够【细胞毒素】生效）。</summary>
    private static WorldState TCellVersusCancer()
    {
        var at = new HexPosition(0, 0, 0);
        var foe = new HexPosition(1, 0, -1);
        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [at] = Tile(at, TissueState.Healthy, new EntityId(1)),
                    [foe] = Tile(foe, TissueState.Cancer, new EntityId(2)),
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = Immune(new EntityId(1), 0, at).Copy(type: CellType.TCell, differentiated: true),
                [new EntityId(2)] = new()
                {
                    Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
                    Position = foe, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.III },
                [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    /// <summary>一只 B 细胞，旁边一格癌组织上站着癌细胞（够【抗体】找到目标）。</summary>
    private static WorldState BCellWorld(int energy, bool matured)
    {
        var world = TCellVersusCancer();
        var cell = world.Cells[new EntityId(1)];
        return world.UpdateCell(cell.Id, cell.Copy(
            type: CellType.BCell, energy: energy,
            equipped: matured ? new[] { "抗体亲和力成熟" } : Array.Empty<string>()));
    }

    /// <summary>一只免疫细胞被癌组织围着 ⇒ E 阶段必然吃到【微环境压迫】。</summary>
    private static WorldState PressureWorld(bool exhaustion)
    {
        var at = new HexPosition(0, 0, 0);
        var tiles = new Dictionary<HexPosition, Tissue> { [at] = Tile(at, TissueState.Healthy, new EntityId(1)) };
        foreach (var n in at.GetNeighbors()) tiles[n] = Tile(n, TissueState.Cancer, null);

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = Immune(new EntityId(1), 0, at).Copy(
                    equipped: exhaustion ? new[] { "耗竭抵抗" } : Array.Empty<string>()),
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.E, ActivePlayerSeat = 0 }
        };
    }

    private static WorldState ImmuneWithHand(string card)
    {
        var world = MoveCostWorld(ImmuneLevel.III);
        var cell = world.Cells[new EntityId(1)];
        return world.UpdateCell(cell.Id, cell.Copy(hand: new[] { card }));
    }

    private static Tissue Tile(HexPosition p, TissueState st, EntityId? occ) =>
        new() { Position = p, Type = TissueType.Normal, State = st, SolidificationCount = 0, OccupyingCell = occ, Charge = 0 };

    private static Cell Immune(EntityId id, int seat, HexPosition at) => new()
    {
        Id = id, OwnerSeat = seat, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
        Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
        Hand = [], Equipped = [],
    };
}
