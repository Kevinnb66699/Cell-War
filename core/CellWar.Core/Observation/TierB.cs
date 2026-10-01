namespace CellWar.Core.Observation;

/// <summary>
/// 观测协议 §5.2 的 **tier B 派生字段**（换内核 P2，2026-10-01）：批 0 时 C# 只定了字段位、全给 null，GD 生产者（`cw_obs_codec.gd`）一直在填。
/// 这里逐条照 GD 的算法补上，**每一条的出处都写在旁边**；对拍闸是 L1 的 `EnvelopeParityTests`（四条整局夹具逐步逐字段比，不再剥 tier B）。
///
/// 只读：全部是 WorldState 上的纯计算。要「预演一次伤害」的那条（压迫致死）直接在不可变世界上跑一遍真管线 ——
/// 结果丢掉，`Stage.Emit` 在作用域外是空操作，不会漏出演出。
/// </summary>
internal static class TierB
{
    // ---- 顶层（GD cw_obs_codec.gd `_global` 的 d 段）----

    public static ObsGlobalD Global(WorldState s, ObsGlobalD tierA)
    {
        var tiles = s.Board.Tissues.Values;
        var healthy = tiles.Count(t => t.State == TissueState.Healthy);
        var cancer = tiles.Count(t => t.State == TissueState.Cancer);
        var solid = tiles.Count(t => t.State == TissueState.SolidifiedCancer);
        // GD `CWData.level_min_memory(人数)`：门槛表按人数取，表里没有的人数退回缺省那张（与 CellRules.AddMemory 同一份）
        var thresholds = (CellRules.LevelMinMemoryByPlayers.TryGetValue(s.Players.Count, out var byPlayers) ? byPlayers : CellRules.LevelMinMemory).ToArray();
        var memory = s.FactionMemory(Faction.Immune);
        var next = thresholds.Where(th => th > memory).DefaultIfEmpty(-1).First();
        return tierA with
        {
            CountHealthy = healthy, CountCancer = cancer, CountSolid = solid,
            CountNecrosis = tiles.Count(t => t.NecrosisRounds > 0),   // GD count_necrosis：叠加项，不与前三个凑满整盘
            CancerWeighted = cancer + 2 * solid,                        // GD cw_game.gd:1118 同式
            LevelThresholds = thresholds,
            MemoryNextAt = next,
        };
    }

    // ---- 格子（GD `_board` 的 d 段）----

    /// <summary>GD `_prod_left`：特殊组织下次产出还差几回合。代谢核心只有健康时才按周期产（癌性每回合都产 ⇒ 0）。</summary>
    public static int ProdLeft(Tissue t) => t.Type switch
    {
        TissueType.MetabolicCore => t.State == TissueState.Healthy ? Math.Max(CoreHealthyPeriod - t.ProductionCounter, 0) : 0,
        TissueType.BoneMarrow => Math.Max(MarrowPeriod(t) - t.ProductionCounter, 0),
        _ => 0,
    };

    /// <summary>GD `_store_max`：代谢核心 2.0 能量 / 骨髓 1 张卡，别的格 0。</summary>
    public static int StoreMax(Tissue t) => t.Type switch
    {
        TissueType.MetabolicCore => RulePolicies.MetabolicCoreStoreMax,
        TissueType.BoneMarrow => RulePolicies.BoneMarrowStoreMax,
        _ => 0,
    };

    /// <summary>GD `CWData.store_pending`：骨髓「进度到头、卡还没结算」（界面只淡图标、不动进度环）。</summary>
    public static bool StorePending(Tissue t)
        => t.Type == TissueType.BoneMarrow && (t.Charge ?? 0) < RulePolicies.BoneMarrowStoreMax && t.ProductionCounter >= MarrowPeriod(t);

    /// <summary>GD `CWData.CORE_HEALTHY_PERIOD` / `MARROW_HEALTHY_PERIOD` / `MARROW_CANCER_PERIOD`（与 RulePolicies.StoreFraction 写死的 3 / 2 同一组数）。</summary>
    private const int CoreHealthyPeriod = 2, MarrowHealthyPeriod = 3, MarrowCancerPeriod = 2;
    private static int MarrowPeriod(Tissue t) => t.State == TissueState.Healthy ? MarrowHealthyPeriod : MarrowCancerPeriod;

