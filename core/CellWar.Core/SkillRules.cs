using static CellWar.Core.CellRules;
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
                if (d.Target is not { } jump || !s.Board.Tissues.TryGetValue(jump, out var jt) || jt.OccupyingCell != null || jump.DistanceTo(cell.Position) != 5)
                    return new(false, "终点必须是地图内 5 格外的无细胞格");
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
    /// 【早期血行转移】的费用（GD `CWData.MELANOMA_HOMING_COST`）。
    /// **它是常量不是旋钮** —— 与【转移】不同，GD 那边 `_cell_skill_base("homing")` 直接读常量，
    /// 只有 `"jump"` 走 `game.tune.metastasis_cost`。两者今天同为 1.0，别顺手合并成一个。
    /// </summary>
    private const int MelanomaHomingCost = 10;

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
                if (targets.Length > 0 && damage > 0)
                    foreach (var target in targets) s = Damage(s, target.Id, damage);
                else
                {
                    var tiles = Tiles(s).Where(t => t.State == TissueState.Cancer && t.OccupyingCell == null && AdjacentHealthy(s, t.Position)).ToArray();
                    var max = rng.NextInt(3) < 2 ? 2 : 3;
                    foreach (var pick in rng.Shuffle(tiles).Take(max)) s = s.UpdateTissueState(pick.Position, TissueState.Healthy);
                }
                break;
            }
            case "细胞毒素":
            {
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - 10, toxin: cell.ToxinThisRound + 1));
                var ring = cell.Position.GetNeighbors().Append(cell.Position).ToArray();
                foreach (var pos in ring)
                {
                    if (!s.Board.Tissues.TryGetValue(pos, out var tile) || tile.State != TissueState.Cancer || tile.ToxinRound == s.Turn.WorldRound) continue;
                    s = s.UpdateTissueState(pos, TissueState.Healthy);
                    s = s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithNecrosis(2).WithToxinRound(s.Turn.WorldRound)));
                }
                foreach (var target in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Cancer && x.Position.DistanceTo(cell.Position) <= 1).ToArray())
                    s = Damage(s, target.Id, 10);   // 细胞毒素：1.0 能量（原 1 = 0.1）
                break;
            }
            case "裂解":
            {
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - 10));
                s = s.UpdateTissueState(d.Target!.Value, TissueState.Healthy);
                break;
            }
            case "黏液破裂":
            {
                var position = cell.Position;
                var pool = s.Cells[cell.Id].Energy;
                s = Damage(s, cell.Id, pool);  // 消耗全部能量并死亡
                var ring = Tiles(s).Where(t => t.Position.DistanceTo(position) <= 2).ToArray();
                foreach (var tile in ring)
                    s = s.WithBoard(s.Board.UpdateTissue(tile.Position, s.Board.Tissues[tile.Position].WithMucus(true)));
                // PRD:519「系统从中随机选择最多 10 格**健康组织**立即转化为癌组织」——
                // **没有「无细胞占据」这个条件**，是 C# 自己加的（GD 侧 cw_actions.gd:1458-1461 也只筛健康）。
                // 站在健康格上的免疫细胞脚下照样会被转成癌组织。
                var healthy = ring.Where(t => t.State == TissueState.Healthy).ToArray();
                foreach (var pick in rng.Shuffle(healthy).Take(10)) s = s.UpdateTissueState(pick.Position, TissueState.Cancer);
                foreach (var immune in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Immune && x.Position.DistanceTo(position) <= 2).ToArray())
                    s = Damage(s, immune.Id, 20);
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
                s = Teleport(s, cell.Id, dest);
                var spread = dest.GetNeighbors().Where(n => s.Board.Tissues.TryGetValue(n, out var nt) && nt.State == TissueState.Healthy).ToArray();
                foreach (var pick in rng.Shuffle(spread).Take(3)) s = s.UpdateTissueState(pick, TissueState.Cancer);
                break;
            }
            case "转移":
            {
                // GD 侧这笔钱走 SKILL_MOVE 的费用管线（`_do_jump` → `CWCost.Action.SKILL_MOVE`），
                // 【基质阻隔】那类世界事件会让它翻倍。C# 还没有事件容器，先按基准价直扣 ——
                // 事件容器落地时这里要改成走管线（EV-0/EV-1 那张工单）。
                s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - s.Tuning.MetastasisCost, jump: cell.JumpUsedThisRound + 1));
                s = Teleport(s, cell.Id, d.Target!.Value);
                break;
            }
            case "免疫猎杀":
            {
                s = ConsumeEffector(s, cell);
                if (d.TargetCell is { } hunt && s.Cells.TryGetValue(hunt, out var hunted) && hunted.IsAlive && hunted.Faction == Faction.Cancer)
                    s = ApplyMark(s, hunt, s.Cells[cell.Id]);
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
                break;
            }
            case "连续吞噬":
            {
                s = ConsumeEffector(s, cell);
                s = AddModifier(s, s.Cells[cell.Id], new("连续吞噬", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Skill, 0, 0, null, 5, ModifierDuration.Turn, ModifierRequirement.MoveToCancerous));
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
                s = s.WithTurn(s.Turn.WithChemo(d.Target!.Value, 2, cell.OwnerSeat, cell.Id));
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
                    var splash = new HashSet<HexPosition>();
                    foreach (var pos in ray)
                        foreach (var neighbor in pos.GetNeighbors())
                            if (s.Board.Tissues.ContainsKey(neighbor) && !ray.Contains(neighbor)) splash.Add(neighbor);
                    foreach (var pos in ray)
                        if (s.Board.Tissues[pos].State == TissueState.Cancer)
                        {
                            s = s.UpdateTissueState(pos, TissueState.Healthy);
                            s = s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithNecrosis(2)));
                        }
                    foreach (var pos in splash.Where(p => s.Board.Tissues[p].State == TissueState.Cancer && rng.NextInt(100) < 60))
                    {
                        s = s.UpdateTissueState(pos, TissueState.Healthy);
                        s = s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithNecrosis(2)));
                    }
                    foreach (var target in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Cancer && ray.Contains(x.Position)).ToArray())
                        s = Damage(s, target.Id, 20);   // Excalibur 主射线：2.0 能量（原 2 = 0.2）
                    foreach (var target in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Cancer && splash.Contains(x.Position)).ToArray())
                        s = Damage(s, target.Id, 10);   // Excalibur 侧向波及：1.0 能量（原 1 = 0.1）
                }
                break;
            }
        }
        return new(s, Array.Empty<IGameEvent>(), true);
    }
}
