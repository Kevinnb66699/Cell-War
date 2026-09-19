using static CellWar.Core.CellRules;

namespace CellWar.Core.Tests;

/// <summary>
/// 减免层按来源认账 + 逐组 ON_BENEFIT（2026-09-17，2p 夹具第 52 步撞出来的）：
/// GD `_shield_applies` 里【缺氧适应】只挡癌方技能 / 【微环境压迫】、【DNA损伤修复】只挡免疫方的事件 / 技能（普通攻击不挡），
/// `_reduce` 按组（同名合并）、按打出先后、每组没压低就不消耗、挡光即停。
/// C# 此前对目标身上全部 EnergyLoss 修饰一律套用一律消耗，【突变】的自损把【DNA损伤修复】吃掉了。
/// </summary>
public class ShieldSourceTests
{
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，能量 30
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，能量 60
    private static readonly EntityId Signet3 = new(4);   // 席位 3：印戒（【囊性护甲】），能量 60

    private static WorldState World() => DemoScenario.Create();

    private static WorldState Shield(WorldState s, EntityId id, string card, int value = 10, ModifierDuration duration = ModifierDuration.Game)
        => AddModifier(s, s.Cells[id], new ActiveModifier(card, ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, value, 0, 1, duration));

    private static int Count(WorldState s, EntityId id, string card) => s.Cells[id].Modifiers.Count(m => m.Card == card);

    [Theory]
    [InlineData(LossSource.ImmuneEffect, 60 - 10, 0)]   // 免疫方事件 / 技能：I 期挡 1.0，消耗
    [InlineData(LossSource.ImmuneAttack, 60 - 20, 1)]   // 普通攻击不挡也不消耗（PD-L1 的领地，口径 #62）
    [InlineData(LossSource.CancerSkill, 60 - 20, 1)]
    [InlineData(LossSource.World, 60 - 20, 1)]
    public void DNA损伤修复_只挡免疫方的事件和技能(LossSource source, int energyAfter, int left)
    {
        var s = Shield(World(), Cancer1, "DNA损伤修复");
        var after = Damage(s, Cancer1, 20, source);
        Assert.Equal(energyAfter, after.Cells[Cancer1].Energy);
        Assert.Equal(left, Count(after, Cancer1, "DNA损伤修复"));
    }

    [Fact]
    public void DNA损伤修复的减免值按结算当刻的分期取()
    {
        var s = Shield(World(), Cancer1, "DNA损伤修复");       // I 期打出（存的是 1.0）
        var later = s.WithTurn(s.Turn.Copy(round: 6));          // II 期结算 → 1.5（定案 #64）
        Assert.Equal(60 - (20 - 15), Damage(later, Cancer1, 20, LossSource.ImmuneEffect).Cells[Cancer1].Energy);
    }

    [Theory]
    [InlineData(LossSource.CancerSkill, "", 30 - 10, 0)]
    [InlineData(LossSource.World, "微环境压迫", 30 - 10, 0)]
    [InlineData(LossSource.World, "", 30 - 20, 1)]              // 中立来源 / 反弹不挡
    [InlineData(LossSource.ImmuneEffect, "", 30 - 20, 1)]
    public void 缺氧适应_只挡癌方技能与微环境压迫(LossSource source, string ability, int energyAfter, int left)
    {
        var s = Shield(World(), Immune0, "缺氧适应");
        var after = Damage(s, Immune0, 20, source, ability);
        Assert.Equal(energyAfter, after.Cells[Immune0].Energy);
        Assert.Equal(left, Count(after, Immune0, "缺氧适应"));
    }

    [Theory]
    [InlineData(LossSource.ImmuneAttack)]
    [InlineData(LossSource.CancerSkill)]
    [InlineData(LossSource.World)]
    public void 细胞膜修复与I型干扰素_任何来源都挡(LossSource source)
    {
        var s = Shield(Shield(World(), Cancer1, "细胞膜修复", 15), Cancer1, "I型干扰素", 10, ModifierDuration.Round);
        var after = Damage(s, Cancer1, 40, source);
        Assert.Equal(60 - (40 - 15 - 10), after.Cells[Cancer1].Energy);
        Assert.Equal(0, Count(after, Cancer1, "细胞膜修复"));
        Assert.Equal(0, Count(after, Cancer1, "I型干扰素"));
    }

