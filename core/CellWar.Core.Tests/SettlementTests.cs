namespace CellWar.Core.Tests;

public class SettlementTests
{
    [Fact]
    public void ValueModifiersFollowPrdStageOrder()
    {
        // 基准 1.0（10）→ 替换为 0.5（5）→ +0.3（3）→ -0.1（1）→ ×2（200%）→ ÷2（50%）→ 附加费 +0.4（4）
        var mods = new[]
        {
            new ValueModifier(ModifierStage.Add, SourceLayer.Card, 1, 3),
            new ValueModifier(ModifierStage.Replace, SourceLayer.Card, 2, 5),
            new ValueModifier(ModifierStage.Multiply, SourceLayer.Card, 3, 200),
            new ValueModifier(ModifierStage.Subtract, SourceLayer.Card, 4, 1),
            new ValueModifier(ModifierStage.Divide, SourceLayer.Card, 5, 200),
            new ValueModifier(ModifierStage.Surcharge, SourceLayer.WorldEvent, 6, 4)
        };
        Assert.Equal(11, Settlement.ApplyValue(10, mods));
    }

    [Fact]
    public void SameStageOrdersByLayerThenSequence()
    {
        var mods = new[]
        {
            new ValueModifier(ModifierStage.Add, SourceLayer.Skill, 5, 10),
            new ValueModifier(ModifierStage.Add, SourceLayer.Passive, 9, 20),
            new ValueModifier(ModifierStage.Add, SourceLayer.Card, 2, 40)
        };
        // 顺序：被动(+20) → 卡(+40) → 技能(+10)
        Assert.Equal(70, Settlement.ApplyValue(0, mods));
    }

    [Fact]
    public void SubtractHonoursItsOwnFloor()
    {
        var mods = new[] { new ValueModifier(ModifierStage.Subtract, SourceLayer.Card, 1, 5, Floor: 2) };
        Assert.Equal(2, Settlement.ApplyValue(5, mods));
    }

    [Fact]
    public void FreeWaivesThenUnavoidableSurchargeApplies()
    {
        var mods = new[]
        {
            new ValueModifier(ModifierStage.Free, SourceLayer.Card, 1, 0),
            new ValueModifier(ModifierStage.Surcharge, SourceLayer.WorldEvent, 2, 2)
        };
        Assert.Equal(2, Settlement.ApplyValue(12, mods));
    }

    [Fact]
    public void EnergyLossUsesItsOwnOrderAddMultiplyDivideSubtract()
    {
        // 基础 10 → +5 → ×2 → ÷2 → -15(最低0)
        var mods = new[]
        {
            new ValueModifier(ModifierStage.Subtract, SourceLayer.Card, 4, 15, Floor: 0),
            new ValueModifier(ModifierStage.Multiply, SourceLayer.Card, 2, 200),
            new ValueModifier(ModifierStage.Add, SourceLayer.Card, 1, 5),
            new ValueModifier(ModifierStage.Divide, SourceLayer.Card, 3, 200)
        };
        Assert.Equal(0, Settlement.ApplyEnergyLoss(10, mods));
        Assert.Equal(0, Settlement.ApplyEnergyLoss(3, new[] { new ValueModifier(ModifierStage.Subtract, SourceLayer.Card, 1, 10) }));
    }

    [Fact]
    public void AffordabilityForbidsNonSelfDestructiveCostAtZeroRemaining()
    {
        Assert.False(Settlement.CanPay(10, 10));
        Assert.True(Settlement.CanPay(11, 10));
        Assert.True(Settlement.CanPay(10, 10, selfDestructive: true));
    }

    [Fact]
    public void RoundTenthUsesAwayFromZero()
    {
        Assert.Equal(3, Settlement.RoundTenth(2.5));
        Assert.Equal(4, Settlement.RoundTenth(3.5));
        Assert.Equal(25, Settlement.RoundTenth(24.5));
    }
}

