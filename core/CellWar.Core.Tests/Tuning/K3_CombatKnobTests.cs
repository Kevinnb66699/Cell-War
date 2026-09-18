using CellWar.Core;
using CellWar.Core.Observation;

namespace CellWar.Core.Tests.Tuning;

/// <summary>
/// K3 · 战斗 / 技能四个旋钮进内核：`attack_dmg_success` / `antibody_halve` /
/// `antibody_max_per_round` / `osteo_ossify_cost`。
///
/// 每条都是**两截**：先钉「默认值 = GD 今天的值」（这是零行为改动的判据），
/// 再把旋钮拧到非默认值、按 GD 公式核结果。只钉默认值挡不住「读了旋钮但算错」，
/// 只拧不钉挡不住「默认值被顺手改掉」—— 2026-09-15 那批「1.0 写成 0.1」正是后一种形状。
///
/// 期望值逐条移植自 `game/tests/headless_test.gd`，每条上面注了 `source`。
/// </summary>
public class K3CombatKnobTests
{
    private static readonly BasicRulesEngine Engine = new();
    private static readonly EntityId Immune0 = new(1);   // 席位 0：免疫，(-4,0)，3.0
    private static readonly EntityId Cancer1 = new(2);   // 席位 1：黑色素瘤，(-1,0)，6.0

    private static HexPosition P(int q, int r) => new(q, r, -q - r);

    // ---- 四个旋钮的默认值钉子 ----

    /// <summary>
    /// source: `cw_tuning.gd:131/243/315/320` + `cw_data.gd:305/366/377`
    /// —— 默认值必须逐个等于 GD 今天的值，否则「零行为改动」这句话就是空的。
    /// </summary>
    [Fact]
    public void 四个旋钮的默认值等于GD今天的值()
    {
        var d = RuleTuning.Default;
        Assert.Equal(10, d.AttackDmgSuccess);      // CWData.ATTACK_DMG_SUCCESS := 10（1.0 能量）
        Assert.True(d.AntibodyHalve);              // cw_tuning.gd `var antibody_halve := true`
        Assert.Equal(0, d.AntibodyMaxPerRound);    // CWData.ANTIBODY_MAX_PER_ROUND := 0（0 = 不限，现行 PRD）
        Assert.Equal(20, d.OsteoOssifyCost);       // CWData.OSTEO_OSSIFY_COST := 20（2.0 能量）
    }

    // ---- ① attack_dmg_success ----

    /// <summary>
    /// source: `headless_test.gd:13923/14316/14395` 那一串 `check(… == … - g.tune.attack_dmg_success …)`
    /// —— GD 侧所有「攻击成功扣多少」的期望都写成旋钮而不是字面量，C# 这一处也得跟着旋钮走。
    /// 大成功那一档在 GD 是另一个旋钮（`attack_dmg_crit`），不在这 12 个里，仍是字面量 20：这里一并钉住它**不**跟着动。
    /// </summary>
    [Fact]
    public void 攻击成功的伤害跟着旋钮走_大成功那一档不动()
    {
        var s = World();
        var before = s.Cells[Cancer1].Energy;

        var successSeed = SeedWhere(s, after => before - after.Cells[Cancer1].Energy == 10);
        var critSeed = SeedWhere(s, after => before - after.Cells[Cancer1].Energy == 20);

        // 同一颗种子、同一串抽取：变的只有旋钮
        var loud = s.WithTuning(s.Tuning with { AttackDmgSuccess = 25 });
        Assert.Equal(before - 25, Attack(loud, successSeed).Cells[Cancer1].Energy);
        Assert.Equal(before - 20, Attack(loud, critSeed).Cells[Cancer1].Energy);

        var quiet = s.WithTuning(s.Tuning with { AttackDmgSuccess = 0 });
        Assert.Equal(before, Attack(quiet, successSeed).Cells[Cancer1].Energy);
    }

    // ---- ② antibody_halve ----

    /// <summary>
    /// source: `headless_test.gd:t_antibody_halve` —— 期望表 `[15, 7, 3, 1, 0]` 逐字照抄
    /// （整数除法向下取整，所以自然衰减到 0 而不是永远留个尾巴），
    /// 以及「旋钮关掉 = 老行为，放几次都打满」。
    /// </summary>
    [Fact]
    public void 抗体伤害逐次减半_旋钮关掉就每次都打满()
    {
        var d = RuleTuning.Default;
        var want = new[] { 15, 7, 3, 1, 0 };
        for (var used = 0; used < want.Length; used++)
            Assert.Equal(want[used], RulePolicies.AntibodyDamage(d, used));

        var off = d with { AntibodyHalve = false };
        for (var used = 0; used < want.Length; used++)
            Assert.Equal(15, RulePolicies.AntibodyDamage(off, used));

        // 【抗体亲和力成熟】只抬基数（2.0），减半照旧走同一个旋钮
        Assert.Equal(20, RulePolicies.AntibodyDamage(d, 0, matured: true));
        Assert.Equal(10, RulePolicies.AntibodyDamage(d, 1, matured: true));
        Assert.Equal(20, RulePolicies.AntibodyDamage(off, 1, matured: true));
    }

