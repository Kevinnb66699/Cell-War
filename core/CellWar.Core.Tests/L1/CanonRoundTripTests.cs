using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// **M2 的闸门**：`w → Canon → FromCanon → w'`，两边的**全量 JSON 逐字节相同**。
///
/// 对拍规格把它排在 harness 写第二行代码之前，理由写得很直白：
///
///   > 原写法「`FromCanon(Canon(w))` 与 `w` 逐字段相等」若那个「逐字段」只覆盖 canon 字段，
///   > 它在缺失的 15 个字段上**必然空过、给出虚假通过**。
///   > 正确形式：取一个真实推进过的 `w`，比**全量**。差异字段清单就是必须补进 canon 的清单。
///   > **这一步不过，后面全是假清单。**
///
/// 所以这里不比 canon、不比「我列出来的字段」，比的是把整个 `WorldState` 序列化之后的那串字符。
/// 少搬一个字段，diff 直接把字段名打在失败信息里。
/// </summary>
public class CanonRoundTripTests
{
    [Theory]
    [MemberData(nameof(Worlds))]
    public void 世界过一遍canon之后逐字段相同(string name, WorldState world)
    {
        var diffs = DeepDiff.Compare(world, CanonCodec.From(CanonCodec.To(world)));
        Assert.True(diffs.Count == 0,
            $"【{name}】过一遍 canon 之后不一样了 —— 下面每一条就是**必须补进 canon 的字段**："
            + Environment.NewLine + "  " + string.Join(Environment.NewLine + "  ", diffs));
    }

    /// <summary>
    /// 夹具要**真实推进过**，不能是手摆的干净盘面 ——
    /// 「只进世界不进文件」的字段（`effector_round` 那一类）只有在推进之后才不是默认值，
    /// 而默认值的字段丢了也看不出来（今天已经在 `Clone` 护栏上栽过三次）。
    /// </summary>
    public static TheoryData<string, WorldState> Worlds()
    {
        var data = new TheoryData<string, WorldState>();
        data.Add("开局", Fresh());
        data.Add("推进若干回合", Advanced());
        data.Add("每个字段都非默认", Loaded());
        return data;
    }

    /// <summary>
    /// 用 `DemoScenario`（盘面已经摆好、有活细胞）而不是 `MatchSetup.Create` ——
    /// 后者出来的是**开局选址**阶段，一个细胞都还没落，推进不动也没什么可比。
    /// </summary>
    private static WorldState Fresh() => DemoScenario.Create();

    /// <summary>真跑几个阶段：让 rng、回合、组织、能量都动起来。</summary>
    private static WorldState Advanced()
    {
        var engine = new BasicRulesEngine();
        var rng = new Xoshiro256StarStar(7);
        var s = DemoScenario.Create();
        for (var i = 0; i < 40 && s.Turn.Phase != Phase.Finished; i++)
            s = engine.AdvancePhase(s, rng).NewState;
        return s;
    }

    /// <summary>
    /// 手工把**容易被漏掉的那些**都填成非默认值：挂起态、两个趋化源、
    /// 闸门、装备戳、修饰九元组、事件容器、旋钮。
    /// </summary>
    private static WorldState Loaded()
    {
        var s = Advanced();
        var id = s.Cells.Values.First(c => c.IsAlive).Id;
        var other = s.Cells.Values.First(c => c.Id != id).Id;

        s = s.UpdateCell(id, s.Cells[id].Copy(
            equipped: ["耗竭抵抗", "组织巡航"],
            equipSeq: new Dictionary<string, int> { ["耗竭抵抗"] = 3, ["组织巡航"] = 5 },
            fxTurn: new Dictionary<string, int> { ["RAS持续激活"] = 1 },
            fxRound: ["模式识别增强"],
            neutralUntil: 9, chemoCooldown: 1, chainLeft: 4, chainBonus: 15,
            hand: ["缺氧适应"], marked: true, markLeft: 2, markRound: 3,
            campRound: 2, campPosition: new HexPosition(1, -1, 0),
            modifiers: [new ActiveModifier("组织巡航·减", ModifierTarget.Move, ModifierStage.Subtract,
                SourceLayer.Passive, 5, 2, 2, ActiveModifier.Unlimited, ModifierDuration.Turn,
                ModifierRequirement.MoveToCancerous)]));

        s = s.InstallEffect("TGF-β释放", left: 2)
             .InstallEffect("基质稳定", left: 1)
             .WithTuning(s.Tuning with { EnergyCap = 200, CancerUpkeepPercent = 5 });

        return s.WithTurn(s.Turn.Copy(
                startStep: 2, streak: 4, pendingDiscard: 1, pendingDiscardCell: other,
                effectorRound: 3)
            .WithChemo(new HexPosition(2, -2, 0), 2, 0, id)
            .WithTrack(other, null, 2)
            .WithPendingMutation(1, other, 2, 3)
            .WithPendingChain(id)
            .WithPendingChemotaxis(other, 2, "炎症性趋化")
            .PushWalk(id, 1, "趋化募集")   // 外层帧非空：Canon 漏搬 WalkOuter 这里会红
            .WithPendingCard("炎症性趋化", other)
            .WithCardResolveDepth(1)
            .WithCancerReviveFrom(2)
            .WithPendingCouple(id, other, id)
            .WithPendingRemodel(id, new HexPosition(1, 0, -1), new HexPosition(0, 2, -2), 1)
            .WithPendingPickCell(1, "炎症风暴", id)
            .WithPendingLand(other, new HexPosition(2, -1, -1), 1));
    }

}
