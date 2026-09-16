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
    [InlineData("CHEMO_SELF_PCT", 50)]         // 建立者朝自己的源走 ×50%
    [InlineData("CHEMO_IMMUNE_PCT", 70)]       // 其余免疫朝源走 ×70%
    [InlineData("CHEMO_CANCER_PCT", 120)]      // 癌方远离源 ×120%（09-09 由 140 降下来）
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

    // ---- 【I-趋化源】进修饰管线（2026-09-15）----
    //
    // 它此前是**烤进基础费用**的：在整条管线之前就乘掉。
    // GD 侧它是管线里的 MULT/DIV 条目，排在固定加费/减费**之后**（cw_cost.gd:97-111）。
    // 另外 GD 的百分比走 `_pct` → `round_tenth` **四舍五入**，C# 原来是整数截断。
    // 两处都会差一个十分位，而且都是「看起来很对」的那种差。

    /// <summary>费用侧的百分比是**四舍五入**（PRD 通用规则 1），不是截断。</summary>
    [Fact]
    public void 趋化源的百分比按四舍五入而不是截断()
    {
        // 健康格基础迁移费 0.5；其余免疫朝源走 ×70% → 0.35 → **0.4**（截断会给 0.3）
        var world = ChemoWorld(owner: false, onCancer: false, skill: null);
        var cost = RulePolicies.QuoteMove(world, world.Cells[new EntityId(1)], ChemoStep);

        var expected = Settlement.RoundDiv(5 * GdConst("CHEMO_IMMUNE_PCT"), 100);
        Assert.Equal(expected, cost);
        Assert.Equal(4, cost);
    }

    /// <summary>
    /// 趋化源排在**固定减费之后**。
    /// 装【LFA-1黏附】（走上癌组织 −0.4、下限 0.2）的免疫朝源走上癌组织：
    ///   对：1.0 → max(0.2, 1.0−0.4)=0.6 → ×70% → 0.42 → **0.4**
    ///   错（烤进基础费用）：1.0 → ×70% = 0.7 → max(0.2, 0.7−0.4) = **0.3**
    /// </summary>
    [Fact]
    public void 趋化源排在固定减费之后而不是之前()
    {
        var world = ChemoWorld(owner: false, onCancer: true, skill: "LFA-1黏附");
        var cost = RulePolicies.QuoteMove(world, world.Cells[new EntityId(1)], ChemoStep);

        Assert.Equal(4, cost);
    }

    /// <summary>三档百分比各自对得上 GD 的常量，且「自身」认的是建立者席位。</summary>
    [Theory]
    [InlineData(true, "CHEMO_SELF_PCT")]     // 建立趋化源的那个席位
    [InlineData(false, "CHEMO_IMMUNE_PCT")]  // 其余免疫
    public void 免疫朝趋化源走的减免分自身与其余两档(bool owner, string constant)
    {
        var world = ChemoWorld(owner: owner, onCancer: false, skill: null);
        var cost = RulePolicies.QuoteMove(world, world.Cells[new EntityId(1)], ChemoStep);

        Assert.Equal(Settlement.RoundDiv(5 * GdConst(constant), 100), cost);
    }

    /// <summary>癌细胞**远离**趋化源要加价；朝它走则什么都不加。</summary>
    [Fact]
    public void 癌细胞远离趋化源加价而朝它走不加()
    {
        var away = ChemoWorld(owner: false, onCancer: false, skill: null, cancer: true);
        var awayCost = RulePolicies.QuoteMove(away, away.Cells[new EntityId(1)], ChemoAwayStep);
        Assert.Equal(Settlement.RoundDiv(12 * GdConst("CHEMO_CANCER_PCT"), 100), awayCost);

        var toward = ChemoWorld(owner: false, onCancer: false, skill: null, cancer: true);
        Assert.Equal(12, RulePolicies.QuoteMove(toward, toward.Cells[new EntityId(1)], ChemoStep));
    }

    /// <summary>趋化源到期（ChemoRounds 归零）之后不该再影响任何费用。</summary>
    [Fact]
    public void 趋化源到期之后不再影响费用()
    {
        var live = ChemoWorld(owner: false, onCancer: false, skill: null);
        var expired = live.WithTurn(live.Turn.Copy(chemoRounds: 0));

        Assert.Equal(4, RulePolicies.QuoteMove(live, live.Cells[new EntityId(1)], ChemoStep));
        Assert.Equal(5, RulePolicies.QuoteMove(expired, expired.Cells[new EntityId(1)], ChemoStep));
    }

    // ---- 伤害侧的取整与费用侧**故意不一样** ----
    //
    // `cw_data.gd:905-908` 明写：卡面写明向下取整的照旧向下 ——
    // 【TGF-β释放】−20%、骨肉瘤【刚性屏障】×40%、【抗体】减半、抗原记忆，这四处都是。
    // 所以费用侧四舍五入、伤害侧截断，两条判据得各钉各的，不然「统一一下」是很自然的改法。

    /// <summary>伤害侧的百分比是**向下取整**，不许跟费用侧一样四舍五入。</summary>
    [Fact]
    public void 伤害侧的百分比向下取整而不是四舍五入()
    {
        // 【刚性屏障】×40%：0.9 的损失 → 0.36 → 截断 **0.3**（四舍五入会给 0.4）
        var barrier = new ValueModifier(ModifierStage.Multiply, SourceLayer.Passive, 0, GdConst("OSTEO_BARRIER_PERCENT"));
        Assert.Equal(3, Settlement.ApplyEnergyLoss(9, [barrier]));

        // 同一个数在**费用**侧要四舍五入 —— 两条口径确实不同，不是笔误
        Assert.Equal(4, Settlement.ApplyValue(9, [barrier]));
    }

    /// <summary>
    /// **多条倍率合成一次整数除法**，不许逐条各截断一次。
    ///
    /// GD 为此写了一整段警告（cw_damage.gd:218-223）：「分开除会各自向下取整一次，
    /// 『×2 再 ÷2 再 ×40%』就会比『一次算』少掉一两个十分位」。
    /// 实锤：被【标记】的骨肉瘤立于固化癌组织受 0.7 伤害 —— 合成算 0.5，逐条算 0.4。
    /// </summary>
    [Fact]
    public void 多条倍率合成一次除法而不是逐条截断()
    {
        var barrier = new ValueModifier(ModifierStage.Multiply, SourceLayer.Passive, 0, GdConst("OSTEO_BARRIER_PERCENT"), Name: "刚性屏障");
        var mark = new ValueModifier(ModifierStage.Multiply, SourceLayer.Skill, 0, 200, Name: "标记");

        // 7 × 2 × 40% = 5.6 十分位 → 向下取整 5；逐条算会先把 7×40% 截成 2，再 ×2 得 4
        Assert.Equal(5, Settlement.ApplyEnergyLoss(7, [barrier, mark]));

        // 换个顺序也必须一样 —— 合成一次除法之后，倍率之间的先后就不再改变结果
        Assert.Equal(5, Settlement.ApplyEnergyLoss(7, [mark, barrier]));
    }

    /// <summary>
    /// 端到端走一遍伤害管线：被【标记】的骨肉瘤立于固化癌组织受 0.7 —— 该扣 0.5。
    /// 上面那条只钉算式，这条钉「两条修饰真的都进了管线、层级与数值也对」。
    /// </summary>
    [Fact]
    public void 标记加刚性屏障的骨肉瘤受伤走完整管线()
    {
        var at = new HexPosition(0, 0, 0);
        var id = new EntityId(1);
        var world = new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [at] = new() { Position = at, Type = TissueType.Normal, State = TissueState.SolidifiedCancer,
                        SolidificationCount = 30, OccupyingCell = id, Charge = 0 },
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [id] = new()
                {
                    Id = id, OwnerSeat = 0, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
                    Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [], Marked = true, MarkLeft = 1, MarkRound = 1,
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };

        var after = CellRules.Damage(world, id, 7);
        Assert.Equal(300 - 5, after.Cells[id].Energy);   // 逐条截断会扣 4
    }

    // ---- 【中和抗体】：只压**与健康组织相邻**的癌细胞，压住的是种类能力 + 永久技能 ----
    //
    // PRD:627「所有与健康组织相邻的癌细胞的**种类特殊效果**/**永久卡牌效果**失效，持续 2 世界回合」。
    //
    // C# 此前两头都错：用一个全局标记一压压全场（太宽），
    // 而那个标记只被查了两处（太窄）——【刚性屏障】【囊性护甲】【瓦伯格】与全部永久技能都没压住。

    /// <summary>靶子是**施放那一刻与健康组织相邻**的癌细胞，深处那个不算。</summary>
    [Fact]
    public void 中和抗体只压住与健康组织相邻的癌细胞()
    {
        var world = NeutralizeBoard();
        var after = new BasicRulesEngine()
            .ExecuteDecision(world, new TypeSkillDecision(0, BCell, "中和抗体"), new Xoshiro256StarStar(3)).NewState;

        Assert.True(RulePolicies.Neutralized(after, after.Cells[EdgeCancer]), "贴着健康组织的那个该被压住");
        Assert.False(RulePolicies.Neutralized(after, after.Cells[DeepCancer]), "癌组织深处那个不该被压住");
        Assert.False(RulePolicies.Neutralized(after, after.Cells[BCell]), "免疫细胞不该被自己的技能压住");
    }

    /// <summary>压住的是**种类特殊效果**：骨肉瘤【刚性屏障】的 ×40% 不再生效。</summary>
    [Fact]
    public void 中和抗体压住癌种被动()
    {
        var world = NeutralizeBoard();
        var barrierOn = CellRules.Damage(world, EdgeCancer, 10);
        var after = new BasicRulesEngine()
            .ExecuteDecision(world, new TypeSkillDecision(0, BCell, "中和抗体"), new Xoshiro256StarStar(3)).NewState;
        var barrierOff = CellRules.Damage(after, EdgeCancer, 10);

        var before = world.Cells[EdgeCancer].Energy;
        Assert.Equal(before - 10 * GdConst("OSTEO_BARRIER_PERCENT") / 100, barrierOn.Cells[EdgeCancer].Energy);  // ×40% → 0.4
        Assert.Equal(before - 10, barrierOff.Cells[EdgeCancer].Energy);  // 屏障失效 → 全额 1.0
    }

    /// <summary>压住的也包括**永久卡牌效果**：【癌症干性】的死亡延迟不再生效。</summary>
    [Fact]
    public void 中和抗体压住癌方永久技能()
    {
        var world = NeutralizeBoard();
        var stem = world.Cells[EdgeCancer];
        world = world.UpdateCell(EdgeCancer, stem.Copy(equipped: ["癌症干性"]));

        Assert.True(RulePolicies.HasSkill(world, world.Cells[EdgeCancer], "癌症干性"));

        var after = new BasicRulesEngine()
            .ExecuteDecision(world, new TypeSkillDecision(0, BCell, "中和抗体"), new Xoshiro256StarStar(3)).NewState;
        Assert.False(RulePolicies.HasSkill(after, after.Cells[EdgeCancer], "癌症干性"),
            "被压住时 HasSkill 就该说「没有」—— 装备列表里还在，但效果不生效");
    }

    /// <summary>「持续 2 世界回合」= 到**下一**回合末为止（通用规则 3）。</summary>
    [Fact]
    public void 中和抗体持续到下一个世界回合末()
    {
        var world = NeutralizeBoard();
        var after = new BasicRulesEngine()
            .ExecuteDecision(world, new TypeSkillDecision(0, BCell, "中和抗体"), new Xoshiro256StarStar(3)).NewState;
        var castRound = after.Turn.WorldRound;

        Assert.True(RulePolicies.Neutralized(after, after.Cells[EdgeCancer]));                                   // 本回合
        Assert.True(RulePolicies.Neutralized(Round(after, castRound + 1), after.Cells[EdgeCancer]));             // 下一回合
        Assert.False(RulePolicies.Neutralized(Round(after, castRound + 2), after.Cells[EdgeCancer]));            // 再下一回合就过期
    }

    private static WorldState Round(WorldState s, int round) => s.WithTurn(s.Turn.Copy(round: round));

    private static readonly EntityId BCell = new(1);
    private static readonly EntityId EdgeCancer = new(2);
    private static readonly EntityId DeepCancer = new(3);

    /// <summary>
    /// 一个够得着【效应应答】的 B 细胞，加两个癌细胞：
    /// 一个骨肉瘤贴着健康组织（还立在固化癌组织上，好验【刚性屏障】），
    /// 一个埋在癌组织深处、四邻全是癌组织。
    /// </summary>
    private static WorldState NeutralizeBoard()
    {
        var bPos = new HexPosition(0, 0, 0);
        var edge = new HexPosition(2, 0, -2);      // 它的邻居里有健康格
        var deep = new HexPosition(-3, 0, 3);      // 四周全铺成癌组织

        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [bPos] = Tile(bPos, TissueState.Healthy, BCell),
            [edge] = new() { Position = edge, Type = TissueType.Normal, State = TissueState.SolidifiedCancer,
                SolidificationCount = 30, OccupyingCell = EdgeCancer, Charge = 0 },
            [deep] = Tile(deep, TissueState.Cancer, DeepCancer),
        };
        // edge 旁边留一格健康的；deep 四周全部铺癌组织
        tiles[new HexPosition(3, 0, -3)] = Tile(new HexPosition(3, 0, -3), TissueState.Healthy, null);
        // B 细胞四周也要有健康格 —— 否则「免疫细胞不该被压住」那条会**蒙对**：
        // 靶子筛选去掉阵营判据时它照样不在名单里（棋盘上根本没铺它的邻居）。
        // 2026-09-15 变异检验抓到的假绿灯。
        foreach (var n in bPos.GetNeighbors())
            tiles.TryAdd(n, Tile(n, TissueState.Healthy, null));
        foreach (var n in deep.GetNeighbors())
            tiles[n] = Tile(n, TissueState.Cancer, null);

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [BCell] = new()
                {
                    Id = BCell, OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.BCell,
                    Position = bPos, Energy = 500, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [], Differentiated = true,
                },
                [EdgeCancer] = new()
                {
                    Id = EdgeCancer, OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
                    Position = edge, Energy = 500, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
                [DeepCancer] = new()
                {
                    Id = DeepCancer, OwnerSeat = 2, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
                    Position = deep, Energy = 500, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 30, ImmuneLevel = ImmuneLevel.X },
                [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
                [2] = new() { Seat = 2, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
            },
            Turn = new TurnState { WorldRound = 3, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    // ---- 「黏液侵染」的 +0.2 也得进管线 ----
    //
    // 它此前和趋化源一样是**烤进基础费用**的。GD 是管线里的 FLAT_ADD 条目
    // （cw_cost.gd:351-360，注释明写「走 FLAT_ADD（④ 固定加费），免费豁免照 PRD 管线能免掉它」）。
    // 位置差在有 **REPLACE**（③ 基础值替换）在场时直接改数 —— 而 REPLACE 今天就有两张卡：
    // 【炎症趋化】（走上癌组织费用改为 0.5）与【上皮—间质转化】（走上健康组织改为 0.2）。

    /// <summary>
    /// 【炎症趋化】把费用**替换**成 0.5 之后，黏液的 +0.2 仍要照加 —— 0.7，不是 0.5。
    /// 烤进基础费用的话会被 REPLACE 连着一起抹掉。
    /// </summary>
    [Fact]
    public void 黏液加价排在基础值替换之后()
    {
        var world = MucusWorld();
        var id = new EntityId(1);
        var step = new HexPosition(1, 0, -1);

        // 没有 REPLACE 时：癌组织基础 1.0 + 黏液 0.2 = 1.2
        Assert.Equal(12, RulePolicies.QuoteMove(world, world.Cells[id], step));

        // 挂上【炎症趋化】（REPLACE 0.5，限走上癌组织）
        var withReplace = world.UpdateCell(id, world.Cells[id].Copy(modifiers:
        [
            new ActiveModifier("炎症趋化", ModifierTarget.Move, ModifierStage.Replace, SourceLayer.Card,
                0, 5, null, 1, ModifierDuration.Turn, ModifierRequirement.MoveToCancerous)
        ]));
        Assert.Equal(7, RulePolicies.QuoteMove(withReplace, withReplace.Cells[id], step));
    }

    /// <summary>癌细胞踏黏液格不加价 —— PRD:523 只写「免疫细胞迁移进入」。</summary>
    [Fact]
    public void 黏液加价只对免疫细胞()
    {
        var world = MucusWorld(cancer: true);
        var step = new HexPosition(1, 0, -1);
        // 癌细胞走癌组织基础 0.2，没有附加费
        Assert.Equal(2, RulePolicies.QuoteMove(world, world.Cells[new EntityId(1)], step));
    }

    /// <summary>免疫细胞站着的健康格照样会被【黏液破裂】转成癌组织（PRD:519 没有「无细胞占据」这个条件）。</summary>
    [Fact]
    public void 黏液破裂转化健康组织时不看有没有细胞站着()
    {
        var burst = new HexPosition(0, 0, 0);
        var occupied = new HexPosition(1, 0, -1);   // 免疫站在这格健康组织上
        var signet = new EntityId(1);
        var immune = new EntityId(2);

        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [burst] = Tile(burst, TissueState.Cancer, signet),
            [occupied] = Tile(occupied, TissueState.Healthy, immune),
        };
        var world = new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [signet] = new()
                {
                    Id = signet, OwnerSeat = 0, Faction = Faction.Cancer, Type = CellType.SignetRing,
                    Position = burst, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
                [immune] = new()
                {
                    Id = immune, OwnerSeat = 1, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                    Position = occupied, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.SignetRing },
                [1] = new() { Seat = 1, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };

        var after = new BasicRulesEngine()
            .ExecuteDecision(world, new TypeSkillDecision(0, signet, "黏液破裂"), new Xoshiro256StarStar(9)).NewState;

        Assert.Equal(TissueState.Cancer, after.Board.Tissues[occupied].State);
        Assert.True(after.Board.Tissues[occupied].Mucus, "2 环内所有组织都进入黏液侵染");
    }

    /// <summary>一格癌组织沾着黏液，细胞站在旁边。</summary>
    private static WorldState MucusWorld(bool cancer = false)
    {
        var home = new HexPosition(0, 0, 0);
        var step = new HexPosition(1, 0, -1);
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [home] = Tile(home, cancer ? TissueState.Cancer : TissueState.Healthy, new EntityId(1)),
            [step] = new() { Position = step, Type = TissueType.Normal, State = TissueState.Cancer,
                SolidificationCount = 0, OccupyingCell = null, Charge = 0, Mucus = true },
        };
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 0,
                    Faction = cancer ? Faction.Cancer : Faction.Immune,
                    Type = cancer ? CellType.Osteosarcoma : CellType.ImmuneBasic,
                    Position = home, Energy = 500, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = cancer ? Faction.Cancer : Faction.Immune, IsAlive = true,
                    DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I,
                    CancerType = cancer ? CellType.Osteosarcoma : null },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    // ---- TU-2：移动费用旋钮 ----
    //
    // GD 的 67 个旋钮挂在 `game.tune` 上，默认值一律指向 `CWData` 的同名常量。
    // C# 这边新建 `RuleTuning`，先搬「移动费用」这一片。
    // 两条判据缺一不可：**默认值对得上 GD**，而且**旋钮真的接上了线**
    // （只验默认值的话，把旋钮拧一下引擎毫无反应也照样绿 —— 那就白搬了）。

    [Theory]
    [InlineData("CANCER_MOVE_CANCEROUS")]
    [InlineData("CANCER_MOVE_HEALTHY")]
    [InlineData("SCLC_MOVE_HEALTHY")]
    [InlineData("PSEUDOPOD_COST")]
    [InlineData("MUCUS_MOVE_SURCHARGE")]
    [InlineData("METASTASIS_COST")]
    public void 移动费用旋钮的默认值等于GDScript常量(string constant)
    {
        var tune = RuleTuning.Default;
        var actual = constant switch
        {
            "CANCER_MOVE_CANCEROUS" => tune.CancerMoveCancerous,
            "CANCER_MOVE_HEALTHY" => tune.CancerMoveHealthy,
            "SCLC_MOVE_HEALTHY" => tune.SclcMoveHealthy,
            "PSEUDOPOD_COST" => tune.PseudopodCost,
            "MUCUS_MOVE_SURCHARGE" => tune.MucusMoveSurcharge,
            _ => tune.MetastasisCost,
        };
        Assert.True(actual == GdConst(constant),
            $"{constant}：GDScript {GdConst(constant)}，C# 旋钮默认值 {actual}");
    }

    [Theory]
    [InlineData("IMMUNE_MOVE_HEALTHY")]
    [InlineData("IMMUNE_MOVE_CANCEROUS")]
    public void 免疫移动费用的四档默认值等于GDScript数组(string constant)
    {
        var gd = GdIntArray(constant);
        var mine = constant == "IMMUNE_MOVE_HEALTHY"
            ? RuleTuning.Default.ImmuneMoveHealthy
            : RuleTuning.Default.ImmuneMoveCancerous;
        Assert.Equal(gd, mine);
    }

    /// <summary>【伪足穿透】的门槛与折扣在 GD 侧是**常量不是旋钮**，但值也得对上。</summary>
    [Fact]
    public void 伪足穿透的门槛与折扣等于GDScript常量()
    {
        Assert.Equal(GdConst("PSEUDOPOD_MIN_ADJ"), RulePolicies.PseudopodMinAdjacent);
        Assert.Equal(GdConst("PSEUDOPOD_DISCOUNT"), RulePolicies.PseudopodDiscount);
    }

    /// <summary>
    /// 旋钮真的接上了线：拧一下，报价要跟着动。
    /// 只验默认值的话，引擎里照旧写死字面量也照样绿 —— 那就白搬了。
    /// </summary>
    [Theory]
    [InlineData(false, 5, 77)]    // 免疫 I 级走健康格
    [InlineData(true, 10, 99)]    // 免疫 I 级走癌性格
    public void 拧动免疫移动旋钮报价要跟着变(bool cancerous, int expectedDefault, int tweaked)
    {
        var world = MoveCostWorld(ImmuneLevel.I);
        var step = new HexPosition(1, 0, -1);
        if (!cancerous) world = world.UpdateTissueState(step, TissueState.Healthy);

        Assert.Equal(expectedDefault, RulePolicies.QuoteMove(world, world.Cells[new EntityId(1)], step));

        var knob = cancerous
            ? world.Tuning with { ImmuneMoveCancerous = [tweaked, tweaked, tweaked, tweaked] }
            : world.Tuning with { ImmuneMoveHealthy = [tweaked, tweaked, tweaked, tweaked] };
        var tunedWorld = new WorldState
        {
            Board = world.Board, Cells = world.Cells, Turn = world.Turn, Players = world.Players, Tuning = knob,
        };
        Assert.Equal(tweaked, RulePolicies.QuoteMove(tunedWorld, tunedWorld.Cells[new EntityId(1)], step));
    }

    /// <summary>
    /// 黏液附加费真的读旋钮：拧成别的数要跟着变，归零 = 关掉这条规则。
    ///
    /// ⚠ 第一版只验了「归零 → 10」—— 那条**抓不到「引擎里写死 2」**：
    /// 写死之后旋钮归零照样走不到那一行（当时还有一句 `> 0` 的闸）。变异检验当场戳穿。
    /// 所以必须有一个**非零的别的数**。
    /// </summary>
    [Theory]
    [InlineData(2, 12)]    // 默认
    [InlineData(7, 17)]    // 拧大 —— 写死 2 的话这条红
    [InlineData(0, 10)]    // 归零 = 关掉
    public void 黏液附加费读的是旋钮(int surcharge, int expected)
    {
        var world = MucusWorld();
        var step = new HexPosition(1, 0, -1);
        var tuned = new WorldState
        {
            Board = world.Board, Cells = world.Cells, Turn = world.Turn, Players = world.Players,
            Tuning = world.Tuning with { MucusMoveSurcharge = surcharge },
        };
        Assert.Equal(expected, RulePolicies.QuoteMove(tuned, tuned.Cells[new EntityId(1)], step));
    }

    /// <summary>
    /// 两个「转移」接的不是同一个数：【转移】走旋钮，【早期血行转移】走常量。
    /// 拧动旋钮时后者**不许**跟着动 —— 它俩今天同为 1.0，最容易被顺手合并。
    /// </summary>
    [Fact]
    public void 早期血行转移不读转移的旋钮()
    {
        var world = HomingWorld();
        var engine = new BasicRulesEngine();
        var homing = new TypeSkillDecision(0, new EntityId(1), "早期血行转移", new HexPosition(3, 0, -3));

        var baseline = engine.ExecuteDecision(world, homing, new Xoshiro256StarStar(5)).NewState;
        var tuned = new WorldState
        {
            Board = world.Board, Cells = world.Cells, Turn = world.Turn, Players = world.Players,
            Tuning = world.Tuning with { MetastasisCost = 99 },
        };
        var afterTuned = engine.ExecuteDecision(tuned, homing, new Xoshiro256StarStar(5)).NewState;

        Assert.Equal(baseline.Cells[new EntityId(1)].Energy, afterTuned.Cells[new EntityId(1)].Energy);
        Assert.Equal(world.Cells[new EntityId(1)].Energy - GdConst("MELANOMA_HOMING_COST"),
            baseline.Cells[new EntityId(1)].Energy);

        // **合法性判据也不许读那个旋钮。**
        // 只看「扣了多少钱」抓不到误接：判据那一行改错了，钱照旧扣对，测试照样绿
        // （2026-09-15 变异检验实测）。所以要挑一个**只有判据会分歧**的能量：
        // 够付常量费、不够付被拧大的旋钮费。
        var poor = new WorldState
        {
            Board = world.Board, Turn = world.Turn, Players = world.Players,
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = world.Cells[new EntityId(1)].Copy(energy: GdConst("MELANOMA_HOMING_COST") + 1),
            },
            Tuning = world.Tuning with { MetastasisCost = 99 },
        };
        Assert.True(engine.ValidateDecision(poor, homing).IsValid,
            "判据该看常量 MELANOMA_HOMING_COST，不该跟着 MetastasisCost 走");
    }

    /// <summary>黑色素瘤站在血管格上，远处留一格空的健康组织当落点。</summary>
    private static WorldState HomingWorld()
    {
        var at = new HexPosition(0, 0, 0);
        var dest = new HexPosition(3, 0, -3);
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [at] = new() { Position = at, Type = TissueType.BloodVessel, State = TissueState.Cancer,
                SolidificationCount = 0, OccupyingCell = new EntityId(1), Charge = 0 },
            [dest] = Tile(dest, TissueState.Healthy, null),
        };
        foreach (var n in dest.GetNeighbors()) tiles.TryAdd(n, Tile(n, TissueState.Healthy, null));

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Cancer, Type = CellType.Melanoma,
                    Position = at, Energy = 500, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    // 细胞站在 (0,0)；趋化源在 (3,0,-3)。朝它走 = (1,0,-1)，背它走 = (-1,0,1)。
    private static readonly HexPosition ChemoAt = new(3, 0, -3);
    private static readonly HexPosition ChemoStep = new(1, 0, -1);
    private static readonly HexPosition ChemoAwayStep = new(-1, 0, 1);

    /// <summary>场上有一个趋化源，细胞站在它的直线上，两侧各留一格可走。</summary>
    private static WorldState ChemoWorld(bool owner, bool onCancer, string? skill, bool cancer = false)
    {
        var home = new HexPosition(0, 0, 0);
        var stepState = onCancer ? TissueState.Cancer : TissueState.Healthy;
        // 癌细胞走「癌组织」只要 0.2，会把百分比差异压没 —— 癌方一律走健康格（基础 1.2）
        var homeState = cancer ? TissueState.Cancer : TissueState.Healthy;

        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [home] = Tile(home, homeState, new EntityId(1)),
                    [ChemoStep] = Tile(ChemoStep, cancer ? TissueState.Healthy : stepState, null),
                    [ChemoAwayStep] = Tile(ChemoAwayStep, cancer ? TissueState.Healthy : stepState, null),
                    [ChemoAt] = Tile(ChemoAt, TissueState.Healthy, null),
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 0,
                    Faction = cancer ? Faction.Cancer : Faction.Immune,
                    Type = cancer ? CellType.Osteosarcoma : CellType.ImmuneBasic,
                    Position = home, Energy = 500, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = skill is null ? [] : [skill],
                    Modifiers = skill == "LFA-1黏附"
                        ? [new ActiveModifier("LFA-1黏附", ModifierTarget.Move, ModifierStage.Subtract, SourceLayer.Passive, 0, 4, 2, 1, ModifierDuration.Turn, ModifierRequirement.MoveToCancerous)]
                        : [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = cancer ? Faction.Cancer : Faction.Immune, IsAlive = true,
                    DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I,
                    CancerType = cancer ? CellType.Osteosarcoma : null },
            },
            // ChemoOwner 是**建立者的席位**（GD 判 chemo["by"] == actor["pid"]），
            // 不是「是不是树突」—— owner:false 时给一个别的席位号。
            Turn = new TurnState
            {
                WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0,
                ChemoAt = ChemoAt, ChemoRounds = 3, ChemoOwner = owner ? 0 : 1,
            }
        };
    }

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
