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
        var k = GdIntArray("ANAEROBIC_CELLS_K")[0];        // 块内 1 个癌细胞
        var floor = GdConst("ANAEROBIC_FLOOR");

        // 单格连通块、块内**一个**癌细胞、全图零固化：
        //   池 = 1^(exp/100) × coef = coef  →  × k%  →  ÷1  →  再被 max{floor, …} 兜底
        //
        // ⚠ 这条 2026-09-15 改过一次：原来断言 `share == coef`，
        // 那是**人数系数 k 出现之前**的式子（PRD 2026-09-14 / issue #43 给整条分式外面乘了 k）。
        // C# 补上 k 之后它当场变红 —— 红得对：它钉住的是旧公式。
        var expected = Math.Max(floor, (int)Math.Round(coef * k / 100.0, MidpointRounding.AwayFromZero));

        var world = AnaerobicWorld(players);
        var share = RulePolicies.AnaerobicShare(world, world.Cells[new EntityId(1)]);

        Assert.True(share == expected,
            $"{players} 人局单格块的无氧份额：GDScript 系数 {coef}、指数 {exp}、独占系数 {k}% ⇒ {expected}，C# 算出 {share}");
    }

    /// <summary>
    /// **人数系数 k**：块内 1/2/3 个癌细胞 → 80%/100%/120%（PRD 2026-09-14 / issue #43）。
    /// 净效果是「罚独占、奖抱团」—— C# 此前完全没有这个系数，独占的癌细胞每回合多拿 20%。
    /// </summary>
    [Fact]
    public void 无氧的人数系数按块内癌细胞数分档()
    {
        var gd = GdIntArray("ANAEROBIC_CELLS_K");
        Assert.Equal(gd, RuleTuning.Default.AnaerobicCellsK);

        // 同一块癌组织上摆 1 / 2 / 3 个癌细胞，比**整块拿到的总量**（份额 × 人数）。
        // 比总量而不是比份额：份额本身还要除以人数，两个变量搅在一起看不出 k。
        var totals = new List<double>();
        for (var cells = 1; cells <= 3; cells++)
        {
            var world = AnaerobicBlockWorld(cells);
            var share = RulePolicies.AnaerobicShare(world, world.Cells[new EntityId(1)]);
            totals.Add(share * (double)cells);
        }

        // 兜底可能把小的那档顶上来，所以只断言**单调不减**，再单独验中/高两档的比值
        Assert.True(totals[1] <= totals[2], $"3 个细胞的总量不该少于 2 个：{totals[1]} vs {totals[2]}");
        Assert.True(totals[0] <= totals[1], $"2 个细胞的总量不该少于 1 个：{totals[0]} vs {totals[1]}");
        Assert.True(totals[2] > totals[1], $"k 没生效：2 个 {totals[1]}、3 个 {totals[2]}（120% 该比 100% 多）");
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
        Assert.Equal(RulePolicies.PseudopodMinAdjacent, GdConst("PSEUDOPOD_MIN_ADJ"));
        Assert.Equal(RulePolicies.PseudopodDiscount, GdConst("PSEUDOPOD_DISCOUNT"));
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
        var tunedWorld = world.WithTuning(knob);
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
        var tuned = world.WithTuning(world.Tuning with { MucusMoveSurcharge = surcharge });
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
        var poor = world
            .UpdateCell(new EntityId(1), world.Cells[new EntityId(1)].Copy(energy: GdConst("MELANOMA_HOMING_COST") + 1))
            .WithTuning(world.Tuning with { MetastasisCost = 99 });
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

    // ---- E 阶段步序（对齐 GD 的 CWWorld.e_phase()）----

    /// <summary>
    /// 【无氧呼吸】是**第 1 步**，算的是**增生/侵蚀之前**那份盘面。
    /// 排在它们之后的话，本回合新转的格子会一起进池 —— 癌方每个世界回合都多收一点。
    /// </summary>
    [Fact]
    public void 无氧呼吸算的是增生之前那份盘面()
    {
        var world = PocketWorld();
        var id = new EntityId(1);
        var before = world.Cells[id].Energy;
        var cancerBefore = world.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy);

        var expectedBeforeGrowth = RulePolicies.AnaerobicShare(world, world.Cells[id]);
        var after = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(20260915));

        // ① 这一回合盘面确实长大了，否则这条什么都证明不了
        var cancerAfter = after.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy);
        Assert.True(cancerAfter > cancerBefore, $"夹具没长大（{cancerBefore} → {cancerAfter}），判据是空的");

        // ② 长大之后那份盘面会给出**不同**的数 —— 不然两种步序结果相同，判据还是空的
        var expectedAfterGrowth = RulePolicies.AnaerobicShare(after, after.Cells[id]);
        Assert.True(expectedAfterGrowth != expectedBeforeGrowth,
            $"两种步序算出来一样（都是 {expectedBeforeGrowth}），换个夹具");

        // ③ 实收的是「长大之前」那个数
        Assert.Equal(expectedBeforeGrowth, after.Cells[id].Energy - before);
    }

    /// <summary>
    /// 【根深蒂固】加的计数走 `RaiseSolid`：够门槛**当场**转固化，而不是等下一回合。
    /// </summary>
    [Fact]
    public void 根深蒂固推过门槛当场转固化()
    {
        // II 期（第 6 世界回合起）门槛 2.0；把目标格摆在 1.5，+1.0 就该转
        var world = RootedWorld(solidCount: 15, round: 6);
        var target = new HexPosition(1, 0, -1);

        var after = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(4));
        Assert.Equal(TissueState.SolidifiedCancer, after.Board.Tissues[target].State);
    }

    /// <summary>【TNF-α局部炎症】冻住的格，【根深蒂固】也加不上计数。</summary>
    [Fact]
    public void 根深蒂固加不了被TNF冻住的格()
    {
        var world = RootedWorld(solidCount: 15, round: 6, frozen: true);
        var target = new HexPosition(1, 0, -1);

        var after = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(4));
        Assert.Equal(TissueState.Cancer, after.Board.Tissues[target].State);

        // 15 −5：【根深蒂固】一点没加上，随后**第 6 步衰减**照常扣了 0.5
        // （目标格上没有癌细胞停留）。这一条顺带钉住了「衰减排在根深蒂固之后」——
        // 反过来的话衰减先扣成 1.0、再被加成 2.0，当场转固化。
        Assert.Equal(10, after.Board.Tissues[target].SolidificationCount);
    }

    /// <summary>【基质硬化】也走同一个口子：够门槛当场转固化，冻住的格加不上。</summary>
    [Theory]
    [InlineData(false, TissueState.SolidifiedCancer)]
    [InlineData(true, TissueState.Cancer)]
    public void 基质硬化走加固化计数的同一个口子(bool frozen, TissueState expected)
    {
        var world = StromaWorld(solidCount: 20, frozen: frozen);   // I 期门槛 3.0，+1.0 到 3.0
        var target = new HexPosition(1, 0, -1);

        var after = CardRules.Resolve(world, world.Cells[new EntityId(1)], "基质硬化",
            new Xoshiro256StarStar(1), target, null);

        Assert.Equal(expected, after.Board.Tissues[target].State);
    }

    /// <summary>
    /// 树突【I-标记】到期：标记后第二次世界回合结算移除（PRD 2026-09-12）。
    /// C# 此前**根本没有这一步** —— 标记是 ×2 倍伤，挂着不掉是实打实的强化。
    /// </summary>
    [Fact]
    public void 标记在下一个世界回合结算时到期()
    {
        var world = MarkedCancerWorld(markRound: 3, worldRound: 3);
        var id = new EntityId(1);

        // 施加的那一回合结算不掉
        var sameRound = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(2));
        Assert.True(sameRound.Cells[id].Marked, "施加的那个回合末还不该掉");

        // 下一个世界回合结算就掉
        var nextRound = BoardRules.EvolveEndOfRound(
            MarkedCancerWorld(markRound: 3, worldRound: 4), new Xoshiro256StarStar(2));
        Assert.False(nextRound.Cells[id].Marked);
        Assert.Equal(0, nextRound.Cells[id].MarkLeft);
    }

    /// <summary>固化门槛三档等于 GD 的 `SOLIDIFY_THRESHOLD_BY_STAGE`（II 期就降到 2.0）。</summary>
    [Fact]
    public void 固化门槛三档等于GDScript数组()
    {
        Assert.Equal(GdIntArray("SOLIDIFY_THRESHOLD_BY_STAGE"), RuleTuning.Default.SolidifyThreshold);
    }

    /// <summary>门槛旋钮真的接上了线：拧高一点，同样的计数就不该转固化。</summary>
    [Fact]
    public void 拧高固化门槛就不再转固化()
    {
        var world = RootedWorld(solidCount: 15, round: 6);   // II 期门槛 2.0，+1.0 到 2.0 该转
        var target = new HexPosition(1, 0, -1);
        Assert.Equal(TissueState.SolidifiedCancer,
            BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(4)).Board.Tissues[target].State);

        var raised = world.WithTuning(world.Tuning with { SolidifyThreshold = [30, 30, 30] });
        Assert.Equal(TissueState.Cancer,
            BoardRules.EvolveEndOfRound(raised, new Xoshiro256StarStar(4)).Board.Tissues[target].State);
    }

    /// <summary>
    /// 【E-侵蚀】不许拿**本轮【增生】刚造出来的格子**当来源（PRD 的「注」，Kevin 2026-09-09 定的读法）。
    ///
    /// 直接测这一步而不是走整个 E 阶段：让增生必中要堆二三十格固化癌组织，
    /// 那样的夹具既难读又难说清到底在验什么。这一条验的就是 `fresh` 这个参数有没有被用上。
    /// </summary>
    [Fact]
    public void 侵蚀不拿本轮新增生的格当来源()
    {
        // 中心一格健康（封闭块），六邻全是癌组织
        var center = new HexPosition(0, 0, 0);
        var ring = center.GetNeighbors().ToArray();
        var tiles = new Dictionary<HexPosition, Tissue> { [center] = Tile(center, TissueState.Healthy, null) };
        foreach (var n in ring) tiles[n] = Tile(n, TissueState.Cancer, null);
        foreach (var n in ring)
            foreach (var m in n.GetNeighbors())
                tiles.TryAdd(m, Tile(m, TissueState.Healthy, null));
        var world = CancerBoard(tiles, ring[0], CellType.Osteosarcoma, worldRound: 1);
        world = world.WithBoard(world.Board.UpdateTissue(ring[0], world.Board.Tissues[ring[0]].WithOccupyingCell(new EntityId(1))));

        // 没有 fresh：中心那格该被侵蚀吃掉
        Assert.Equal(TissueState.Cancer,
            BoardRules.Erosion(world, new Xoshiro256StarStar(3), []).Board.Tissues[center].State);

        // 六邻全算「本轮刚增生出来的」：中心那格就没有合法来源，侵蚀不该动它
        Assert.Equal(TissueState.Healthy,
            BoardRules.Erosion(world, new Xoshiro256StarStar(3), ring).Board.Tissues[center].State);
    }

    // ---- TU-4：E 阶段旋钮 ----

    [Theory]
    [InlineData("PROLIFERATE_BASE_BY_STAGE")]
    [InlineData("PROLIFERATE_SOLID_BY_STAGE")]
    public void 增生旋钮的默认值等于GDScript数组(string constant)
    {
        var mine = constant == "PROLIFERATE_BASE_BY_STAGE"
            ? RuleTuning.Default.ProliferatePerAdjacent
            : RuleTuning.Default.ProliferatePerSolid;
        Assert.Equal(GdIntArray(constant), mine);
    }

    [Theory]
    [InlineData("ANAEROBIC_SOLID_BONUS")]
    [InlineData("ANAEROBIC_FLOOR")]
    [InlineData("ANAEROBIC_CAP")]
    [InlineData("ANAEROBIC_BLOCK_EXP")]
    [InlineData("ANAEROBIC_BLOCK_COEF")]
    public void 无氧旋钮的默认值等于GDScript常量(string constant)
    {
        var tune = RuleTuning.Default;
        var actual = constant switch
        {
            "ANAEROBIC_SOLID_BONUS" => tune.AnaerobicSolidBonus,
            "ANAEROBIC_FLOOR" => tune.AnaerobicFloor,
            "ANAEROBIC_CAP" => tune.AnaerobicCap,
            "ANAEROBIC_BLOCK_EXP" => tune.AnaerobicBlockExp,
            _ => tune.AnaerobicBlockCoef,
        };
        Assert.True(actual == GdConst(constant), $"{constant}：GDScript {GdConst(constant)}，C# {actual}");
    }

    [Theory]
    [InlineData("ANAEROBIC_BLOCK_COEF_BY_PLAYERS")]
    [InlineData("ANAEROBIC_BLOCK_EXP_BY_PLAYERS")]
    public void 无氧分档表等于GDScript字典(string constant)
    {
        var gd = GdIntDict(constant);
        var mine = constant.Contains("COEF")
            ? RuleTuning.Default.AnaerobicBlockCoefByPlayers
            : RuleTuning.Default.AnaerobicBlockExpByPlayers;
        Assert.Equal(gd.OrderBy(kv => kv.Key), mine.OrderBy(kv => kv.Key));
    }

    /// <summary>
    /// 【E-侵蚀】的转化格数：2/3 概率取常见值、1/3 取少见值，掷的是 **d3（1..3）**。
    ///
    /// 值域比概率更要紧：对拍的随机数带子记的是**抽取区间**，
    /// `NextInt(3)`（0..2）在带子上和 GD 的 `randi_range(1,3)` 对不上。
    /// 这和早上那个「骰面 0..5 vs 1..6」是同一个形状。
    /// </summary>
    [Fact]
    public void 侵蚀掷的是一到三的d3()
    {
        var center = new HexPosition(0, 0, 0);
        var ring = center.GetNeighbors().ToArray();
        var tiles = new Dictionary<HexPosition, Tissue> { [center] = Tile(center, TissueState.Healthy, null) };
        foreach (var n in ring) tiles[n] = Tile(n, TissueState.Cancer, null);
        foreach (var n in ring)
            foreach (var m in n.GetNeighbors())
                tiles.TryAdd(m, Tile(m, TissueState.Healthy, null));
        var world = CancerBoard(tiles, ring[0], CellType.Osteosarcoma, worldRound: 1);

        var spy = new RecordingRng(new Xoshiro256StarStar(11));
        BoardRules.Erosion(world, spy, []);

        Assert.Contains((1, 4), spy.Ranges);
        Assert.DoesNotContain((0, 3), spy.Ranges);   // 旧写法的形状，不许回来
    }

    /// <summary>
    /// 增生的两个旋钮**真的接上了线**：关掉一格不转，拧到必中全转。
    ///
    /// 只验默认值抓不到「引擎里照旧写死 30/35/40」—— 默认值和字面量一模一样，
    /// 变异检验当场戳穿（TU-2 那批也栽在同一处）。
    /// </summary>
    [Fact]
    public void 增生读的是旋钮()
    {
        var world = PocketWorld();
        var before = world.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy);

        // 基数与固化加成都归零：一格都不该转
        var off = world.WithTuning(world.Tuning with
            { ProliferatePerAdjacent = [0, 0, 0], ProliferatePerSolid = [0, 0, 0] });
        BoardRules.Proliferate(off, new Xoshiro256StarStar(77), out var afterOff);
        Assert.Equal(before, afterOff.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy));

        // 基数拧到 1000‰：每格只要有 1 个相邻癌性组织就必中
        var on = world.WithTuning(world.Tuning with { ProliferatePerAdjacent = [1000, 1000, 1000] });
        BoardRules.Proliferate(on, new Xoshiro256StarStar(77), out var afterOn);
        Assert.True(afterOn.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy) > before,
            "基数拧到必中都没转，说明引擎根本没读这个旋钮");
    }

    /// <summary>固化加成那一档也接上了线：基数归零、只靠固化加成也能转。</summary>
    [Fact]
    public void 增生的固化加成读的是旋钮()
    {
        var world = PocketWorld();
        // 把一格癌组织换成固化癌组织，给「每格固化 +N‰」一个来源
        var ring = new HexPosition(0, 0, 0).GetNeighbors().ToArray();
        var solidAt = ring[3];
        world = world.WithBoard(world.Board.UpdateTissue(solidAt,
            world.Board.Tissues[solidAt].WithState(TissueState.SolidifiedCancer)));
        var before = world.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy);

        var on = world.WithTuning(world.Tuning with
            { ProliferatePerAdjacent = [0, 0, 0], ProliferatePerSolid = [1000, 1000, 1000] });
        BoardRules.Proliferate(on, new Xoshiro256StarStar(77), out var after);

        Assert.True(after.Board.Tissues.Values.Count(t => t.State != TissueState.Healthy) > before,
            "固化加成拧到必中都没转，说明引擎根本没读这个旋钮");
    }

    /// <summary>【E-侵蚀】的格数默认值等于 GD 的 `EROSION_TILES_BY_STAGE`。</summary>
    [Fact]
    public void 侵蚀格数的三档默认值等于GDScript()
    {
        // GD 是 Array[Vector2i]：[Vector2i(2, 3), Vector2i(2, 3), Vector2i(3, 5)]
        // 别拿行尾锚点收尾：cw_data.gd 是 CRLF，$ 卡在回车前面匹配不到 ]（踩过两次的坑）
        var gd = Regex.Match(DataGd.Value,
            @"^const EROSION_TILES_BY_STAGE[^\r\n]*", RegexOptions.Multiline);
        Assert.True(gd.Success, "cw_data.gd 里找不到 EROSION_TILES_BY_STAGE");
        var pairs = Regex.Matches(gd.Value, @"Vector2i\(\s*(\d+)\s*,\s*(\d+)\s*\)")
            .Select(m => (int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value))).ToArray();

        Assert.Equal(pairs, RuleTuning.Default.ErosionTiles);
    }

    // ---- 【S-过载】（PRD 2026-09-15 新增，S 阶段第 6 步）----
    //
    //   能量损失 = min{15, max{0, ((x − 10) ÷ 2)^1.18}}
    //
    // 它是 09-15 当天在 GDScript 上线的规则（v26），C# 内核里此前一行都没有。

    [Theory]
    [InlineData("OVERLOAD_THRESHOLD")]
    [InlineData("OVERLOAD_DIV")]
    [InlineData("OVERLOAD_EXP")]
    [InlineData("OVERLOAD_CAP")]
    public void 过载旋钮的默认值等于GDScript常量(string constant)
    {
        var tune = RuleTuning.Default;
        var actual = constant switch
        {
            "OVERLOAD_THRESHOLD" => tune.OverloadThreshold,
            "OVERLOAD_DIV" => tune.OverloadDiv,
            "OVERLOAD_EXP" => tune.OverloadExp,
            _ => tune.OverloadCap,
        };
        Assert.True(actual == GdConst(constant), $"{constant}：GDScript {GdConst(constant)}，C# {actual}");
    }

    /// <summary>
    /// 逐点核对公式本身。期望值**由 GDScript 的常量现算**，不写字面量 ——
    /// 写死的话改了旋钮这条测试反而会钉住旧值（09-15 早上踩过三次的形状）。
    ///
    /// ⚠ 采样点要**挑过**：第一版的四个点里，小数位全都 &lt;.5 或者被上限盖住，
    /// 于是「四舍五入改成截断」这个变异全绿。16.0 与 21.0 是专门补来卡这条分界的。
    /// </summary>
    [Theory]
    [InlineData(100)]   // 正好在门槛上：不扣
    [InlineData(99)]    // 门槛以下：不扣
    [InlineData(101)]   // 刚过门槛
    [InlineData(150)]   // 15.0 → ((15−10)/2)^1.18 = 2.5^1.18
    [InlineData(160)]   // 16.0 → 3.0^1.18 = 3.656 → **36.56**：小数位 ≥.5，四舍五入与截断在这里分道
    [InlineData(210)]   // 21.0 → 5.5^1.18 = 7.476 → **74.76**：同上，再取一个
    [InlineData(300)]   // 30.0 → 已越过上限交叉点
    [InlineData(600)]   // 60.0 → 远在上限之上
    public void 过载损失逐点对上PRD的式子(int energy)
    {
        var threshold = GdConst("OVERLOAD_THRESHOLD");
        var div = GdConst("OVERLOAD_DIV");
        var exp = GdConst("OVERLOAD_EXP");
        var cap = GdConst("OVERLOAD_CAP");

        var over = energy - threshold;
        var expected = 0;
        if (over > 0)
        {
            expected = (int)Math.Round(Math.Pow(over / 10.0 / div, exp / 100.0) * 10.0, MidpointRounding.AwayFromZero);
            if (cap > 0) expected = Math.Min(cap, expected);
            expected = Math.Min(expected, energy);
        }

        var world = OverloadWorld(energy);
        Assert.Equal(expected, RulePolicies.OverloadLoss(world, world.Cells[new EntityId(1)]));
    }

    /// <summary>上限真的封住了：越过交叉点之后损失恒定。</summary>
    [Fact]
    public void 过载损失封顶之后恒定()
    {
        var cap = GdConst("OVERLOAD_CAP");
        foreach (var energy in new[] { 300, 400, 900 })
        {
            var world = OverloadWorld(energy);
            Assert.Equal(cap, RulePolicies.OverloadLoss(world, world.Cells[new EntityId(1)]));
        }

        // 关掉上限，同样的能量就该超过它 —— 否则这条只是在验「公式恰好小于 15」
        var uncapped = OverloadWorld(900);
        uncapped = uncapped.WithTuning(uncapped.Tuning with { OverloadCap = 0 });
        Assert.True(RulePolicies.OverloadLoss(uncapped, uncapped.Cells[new EntityId(1)]) > cap,
            "关掉上限之后损失没超过它，说明这条测试其实没验到封顶");
    }

    /// <summary>`OverloadDiv ≤ 0` 关闭整条规则（扫描的对照档，顺带兜住除零）。</summary>
    [Fact]
    public void 过载分母归零就关掉整条规则()
    {
        var world = OverloadWorld(600);
        Assert.True(RulePolicies.OverloadLoss(world, world.Cells[new EntityId(1)]) > 0);

        var off = world.WithTuning(world.Tuning with { OverloadDiv = 0 });
        Assert.Equal(0, RulePolicies.OverloadLoss(off, off.Cells[new EntityId(1)]));
    }

    /// <summary>
    /// 损失**不超过当前能量**。默认值下打不到（上限 15.0 恒小于触发线 10.0 以上的能量），
    /// 所以把上限关掉、门槛压低来逼出这条 —— 它守的是契约，不是活路径。
    /// </summary>
    [Fact]
    public void 过载损失不超过当前能量()
    {
        var world = OverloadWorld(120)
            .WithTuning(RuleTuning.Default with { OverloadCap = 0, OverloadThreshold = 0, OverloadDiv = 1 });
        // 12.0 能量、门槛 0、分母 1 ⇒ 12^1.18 ≈ 18.6 > 12.0
        Assert.Equal(120, RulePolicies.OverloadLoss(world, world.Cells[new EntityId(1)]));
    }

    /// <summary>
    /// S 阶段真的走这一步，而且**排在【有氧呼吸】之后**。
    /// 只扣癌细胞；免疫细胞不受影响（它那一步是有氧进账）。
    /// </summary>
    [Fact]
    public void S阶段第六步结算过载且只扣癌细胞()
    {
        var world = OverloadWorld(600, withImmune: true);
        var cancer = new EntityId(1);
        var immune = new EntityId(2);
        var expected = RulePolicies.OverloadLoss(world, world.Cells[cancer]);
        Assert.True(expected > 0, "夹具本身要能触发过载");

        var immuneBefore = world.Cells[immune].Energy;
        var after = new BasicRulesEngine()
            .AdvancePhase(world.WithTurn(world.Turn.Copy(phase: Phase.S, startStep: 99)), new Xoshiro256StarStar(3))
            .NewState;

        Assert.Equal(600 - expected, after.Cells[cancer].Energy);
        Assert.True(after.Cells[immune].Energy >= immuneBefore, "免疫细胞不该被【过载】扣");
    }

    /// <summary>一个癌细胞（可选再加一个免疫），能量可设。</summary>
    private static WorldState OverloadWorld(int energy, bool withImmune = false)
    {
        var at = new HexPosition(0, 0, 0);
        var near = new HexPosition(1, 0, -1);
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [at] = Tile(at, TissueState.Cancer, new EntityId(1)),
            [near] = Tile(near, TissueState.Healthy, withImmune ? new EntityId(2) : null),
        };
        var cells = new Dictionary<EntityId, Cell>
        {
            [new EntityId(1)] = new()
            {
                Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
                Position = at, Energy = energy, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [], Equipped = [],
            },
        };
        var seats = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
        };
        if (withImmune)
        {
            cells[new EntityId(2)] = new()
            {
                Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                Position = near, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [], Equipped = [],
            };
            seats[1] = new() { Seat = 1, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };
        }

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = cells,
            Players = seats,
            Turn = new TurnState { WorldRound = 3, Phase = Phase.S, ActivePlayerSeat = 0 }
        };
    }

    // ---- 巨噬【效应应答·连续吞噬】（PRD:603-607）----
    //
    // 「发动后，本行动回合巨噬细胞第一次【净化】后，可立即免费向相邻**癌组织**迁移；
    //   若再次净化则重复触发，最多触发 5 次」
    //
    // C# 此前拿一条「本回合 5 次免费移动」的修饰顶着 —— 那是**本回合随便花**，
    // 而 PRD 要的是「净化之后当场接着走」的连锁。

    [Theory]
    [InlineData("CHAIN_PHAGO_MAX")]
    [InlineData("CHAIN_PHAGO_BONUS")]
    public void 连续吞噬的常量等于GDScript(string constant)
    {
        var actual = constant == "CHAIN_PHAGO_MAX" ? CellRules.ChainPhagoMax : CellRules.ChainPhagoBonus;
        Assert.True(actual == GdConst(constant), $"{constant}：GDScript {GdConst(constant)}，C# {actual}");
    }

    /// <summary>
    /// 一条完整的连锁：净化 → 挂起等选 → 免费跳一格（又净化）→ 再挂起 → 选「不连了」。
    /// 每跳攒 0.5 的攻击加成；跳本身**不花钱**。
    /// </summary>
    [Fact]
    public void 连续吞噬净化后挂起并可免费连跳()
    {
        var engine = new BasicRulesEngine();
        var id = new EntityId(1);
        var world = ChainWorld();
        var before = world.Cells[id].Energy;

        // 第一步是**正常收费**的迁移，净化之后挂起
        var first = new HexPosition(1, 0, -1);
        var s = engine.ExecuteDecision(world, new MoveDecision(0, id, first), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(id, s.Turn.PendingChainCell);
        Assert.Equal(CellRules.ChainPhagoMax, s.Cells[id].ChainLeft);

        // 挂起期间只给「跳」与「不连了」
        var options = engine.GetAvailableDecisions(s, 0);
        Assert.Contains(options, o => o is ChainMoveDecision);
        Assert.Contains(options, o => o is StopChainDecision);
        Assert.DoesNotContain(options, o => o is EndTurnDecision);

        // 跳一格：不花钱、额度 −1、加成 +0.5
        var hop = options.OfType<ChainMoveDecision>().First();
        var energyBeforeHop = s.Cells[id].Energy;
        s = engine.ExecuteDecision(s, hop, new Xoshiro256StarStar(1)).NewState;

        Assert.Equal(energyBeforeHop, s.Cells[id].Energy);                       // 真免费
        Assert.Equal(CellRules.ChainPhagoMax - 1, s.Cells[id].ChainLeft);
        Assert.Equal(GdConst("CHAIN_PHAGO_BONUS"), s.Cells[id].ChainBonus);
        Assert.Equal(TissueState.Healthy, s.Board.Tissues[hop.Target].State);    // 跳过去照样净化

        // 「不连了」把挂起摘掉
        s = engine.ExecuteDecision(s, new StopChainDecision(0, id), new Xoshiro256StarStar(1)).NewState;
        Assert.Null(s.Turn.PendingChainCell);
        Assert.True(s.Cells[id].Energy > before - 10, "两步只该花第一步那一次钱");
    }

    /// <summary>没发动过【连续吞噬】的巨噬，净化之后不该挂起。</summary>
    [Fact]
    public void 没发动连续吞噬时净化不挂起()
    {
        var world = ChainWorld(chainLeft: 0);
        var s = new BasicRulesEngine()
            .ExecuteDecision(world, new MoveDecision(0, new EntityId(1), new HexPosition(1, 0, -1)), new Xoshiro256StarStar(1)).NewState;

        Assert.Null(s.Turn.PendingChainCell);
    }

    /// <summary>额度是「**本行动回合**」的：回合开始清零。</summary>
    [Fact]
    public void 连锁额度在回合开始清零()
    {
        var world = ChainWorld();
        Assert.Equal(CellRules.ChainPhagoMax, world.Cells[new EntityId(1)].ChainLeft);

        var begun = new BasicRulesEngine()
            .AdvancePhase(world.WithTurn(world.Turn.Copy(phase: Phase.S, startStep: 99)), new Xoshiro256StarStar(2))
            .NewState;
        Assert.Equal(0, begun.Cells[new EntityId(1)].ChainLeft);
    }

    /// <summary>攒下的加成在**下一次攻击**上一次性吃掉，然后清零（不按回合过期）。</summary>
    [Fact]
    public void 连续吞噬的加成在下一次攻击吃掉()
    {
        var from = new HexPosition(0, 0, 0);
        var to = new HexPosition(1, 0, -1);
        var id = new EntityId(1);
        var victim = new EntityId(2);

        var plain = AttackBoard(from, to, chainBonus: 0);
        var boosted = AttackBoard(from, to, chainBonus: 20);
        var engine = new BasicRulesEngine();

        var a = engine.ExecuteDecision(plain, new MoveDecision(0, id, to), new Xoshiro256StarStar(20260915)).NewState;
        var b = engine.ExecuteDecision(boosted, new MoveDecision(0, id, to), new Xoshiro256StarStar(20260915)).NewState;

        Assert.True(b.Cells[victim].Energy < a.Cells[victim].Energy, "加成没打出去");
        Assert.Equal(0, b.Cells[id].ChainBonus);   // 用掉即清
    }

    /// <summary>巨噬站 (0,0)，右边一串癌组织可以一路净化过去。</summary>
    private static WorldState ChainWorld(int chainLeft = CellRules.ChainPhagoMax)
    {
        var at = new HexPosition(0, 0, 0);
        var tiles = new Dictionary<HexPosition, Tissue> { [at] = Tile(at, TissueState.Healthy, new EntityId(1)) };
        for (var i = 1; i <= 4; i++)
        {
            var p = new HexPosition(i, 0, -i);
            tiles[p] = Tile(p, TissueState.Cancer, null);
        }

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = Immune(new EntityId(1), 0, at)
                    .Copy(type: CellType.Macrophage, differentiated: true, chainLeft: chainLeft),
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.X },
            },
            Turn = new TurnState { WorldRound = 3, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    /// <summary>一个免疫紧邻一个癌细胞，免疫身上带着指定的连锁加成。</summary>
    private static WorldState AttackBoard(HexPosition from, HexPosition to, int chainBonus)
    {
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [from] = Tile(from, TissueState.Healthy, new EntityId(1)),
            [to] = Tile(to, TissueState.Cancer, new EntityId(2)),
        };
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = Immune(new EntityId(1), 0, from)
                    .Copy(type: CellType.Macrophage, chainBonus: chainBonus),
                [new EntityId(2)] = new()
                {
                    Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
                    Position = to, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
                [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
            },
            Turn = new TurnState { WorldRound = 3, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    // ---- 【免疫猎杀】的【追踪趋化源】（PRD:583）----
    //
    // 「选定全局任意一个癌细胞使其获得【标记】，同时在其上附着**跟随的**【追踪趋化源】」。
    // 它与普通趋化源共用同一套费用修饰（方向判据取 OR）。C# 此前完全没有这个状态。

    [Fact]
    public void 追踪趋化源的持续回合等于GDScript常量()
        => Assert.Equal(SkillRules.HuntChemoRounds, GdConst("HUNT_CHEMO_ROUNDS"));

    /// <summary>
    /// **跟随**：位置不存在状态里，活着时现读被追细胞的位置 ——
    /// 它一挪，别人朝它走的折扣也跟着挪。
    /// </summary>
    [Fact]
    public void 追踪趋化源跟着被追的细胞走()
    {
        var hunted = new EntityId(2);
        var world = TrackWorld();
        Assert.Equal(world.Cells[hunted].Position, RulePolicies.TrackAt(world));

        var moved = new HexPosition(5, 0, -5);
        world = world.UpdateCell(hunted, world.Cells[hunted].Copy(position: moved));
        Assert.Equal(moved, RulePolicies.TrackAt(world));
    }

    /// <summary>「癌细胞死亡后趋化源留在死亡格」：冻住位置、断开跟随。</summary>
    [Fact]
    public void 被追的癌细胞死后趋化源留在死亡格()
    {
        var hunted = new EntityId(2);
        var world = TrackWorld();
        var deathAt = world.Cells[hunted].Position;

        var after = CellRules.Damage(world, hunted, 9999);
        Assert.False(after.Cells[hunted].IsAlive);
        Assert.Null(after.Turn.TrackCell);
        Assert.Equal(deathAt, RulePolicies.TrackAt(after));
    }

    /// <summary>
    /// 免疫朝**追踪源**走同样吃减免 —— 两个源的方向判据取 OR，
    /// 场上没有普通趋化源时也该生效。
    /// </summary>
    [Fact]
    public void 免疫朝追踪趋化源走也吃减免()
    {
        var world = TrackWorld();
        var immune = new EntityId(1);
        var toward = new HexPosition(1, 0, -1);    // 朝被追的细胞(4,0,-4) 走
        var away = new HexPosition(-1, 0, 1);

        // 基础迁移费 0.5（健康格）；朝追踪源走 ×70% → 0.4
        Assert.Equal(4, RulePolicies.QuoteMove(world, world.Cells[immune], toward));
        Assert.Equal(5, RulePolicies.QuoteMove(world, world.Cells[immune], away));
    }

    /// <summary>
    /// **被追的那个癌细胞自己「移动视为远离」**（PRD 明文）：它往哪挪都吃加价。
    ///
    /// ⚠ 实现里那句显式特判（`TrackCell == c.Id → return 1`）今天是**冗余**的：
    /// 源跟着它走，`TrackAt` 读的就是它当前的格，所以「从自己出发」的距离差恒 ≥ 1，
    /// 通用式子已经给出正值 —— 删掉特判这条测试照样绿（变异检验实测）。
    /// **留着不是为了过测试，是因为 PRD 明写了这条、而且 GD 也这么写**：
    /// 哪天 `TrackAt` 改成别的口径（比如冻结位置也参与），特判就是唯一拦得住的那道。
    /// 这条测试钉的是**行为**（它自己动一律算远离），不是那句特判。
    /// </summary>
    [Fact]
    public void 被追的癌细胞自己动一律算远离()
    {
        var world = TrackWorld();
        var hunted = new EntityId(2);
        var step = new HexPosition(3, 0, -3);      // 往回走，离「自己」更近？——不存在这回事

        // 癌细胞走癌组织基础 0.2；被判「远离」→ ×120% → 0.24 → 四舍五入 0.2
        // 所以这里比的是**有没有命中修饰**，直接问修饰本身更干脆
        var mod = RulePolicies.ChemoModifier(world, world.Cells[hunted], step);
        Assert.NotNull(mod);
        Assert.Equal(120, mod!.Value);
    }

    /// <summary>倒计时走完就消散。</summary>
    [Fact]
    public void 追踪趋化源到期消散()
    {
        var s = TrackWorld();
        for (var i = 0; i < SkillRules.HuntChemoRounds; i++)
            s = BoardRules.EvolveEndOfRound(s, new Xoshiro256StarStar(3));

        Assert.Equal(0, s.Turn.TrackRounds);
        Assert.Null(RulePolicies.TrackAt(s));
    }

    /// <summary>一个免疫站 (0,0)，一个被追的癌细胞站 (4,0,-4)；场上**没有**普通趋化源。</summary>
    private static WorldState TrackWorld()
    {
        var at = new HexPosition(0, 0, 0);
        var huntedAt = new HexPosition(4, 0, -4);
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [at] = Tile(at, TissueState.Healthy, new EntityId(1)),
            [huntedAt] = Tile(huntedAt, TissueState.Cancer, new EntityId(2)),
        };
        foreach (var n in at.GetNeighbors()) tiles.TryAdd(n, Tile(n, TissueState.Healthy, null));
        foreach (var n in huntedAt.GetNeighbors()) tiles.TryAdd(n, Tile(n, TissueState.Cancer, null));
        tiles[new HexPosition(5, 0, -5)] = Tile(new HexPosition(5, 0, -5), TissueState.Cancer, null);

        return new WorldState
        {
            Board = new Board { Radius = 9, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = Immune(new EntityId(1), 0, at),
                [new EntityId(2)] = new()
                {
                    Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
                    Position = huntedAt, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
                [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
            },
            Turn = new TurnState
            {
                WorldRound = 3, Phase = Phase.PlayerAction, ActivePlayerSeat = 0,
                TrackCell = new EntityId(2), TrackRounds = SkillRules.HuntChemoRounds,
            }
        };
    }

    // ---- 树突【I-趋化源】的技能冷却（issue #33）----
    //
    // PRD「趋化源消失后，技能冷却 1 世界回合才能再次使用」。
    // 冷却**从效果结束那一刻算起**，记在**建立它的那只细胞**身上 ——
    // 换个树突去立是另一个细胞的技能，所以不是全局锁。C# 此前完全没有这套。

    [Fact]
    public void 趋化源冷却回合数等于GDScript常量()
        => Assert.Equal(BoardRules.ChemoCooldownRounds, GdConst("CHEMO_COOLDOWN_ROUNDS"));

    /// <summary>
    /// 源走的是「持续 n **完整回合**」的时钟：**建立者的每个行动回合开打之前**各走一格，
    /// 而不是 E 阶段第 8 步（那是世界回合制，两套时钟别混 —— GD 专门警告过）。
    ///
    /// 消散那一刻给建立者记上技能冷却；冷却本身才是世界回合制，E 阶段第 8 步 −1。
    /// </summary>
    [Fact]
    public void 趋化源按完整回合过期并给建立者记冷却()
    {
        var engine = new BasicRulesEngine();
        var id = new EntityId(1);
        var decision = new TypeSkillDecision(0, id, "趋化源", new HexPosition(2, 0, -2));

        var s = engine.ExecuteDecision(ChemoClockWorld(), decision, new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(2, s.Turn.ChemoRounds);
        Assert.Equal(0, s.Cells[id].ChemoCooldown);

        // **E 阶段本身不该动它** —— 这一条正是那两套时钟的分水岭
        Assert.Equal(2, BoardRules.EvolveEndOfRound(s, new Xoshiro256StarStar(2)).Turn.ChemoRounds);

        // 推回合：每转回这个席位开打之前走一格
        var rng = new Xoshiro256StarStar(2);
        var seen = new List<int>();
        for (var i = 0; i < 12 && s.Turn.ChemoRounds > 0; i++)
        {
            s = engine.AdvancePhase(s, rng).NewState;
            // 只记**建立者自己**开打的那一格：GD 的 `tick_full_turn(pid)` 每个席位都调，
            // 但只在 `chemo["by"] == pid` 时才减 —— 数的是建立者的行动回合，不是所有人的
            if (s.Turn.Phase == Phase.PlayerAction && s.Turn.ActivePlayerSeat == 0) seen.Add(s.Turn.ChemoRounds);
        }

        Assert.Equal(0, s.Turn.ChemoRounds);
        Assert.Null(s.Turn.ChemoAt);
        Assert.Equal([1, 0], seen);   // 两次开打，各走一格
        Assert.Equal(BoardRules.ChemoCooldownRounds, s.Cells[id].ChemoCooldown);
        Assert.False(engine.ValidateDecision(s, decision).IsValid, "冷却期内不该再立得起来");

        // 冷却是世界回合制：这个世界回合末 −1 之后就能再立
        var thawed = BoardRules.EvolveEndOfRound(s, new Xoshiro256StarStar(2));
        Assert.Equal(0, thawed.Cells[id].ChemoCooldown);
        Assert.True(engine.ValidateDecision(thawed, decision).IsValid, "冷却走完就该能再立");
    }

    /// <summary>冷却记在**细胞**上不是全局：另一只树突不受影响。</summary>
    [Fact]
    public void 趋化源冷却只锁建立它的那只细胞()
    {
        var cooling = new EntityId(1);
        var other = new EntityId(9);
        var at = new HexPosition(-2, 0, 2);

        var world = DendriticWorld(energy: 300);
        world = world.WithBoard(world.Board.UpdateTissue(at,
            new Tissue { Position = at, Type = TissueType.Normal, State = TissueState.Healthy,
                SolidificationCount = 0, OccupyingCell = other, Charge = 0 }));
        world = world.AddCell(new Cell
        {
            Id = other, OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.Dendritic,
            Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
            Hand = [], Equipped = [], Differentiated = true,
        });
        world = world.UpdateCell(cooling, world.Cells[cooling].Copy(chemoCooldown: 1));

        var engine = new BasicRulesEngine();
        var target = new HexPosition(2, 0, -2);
        Assert.False(engine.ValidateDecision(world, new TypeSkillDecision(0, cooling, "趋化源", target)).IsValid);
        Assert.True(engine.ValidateDecision(world, new TypeSkillDecision(0, other, "趋化源", target)).IsValid,
            "另一只树突不该被别人的冷却锁住");
    }

    /// <summary>
    /// 树突 + 一个癌细胞的盘面 —— **两边都在**，否则第一个 E 阶段就判胜负、回合再也推不动
    /// （`DendriticWorld` 里没有癌细胞，拿它推回合会空转）。
    /// </summary>
    private static WorldState ChemoClockWorld()
    {
        var at = new HexPosition(0, 0, 0);
        var far = new HexPosition(2, 0, -2);
        var cancerAt = new HexPosition(4, 0, -4);

        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [at] = Tile(at, TissueState.Healthy, new EntityId(1)),
                    [far] = Tile(far, TissueState.Cancer, null),
                    [cancerAt] = Tile(cancerAt, TissueState.Cancer, new EntityId(2)),
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = Immune(new EntityId(1), 0, at)
                    .Copy(type: CellType.Dendritic, energy: 300, differentiated: true),
                [new EntityId(2)] = new()
                {
                    Id = new EntityId(2), OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
                    Position = cancerAt, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.III },
                [1] = new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
            },
            Turn = new TurnState { WorldRound = 1, Phase = Phase.PlayerAction, ActivePlayerSeat = 0 }
        };
    }

    // ---- E 阶段的两个旋钮档：【代谢消耗】与【E-能量上限】----
    //
    // 两个**默认都关**（GD 侧同样），是给 balance_scan 拨的对照档。
    // 但它们是 E 阶段步序的一部分，不实现的话那两步在 C# 里就是两行注释。

    [Fact]
    public void 能量上限与代谢消耗默认都关着()
    {
        Assert.Equal(GdConst("ENERGY_CAP_PER_ROUND"), RuleTuning.Default.EnergyCap);
        Assert.Equal(0, RuleTuning.Default.CancerUpkeepPercent);
    }

    /// <summary>【E-能量上限】拧开之后，**两个阵营**的存活细胞都削到那个数。</summary>
    [Fact]
    public void 能量上限拧开后两个阵营都削()
    {
        var world = OverloadWorld(600, withImmune: true)
            .WithTuning(RuleTuning.Default with { EnergyCap = 200, OverloadDiv = 0 });   // 关掉过载免得干扰

        var after = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(1));
        Assert.Equal(200, after.Cells[new EntityId(1)].Energy);
        Assert.Equal(200, after.Cells[new EntityId(2)].Energy);
    }

    /// <summary>
    /// 【代谢消耗】按**当前能量的百分比**扣、向下取整，而且**只扣癌方**。
    /// 它排在【无氧呼吸】之后 —— 税的是「存款 + 这回合刚进的账」。
    /// </summary>
    [Fact]
    public void 代谢消耗按比例扣且只扣癌方()
    {
        var world = OverloadWorld(600, withImmune: true)
            .WithTuning(RuleTuning.Default with { CancerUpkeepPercent = 10, OverloadDiv = 0 });

        var plain = BoardRules.EvolveEndOfRound(
            world.WithTuning(world.Tuning with { CancerUpkeepPercent = 0 }), new Xoshiro256StarStar(1));
        var taxed = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(1));

        // 癌细胞：先无氧进账，再按**那时**的能量扣 10%
        Assert.True(taxed.Cells[new EntityId(1)].Energy < plain.Cells[new EntityId(1)].Energy);
        // 免疫细胞：一分不扣
        Assert.Equal(plain.Cells[new EntityId(2)].Energy, taxed.Cells[new EntityId(2)].Energy);
    }

    /// <summary>
    /// 【代谢消耗】**向下取整**，所以扣不足 0.1 时一分不扣 —— 这正是「杀不死细胞」的来由。
    ///
    /// ⚠ 判据要挑在整除边界上，而且要算上**它排在无氧之后**：
    /// 第一版拿「0.4 能量 × 20%」当例子，可无氧先进账把能量抬到 2.6，
    /// 边界就不在那儿了 —— 改成向上取整照样绿（变异检验实测）。
    /// 这里用 1%：进账后 2.6 能量 × 1% = 0.026，向下取整 0、向上取整 0.1，两者分得开。
    /// </summary>
    [Fact]
    public void 代谢消耗向下取整所以扣不足一分就不扣()
    {
        var world = OverloadWorld(4).WithTuning(RuleTuning.Default with { OverloadDiv = 0 });
        var taxed = world.WithTuning(world.Tuning with { CancerUpkeepPercent = 1 });

        var plain = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(1));
        var after = BoardRules.EvolveEndOfRound(taxed, new Xoshiro256StarStar(1));

        Assert.Equal(plain.Cells[new EntityId(1)].Energy, after.Cells[new EntityId(1)].Energy);
        Assert.True(after.Cells[new EntityId(1)].IsAlive);
    }

    // ---- 树突【E-组织黏连】（PRD:579，E 阶段第 7 步）----
    //
    // 「被标记的癌细胞会将标记传染给 2 环内的所有癌细胞，**本阶段造成的感染不会再次感染**」
    // C# 此前完全没有这一步。

    /// <summary>传染范围与 GD 的 `ADHESION_RANGE` 一致。</summary>
    [Fact]
    public void 组织黏连的传染范围等于GDScript常量()
        => Assert.Equal(BoardRules.AdhesionRange, GdConst("ADHESION_RANGE"));

    /// <summary>
    /// 2 环内传染、2 环外不传染；而且**本阶段新染上的不能再当传染源** ——
    /// 否则一次 E 阶段就能顺着一串癌细胞蔓延到天边。
    ///
    /// 摆一条链：源(0,0) —2格— A(2,0) —2格— B(4,0)。
    /// 只有源带标记，那么这一阶段只有 A 该被染上，B 不该（它离源 4 格）。
    /// </summary>
    [Fact]
    public void 组织黏连只传两环且本阶段新染的不再当源()
    {
        var world = AdhesionWorld();
        var after = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(5));

        Assert.True(after.Cells[new EntityId(2)].Marked, "2 环内的该被传染");
        Assert.False(after.Cells[new EntityId(3)].Marked, "4 格外的这一阶段不该被传染（新染的不能再当源）");
    }

    /// <summary>场上没有树突就整步不发生 —— 标记是树突的机制。</summary>
    [Fact]
    public void 场上没有树突时组织黏连不发生()
    {
        var world = AdhesionWorld(withDendritic: false);
        var after = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(5));

        Assert.False(after.Cells[new EntityId(2)].Marked);
    }

    /// <summary>
    /// 一条癌细胞链：源(0,0) —2格— A(2,0) —2格— B(4,0)，只有源带标记。
    /// 树突摆在远处（8 格外），免得它自己的 2 环光环把三个都标了。
    /// </summary>
    private static WorldState AdhesionWorld(bool withDendritic = true)
    {
        var src = new HexPosition(0, 0, 0);
        var a = new HexPosition(2, 0, -2);
        var b = new HexPosition(4, 0, -4);
        var far = new HexPosition(-8, 0, 8);

        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [src] = Tile(src, TissueState.Cancer, new EntityId(1)),
            [a] = Tile(a, TissueState.Cancer, new EntityId(2)),
            [b] = Tile(b, TissueState.Cancer, new EntityId(3)),
        };
        var cells = new Dictionary<EntityId, Cell>
        {
            [new EntityId(1)] = Cancer(new EntityId(1), src, marked: true),
            [new EntityId(2)] = Cancer(new EntityId(2), a, marked: false),
            [new EntityId(3)] = Cancer(new EntityId(3), b, marked: false),
        };
        var seats = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Osteosarcoma },
        };
        if (withDendritic)
        {
            tiles[far] = Tile(far, TissueState.Healthy, new EntityId(4));
            cells[new EntityId(4)] = new()
            {
                Id = new EntityId(4), OwnerSeat = 1, Faction = Faction.Immune, Type = CellType.Dendritic,
                Position = far, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [], Equipped = [],
            };
            seats[1] = new() { Seat = 1, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };
        }

        return new WorldState
        {
            Board = new Board { Radius = 9, Tissues = tiles },
            Cells = cells,
            Players = seats,
            // 标记记在**上一个**世界回合：第 8 步的到期判据是 `本回合 >= 施加回合 + 1`，
            // 记本回合的话源自己会在同一次 E 阶段里被摘掉，读不出传染有没有发生
            Turn = new TurnState { WorldRound = 5, Phase = Phase.E, ActivePlayerSeat = 0 }
        };
    }

    private static Cell Cancer(EntityId id, HexPosition at, bool marked) => new()
    {
        Id = id, OwnerSeat = 0, Faction = Faction.Cancer, Type = CellType.Osteosarcoma,
        Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
        Hand = [], Equipped = [],
        Marked = marked, MarkLeft = marked ? 1 : 0, MarkRound = marked ? 5 : -1,
    };

    // ---- EV-0：世界事件 / 全局修饰容器 ----

    /// <summary>15 个世界事件的名字表与 GD 的 `CWWorldFx.EVENTS` 逐条一致。</summary>
    [Fact]
    public void 世界事件名字表与GDScript一致()
    {
        var gd = Regex.Match(WorldFxGd.Value, @"^const EVENTS: Array = \[(.+?)\]", RegexOptions.Multiline | RegexOptions.Singleline);
        Assert.True(gd.Success, "cw_world_fx.gd 里找不到 const EVENTS");
        var names = Regex.Matches(gd.Groups[1].Value, "\"([^\"]+)\"").Select(m => m.Groups[1].Value).ToArray();

        Assert.Equal(names, WorldEffects.WorldEventNames);
    }

    /// <summary>触发回合与 GD 的 `is_world_event_round` 一致：3 / 6 / 10 / 14。</summary>
    [Fact]
    public void 世界事件的触发回合与GDScript一致()
    {
        var gd = Regex.Match(DataGd.Value, @"return r in \[([\d,\s]+)\]");
        Assert.True(gd.Success, "cw_data.gd 里找不到 is_world_event_round 的回合表");
        var rounds = gd.Groups[1].Value.Split(',').Select(x => int.Parse(x.Trim())).ToHashSet();

        for (var r = 1; r <= 20; r++)
            Assert.True(WorldEffects.IsWorldEventRound(r) == rounds.Contains(r), $"第 {r} 回合：GDScript {rounds.Contains(r)}，C# {WorldEffects.IsWorldEventRound(r)}");
    }

    /// <summary>
    /// 强度是**同名条目求和**，不是取第一条。
    /// 打两张【TGF-β释放】就是两条各 1 层，逐份 −20%（定案 #63）。
    /// </summary>
    [Fact]
    public void 同名条目的强度是求和不是取第一条()
    {
        var world = AnaerobicWorld(4)
            .InstallEffect("TGF-β释放", left: 2)
            .InstallEffect("TGF-β释放", left: 2);

        Assert.Equal(2, WorldEffects.Stacks(world, "TGF-β释放"));
        Assert.Equal(0, WorldEffects.Stacks(world, "基质稳定"));
        Assert.True(WorldEffects.Active(world, "TGF-β释放"));
        Assert.False(WorldEffects.Active(world, "基质稳定"));
    }

    /// <summary>E 阶段第 8 步倒计时：`Left` 每回合 −1，归零移除。</summary>
    [Fact]
    public void 全局修饰在E阶段末倒计时并到期移除()
    {
        // left=1（【基质稳定】）本回合末就该走；left=2（【TGF-β释放】）要活过本回合末
        var world = LoneCancerBoard()
            .InstallEffect("基质稳定", left: 1)
            .InstallEffect("TGF-β释放", left: 2);

        var after = BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(6));
        Assert.False(WorldEffects.Active(after, "基质稳定"), "left=1 的条目本回合末该移除");
        Assert.True(WorldEffects.Active(after, "TGF-β释放"), "left=2 的条目要活过本回合末");

        var afterTwo = BoardRules.EvolveEndOfRound(after, new Xoshiro256StarStar(6));
        Assert.False(WorldEffects.Active(afterTwo, "TGF-β释放"), "再过一个回合就该到期");
    }

    /// <summary>
    /// 【基质稳定】现在住在容器里：在场那一回合固化计数不衰减。
    /// left=1 —— E 阶段衰减在回合末**之前**结算，正好盖住本回合那一次。
    /// </summary>
    [Fact]
    public void 基质稳定在场时固化计数不衰减()
    {
        var target = new HexPosition(1, 0, -1);
        var plain = RootedWorld(solidCount: 15, round: 6);   // 目标格上没有癌细胞 → 正常该 −0.5

        // 门槛拧高，免得【根深蒂固】把它推成固化、盖过衰减这条判据
        plain = plain.WithTuning(plain.Tuning with { SolidifyThreshold = [99, 99, 99] });
        var decayed = BoardRules.EvolveEndOfRound(plain, new Xoshiro256StarStar(4));
        var held = BoardRules.EvolveEndOfRound(plain.InstallEffect("基质稳定", left: 1), new Xoshiro256StarStar(4));

        Assert.True(held.Board.Tissues[target].SolidificationCount > decayed.Board.Tissues[target].SolidificationCount,
            $"【基质稳定】没挡住衰减：没挂 {decayed.Board.Tissues[target].SolidificationCount}、挂了 {held.Board.Tissues[target].SolidificationCount}");
    }

    /// <summary>
    /// 【基质稳定】只盖**本**回合：打出后这一回合衰减停摆，下一回合恢复。
    /// 上面那条是手工挂条目，这条走真卡 —— 卡挂成 left=2 的话下一回合还会停摆。
    /// </summary>
    [Fact]
    public void 基质稳定只盖本回合()
    {
        var target = new HexPosition(1, 0, -1);
        var world = RootedWorld(solidCount: 15, round: 6)
            .WithTuning(RuleTuning.Default with { SolidifyThreshold = [99, 99, 99] });

        var played = CardRules.Resolve(world, world.Cells[new EntityId(1)], "基质稳定",
            new Xoshiro256StarStar(1), null, null);

        // 跟**没打这张卡**的对照组比差值，而不是钉绝对数 ——
        // 这格上【根深蒂固】每回合也在 +1.0，钉绝对数既难读又一改别处就碎。
        int Count(WorldState w) => w.Board.Tissues[target].SolidificationCount;
        WorldState Next(WorldState w) => BoardRules.EvolveEndOfRound(w, new Xoshiro256StarStar(4));

        var plain1 = Next(world);
        var held1 = Next(played);
        Assert.Equal(5, Count(held1) - Count(plain1));      // 本回合挡下一次 −0.5 的衰减

        var plain2 = Next(plain1);
        var held2 = Next(held1);
        Assert.Equal(5, Count(held2) - Count(plain2));      // 差值**不再扩大** = 下一回合已经失效
    }

    /// <summary>
    /// 【TGF-β释放】要**活过本回合末**（下一次有氧在下个世界回合的 S 阶段），
    /// 并在那次有氧结算后**整批消耗**。
    ///
    /// 挂成 left=1 的话它在 E 阶段末就没了，减免根本轮不上；
    /// 不消耗的话下一回合还会再减一次。这两条都是手工挂条目测不出来的。
    /// </summary>
    [Fact]
    public void TGFβ活过回合末且有氧结算后整批消耗()
    {
        var world = TgfWorld();
        var id = new EntityId(1);

        var played = CardRules.Resolve(world, world.Cells[id], "TGF-β释放", new Xoshiro256StarStar(1), null, null);
        var afterE = BoardRules.EvolveEndOfRound(played, new Xoshiro256StarStar(2));
        Assert.True(WorldEffects.Active(afterE, "TGF-β释放"), "left=2 才能活到下一个 S 阶段");

        // 下一个世界回合的 S 阶段：有氧减免该生效，结算后条目该没了
        var plainGain = Aerobic(BoardRules.EvolveEndOfRound(world, new Xoshiro256StarStar(2)), id);
        var tgfGain = Aerobic(afterE, id);

        Assert.True(plainGain > 0, "夹具本身要有正收入，否则这条什么都证明不了");
        Assert.True(tgfGain < plainGain, $"TGF-β 没减到：没挂 {plainGain}、挂了 {tgfGain}");
    }

    /// <summary>跑一次 S 阶段的有氧，返回细胞这一次进账多少；顺带断言条目被消耗掉了。</summary>
    private static int Aerobic(WorldState s, EntityId id)
    {
        var before = s.Cells[id].Energy;
        var hadTgf = WorldEffects.Active(s, "TGF-β释放");
        var after = new BasicRulesEngine()
            .AdvancePhase(s.WithTurn(s.Turn.Copy(phase: Phase.S, startStep: 99)), new Xoshiro256StarStar(8))
            .NewState;
        if (hadTgf)
            Assert.False(WorldEffects.Active(after, "TGF-β释放"), "有氧结算之后同名条目该整批消耗");
        return after.Cells[id].Energy - before;
    }

    /// <summary>一个免疫细胞站在健康组织上，周围铺一圈健康组织给有氧供能。</summary>
    private static WorldState TgfWorld()
    {
        var at = new HexPosition(0, 0, 0);
        var tiles = new Dictionary<HexPosition, Tissue> { [at] = Tile(at, TissueState.Healthy, new EntityId(1)) };
        foreach (var n in at.GetNeighbors()) tiles[n] = Tile(n, TissueState.Healthy, null);

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = new Dictionary<EntityId, Cell>
            {
                [new EntityId(1)] = new()
                {
                    Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                    Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [],
                },
            },
            Players = new Dictionary<int, Player>
            {
                [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0,
                    AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I },
            },
            Turn = new TurnState { WorldRound = 3, Phase = Phase.E, ActivePlayerSeat = 0 }
        };
    }

    /// <summary>一格癌组织、一个癌细胞 —— 给容器的倒计时测试当最小盘面。</summary>
    private static WorldState LoneCancerBoard()
    {
        var at = new HexPosition(0, 0, 0);
        return CancerBoard(new Dictionary<HexPosition, Tissue> { [at] = Tile(at, TissueState.Cancer, new EntityId(1)) },
            at, CellType.Osteosarcoma, worldRound: 1);
    }

    private static readonly Lazy<string> WorldFxGd = new(() =>
    {
        var dir = AppContext.BaseDirectory;
        for (var i = 0; i < 12 && dir != null; i++)
        {
            var candidate = Path.Combine(dir, "game", "scripts", "core", "cw_world_fx.gd");
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
            dir = Path.GetDirectoryName(dir);
        }
        throw new FileNotFoundException("找不到 game/scripts/core/cw_world_fx.gd —— 这一组测试拿它当真相源");
    });

    // ---- E 阶段步序用的夹具 ----

    /// <summary>
    /// 一圈癌组织（6 格）围着**中心一格健康组织**，外面再铺两圈健康。
    ///
    /// 中心那格是个**封闭**的健康连通块（六邻全在棋盘内），所以【侵蚀】这一步**必定**
    /// 把它转成癌组织 —— 癌性块从 6 格长到 7 格。
    /// 不靠增生掷点是故意的：增生 3% 一格，靠运气的夹具会让判据时灵时不灵。
    /// </summary>
    private static WorldState PocketWorld()
    {
        var center = new HexPosition(0, 0, 0);
        var ring = center.GetNeighbors().ToArray();
        var tiles = new Dictionary<HexPosition, Tissue> { [center] = Tile(center, TissueState.Healthy, null) };
        foreach (var n in ring) tiles[n] = Tile(n, TissueState.Cancer, null);
        foreach (var n in ring)
            foreach (var m in n.GetNeighbors())
                tiles.TryAdd(m, Tile(m, TissueState.Healthy, null));
        foreach (var n in ring)
            foreach (var m in n.GetNeighbors())
                foreach (var k in m.GetNeighbors())
                    tiles.TryAdd(k, Tile(k, TissueState.Healthy, null));

        var home = ring[0];
        tiles[home] = Tile(home, TissueState.Cancer, new EntityId(1));
        return CancerBoard(tiles, home, CellType.Osteosarcoma, worldRound: 1);
    }

    /// <summary>一格固化癌组织，旁边一格癌组织带着给定的计数（可选被 TNF-α 冻住）。</summary>
    private static WorldState RootedWorld(int solidCount, int round, bool frozen = false)
    {
        var solid = new HexPosition(0, 0, 0);
        var target = new HexPosition(1, 0, -1);
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [solid] = new() { Position = solid, Type = TissueType.Normal, State = TissueState.SolidifiedCancer,
                SolidificationCount = 30, OccupyingCell = new EntityId(1), Charge = 0 },
            [target] = new() { Position = target, Type = TissueType.Normal, State = TissueState.Cancer,
                SolidificationCount = solidCount, OccupyingCell = null, Charge = 0,
                SolidLockRound = frozen ? round : 0 },
        };
        return CancerBoard(tiles, solid, CellType.Osteosarcoma, worldRound: round);
    }

    /// <summary>手里拿着【基质硬化】的癌细胞，旁边一格癌组织带着给定的计数。</summary>
    private static WorldState StromaWorld(int solidCount, bool frozen)
    {
        var at = new HexPosition(0, 0, 0);
        var target = new HexPosition(1, 0, -1);
        var tiles = new Dictionary<HexPosition, Tissue>
        {
            [at] = Tile(at, TissueState.Cancer, new EntityId(1)),
            [target] = new() { Position = target, Type = TissueType.Normal, State = TissueState.Cancer,
                SolidificationCount = solidCount, OccupyingCell = null, Charge = 0,
                SolidLockRound = frozen ? 1 : 0 },
        };
        return CancerBoard(tiles, at, CellType.Osteosarcoma, worldRound: 1, hand: ["基质硬化"]);
    }

    /// <summary>一个被【标记】的癌细胞。</summary>
    private static WorldState MarkedCancerWorld(int markRound, int worldRound)
    {
        var at = new HexPosition(0, 0, 0);
        var tiles = new Dictionary<HexPosition, Tissue> { [at] = Tile(at, TissueState.Cancer, new EntityId(1)) };
        var world = CancerBoard(tiles, at, CellType.Osteosarcoma, worldRound);
        var c = world.Cells[new EntityId(1)];
        return world.UpdateCell(c.Id, c.Copy(marked: true, markLeft: 1, markRound: markRound));
    }

    /// <summary>一个癌方独占的盘面（免疫一个都没有，E 阶段里压迫那一步就不会干扰）。</summary>
    private static WorldState CancerBoard(Dictionary<HexPosition, Tissue> tiles, HexPosition at,
        CellType type, int worldRound, IReadOnlyList<string>? hand = null) => new()
    {
        Board = new Board { Radius = 6, Tissues = tiles },
        Cells = new Dictionary<EntityId, Cell>
        {
            [new EntityId(1)] = new()
            {
                Id = new EntityId(1), OwnerSeat = 0, Faction = Faction.Cancer, Type = type,
                Position = at, Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = hand ?? [], Equipped = [],
            },
        },
        Players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0,
                AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = type },
        },
        Turn = new TurnState { WorldRound = worldRound, Phase = Phase.E, ActivePlayerSeat = 0 }
    };

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

    /// <summary>一块 4 格的癌组织，上面摆 1~3 个癌细胞（四人局）。</summary>
    private static WorldState AnaerobicBlockWorld(int cancerCells)
    {
        var spots = new[]
        {
            new HexPosition(0, 0, 0), new HexPosition(1, 0, -1),
            new HexPosition(2, 0, -2), new HexPosition(3, 0, -3),
        };
        var tiles = new Dictionary<HexPosition, Tissue>();
        var cells = new Dictionary<EntityId, Cell>();
        for (var i = 0; i < spots.Length; i++)
        {
            var occupant = i < cancerCells ? new EntityId((ulong)(i + 1)) : (EntityId?)null;
            tiles[spots[i]] = Tile(spots[i], TissueState.Cancer, occupant);
            if (occupant is not { } id) continue;
            cells[id] = new()
            {
                Id = id, OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
                Position = spots[i], Energy = 300, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                Hand = [], Equipped = [],
            };
        }

        var seats = new Dictionary<int, Player>();
        for (var i = 0; i < 4; i++)
            seats[i] = i == 1
                ? new() { Seat = 1, Faction = Faction.Cancer, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I, CancerType = CellType.Melanoma }
                : new() { Seat = i, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I };

        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tiles },
            Cells = cells,
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
