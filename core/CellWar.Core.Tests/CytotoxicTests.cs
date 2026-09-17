namespace CellWar.Core.Tests;

/// <summary>
/// 【细胞毒性增强】（2026-09-17 深夜，口径一第三批第 7 步）。GD cw_actions.gd:878-883 在攻击成功那一刻现读技能：
/// 非 T：每行动回合首次攻击成功 +1.0 进主笔固定加成，`first_this_turn` 闸门只在成功时烧；
/// T 细胞：每次攻击成功都追加一笔 1.0 的直击（同批第二笔，UNPREVENTABLE：走倍率、跳过第 ⑤ 层减免、不动闸门），与主笔合计判 BCL-2。
/// C# 此前是 BeginTurn 发一条 Uses=1 的攻击修饰：判定前就消耗、T 细胞一回合只吃一次、L1 视图的 mods 多一条。
/// </summary>
public class CytotoxicTests
{
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，站 (-4,0)
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，能量 60
    private static HexPosition P(int q, int r) => new(q, r, -q - r);
    private const string Skill = "细胞毒性增强";

    /// <summary>黑色素瘤挪到 (-3,0)，免疫细胞装备本卡、按需换型；攻击 = 朝它的格迁移。</summary>
    private static WorldState World(CellType attacker = CellType.ImmuneBasic)
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        var c = s.Cells[Cancer1];
        s = s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(P(-3, 0), Cancer1).UpdateCell(Cancer1, c.Copy(position: P(-3, 0)));
        return s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: attacker, equipped: [Skill]));
    }

    private static WorldState Attack(WorldState s, int seed)
    {
        var r = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), new RecordingRng(new Xoshiro256StarStar((ulong)seed)));
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    /// <summary>扫种子直到这次攻击的主笔是「成功」（不是无效、不是大成功）：目标损失恰好 <paramref name="expectedLoss"/>。</summary>
    private static WorldState AttackUntilLoss(WorldState s, int expectedLoss, out int usedSeed)
    {
        for (var seed = 1; seed <= 200; seed++)
        {
            var after = Attack(s, seed);
            var loss = s.Cells[Cancer1].Energy - after.Cells[Cancer1].Energy;
            if (loss != expectedLoss) continue;
            usedSeed = seed;
            return after;
        }
        throw new Xunit.Sdk.XunitException($"200 颗种子里没有一次攻击让目标恰好损失 {expectedLoss}");
    }

    private static WorldState AttackUntilFail(WorldState s)
    {
        for (var seed = 1; seed <= 200; seed++)
        {
            var after = Attack(s, seed);
            if (after.Cells[Cancer1].Energy == s.Cells[Cancer1].Energy && after.Cells[Immune0].Position == P(-4, 0)) return after;
        }
        throw new Xunit.Sdk.XunitException("200 颗种子里没有一次攻击无效");
    }

    private static int Gate(WorldState s) => s.Cells[Immune0].FxTurn.GetValueOrDefault(Skill);

    [Fact]
    public void 非T_首次攻击成功加1_0_闸门只在成功时烧_第二次不加()
    {
        var first = AttackUntilLoss(World(), 20, out _);          // 成功 1.0 + 本卡 1.0
        Assert.Equal(1, Gate(first));
        Assert.DoesNotContain(first.Cells[Immune0].Modifiers, m => m.Card == Skill);   // 不再是修饰
        var second = AttackUntilLoss(first, 10, out _);            // 同回合第二次成功：没有加成
        Assert.Equal(2, Gate(second));                             // GD first_this_turn 每次成功都记一笔
    }

    [Fact]
    public void 非T_攻击无效不烧闸门_本回合下一次成功仍加1_0()
    {
        var failed = AttackUntilFail(World());
        Assert.Equal(0, Gate(failed));
        Assert.False(failed.Cells[Immune0].FxTurn.ContainsKey(Skill));
        var success = AttackUntilLoss(failed, 20, out _);
        Assert.Equal(1, Gate(success));
    }

    [Fact]
    public void T细胞_每次成功都追加直击_直击不吃护盾也不消耗护盾_不动闸门()
    {
        var s = World(CellType.TCell);
        s = CellRules.AddModifier(s, s.Cells[Cancer1], new ActiveModifier("细胞膜修复", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 15, 0, 1, ModifierDuration.Game));
        // 主笔 1.0 被【细胞膜修复】挡光（盾被消耗），直击 1.0 照扣 → 共 1.0
        var first = AttackUntilLoss(s, 10, out _);
        Assert.DoesNotContain(first.Cells[Cancer1].Modifiers, m => m.Card == "细胞膜修复");
        Assert.False(first.Cells[Immune0].FxTurn.ContainsKey(Skill));                 // T 细胞永远不写这把闸门
        // 第二次成功：主笔 1.0 + 直击 1.0
        var second = AttackUntilLoss(first, 20, out _);
        Assert.False(second.Cells[Immune0].FxTurn.ContainsKey(Skill));
    }

    [Fact]
    public void T细胞_被标记的目标两笔各自翻倍_各扣一层标记()
    {
        var s = World(CellType.TCell);
        s = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(marked: true, markLeft: 2));
        var after = AttackUntilLoss(s, 40, out _);                 // (1.0 + 1.0) × 2
        Assert.Equal(0, after.Cells[Cancer1].MarkLeft);
        Assert.False(after.Cells[Cancer1].Marked);
    }

    [Fact]
    public void T细胞_BCL2按两笔合计判_免掉整批_吞噬体成熟不斩杀()
    {
        var s = World(CellType.TCell);
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(equipped: [Skill, "吞噬体成熟"]));
        s = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(energy: 15));
        s = CellRules.AddModifier(s, s.Cells[Cancer1], new ActiveModifier("BCL-2抗凋亡", ModifierTarget.EnergyLoss, ModifierStage.Add, SourceLayer.Card, 0, 0, null, 1, ModifierDuration.Game));
        for (var seed = 1; seed <= 200; seed++)
        {
            var after = Attack(s, seed);
            if (after.Cells[Cancer1].Energy == 15 && CellRules.HasModifier(after.Cells[Cancer1], "BCL-2抗凋亡")) continue;   // 攻击无效，换颗种子
            // 主笔 1.0（或大成功 2.0）+ 直击 1.0 ≥ 1.5 → 整批被免，能量改为 I 期的 0.5，卡弃置；「造成了伤害」为 0 → 【吞噬体成熟】不入队
            Assert.True(after.Cells[Cancer1].IsAlive);
            Assert.Equal(5, after.Cells[Cancer1].Energy);
            Assert.DoesNotContain(after.Cells[Cancer1].Modifiers, m => m.Card == "BCL-2抗凋亡");
            return;
        }
        Assert.Fail("200 颗种子全是攻击无效");
    }

    [Fact]
    public void 伤害管线的直击口径_不受减伤_合计判免死_实际失去合计()
    {
        var s = World();
        s = CellRules.AddModifier(s, s.Cells[Cancer1], new ActiveModifier("细胞膜修复", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 15, 0, 1, ModifierDuration.Game));
        var after = CellRules.Damage(s, Cancer1, 10, LossSource.ImmuneAttack, "攻击", 10, out var dealt);
        Assert.Equal(10, dealt);                                   // 主笔被挡光、直击照扣
        Assert.Equal(50, after.Cells[Cancer1].Energy);
        Assert.DoesNotContain(after.Cells[Cancer1].Modifiers, m => m.Card == "细胞膜修复");   // 主笔消耗了它，直击一个盾都不碰

        var low = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(energy: 8));
        var killed = CellRules.Damage(low, Cancer1, 0, LossSource.ImmuneAttack, "攻击", 10, out var dealtLow);
        Assert.Equal(8, dealtLow);                                 // 实际失去 = min(合计, 结算前能量)
        Assert.False(killed.Cells[Cancer1].IsAlive);
    }

    // ---------- 抗原记忆 / 巨噬吸血的基数：GD 读这一批的 actual（过完倍率与护盾），C# 此前读裸值 ----------

    [Fact]
    public void 抗原记忆按实际失去算_标记翻倍给两点_被盾挡光不给()
    {
        var s = World();
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(equipped: []));
        var marked = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(marked: true, markLeft: 1));
        var doubled = AttackUntilLoss(marked, 20, out _);           // 成功 1.0 × 2
        Assert.Equal(2, doubled.Players[0].AntigenMemory);          // 此前只按裸值 1.0 给 1 点

        var shielded = CellRules.AddModifier(s, s.Cells[Cancer1], new ActiveModifier("细胞膜修复", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 15, 0, 1, ModifierDuration.Game));
        var blocked = AttackUntilLoss(shielded, 0, out _);          // 1.0 被 1.5 挡光（盾消耗掉），可能是无效也可能是成功被挡 —— 两种都不该给记忆
        Assert.Equal(0, blocked.Players[0].AntigenMemory);
    }

    [Fact]
    public void 巨噬吸血按主笔实际失去算_被盾挡光就不回()
    {
        var s = World(CellType.Macrophage);
        s = s.UpdateCell(Immune0, s.Cells[Immune0].Copy(equipped: []));
        s = CellRules.AddModifier(s, s.Cells[Cancer1], new ActiveModifier("细胞膜修复", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 15, 0, 1, ModifierDuration.Game));
        var cost = RulePolicies.QuoteMove(s, s.Cells[Immune0], P(-3, 0), null)!.Value;
        for (var seed = 1; seed <= 200; seed++)
        {
            var after = Attack(s, seed);
            if (CellRules.HasModifier(after.Cells[Cancer1], "细胞膜修复") || after.Cells[Cancer1].Energy != 60) continue;   // 无效（盾还在）或大成功（2.0 − 1.5 还剩 0.5）：换颗种子
            Assert.Equal(s.Cells[Immune0].Energy - cost, after.Cells[Immune0].Energy);   // 此前按理论值 1.0 回 0.5
            return;
        }
        Assert.Fail("200 颗种子全是攻击无效");
    }
}