    [Fact]
    public void 同名合并成一组_两张细胞膜修复这一次减3_0()
    {
        var s = Shield(Shield(World(), Cancer1, "细胞膜修复", 15), Cancer1, "细胞膜修复", 15);
        var after = Damage(s, Cancer1, 40, LossSource.ImmuneAttack);
        Assert.Equal(60 - 10, after.Cells[Cancer1].Energy);
        Assert.Equal(0, Count(after, Cancer1, "细胞膜修复"));   // 定案 #57：同名一起扣
    }

    [Fact]
    public void 挡光即停_后面的盾留着_零伤害一组都不消耗()
    {
        // 先打【细胞膜修复】（1.5）再打【I型干扰素】（1.0）：1.0 的伤害被第一组挡光，第二组不消耗
        var s = Shield(Shield(World(), Cancer1, "细胞膜修复", 15), Cancer1, "I型干扰素", 10, ModifierDuration.Round);
        var after = Damage(s, Cancer1, 10, LossSource.ImmuneAttack);
        Assert.Equal(60, after.Cells[Cancer1].Energy);
        Assert.Equal(0, Count(after, Cancer1, "细胞膜修复"));
        Assert.Equal(1, Count(after, Cancer1, "I型干扰素"));

        var zero = Damage(s, Cancer1, 0, LossSource.ImmuneAttack);
        Assert.Equal(1, Count(zero, Cancer1, "细胞膜修复"));
        Assert.Equal(1, Count(zero, Cancer1, "I型干扰素"));
    }

    [Fact]
    public void 囊性护甲排最前_它挡光了护盾卡就不动()
    {
        var s = Shield(World(), Signet3, "细胞膜修复", 15);
        var after = Damage(s, Signet3, 5, LossSource.ImmuneAttack);   // 印戒【囊性护甲】−0.5 先挡光
        Assert.Equal(60, after.Cells[Signet3].Energy);
        Assert.True(after.Cells[Signet3].ArmorUsedThisRound);
        Assert.Equal(1, Count(after, Signet3, "细胞膜修复"));
    }

    [Fact]
    public void 护盾组按打出先后排_护甲最前()
    {
        var s = Shield(Shield(World(), Signet3, "I型干扰素"), Signet3, "细胞膜修复", 15);
        var groups = ShieldGroups(s, s.Cells[Signet3], LossSource.ImmuneAttack, "");
        Assert.Equal(new[] { "囊性护甲", "I型干扰素", "细胞膜修复" }, groups.Select(g => g.Name).ToArray());
        Assert.Equal(new[] { ArmorReduction, Ifn1Cut, MembraneCut }, groups.Select(g => g.Cut).ToArray());
    }

    [Fact]
    public void 标记只认免疫来源()
    {
        var s = World();
        s = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(marked: true, markLeft: 1));
        var cancerHit = Damage(s, Cancer1, 10, LossSource.CancerSkill);
        Assert.Equal(50, cancerHit.Cells[Cancer1].Energy);
        Assert.True(cancerHit.Cells[Cancer1].Marked);
        var immuneHit = Damage(s, Cancer1, 10, LossSource.ImmuneEffect);
        Assert.Equal(40, immuneHit.Cells[Cancer1].Energy);
        Assert.False(immuneHit.Cells[Cancer1].Marked);
    }

    [Fact]
    public void 突变第三点的自损不进伤害管线_护盾与标记都不动_扣到0以下就死()
    {
        var s = World();
        s = Shield(s, Cancer1, "DNA损伤修复");
        s = Shield(s, Cancer1, "细胞膜修复", 15);
        s = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(marked: true, markLeft: 1));
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 1).WithPendingMutation(1, Cancer1, 3, 3));

        var after = CardRules.ChooseMutation(s, new ChooseMutationDecision(1, Cancer1, 0), new Xoshiro256StarStar(1)).NewState;
        Assert.Equal(60 - 8, after.Cells[Cancer1].Energy);             // MUTATE_EXTRA_LOSS 原样扣
        Assert.Equal(1, Count(after, Cancer1, "DNA损伤修复"));
        Assert.Equal(1, Count(after, Cancer1, "细胞膜修复"));
        Assert.True(after.Cells[Cancer1].Marked);

        var dying = s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(energy: 8));
        var dead = CardRules.ChooseMutation(dying, new ChooseMutationDecision(1, Cancer1, 0), new Xoshiro256StarStar(1)).NewState;
        Assert.False(dead.Cells[Cancer1].IsAlive);                    // 效果扣减可致死（GD：`if energy <= 0: kill`）
    }
}
