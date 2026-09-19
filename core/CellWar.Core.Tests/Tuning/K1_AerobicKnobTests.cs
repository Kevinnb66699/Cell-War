using CellWar.Core;

namespace CellWar.Core.Tests.Tuning;

/// <summary>
/// K1 · 有氧族 5 个旋钮进内核（口径二 E-3；`docs/内核替换_拍板记录.md` §九，Kevin 2026-09-19：
/// 待定的 6 个也补进内核、有氧这一族由我做）。
///
/// 期望一律**从 GD 搬**：`game/tests/headless_test.gd:t_batch2_rules` 的 ①（有氧均分）与 ②（坏死打折）两段，
/// 以及 `game/scripts/core/cw_world.gd` 的 `_aerobic_base` / `_split_aerobic` / `necrosis_cut` 三条算式。
/// **不拿「C# 今天算出多少」当期望** —— 那样只会把偏离钉死（GdScriptParityTests 开头那段教训）。
/// </summary>
public class K1_AerobicKnobTests
{
    private const int LevelIShare = 20;   // CWData.AEROBIC_BY_LEVEL[0] = CWData.AEROBIC_LEVEL_BASE = 2.0
    private const int SplitRef = 2;       // CWData.AEROBIC_SPLIT_REF

    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    /// <summary>只有 n 个免疫细胞的空盘面（都在席位 0、都活着、能量 0）—— GD `bare_game()` + `put_immune()` 的对应物。
    /// 有氧只读「等级 / 存活免疫数 / 脚下那格坏死没有」，所以盘面不必铺满。</summary>
    private static WorldState World(int immuneCount = 1, ImmuneLevel level = ImmuneLevel.I)
    {
        var tissues = new Dictionary<HexPosition, Tissue>();
        var cells = new Dictionary<EntityId, Cell>();
        for (var i = 0; i < immuneCount; i++)
        {
            var p = P(i, 0);
            var id = new EntityId((ulong)i + 1);
            tissues[p] = new Tissue
            {
                Position = p, Type = TissueType.Normal, State = TissueState.Healthy,
                SolidificationCount = 0, OccupyingCell = id, Charge = 0
            };
            cells[id] = new Cell
            {
                Id = id, OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.ImmuneBasic,
                Position = p, Energy = 0, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>()
            };
        }
        var players = new Dictionary<int, Player>
        {
            [0] = new() { Seat = 0, Faction = Faction.Immune, IsAlive = true, DrawCount = 0, AntigenMemory = 0, ImmuneLevel = level }
        };
        return new WorldState
        {
            Board = new Board { Radius = 6, Tissues = tissues }, Cells = cells, Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.S, ActivePlayerSeat = 0 }
        };
    }

    private static WorldState Tune(WorldState s, Func<RuleTuning, RuleTuning> f) => s.WithTuning(f(s.Tuning));

    /// <summary>把第一只免疫细胞脚下那格变成坏死（GD `g.tiles[pos]["necrosis"] = CWData.NECROSIS_TOXIN`）。</summary>
    private static WorldState Necrotic(WorldState s)
    {
        var p = s.Cells.Values.First().Position;
        return s.WithBoard(s.Board.UpdateTissue(p, s.Board.Tissues[p].WithNecrosis(3)));
    }

    private static int Share(WorldState s) => RulePolicies.AerobicShare(s, s.Cells.Values.First());

    // ---- 文档钉子：12 个旋钮的默认值逐个 = GD 今天的值（零行为改动的前提）----

    /// <summary>
    /// 默认值表。左边是 C# 属性，右边注释是 GD 出处（`cw_tuning.gd` 的字段 → `cw_data.gd` 的常量）。
    /// 单位：能量一律**十分位**（GD 也是），概率/比例是**百分数**，bool 照抄。
    /// 这一条红了只有两种可能：GD 改了规则（那 C# 要跟），或者这张表抄错了（那改表，别改 GD）。
    /// </summary>
    [Fact]
    public void 十二个旋钮的默认值逐个等于GD()
    {
        var t = RuleTuning.Default;

        // K1 · 有氧族（cw_tuning.gd: aerobic_by_level / aerobic_level_base / aerobic_split / aerobic_split_ref / necrosis_aerobic_pct）
        Assert.Equal(new[] { 20, 30, 45, 50 }, t.AerobicByLevel);   // CWData.AEROBIC_BY_LEVEL = 2.0 / 3.0 / 4.5 / 5.0
        Assert.Equal(20, t.AerobicLevelBase);                       // CWData.AEROBIC_LEVEL_BASE = 2.0
        Assert.Equal(15, t.AerobicLevelStep);                       // CWData.AEROBIC_LEVEL_STEP = 1.5（AerobicLevelBase 的配件，不在 12 个里）
        Assert.False(t.AerobicSplit);                               // 2026-09-05 方案 f：不均分
        Assert.Equal(SplitRef, t.AerobicSplitRef);                  // CWData.AEROBIC_SPLIT_REF = 2
        Assert.Equal(50, t.NecrosisAerobicPct);                     // CWData.NECROSIS_AEROBIC_PCT = 50（减半）

        // K2 · 流程 / 全局开关（这两个由 K2 接进规则，这里只钉默认值）
        Assert.False(t.AnaerobicOnTurnEnd);                         // Kevin 2026-09-06 改回 E 阶段结算
        Assert.Equal(2, t.CancerWinHoldRounds);                     // CWData.CANCER_WIN_HOLD_ROUNDS = 2

        // K3 · 战斗 / 技能（同上，由 K3 接）
        Assert.Equal(10, t.AttackDmgSuccess);                       // CWData.ATTACK_DMG_SUCCESS = 1.0
        Assert.True(t.AntibodyHalve);                               // 团队 2026-09-04 定案保留
        Assert.Equal(0, t.AntibodyMaxPerRound);                     // CWData.ANTIBODY_MAX_PER_ROUND = 0 = 不限
        Assert.Equal(20, t.OsteoOssifyCost);                        // CWData.OSTEO_OSSIFY_COST = 2.0
    }

    // ---- aerobic_by_level ----

    /// <summary>表档最优先：GD `_aerobic_base` 的第一条分支 `by_level[clampi(immune_level, 0, size-1)]`。</summary>
    [Theory]
    [InlineData(ImmuneLevel.I, 20)]
    [InlineData(ImmuneLevel.II, 30)]
    [InlineData(ImmuneLevel.III, 45)]
    [InlineData(ImmuneLevel.X, 50)]
    public void aerobic_by_level_默认表按等级查(ImmuneLevel level, int want) => Assert.Equal(want, Share(World(1, level)));

    /// <summary>拧表就跟着变；表比等级短时按 GD 的 `clampi` 取最后一档（balance_scan 会传一格的表）。</summary>
    [Fact]
    public void aerobic_by_level_拧一下_表短了按GD的clampi取最后一档()
    {
        Assert.Equal(77, Share(Tune(World(1, ImmuneLevel.II), t => t with { AerobicByLevel = new[] { 20, 77, 45, 50 } })));
        Assert.Equal(77, Share(Tune(World(1, ImmuneLevel.X), t => t with { AerobicByLevel = new[] { 77 } })));
    }

    // ---- aerobic_level_base（+ 配件 aerobic_level_step）----

    /// <summary>置空表退到线性档：GD `base + step × immune_level`（immune_level 0 起，所以 II 级是 ×1）。
    /// `abase=25 整体覆盖 → 2.5` 这条逐字来自 headless_test.gd:t_batch2_rules。</summary>
    [Fact]
    public void aerobic_level_base_置空表后走线性档()
    {
        var empty = Tune(World(1, ImmuneLevel.II), t => t with { AerobicByLevel = Array.Empty<int>() });
        Assert.Equal(20 + 15 * 1, Share(empty));                                       // 默认 base/step：II 级 3.5
        Assert.Equal(25 + 15 * 1, Share(Tune(empty, t => t with { AerobicLevelBase = 25 })));

        var levelOne = Tune(World(), t => t with { AerobicByLevel = Array.Empty<int>(), AerobicLevelBase = 25 });
        Assert.Equal(25, Share(levelOne));                                             // GD：abase=25 整体覆盖 → 2.5
    }

    /// <summary>GD 那两条对照档（`-1` 按人数分档、`0` 退回盘面式）**2026-09-19 已迁**
    /// （批 2 第二段 P1，COVERAGE 空档 aerobic-board-formula-not-migrated 就此收）——
    /// 此前这里钉的是「必须抛 NotSupportedException」，那笔登记到期了。
    ///
    /// 细账在 `K5Batch2RuleResultTests`；这里只留一条「不再抛、且给的是 GD 的数」的看门狗：
    /// 本类的 `World()` 只有 **1 个席位** ⇒ 按人数表里没有 1 人、退回 `CWData.AEROBIC_LEVEL_BASE` = 2.0（I 级 step ×0）；
    /// 盘面上只有 **1 格健康、0 格坏死** ⇒ 盘面式 `round_tenth(1 × 3.0, 127)` = 0。</summary>
    [Theory]
    [InlineData(-1, LevelIShare)]
    [InlineData(0, 0)]
    public void aerobic_level_base_的按人数档与盘面档已迁(int baseValue, int expected)
    {
        var s = Tune(World(), t => t with { AerobicByLevel = Array.Empty<int>(), AerobicLevelBase = baseValue });
        Assert.Equal(expected, Share(s));
    }

    // ---- aerobic_split / aerobic_split_ref ----

    /// <summary>GD `_split_aerobic`：n ≤ ref 每人全额；n &gt; ref 把 ref 份总额均分、四舍五入到十分位。
    /// 三个免疫那条期望逐字来自 headless_test.gd:t_batch2_rules 的 `(2 * B * ref + 3) / (2 * 3)`。</summary>
    [Fact]
    public void aerobic_split_与split_ref_按GD的_split_aerobic均分()
    {
        var three = Tune(World(3), t => t with { AerobicSplit = true });
        Assert.Equal((2 * LevelIShare * SplitRef + 3) / (2 * 3), Share(three));   // 2.0×2 ÷ 3 = 1.3
        Assert.Equal(13, Share(three));                                           // 同一个数写死一遍，防公式两边一起抄错

        Assert.Equal(LevelIShare, Share(Tune(World(2), t => t with { AerobicSplit = true })));   // n ≤ ref：全额
        Assert.Equal(LevelIShare, Share(Tune(World(1), t => t with { AerobicSplit = true })));

        var pure = Tune(three, t => t with { AerobicSplitRef = 0 });
        Assert.Equal((2 * LevelIShare + 3) / (2 * 3), Share(pure));                // asplitref=0：纯 2.0 ÷ 3 = 0.7

        Assert.Equal(LevelIShare, Share(World(3)));                               // 默认关（方案 f）：每人全额
    }

    /// <summary>分母是**存活**免疫细胞数（GD `living_cells(IMMUNE)`）：死一个，剩下两个就回到「n ≤ ref 全额」。</summary>
    [Fact]
    public void aerobic_split_只数活着的免疫细胞()
    {
        var s = Tune(World(3), t => t with { AerobicSplit = true });
        var dead = s.Cells.Values.Last();
        s = s.UpdateCell(dead.Id, dead.WithIsAlive(false));
        Assert.Equal(LevelIShare, Share(s));
    }

    // ---- necrosis_aerobic_pct ----

    /// <summary>GD `necrosis_cut` = `round_tenth(gain × pct, 100)`。三档期望逐字来自 headless_test.gd:t_batch2_rules ②。</summary>
    [Fact]
    public void necrosis_aerobic_pct_站在坏死格上打折()
    {
        var s = Necrotic(World());
        Assert.Equal(LevelIShare * 50 / 100, Share(s));                                  // 现行五折：2.0 → 1.0
        Assert.Equal(0, Share(Tune(s, t => t with { NecrosisAerobicPct = 0 })));          // necro=0：一份不给
        Assert.Equal(LevelIShare, Share(Tune(s, t => t with { NecrosisAerobicPct = 100 })));   // necro=100：坏死无影响
        Assert.Equal(LevelIShare, Share(World()));                                       // 不站在坏死格上：不打折
    }

    /// <summary>取整是**四舍五入到十分位**（PRD 通用规则 1），不是截断：III 级 4.5 打五折 = 2.3。
    /// 这一条同时钉住「换成旋钮之后与原先写死的 `RoundTenth(income × 0.5)` 逐位相同」。</summary>
    [Fact]
    public void necrosis_aerobic_pct_四舍五入到十分位()
    {
        Assert.Equal(23, Share(Necrotic(World(1, ImmuneLevel.III))));   // (45×50 + 50) / 100 = 23
        Assert.Equal(25, Share(Necrotic(World(1, ImmuneLevel.X))));     // (50×50 + 50) / 100 = 25
    }

    // ---- 旋钮真的接进了结算，不只是查询 ----

    /// <summary>S.5 那一步（`PhaseRules.Aerobic` = GD `CWWorld._aerobic`）读的就是同一份算式：
    /// 三个免疫、均分开着，每只到手 1.3；坏死格上的那只再打五折。</summary>
    [Fact]
    public void 有氧结算那一步真读旋钮()
    {
        var s = PhaseRules.Aerobic(Tune(World(3), t => t with { AerobicSplit = true }));
        Assert.All(s.Cells.Values, c => Assert.Equal(13, c.Energy));

        var necro = PhaseRules.Aerobic(Necrotic(Tune(World(3), t => t with { AerobicSplit = true })));
        Assert.Equal(7, necro.Cells.Values.First().Energy);            // (13×50 + 50) / 100 = 7
        Assert.Equal(13, necro.Cells.Values.Last().Energy);
    }
}
