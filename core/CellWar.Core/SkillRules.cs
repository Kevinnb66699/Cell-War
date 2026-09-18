using System.Collections.Immutable;
﻿using static CellWar.Core.CellRules;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 细胞种类主动技能与效应应答所有权域（对应三层设计的 SkillRules）：
/// 免疫 B/T/巨噬/树突 与 四种癌细胞的主动技能、X 级效应应答的验证与结算。
/// 决策合法性（阶段/回合/存活等公共前提）由编排层先行校验，本域只校验技能自身前提。
/// </summary>
internal static class SkillRules
{
    public static ValidationResult Validate(WorldState s, TypeSkillDecision d)
    {
        if (s.Turn.Phase != Phase.PlayerAction) return new(false, "当前阶段不允许玩家操作");
        if (d.PlayerSeat != s.Turn.ActivePlayerSeat) return new(false, "不是该玩家的回合");
        if (!s.Players.TryGetValue(d.PlayerSeat, out var player) || !player.IsAlive) return new(false, "玩家已死亡或不存在");
        if (!s.Cells.TryGetValue(d.CellId, out var cell) || !cell.IsAlive || cell.OwnerSeat != d.PlayerSeat) return new(false, "细胞不存在或不可控制");
        switch (d.Skill)
        {
            case "抗体":
                if (cell.Type != CellType.BCell) return new(false, "只有 B 细胞可以发动【抗体】");
                // 【抗体亲和力成熟】把费用降 0.5；**判据必须和实扣是同一个数**
                // —— 判与扣对不上正是【趋化源】那条 bug 的形状。
                return Settlement.CanPay(cell.Energy, RulePolicies.HasSkill(s, cell, "抗体亲和力成熟") ? 5 : 10)
                    ? new(true) : new(false, "能量不足");
            case "细胞毒素":
                if (cell.Type != CellType.TCell) return new(false, "只有 T 细胞可以发动【细胞毒素】");
                if (cell.ToxinThisRound >= 3) return new(false, "每个世界回合最多发动 3 次");
                // GD `_can_toxin` / `_toxin_targets`（cw_actions.gd:1294-1306）：**脚下那一格**本世界回合发动过就不能再发（站着不动刷不出来）；1 环内没有普通癌组织就不出选项
                if (s.Board.Tissues[cell.Position].ToxinRound == s.Turn.WorldRound) return new(false, "这一格本世界回合已发动过【细胞毒素】");
                if (ToxinTargets(s, cell).Count == 0) return new(false, "1 环内没有可转化的癌组织");
                return Settlement.CanPay(cell.Energy, 10) ? new(true) : new(false, "能量不足");
            case "裂解":
                if (cell.Type != CellType.TCell) return new(false, "只有 T 细胞可以发动【裂解】");
                if (d.Target is not { } lyse || lyse.DistanceTo(cell.Position) > 1 || !s.Board.Tissues.TryGetValue(lyse, out var lt) || lt.State != TissueState.SolidifiedCancer)
                    return new(false, "必须选择相邻的固化癌组织");
                return Settlement.CanPay(cell.Energy, 10) ? new(true) : new(false, "能量不足");
            case "黏液破裂":
                if (cell.Type != CellType.SignetRing) return new(false, "只有印戒细胞癌可以发动【黏液破裂】");
                return cell.Energy >= 20 ? new(true) : new(false, "至少需要 2 能量");   // 十分位；PRD:519「至少2点」，对齐 CWData.MUCUS_MIN_ENERGY := 20
            case "骨样硬化":
                if (cell.Type != CellType.Osteosarcoma) return new(false, "只有骨肉瘤可以发动【骨样硬化】");
                if (!s.Board.Tissues.TryGetValue(cell.Position, out var own) || own.State != TissueState.Cancer) return new(false, "脚下不是癌组织");
                // GD `_can_ossify` 还有两条：已经标过（ossify_at != 0）不能再标、血管永不可固化（标都不让标，Kevin 2026-09-06）——
                // 缺了它们 C# 会多出一条 GD 没有的选项（L1 2p 第 47 步）
                if (own.OssifyAtRound != 0) return new(false, "脚下的癌组织已经标记过【骨样硬化】");
                if (own.Type == TissueType.BloodVessel) return new(false, "血管不可固化");
                return Settlement.CanPay(cell.Energy, 20) ? new(true) : new(false, "能量不足");
            case "早期血行转移":
                if (cell.Type != CellType.Melanoma) return new(false, "只有恶性黑色素瘤可以发动【早期血行转移】");
                if (cell.MetastasisUsedThisRound) return new(false, "每世界回合限发动 1 次");
                if (!s.Board.Tissues.TryGetValue(cell.Position, out var vessel) || vessel.Type != TissueType.BloodVessel) return new(false, "自身必须处于血管格");
                if (d.Target is not { } homing || !s.Board.Tissues.TryGetValue(homing, out var ht) || ht.State != TissueState.Healthy || ht.OccupyingCell != null)
                    return new(false, "必须选择无细胞占据的健康组织");
                return Settlement.CanPay(cell.Energy, MelanomaHomingCost) ? new(true) : new(false, "能量不足");
            case "转移":
                if (cell.Type != CellType.SmallCellLung) return new(false, "只有小细胞肺癌可以发动【转移】");
                if (!JumpQuotaLeft(s, cell)) return new(false, "本世界回合【转移】次数已用完");
                if (d.Target is not { } jump || !JumpTargets(s, cell).Contains(jump))
                    return new(false, "终点必须是沿某个方向直线跃进 5 格、地图内、无细胞占据的格");
                return Settlement.CanPay(cell.Energy, s.Tuning.MetastasisCost) ? new(true) : new(false, "能量不足");
            case "免疫猎杀":
                return ValidateEffector(s, cell, CellType.Dendritic);
            case "连续吞噬":
                return ValidateEffector(s, cell, CellType.Macrophage);
            case "中和抗体":
                return ValidateEffector(s, cell, CellType.BCell);
            case "Excalibur":
                return ValidateEffector(s, cell, CellType.TCell);
            case "趋化源":
                if (cell.Type != CellType.Dendritic) return new(false, "只有树突状细胞可以建立【趋化源】");
                if (s.Turn.ChemoRounds > 0) return new(false, "场上已有趋化源");
                // 冷却记在**这只细胞**身上（PRD「趋化源消失后，技能冷却 1 世界回合才能再次使用」）——
                // 换个树突去立是另一个细胞的技能，所以不是全局锁
                if (cell.ChemoCooldown > 0) return new(false, $"【趋化源】冷却中，还剩 {cell.ChemoCooldown} 个世界回合");
                if (d.Target is not { } chemo || !s.Board.Tissues.ContainsKey(chemo)) return new(false, "必须选择棋盘内任意格");
                return Settlement.CanPay(cell.Energy, 30) ? new(true) : new(false, "能量不足");   // 【趋化源】3.0（PRD:561）；原来判 20 与实扣不一致
            default:
                return new(false, "未知的种类技能");
        }
    }