    // ---- 细胞（GD `_cell_d`）----

    public static ObsCellD Cell(WorldState s, Cell c, ObsCellD tierA)
    {
        var alive = c.IsAlive;
        var isB = c.Type == CellType.BCell;
        return tierA with
        {
            ActionKinds = alive ? ActionKinds(s, c) : [],
            StatusRows = alive ? StatusRows(s, c) : [],
            PressureLethal = alive && PressureLethal(s, c),
            Neutralized = RulePolicies.Neutralized(s, c),
            TypeAbilityOn = RulePolicies.TypeAbilityOn(s, c),
            AntibodyCost = isB ? AntibodyCost(s, c) : 0,
            // GD `skill_move_cost(cell, base)` = 费用管线 SKILL_MOVE 档的报价。C# 技能迁移结算时按原价扣（SkillRules 59 / 65），这里同口径；
            // 若 GD 管线在 SKILL_MOVE 上挂了修饰而 C# 没有，L1 envelope 对拍会在这一格红 —— 那是规则差，要合，不是这里的事
            MetastasisCostReal = c.Type == CellType.SmallCellLung ? s.Tuning.MetastasisCost : 0,
            OssifyCostReal = c.Type == CellType.Osteosarcoma ? s.Tuning.OsteoOssifyCost : 0,
            HomingCostReal = c.Type == CellType.Melanoma ? SkillRules.MelanomaHomingCost : 0,
            AttackCapLeft = Math.Max(s.Tuning.AttackMaxPerTurn - c.AttacksThisTurn, 0),   // GD 原式：旋钮 0（不限）时这里也是 0，照抄
            DrawCapLeft = Math.Max(CardRules.DrawMaxPerTurn - c.DrawsThisTurn, 0),
        };
    }

    /// <summary>GD `cw_actions.gd action_kinds`：行动栏按钮集合，**顺序即按钮顺序**；只看种类与等级、不看此刻付不付得起（行动栏宽度不跳）。</summary>
    public static string[] ActionKinds(WorldState s, Cell c)
    {
        var out_ = new List<string> { "move", "draw" };
        if (c.Faction == Faction.Immune)
        {
            var level = s.FactionImmuneLevel(Faction.Immune);
            // 分化挂 III 级（GD `tune.differentiate_min_level` 缺省 2 = III；C# 没有这个旋钮，PlacementRules.ValidateDifferentiate 写死 III）
            if (level >= ImmuneLevel.III && !c.Differentiated) out_.Add("differentiate");
            switch (c.Type)
            {
                case CellType.BCell: out_.Add("antibody"); break;
                case CellType.TCell: out_.Add("toxin"); out_.Add("lyse"); break;
                case CellType.Dendritic: out_.Add("chemo"); break;
            }
            if (c.Type != CellType.ImmuneBasic && level >= ImmuneLevel.X) out_.Add("effector");
        }
        else
        {
            out_.Add("mutate");
            switch (c.Type)
            {
                case CellType.Melanoma: out_.Add("homing"); break;
                case CellType.SignetRing: out_.Add("mucus"); break;
                case CellType.SmallCellLung: out_.Add("jump"); break;
                case CellType.Osteosarcoma: out_.Add("ossify"); break;
            }
        }
        return out_.ToArray();
    }