    /// <summary>
    /// source: 同上那条 check 的后半截「第 N 发实扣 …」—— 判据（`antibody_damage`）与实扣必须是同一个数，
    /// 所以再走一遍真结算：默认 15 → 7，旋钮关掉 15 → 15。
    /// </summary>
    [Fact]
    public void 抗体实扣跟着减半旋钮走()
    {
        var s = BCellWorld();
        var before = s.Cells[Cancer1].Energy;

        var twice = Antibody(Antibody(s));
        Assert.Equal(before - 15 - 7, twice.Cells[Cancer1].Energy);
        Assert.Equal(2, twice.Cells[Immune0].AntibodyThisRound);

        var off = Antibody(Antibody(s.WithTuning(s.Tuning with { AntibodyHalve = false })));
        Assert.Equal(before - 15 - 15, off.Cells[Cancer1].Energy);
    }

    // ---- ③ antibody_max_per_round ----

    /// <summary>
    /// source: `headless_test.gd:t_antibody_cap` —— 默认 0 = 不限（打了 3 发选项仍在）；
    /// 拧到 2 之后「本回合已用 3 → 选项消失」「重置 → 选项回来」「第 3 发不给选」。
    /// 走 `DecisionRouter.Available`（= GD 的 `build_options`）而不是只走 Validate：
    /// GD 那条 check 看的就是选项在不在。
    /// </summary>
    [Fact]
    public void 抗体次数上限旋钮_默认不限_拧上就收选项()
    {
        var s = BCellOnBoard();
        Assert.Equal(0, s.Tuning.AntibodyMaxPerRound);

        for (var k = 0; k < 3; k++)
        {
            Assert.True(HasAntibodyOption(s), $"默认：第 {k + 1} 发前选项在");
            s = Antibody(s);
        }
        Assert.Equal(3, s.Cells[Immune0].AntibodyThisRound);
        Assert.True(HasAntibodyOption(s), "默认：打了 3 发选项仍在");

        var capped = s.WithTuning(s.Tuning with { AntibodyMaxPerRound = 2 });
        Assert.False(HasAntibodyOption(capped), "上限 2：本回合已用 3 → 选项消失");

        // S 阶段重置（CWWorld._reset_round_flags 把 antibody_used 清零）→ 选项回来
        var reset = capped.UpdateCell(Immune0, capped.Cells[Immune0].Copy(antibody: 0));
        Assert.True(HasAntibodyOption(reset));
        reset = Antibody(Antibody(reset));
        Assert.False(HasAntibodyOption(reset), "上限 2：第 3 发不给选");

        // 闸门与执行是同一个：选项没了，硬发也得被驳回
        Assert.False(Engine.ValidateDecision(reset, new TypeSkillDecision(0, Immune0, "抗体")).IsValid);
    }

    // ---- ④ osteo_ossify_cost ----

    /// <summary>
    /// source: `headless_test.gd:t_ossify_cost_and_pin`（价签「改旋钮价签跟着变，没写死」，那条用的就是 35）
    /// —— 判据、实扣、价签三处读同一个旋钮。
    /// </summary>
    [Fact]
    public void 骨样硬化的费用跟着旋钮走()
    {
        var s = OsteoWorld(energy: 100);
        var decision = new TypeSkillDecision(1, Cancer1, "骨样硬化");

        Assert.Equal(100 - 20, Engine.ExecuteDecision(s, decision, Rng(1)).NewState.Cells[Cancer1].Energy);

        var pricey = s.WithTuning(s.Tuning with { OsteoOssifyCost = 35 });
        Assert.Equal(100 - 35, Engine.ExecuteDecision(pricey, decision, Rng(1)).NewState.Cells[Cancer1].Energy);

        // 判据与实扣是同一个数：默认 2.0 时 3.0 能量付得起，涨到 3.5 就付不起了
        // （`Settlement.CanPay` 是严格大于：非自毁技能不许把自己花到 0，所以 4.0 才付得起 3.5）
        Assert.True(Engine.ValidateDecision(Poor(s, 30), decision).IsValid);
        Assert.False(Engine.ValidateDecision(Poor(pricey, 30), decision).IsValid);
        Assert.True(Engine.ValidateDecision(Poor(pricey, 40), decision).IsValid);

        // 选项价签读的也得是旋钮，不是编码器里那份写死的 20（GD 侧 t_ossify_cost_and_pin 专门钉过「没写死」）
        Assert.Equal("骨样硬化（2.0 能量）", OssifyLabel(s));
        Assert.Equal("骨样硬化（3.5 能量）", OssifyLabel(pricey));
    }