    /// <summary>
    /// 【抗体】无目标时转化几格：按免疫等级（I/II/III/X）分档的 [2/3 概率的数, 1/3 概率的数]
    /// （GD `ANTIBODY_NO_TARGET_X`）。前两行是**兜底**（I/II 级根本没有 B 细胞，放不出【抗体】）。
    /// </summary>
    internal static readonly IReadOnlyList<IReadOnlyList<int>> AntibodyNoTargetX =
        [[2, 3], [2, 3], [3, 5], [4, 6]];

    /// <summary>GD `_excalibur_sweep(cells_at, dmg)`：扫一串格子 —— 癌组织转健康 + 坏死（固化癌组织不转），再打上面的癌细胞。</summary>
    private static WorldState ExcaliburSweep(WorldState s, IReadOnlyList<HexPosition> tiles, int damage)
    {
        foreach (var pos in tiles)
            if (s.Board.Tissues[pos].State == TissueState.Cancer)
            {
                s = CardRules.ToHealthy(s, pos);   // GD `to_healthy` 再 `necrosis = NECROSIS_TOXIN`
                s = s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithNecrosis(2)));
            }
        foreach (var target in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Cancer && tiles.Contains(x.Position)).ToArray())
            s = Damage(s, target.Id, damage, LossSource.CancerSkill);   // 主射线 2.0 / 侧向 1.0（原 2 / 1 = 0.2 / 0.1）
        return s;
    }

    /// <summary>T【Excalibur】主射线相邻的癌组织进入波及范围的概率（GD `EXCALIBUR_SPLASH_PCT`）。</summary>
    internal const int ExcaliburSplashPercent = 60;

    /// <summary>【免疫猎杀】附着的【追踪趋化源】持续几个世界回合（GD `HUNT_CHEMO_ROUNDS`）。</summary>
    internal const int HuntChemoRounds = 2;

    /// <summary>
    /// 树突【I-趋化源】持续几个**完整回合**（GD `CHEMO_FULL_TURNS`；PRD「效果持续 1 完整回合」）。
    /// 2026-09-19 之前这里写死 2（旧 PRD「2 世界回合」的残留）—— 三条 L1 夹具里从没人建过源，
    /// 直到专门录的树突建源局 `trace_4p_chemo_4242` 在第 237 步把它揪出来。
    /// </summary>
    internal const int ChemoFullTurns = 1;

    /// <summary>GD `_toxin_targets`：脚下 + 六邻（`CWData.ring(pos, 1)`，Q↑R↑ 排序）里的**普通**癌组织。</summary>
    internal static IReadOnlyList<HexPosition> ToxinTargets(WorldState s, Cell cell)
        => Tiles(s).Where(t => t.Position.DistanceTo(cell.Position) <= 1 && t.State == TissueState.Cancer).Select(t => t.Position).ToList();

    /// <summary>
    /// 【早期血行转移】的费用（GD `CWData.MELANOMA_HOMING_COST`）。
    /// **它是常量不是旋钮** —— 与【转移】不同，GD 那边 `_cell_skill_base("homing")` 直接读常量，
    /// 只有 `"jump"` 走 `game.tune.metastasis_cost`。两者今天同为 1.0，别顺手合并成一个。
    /// </summary>
    internal const int MelanomaHomingCost = 10;

    /// <summary>【转移】落点：GD `_jump_targets` —— **朝六个方向各直线跃进 5 格**（`pos + d * METASTASIS_RANGE`），落在板内且无细胞占据。
    /// 此前 C# 给的是「所有距离 == 5 的空格」（5 环有 30 格），选项表比 GD 多出一圈（L1 6p 第 39 步，2026-09-17）。</summary>
    internal static IReadOnlyList<HexPosition> JumpTargets(WorldState s, Cell cell)
    {
        var targets = new List<HexPosition>();
        foreach (var (dq, dr) in JumpDirs)
        {
            var q = cell.Position.Q + dq * MetastasisRange;
            var r = cell.Position.R + dr * MetastasisRange;
            var p = new HexPosition(q, r, -q - r);
            if (s.Board.Tissues.TryGetValue(p, out var t) && t.OccupyingCell == null) targets.Add(p);
        }
        return targets;
    }

    private const int MetastasisRange = 5;   // CWData.METASTASIS_RANGE
    private static readonly (int Dq, int Dr)[] JumpDirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];   // CWData.DIRS

    /// <summary>GD `_jump_quota_left`：旋钮 `metastasis_max_per_round`，0 = 不限。</summary>
    internal static bool JumpQuotaLeft(WorldState s, Cell cell)
        => s.Tuning.MetastasisMaxPerRound <= 0 || cell.JumpUsedThisRound < s.Tuning.MetastasisMaxPerRound;

    private static ValidationResult ValidateEffector(WorldState s, Cell cell, CellType required)
    {
        if (cell.Type != required) return new(false, "该【效应应答】不属于此细胞种类");
        if (s.Players[cell.OwnerSeat].ImmuneLevel < ImmuneLevel.X) return new(false, "免疫等级未达 X 级");
        if (!cell.Differentiated) return new(false, "未分化的免疫细胞不能发动【效应应答】");
        if (cell.EffectorUsed) return new(false, "每个细胞每局只能发动 1 次【效应应答】");
        if (s.Turn.EffectorRound == s.Turn.WorldRound) return new(false, "免疫方每个世界回合只能发动 1 次【效应应答】");
        if (s.Players[cell.OwnerSeat].AntigenMemory < 20) return new(false, "效应记忆不足 20");
        return new(true);
    }

    private static WorldState ConsumeEffector(WorldState s, Cell cell)
    {
        s = s.UpdatePlayer(cell.OwnerSeat, s.Players[cell.OwnerSeat].WithAntigenMemory(Math.Max(0, s.Players[cell.OwnerSeat].AntigenMemory - 20)));
        s = s.UpdateCell(cell.Id, s.Cells[cell.Id].Copy(effectorUsed: true));
        return s.WithTurn(s.Turn.Copy(effectorRound: s.Turn.WorldRound));
    }

    public static RulesResult Execute(WorldState s, TypeSkillDecision d, IDeterministicRng rng)
    {
        var cell = s.Cells[d.CellId];
        switch (d.Skill)
        {
            case "抗体":
            {
                // 【抗体亲和力成熟】2026-09-15 补齐：此前 C# 只实现了三条中的一条
                // （攻击邻健康癌细胞 +0.5，在 CellRules）。另外两条按 PRD:1325 与 GDScript 补上：
                //   · 抗体**费用降低 0.5**（`cw_actions.gd:1230-1235`；卡面 09-07 由「降低为 0.5」
                //     改成「降低 0.5」—— 基础费 1.0 时两种读法同值，但基础费一变，减量才是卡面说的那件事）
                //   · 抗体的**初始伤害改为 2.0**（`cw_data.gd:501`，09-07 卡面 1.5 → 2）
                var matured = RulePolicies.HasSkill(s, cell, "抗体亲和力成熟");
                var cost = Math.Max(0, 10 - (matured ? 5 : 0));
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - cost, antibody: cell.AntibodyThisRound + 1));
                var damage = AntibodyDamage(cell.AntibodyThisRound, matured);
                var targets = Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Cancer && AdjacentHealthy(s, x.Position)).ToArray();
                // GD cw_actions.gd:1250-1259：有目标就打（伤害减到 0 也照走这一支、不去转化组织）；此前 C# 多了 `damage > 0` 才打，用满次数后会改去转化
                if (targets.Length > 0)
                {
                    Stage.Emit(Stage.Fx(s, "antibody", ("from", cell.Position), ("targets", targets.Select(x => x.Position).ToArray())));
                    foreach (var target in targets) s = Damage(s, target.Id, damage, LossSource.ImmuneEffect);
                }
                else
                {
                    // GD cw_actions.gd:1263-1269：只排**癌细胞**站着的（说明 #20），免疫细胞站着的癌组织（骨样硬化蹲守格）照算 —— 此前 C# 用 OccupyingCell == null 多排了它们，候选表长度不同、pick_n 抽的下标就对不上
                    var tiles = Tiles(s).Where(t => t.State == TissueState.Cancer && s.GetCellAt(t.Position) is not { IsAlive: true, Faction: Faction.Cancer } && AdjacentHealthy(s, t.Position)).ToArray();
                    if (tiles.Length == 0) break;   // GD cw_actions.gd:1270-1272：无可转化癌组织直接落空，**不掷骰**（此前 C# 照掷，多一发 rng）
                    // 无目标时改为转化癌组织：掷 **d3**，2/3 概率取前一个数、1/3 概率取后一个数，
                    // 而那两个数**按免疫等级分档**（PRD 2026-09-13 云端版 / issue #37：III 级 3/5、X 级 4/6）。
                    //
                    // 2026-09-16 修：C# 此前写死 2/3 —— 那是**改版前**的值，III/X 级都少转了。
                    // 掷法也不对：`NextInt(3)`（0..2）与 GD 的 `roll_shown(3, …)` = `randi_range(1,3)`
                    // 概率一样但**抽取区间不一样**，对拍带子逐笔比对时那一步就分叉。
                    var tier = AntibodyNoTargetX[Math.Clamp((int)s.Players[cell.OwnerSeat].ImmuneLevel - 1, 0, AntibodyNoTargetX.Count - 1)];
                    var roll = rng.NextIntRange(1, 4);
                    Stage.Emit(new DiceRolled(s.Turn.WorldRound, s.Turn.Phase, "抗体", roll, 3, cell.OwnerSeat, cell.Position));   // GD roll_shown(3, "抗体")
                    var max = roll <= 2 ? tier[0] : tier[1];
                    Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, $"抗体：转化 {max} 格", cell.Position));   // GD cw_actions.gd:1278
                    foreach (var pick in rng.PickRandom(tiles, max)) s = CardRules.ToHealthy(s, pick.Position);   // GD `to_healthy`
                }
                break;
            }
            case "细胞毒素":
            {
                // GD `_do_toxin`（cw_actions.gd:1309-1322）：付费、toxin_used +1、**脚下那一格**记 toxin_round（此前 C# 把它当目标格去重章、盖在每个目标上 —— L1 逐格比 toxin_round）
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - 10, toxin: cell.ToxinThisRound + 1));
                s = s.WithBoard(s.Board.UpdateTissue(cell.Position, s.Board.Tissues[cell.Position].WithToxinRound(s.Turn.WorldRound)));
                Stage.Emit(Stage.Fx(s, "toxin", ("from", cell.Position), ("tiles", new[] { cell.Position }.Concat(RulePolicies.GdNeighbors(s, cell.Position)).ToArray())));   // GD cw_actions.gd:1324：1 环七格
                foreach (var pos in ToxinTargets(s, cell))
                {
                    // GD `CWTissue.to_necrotic(tile, NECROSIS_TOXIN)`：坏死时长取 max(原, 2)，代谢核心 / 骨髓的库存与产出进度一起清
                    s = CardRules.Necrotize(s, pos, 2);
                }
                foreach (var target in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Cancer && x.Position.DistanceTo(cell.Position) <= 1).ToArray())
                    s = Damage(s, target.Id, 10, LossSource.ImmuneEffect);   // 细胞毒素：1.0 能量（原 1 = 0.1）
                break;
            }
            case "裂解":
            {
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - 10));
                Stage.Emit(Stage.Fx(s, "lyse", ("from", cell.Position), ("to", d.Target!.Value)));   // GD cw_actions.gd:1342
                s = CardRules.ToHealthy(s, d.Target!.Value);   // GD `CWTissue.to_healthy`
                break;
            }
            case "黏液破裂":
            {
                // 顺序照 GD `_do_mucus`（cw_actions.gd:1442-1476）：整片覆黏液 → 随机 ≤10 格健康组织转癌（**新生**）→ 范围内免疫各 -2.0
                // → **kill 自己** → 刷新标记。自毁走 Kill 而不是 Damage：印戒自己的【囊性护甲】会把那一下减掉 0.5，
                // 剩 0.5 能量「自杀未遂」、继续占着回合，GD 那边已经进 E 阶段了（L1 第 56 步，2026-09-17）
                var position = cell.Position;
                var ring = Tiles(s).Where(t => t.Position.DistanceTo(position) <= 2).ToArray();
                foreach (var tile in ring)
                    s = s.WithBoard(s.Board.UpdateTissue(tile.Position, s.Board.Tissues[tile.Position].WithMucus(true)));
                // PRD:519「系统从中随机选择最多 10 格**健康组织**立即转化为癌组织」——
                // **没有「无细胞占据」这个条件**，是 C# 自己加的（GD 侧 cw_actions.gd:1458-1461 也只筛健康）。
                // 站在健康格上的免疫细胞脚下照样会被转成癌组织。
                var healthy = ring.Where(t => t.State == TissueState.Healthy).ToArray();
                foreach (var pick in rng.PickRandom(healthy, 10))
                {
                    s = CardRules.ToCancer(s, pick.Position, newborn: true);
                    var dir = Stage.DirToward(pick.Position, position);   // GD cw_actions.gd:1466：癌从引爆者那一侧漫入；脚下那格取不出方向就不演
                    if (dir >= 0) Stage.Emit(new TissueConverted(s.Turn.WorldRound, s.Turn.Phase, pick.Position, dir, "黏液破裂"));
                }
                Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, "黏液破裂", position, true));   // GD cw_actions.gd:1469
                foreach (var immune in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Immune && x.Position.DistanceTo(position) <= 2).ToArray())
                    s = Damage(s, immune.Id, 20, LossSource.CancerSkill);
                s = Kill(s, cell.Id);
                s = UpdateMarks(s);
                break;
            }
            case "骨样硬化":
            {
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - 20));
                var at = cell.Position;
                s = s.WithBoard(s.Board.UpdateTissue(at, s.Board.Tissues[at].WithOssifyAt(s.Turn.WorldRound + 2)));
                break;
            }
            case "早期血行转移":
            {
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - MelanomaHomingCost, metastasis: true));
                var dest = d.Target!.Value;
                var from = cell.Position;
                s = EnterTile(s, cell.Id, dest, rng);   // GD `_homing` 走 enter_tile（落地即【定殖】+ 特殊组织收取）
                var spread = RulePolicies.GdNeighbors(s, dest).Where(n => s.Board.Tissues[n].State == TissueState.Healthy).ToArray();   // GD `game.neighbors` DIRS 序：pick_n 抽的是下标（批扫 4p_1002 / 2p_1017）
                var picked = rng.PickRandom(spread, 3).ToArray();
                foreach (var pick in picked)
                {
                    s = CardRules.ToCancer(s, pick, newborn: true);   // GD `to_cancer(t, true)`：新生、清坏死
                    var dir = Stage.DirToward(pick, dest);   // GD cw_actions.gd:1435：癌从落点那一侧漫入
                    if (dir >= 0) Stage.Emit(new TissueConverted(s.Turn.WorldRound, s.Turn.Phase, pick, dir, "早期血行转移"));
                }
                Stage.Emit(Stage.Fx(s, "homing", ("from", from), ("to", dest), ("spread", picked)));   // GD cw_actions.gd:1437
                break;
            }
            case "转移":
            {
                // GD 侧这笔钱走 SKILL_MOVE 的费用管线（`_do_jump` → `CWCost.Action.SKILL_MOVE`），
                // 【基质阻隔】那类世界事件会让它翻倍。C# 还没有事件容器，先按基准价直扣 ——
                // 事件容器落地时这里要改成走管线（EV-0/EV-1 那张工单）。
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - s.Tuning.MetastasisCost, jump: cell.JumpUsedThisRound + 1));
                s = EnterTile(s, cell.Id, d.Target!.Value, rng);   // GD `_jump` 走 enter_tile
                break;
            }
            case "免疫猎杀":
            {
                s = ConsumeEffector(s, cell);
                if (d.TargetCell is { } hunt && s.Cells.TryGetValue(hunt, out var hunted) && hunted.IsAlive && hunted.Faction == Faction.Cancer)
                {
                    s = ApplyMark(s, hunt, s.Cells[cell.Id]);
                    // 「同时在其上附着跟随的【追踪趋化源】」（PRD:583）
                    s = s.WithTurn(s.Turn.WithTrack(hunt, null, HuntChemoRounds));
                    Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, "免疫猎杀", hunted.Position, true));   // GD cw_actions.gd:1582
                }
                break;
            }
            case "中和抗体":
            {
                // PRD:627「**所有与健康组织相邻的**癌细胞的种类特殊效果 / 永久卡牌效果失效，持续 2 世界回合」。
                //
                // 2026-09-15 修：这里原来写一个全局标记 `Turn.CancerEffectsDisabledUntil`，
                // 一压压全场 —— 连躲在癌组织深处、PRD 明文不该被压到的也压。
                // 改成照 GD（cw_actions.gd:1607-1613）逐个写到细胞上，靶子在**施放那一刻**定死。
                //
                // 「持续 2 世界回合」= 到**下一**回合末（通用规则 3：第「当前 + 2 − 1」回合 E 阶段结束），
                // 所以记的是 `WorldRound + 1`，判据是 `WorldRound <= NeutralUntil`。
                // 记「到第几回合末」而不是倒计时：存档读档、快照回滚都不会走样。
                s = ConsumeEffector(s, cell);
                var until = s.Turn.WorldRound + 1;
                foreach (var t in RulePolicies.Cells(s)
                    .Where(x => x.IsAlive && x.Faction == Faction.Cancer && RulePolicies.AdjacentHealthy(s, x.Position))
                    .ToArray())
                    s = s.UpdateCell(t.Id, s.Cells[t.Id].Copy(neutralUntil: until));
                Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, "中和抗体", cell.Position, true));   // GD cw_actions.gd:1616
                break;
            }
            case "连续吞噬":
            {
                // 发的是**连锁额度**而不是 5 次免费移动 —— PRD:605「第一次【净化】后，
                // 可立即免费向相邻**癌组织**迁移；若再次净化则重复触发，最多 5 次」。
                // 它是「净化之后当场接着走」的连锁，不是「本回合随便花的 5 次免费移动」。
                s = ConsumeEffector(s, cell);
                s = s.UpdateCell(cell.Id, s.Cells[cell.Id].Copy(chainLeft: CellRules.ChainPhagoMax));
                break;
            }
            case "趋化源":
                // 2026-09-15 修：这里原来是 `Round(cell.Energy - 2)`，**不是少个 0，是反的**。
                // `RulePolicies.Round(double energyUnits) => RoundTenth(energyUnits * 10)` 收的是
                // **能量单位**，而 `cell.Energy` 已经是十分位 ——
                // 能量 3.0(=30) 发动一次之后变成 Round(28) = **280 = 28.0**：
                // 不但不扣费，还凭空涨 10 倍，冷却允许时可反复刷。
                // 费用 3.0 见 PRD:561，对齐 GDScript 的 CWData.CHEMO_COST := 30。
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - 30));
                s = s.WithTurn(s.Turn.WithChemo(d.Target!.Value, ChemoFullTurns, cell.OwnerSeat, cell.Id));
                Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, "趋化源", d.Target!.Value, true));   // GD cw_actions.gd:1164
                break;
            case "Excalibur":
            {
                s = ConsumeEffector(s, cell);
                var start = s.Cells[cell.Id].Position;
                var direction = d.Target is { } aim ? RayDirection(start, aim) : null;
                if (direction is { } dir)
                {
                    var ray = new List<HexPosition>();
                    var cursor = start;
                    while (true)
                    {
                        cursor = new HexPosition(cursor.Q + dir.Q, cursor.R + dir.R, cursor.S + dir.S);
                        if (!s.Board.Tissues.ContainsKey(cursor)) break;
                        ray.Add(cursor);
                    }
                    // 侧向波及：主射线相邻的癌组织各掷一次 60%（GD cw_actions.gd:1643-1651）。**候选序必须是 DIRS 序**（GdNeighbors）：
                    // 掷骰的发数与格子的配对靠这个序，此前用 HexPosition.GetNeighbors() 的另一套次序，同一条带子的第 i 发落到另一格（复核 2026-09-18）。
                    // 掷 1..100 判 `<= 60`，逐位对齐 GD 的 `randi_range(1, 100) <= EXCALIBUR_SPLASH_PCT`。
                    var seen = new HashSet<HexPosition>(ray);
                    var hit = new List<HexPosition>();
                    foreach (var pos in ray)
                        foreach (var neighbor in RulePolicies.GdNeighbors(s, pos))
                        {
                            if (seen.Contains(neighbor) || s.Board.Tissues[neighbor].State != TissueState.Cancer) continue;
                            seen.Add(neighbor);
                            if (rng.NextIntRange(1, 101) <= ExcaliburSplashPercent) hit.Add(neighbor);
                        }
                    // 光束先演、伤害随后落（GD cw_actions.gd:1654）；射线为空（贴边）不发
                    if (ray.Count > 0) Stage.Emit(new BeamFired(s.Turn.WorldRound, s.Turn.Phase, start, ray[^1], hit.ToImmutableArray()));
                    // GD `_excalibur_sweep(ray, 2.0)` 再 `_excalibur_sweep(splash, 1.0)`：每段先翻组织（癌组织 → 健康 + 坏死）再打站着的癌细胞；
                    // 侧向那段**只打掷中的格**（此前 C# 打的是全部候选格，连没掷中的、非癌组织格上的癌细胞都挨一下）
                    s = ExcaliburSweep(s, ray, 20);
                    s = ExcaliburSweep(s, hit, 10);
                    Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, "Excalibur", start, true));   // GD cw_actions.gd:1657
                }
                break;
            }
        }
        return new(s, Array.Empty<IGameEvent>(), true);
    }
}