    /// <summary>GD `cw_damage.gd status_rows`：悬浮详情里的受击状态 `[{kind: 易伤/减伤, name, detail}]`，顺序照 GD。</summary>
    public static ObsStatusRow[] StatusRows(WorldState s, Cell c)
    {
        var rows = new List<ObsStatusRow>();
        if (c.Marked)
            rows.Add(new("易伤", "标记", $"下次能量损失 ×2（剩 {c.MarkLeft} 次）"));
        if (c.Faction == Faction.Cancer && WorldEffects.Stacks(s, "抗原丢失") > 0)   // 世界事件删了之后恒不成立（GD 那句也还留着），照抄
            rows.Add(new("减伤", "抗原丢失", "本回合免疫普通攻击无效"));
        var pdl1 = c.Modifiers.Count(m => m.Card == "PD-L1表达");
        if (pdl1 > 0)
            rows.Add(new("减伤", "PD-L1表达", "下次普通攻击判定降级" + (pdl1 > 1 ? $"（×{pdl1}）" : "")));
        if (c.Type == CellType.Osteosarcoma && RulePolicies.TypeAbilityOn(s, c) && s.Board.Tissues[c.Position].State == TissueState.SolidifiedCancer)
            rows.Add(new("减伤", "刚性屏障", $"所有能量损失降至 {OsteoBarrierPercent}%"));
        if (c.Faction == Faction.Cancer && c.Type == CellType.SignetRing && !c.ArmorUsedThisRound && RulePolicies.TypeAbilityOn(s, c))
            rows.Add(new("减伤", "囊性护甲", $"本世界回合首次损失 -{Stage.Fmt(CellRules.ArmorReduction)}"));
        foreach (var (card, what) in ShieldRows)
        {
            var n = c.Modifiers.Count(m => m.Card == card);
            if (n == 0) continue;
            rows.Add(new("减伤", card, $"{what} -{Stage.Fmt(CellRules.ShieldValue(s, card) * n)}"));
        }
        if (RulePolicies.HasSkill(s, c, "耗竭抵抗"))
        {
            var parts = new List<string>();
            if (CellRules.RoundGateOpen(c, "耗竭抵抗")) parts.Add($"本世界回合首次损失 -{Stage.Fmt(CellRules.ExhaustFirstCut)}");
            parts.Add($"微环境压迫额外 -{Stage.Fmt(CellRules.ExhaustPressureCut)}");
            rows.Add(new("减伤", "耗竭抵抗", string.Join("；", parts)));
        }
        return rows.ToArray();
    }

    /// <summary>GD 那张四行表（cw_damage.gd status_rows 的 for 循环）：卡名 → 文案前半句。</summary>
    private static readonly (string Card, string What)[] ShieldRows =
    [
        ("细胞膜修复", "下一次任意能量损失"), ("I型干扰素", "下一次任意能量损失"),
        ("缺氧适应", "下一次癌细胞技能或微环境压迫"), ("DNA损伤修复", "下一次免疫事件或技能"),
    ];

    /// <summary>GD `CWData.OSTEO_BARRIER_PERCENT`（CellRules.Damage 里同一个 40 写在倍率上）。</summary>
    private const int OsteoBarrierPercent = 40;

    /// <summary>
    /// GD `cw_world.gd pressure_lethal`：这一格的【微环境压迫】过完减免管线会不会打死它（只看免疫细胞）。
    /// GD 用 `damage.preview_amount`；C# 没有单独的预览函数，就在不可变世界上跑一遍真管线（与 BoardRules.Pressure 同一个调用），看实扣够不够。
    /// </summary>
    public static bool PressureLethal(WorldState s, Cell c)
    {
        if (!c.IsAlive || c.Faction != Faction.Immune) return false;
        var raw = RulePolicies.PressureAt(s, c.Position);
        if (raw <= 0) return false;
        CellRules.Damage(s, c.Id, raw, LossSource.World, "微环境压迫", 0, out var dealt);
        return dealt >= c.Energy;
    }

    /// <summary>GD `cw_actions.gd antibody_cost`：1.0，装了【抗体亲和力成熟】降 0.5（下限 0）。</summary>
    public static int AntibodyCost(WorldState s, Cell c)
        => RulePolicies.HasSkill(s, c, "抗体亲和力成熟") ? Math.Max(AntibodyBaseCost - MaturedAntibodyCut, 0) : AntibodyBaseCost;

    /// <summary>GD `CWData.ANTIBODY_COST` / `MATURED_ANTIBODY_CUT`（C# 观测编码器的价签那里写的 10 / 5 是同一组数）。</summary>
    private const int AntibodyBaseCost = 10, MaturedAntibodyCut = 5;
}