    private static string OssifyLabel(WorldState s)
    {
        var image = new WorldImage(s) { Simulation = new SimulationState { Input = new PendingInput(1, 1, [new TypeSkillDecision(1, Cancer1, "骨样硬化")]) } };
        return ObservationV1Codec.Encode(image, new Revision(1)).Ask!.Options[0].Label;
    }

    // ---- 夹具 ----

    private static Xoshiro256StarStar Rng(int seed) => new((ulong)seed);

    /// <summary>DemoScenario + 玩家回合，癌细胞挪到免疫细胞隔壁（照搬 `AttackAndLandTests.World`）。</summary>
    private static WorldState World()
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 0, startStep: 2));
        var c = s.Cells[Cancer1];
        return s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(P(-3, 0), Cancer1).UpdateCell(Cancer1, c.Copy(position: P(-3, 0)));
    }

    private static WorldState Attack(WorldState s, int seed)
    {
        var r = CellRules.Move(s, new MoveDecision(0, Immune0, P(-3, 0)), Rng(seed));
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    private static int SeedWhere(WorldState s, Func<WorldState, bool> want)
    {
        for (var seed = 1; seed <= 300; seed++)
            if (want(Attack(s, seed))) return seed;
        throw new Xunit.Sdk.XunitException("300 颗种子里没有一次攻击满足条件");
    }

    /// <summary>一只 B 细胞，隔壁一格癌组织上站着黑色素瘤（脚下是健康格 ⇒【抗体】找得到目标）。</summary>
    private static WorldState BCellWorld()
    {
        var at = P(0, 0);
        var foe = P(1, 0);
        return new WorldState
        {
            Board = new Board
            {
                Radius = 6,
                Tissues = new Dictionary<HexPosition, Tissue>
                {
                    [at] = Tile(at, TissueState.Healthy, Immune0),
                    [foe] = Tile(foe, TissueState.Cancer, Cancer1),
                }
            },
            Cells = new Dictionary<EntityId, Cell>
            {
                [Immune0] = new()
                {
                    Id = Immune0, OwnerSeat = 0, Faction = Faction.Immune, Type = CellType.BCell,
                    Position = at, Energy = 5000, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
                    Hand = [], Equipped = [], Differentiated = true,
                },
                [Cancer1] = new()
                {
                    Id = Cancer1, OwnerSeat = 1, Faction = Faction.Cancer, Type = CellType.Melanoma,
                    Position = foe, Energy = 5000, IsAlive = true, StatusEffects = Array.Empty<StatusEffect>(),
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

    /// <summary>整张 DemoScenario 棋盘上的 B 细胞：选项表要在真棋盘上枚举才算数。</summary>
    private static WorldState BCellOnBoard()
    {
        var s = World();
        return s.UpdateCell(Immune0, s.Cells[Immune0].Copy(type: CellType.BCell, energy: 5000, differentiated: true));
    }

    private static WorldState Antibody(WorldState s)
    {
        var r = Engine.ExecuteDecision(s, new TypeSkillDecision(0, Immune0, "抗体"), Rng(7));
        Assert.True(r.Success, r.ErrorMessage);
        return r.NewState;
    }

    private static bool HasAntibodyOption(WorldState s)
        => DecisionRouter.Available(s, 0).Any(d => d is TypeSkillDecision { Skill: "抗体" });

    /// <summary>骨肉瘤站在自己脚下的普通癌组织上（席位 1 的回合）。</summary>
    private static WorldState OsteoWorld(int energy)
    {
        var s = DemoScenario.Create();
        s = s.WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 1, startStep: 2));
        var c = s.Cells[Cancer1];
        return s.UpdateCell(Cancer1, c.Copy(type: CellType.Osteosarcoma, energy: energy));
    }

    private static WorldState Poor(WorldState s, int energy) => s.UpdateCell(Cancer1, s.Cells[Cancer1].Copy(energy: energy));

    private static Tissue Tile(HexPosition p, TissueState st, EntityId? occ) =>
        new() { Position = p, Type = TissueType.Normal, State = st, SolidificationCount = 0, OccupyingCell = occ, Charge = 0 };
}
