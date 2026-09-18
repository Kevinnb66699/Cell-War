using CellWar.Core;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// `setup_ops` 前奏（E-2，Kevin 2026-09-19 拍板）的闸：
/// **`cells[].mods` 写什么，装完就得逐字是什么** —— 四元组 `{name, uses, until, seq}` 是 envelope 的载体（闸二 2b），
/// 而缺的六项由前奏转调生产代码现挂、loader 里没有 `name → ActiveModifier` 工厂（纪律 3）。
///
/// 覆盖 E-2 点名的四张（`cw_cost.gd:TEMPLATES` 里 `Store.MOD` 的四张）+ Flag 类各一条最小用例，
/// 外加三条反向闸：路由表认不出的名字、`until` 与生产代码对不上、`mods` 没按 (seq, 名) 升序写。
/// </summary>
public class SetupOpsTests
{
    private const string Cytokine = "细胞因子网络·待发";

    public static TheoryData<string, string, int, string, string, ModifierStage, int, ModifierRequirement> Rows() => new()
    {
        // 名字, until, uses, 细胞种类, 该席阵营（"" = 免疫）, 生产代码挂出来的 Stage / Value / Requirement（断言 ③ 用：都不是默认值）
        { "炎症趋化", "turn", 1, "ImmuneBasic", "", ModifierStage.Replace, 5, ModifierRequirement.MoveToCancerous },
        { "CXCR3趋化", "turn", 2, "ImmuneBasic", "", ModifierStage.Subtract, 5, ModifierRequirement.MoveToCancerous },
        { "上皮—间质转化", "turn", 1, "Melanoma", "Melanoma", ModifierStage.Replace, 2, ModifierRequirement.MoveToHealthy },
        { "癌症干性", "round", 2, "Melanoma", "Melanoma", ModifierStage.Free, 0, ModifierRequirement.MoveToCancerous },
        { Cytokine, "round", 1, "ImmuneBasic", "", ModifierStage.Add, 0, ModifierRequirement.None },
    };

    [Theory]
    [MemberData(nameof(Rows))]
    public void 四张卡加Flag各一条_装完的mods四元组逐字等于用例(string name, string until, int uses, string type, string cancer,
        ModifierStage stage, int value, ModifierRequirement requirement)
    {
        var world = WorldLoader.Load(Spec(name, until, uses, type, cancer));

        // ① 四元组逐字（Dump 那一路）
        var dumped = WorldLoader.Dump(world).Cells.Single().Mods;
        Assert.Equal([new L0Mod(name, uses, until, 3)], dumped);

        // ② envelope 那一路（闸二 2b 真正比的载体）：`L1View` 的 `cells[].mods` 同样是这四个键
        var mods = (List<object?>)((Dictionary<string, object?>)((List<object?>)L1View.Of(world)["cells"]!)[0]!)["mods"]!;
        Assert.Equal(new Dictionary<string, object?>
        {
            ["name"] = name, ["uses"] = (long)uses, ["until"] = until, ["seq"] = 3L,
        }, Assert.Single(mods));

        // ③ 前奏挂上的不是个空壳：四元组之外的 Stage / Value / Requirement 逐行断**非默认值**（`Move` 是 `default(ModifierTarget)`，
        //    只断 Target 对四张移动费用卡等于没断）—— 这几项 loader 里没有来源，只能是生产代码现挂的
        var made = world.Cells.Values.Single().Modifiers.Single();
        Assert.Equal((name == Cytokine ? ModifierTarget.Flag : ModifierTarget.Move, stage, value, requirement),
            (made.Target, made.Stage, made.Value, made.Requirement));
    }

    [Fact]
    public void 路由表认不出的名字是UNLOADABLE而不是静默跳过()
    {
        var spec = Spec("并不存在的修饰", "turn", 1, "ImmuneBasic", "");
        var e = Assert.Throws<UnloadableException>(() => WorldLoader.Load(spec));
        Assert.Contains("前奏路由表里没有它", e.Message);
    }

    [Fact]
    public void until与生产代码对不上就炸()
    {
        var spec = Spec("炎症趋化", "round", 1, "ImmuneBasic", "");   // 生产代码挂的是 turn
        var e = Assert.Throws<UnloadableException>(() => WorldLoader.Load(spec));
        Assert.Contains("`until` 就是 `Duration`", e.Message);
    }

    [Fact]
    public void mods没按序写就炸()
    {
        var spec = Spec("炎症趋化", "turn", 1, "ImmuneBasic", "");
        var cell = spec.Cells[0] with { Mods = [new L0Mod("CXCR3趋化", 2, "turn", 5), new L0Mod("炎症趋化", 1, "turn", 3)] };
        var e = Assert.Throws<UnloadableException>(() => WorldLoader.Load(spec with { Cells = [cell] }));
        Assert.Contains("升序", e.Message);
    }

    /// <summary>一只细胞、一条修饰的最小盘面。`play_n` 写 3 让前奏自然产出的 `Sequence` = 4（`AddModifier` 盖 `PlayCounter + 1`），与用例写的 `seq` = 3 不同 —— 盖不回去就露馅。</summary>
    private static L0World Spec(string name, string until, int uses, string type, string cancer) => new()
    {
        Players = [cancer == ""
            ? new L0Player(0, "immune")
            : new L0Player(0, "cancer", CancerType: cancer)],
        Cells =
        [
            new L0Cell
            {
                Seat = 0, Type = type, At = "0,0",
                PlayN = 3,
                Equipped = name == "细胞因子网络·待发" ? ["细胞因子网络"] : [],
                Mods = [new L0Mod(name, uses, until, 3)],
            },
        ],
    };
}
