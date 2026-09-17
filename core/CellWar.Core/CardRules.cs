using static CellWar.Core.CellRules;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>单张卡牌效果：输入当前世界、来源细胞、随机源与可选目标，返回结算后的世界。</summary>
internal delegate WorldState CardEffect(WorldState s, Cell cell, IDeterministicRng rng, HexPosition? target, EntityId? targetCell);

/// <summary>
/// 卡牌效果注册表（对应三层设计的 CardRules 所有权域）。
/// 每张卡是注册表里的一条独立条目：加/改一张卡只动它自己的一条，不再编辑巨型 switch。
/// 被动型永久技能（组织驻留、癌症干性等）不在此表内，由 GrantTurnModifiers / 移动 / 呼吸等域生效；
/// 未登记的名字返回原状态（与旧 switch 的 default 行为一致）。
/// 注册键必须覆盖 <see cref="CardImplementation"/> 中每张已实现卡（由测试钉死）。
/// </summary>
internal static class CardRules
{
    private static readonly Dictionary<string, CardEffect> Registry = new(StringComparer.Ordinal)
    {
        ["细胞膜修复"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new ActiveModifier("细胞膜修复", ModifierTarget.EnergyLoss,
                ModifierStage.Subtract, SourceLayer.Card, 0, 15, 0, 1, ModifierDuration.Game));
            return s;
        },
        ["急性炎症反应"] = (s, cell, rng, target, targetCell) =>
        {
            s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + AerobicShare(s, cell)));
            return s;
        },
        ["抗原摄取"] = (s, cell, rng, target, targetCell) =>
        {
            var adjacent = cell.Position.GetNeighbors().Any(n => s.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t));
            return AddMemory(s, adjacent ? 2 : 1);
        },
        ["抗原呈递增强"] = (s, cell, rng, target, targetCell) => AddMemory(s, 3),
        ["克隆扩增"] = (s, cell, rng, target, targetCell) =>
        {
            foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune).ToArray())
                s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy + 10));
            return s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
        },
        ["肿瘤血管生成"] = (s, cell, rng, target, targetCell) =>
        {
            var amount = CancerPhase(s.Turn.WorldRound) switch { 0 => 10, 1 => 20, _ => 25 };
            foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer).ToArray())
                s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy + amount));
            return s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
        },
        // 【局部吞噬】：相邻无细胞的普通癌组织里随机 1 格转健康、+1 记忆（卡面明写才给，不过 purify_gives_memory）。
        // 候选按 GD DIRS 序（randi_range 抽的是下标）；GD 不看黏液，此前 C# 多了一条 `!t.Mucus`
        ["局部吞噬"] = (s, cell, rng, target, targetCell) =>
        {
            var cands = PhagocytosisTargets(s, cell);
            if (cands.Count == 0) return s;   // 选项层已经拦了（Playable），这里是兜底
            s = s.UpdateTissueState(cands[rng.NextInt(cands.Count)], TissueState.Healthy);
            return AddMemory(s, 1);
        },
        // 【基质降解】：格子由玩家选（GD hand_options 一格一条），**零随机** —— 此前 C# 自己随机挑，带子上多一发
        ["基质降解"] = (s, cell, rng, target, targetCell) =>
            target is { } pos && DegradeTargets(s, cell).Contains(pos) ? CrackToCancer(s, pos) : s,
        // 【溶酶体强化】：相邻无细胞的普通癌组织随机最多 4 格转健康（pick_n，候选按 GD DIRS 序）；巨噬每格 +0.3
        ["溶酶体强化"] = (s, cell, rng, target, targetCell) =>
        {
            var targets = AdjacentPlainCancerEmpty(s, cell.Position);
            foreach (var pick in rng.PickRandom(targets, 4))
            {
                s = s.UpdateTissueState(pick, TissueState.Healthy);
                if (cell.Type == CellType.Macrophage)
                    s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 3));
            }
            return s;
        },
        ["骨髓动员"] = (s, cell, rng, target, targetCell) =>
        {
            foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune).ToArray())
                s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy + 5));
            // GD `_marrow_mobilization`：按 CWData.MARROWS 的顺序，空仓的健康骨髓存 1 张，站在上面的细胞**当场**收（抽卡）。
            // GD 那一行此前漏了 await（同步桥下嵌套、界面桥下脱手）—— Kevin 2026-09-18 裁：GD 补 await（协议 v29）、C# 照嵌套语义做。
            var due = new List<HexPosition>();
            foreach (var m in MatchSetup.Marrows)
            {
                if (!s.Board.Tissues.TryGetValue(m, out var t) || t.Type != TissueType.BoneMarrow || t.State != TissueState.Healthy || (t.Charge ?? 0) >= BoneMarrowStoreMax) continue;
                s = s.WithBoard(s.Board.UpdateTissue(m, t.WithCharge(BoneMarrowStoreMax)));
                due.Add(m);
            }
            return CellRules.CollectMarrows(s, due, rng);
        },
        ["全身免疫动员"] = (s, cell, rng, target, targetCell) =>
        {
            foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune).ToArray())
                s = s.UpdateCell(c.Id, s.Cells[c.Id].WithEnergy(s.Cells[c.Id].Energy + 15));
            return s;
        },
        ["全身性免疫清除"] = (s, cell, rng, target, targetCell) =>
        {
            var candidates = Tiles(s).Where(t => t.State == TissueState.Cancer && t.OccupyingCell == null &&
                t.Position.GetNeighbors().Any(n => s.Board.Tissues.TryGetValue(n, out var x) && x.State == TissueState.Healthy)).ToArray();
            foreach (var pick in rng.PickRandom(candidates, 5))
                s = s.UpdateTissueState(pick.Position, TissueState.Healthy);
            return s;
        },
        ["IFN-γ释放"] = (s, cell, rng, target, targetCell) => IfnBurst(s, cell.Position),   // 事件卡：圆心 = 自己
        ["糖酵解爆发"] = (s, cell, rng, target, targetCell) =>
        {
            s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + AnaerobicShare(s, cell)));
            return s;
        },
        // left=1：E 阶段衰减在回合末之前结算，挂到回合末正好盖住本回合那一次
        ["基质稳定"] = (s, cell, rng, target, targetCell) => s.InstallEffect("基质稳定", left: 1),
        // left=2：下一次有氧在**下个**世界回合的 S 阶段，要活过本回合末；
        // 结算时同名整批消耗（RulePolicies 那侧），多打几张就多几条，逐份 −20%（定案 #63）
        ["TGF-β释放"] = (s, cell, rng, target, targetCell) => s.InstallEffect("TGF-β释放", left: 2),
        ["缺氧适应"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("缺氧适应", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 10, 0, 1, ModifierDuration.Game));   // 缺氧适应：挡下 1.0（原 1 = 0.1）
            return s;
        },
        ["DNA损伤修复"] = (s, cell, rng, target, targetCell) =>
        {
            // 减免值在**结算当刻**按分期重算（定案 #64，CellRules.ShieldValue）；这里存的 cut 只是打出时的记录
            var cut = CancerPhase(s.Turn.WorldRound) switch { 0 => 10, 1 => 15, _ => 20 };
            s = AddModifier(s, s.Cells[cell.Id], new("DNA损伤修复", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, cut, 0, 1, ModifierDuration.Game));
            return s;
        },
        ["炎症趋化"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("炎症趋化", ModifierTarget.Move, ModifierStage.Replace, SourceLayer.Card, 0, 5, null, 1, ModifierDuration.Turn, ModifierRequirement.MoveToCancerous));
            return s;
        },
        ["上皮—间质转化"] = (s, cell, rng, target, targetCell) =>
        {
            var uses = CancerPhase(s.Turn.WorldRound) + 1;
            s = AddModifier(s, s.Cells[cell.Id], new("上皮—间质转化", ModifierTarget.Move, ModifierStage.Replace, SourceLayer.Card, 0, 2, null, uses, ModifierDuration.Turn, ModifierRequirement.MoveToHealthy));
            return s;
        },
        ["CXCR3趋化"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("CXCR3趋化", ModifierTarget.Move, ModifierStage.Subtract, SourceLayer.Card, 0, 5, 2, 2, ModifierDuration.Turn, ModifierRequirement.MoveToCancerous));
            return s;
        },
        ["组织浸润"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("组织浸润", ModifierTarget.Move, ModifierStage.Subtract, SourceLayer.Passive, 0, 3, 2, ActiveModifier.Unlimited, ModifierDuration.Game, ModifierRequirement.MoveToCancerous));
            return s;
        },
        ["穿孔素-颗粒酶"] = (s, cell, rng, target, targetCell) =>
        {
            var extra = cell.Type == CellType.TCell ? 20 : 10;
            s = AddModifier(s, s.Cells[cell.Id], new("穿孔素-颗粒酶", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, extra, null, 1, ModifierDuration.Turn));
            return s;
        },
        ["高亲和力克隆"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("高亲和力克隆", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 10, null, 1, ModifierDuration.Turn));   // 高亲和力克隆：额外 1.0（原 1 = 0.1）
            return s;
        },
        ["补体调理"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("补体调理", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 5, null, 1, ModifierDuration.Turn));
            return s;
        },
        ["补体级联"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("补体级联", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 0, null, 1, ModifierDuration.Turn));
            return s;
        },
        ["PD-L1表达"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("PD-L1表达", ModifierTarget.Attack, ModifierStage.Add, SourceLayer.Card, 0, 0, null, 1, ModifierDuration.Game));
            return s;
        },
        ["BCL-2抗凋亡"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("BCL-2抗凋亡", ModifierTarget.EnergyLoss, ModifierStage.Add, SourceLayer.Card, 0, 0, null, 1, ModifierDuration.Game));
            return s;
        },
        ["乳酸酸化"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is not { } tid || !LacticAcidTargets(s, cell).Contains(tid)) return s;
            var loss = CancerPhase(s.Turn.WorldRound) switch { 0 => 8, 1 => 15, _ => 20 };
            if (AdjacentCancerous(s, s.Cells[tid].Position, 3)) loss += 5;
            return Damage(s, tid, loss, LossSource.CancerSkill);
        },
        ["基质硬化"] = (s, cell, rng, target, targetCell) =>
        {
            // 三道闸（新生保护 / TNF-α 冻结 / 血管）在选项层就拦（HardenTargets），这里只认候选表里的格
            if (target is { } pos && HardenTargets(s, cell).Contains(pos))
            {
                var add = CancerPhase(s.Turn.WorldRound) switch { 0 => 10, 1 => 15, _ => 20 };
                // 走 `BoardRules.RaiseSolid` 而不是自己改字段 —— GD 侧 `_stroma_harden` 也是调 `raise_solid`。
                // 直接改字段会绕过三道判据：TNF-α 冻结、血管不可固化、**加够门槛当场转固化**。
                // 2026-09-15 之前这里靠 E 阶段那个大循环每回合重判所有癌组织兜着，
                // E 阶段拆成具名步之后那张网没了 —— 不改的话推过门槛也永远不转。
                s = BoardRules.RaiseSolid(s, pos, add);
            }
            return s;
        },
        // 【交叉呈递】：射程树突 4 / 其余 2，已标记的、本回合给过标记的不出选项；结算走 ApplyMark（GD `apply_mark`，
        // Kevin 2026-09-17 裁定方案 A、协议 v28）：记施加回合（寿命从本回合起算）、记层数（树突带【抗原呈递强化】给 2 层）、同回合只给一次。
        // 此前两边都是裸写 marked 一个字段，寿命按上一次的施加回合算、只翻一次。
        ["交叉呈递"] = (s, cell, rng, target, targetCell) =>
            targetCell is { } tid && CrossPresentTargets(s, cell).Contains(tid) ? ApplyMark(s, tid, cell) : s,
        ["抗体依赖细胞毒作用"] = (s, cell, rng, target, targetCell) =>
            targetCell is { } tid && AdccTargets(s, cell).Contains(tid) ? Damage(s, tid, cell.Type == CellType.BCell ? 15 : 10, LossSource.ImmuneEffect) : s,
        // 【IFN-γ高峰】：技能卡，圆心 = 所选免疫细胞（可以是自己、不限距离），选项层用 IfnHasEffect 把「打了什么都不发生」的目标挡掉
        ["IFN-γ高峰"] = (s, cell, rng, target, targetCell) =>
            targetCell is { } tid && IfnPeakTargets(s, cell).Contains(tid) ? IfnBurst(s, s.Cells[tid].Position) : s,
        ["免疫风暴"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Immune)
            {
                foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(t.Position) <= 2).ToArray())
                    s = Damage(s, c.Id, 10, LossSource.ImmuneEffect);   // 免疫风暴：1.0 能量（原 1 = 0.1）
                foreach (var tile in Tiles(s).Where(x => x.State == TissueState.Cancer && x.OccupyingCell == null && x.Position.DistanceTo(t.Position) <= 2).ToArray())
                    s = s.UpdateTissueState(tile.Position, TissueState.Healthy);
            }
            return s;
        },
        // 【免疫增援】：队友只认**别的席位**（GD `t.pid != cell.pid`），落点在结算时刻重算 —— 与选项层同一个函数、同一个顺序，
        // 抽一发 NextInt(|候选|)（候选恰好 1 格时带子零消耗）；落地走 EnterTile（骨髓有卡会再抽一张）
        ["免疫增援"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is not { } tid || !ReinforceAllies(s, cell).Contains(tid)) return s;
            var cands = EmptyHealthyWithin(s, s.Cells[tid].Position, 2);
            return CellRules.EnterTile(s, cell.Id, cands[rng.NextInt(cands.Count)], rng);
        },
        // 【肿瘤细胞募集】：把**别人**拉到自己身边 —— 落点以**施法者**为心（GD `_recruit`），目标只认别的席位
        ["肿瘤细胞募集"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is not { } tid || !RecruitTargets(s, cell).Contains(tid)) return s;
            var dests = CancerousLandings(s, cell.Position, TumorTeleportRings(s));
            return CellRules.EnterTile(s, tid, dests[rng.NextInt(dests.Count)], rng);
        },
        // 【肿瘤增援】：把**自己**送过去 —— 落点以**目标**为心（GD `_tumor_reinforce`），选项层逐目标判有没有落点
        ["肿瘤增援"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is not { } tid || !TumorReinforceTargets(s, cell).Contains(tid)) return s;
            var dests = CancerousLandings(s, s.Cells[tid].Position, TumorTeleportRings(s));
            return CellRules.EnterTile(s, cell.Id, dests[rng.NextInt(dests.Count)], rng);
        },
        // 【代谢耦联】（Kevin 2026-09-16 拍板跟 GD 的形状 + 一个「取消」）：打出时已选队友（TargetCell），
        // 随后两问 —— 方向（送给 / 索取，各自只在那一侧付得起最低档时才出现）、档位（1.0→1.2 / 1.5→2.0 / 2.0→2.5）——
        // 走挂起态；两问的下标 0 都是「取消」：无效果、**卡不弃置**。双方都付不出最低一档 = 落空（卡照常弃置）。
        // 此前 C# 是按肿瘤分期定档、只能自己付、还把付款截到手头能量 —— 三处都不是 GD 的规则。
        // GD 的两侧数额还过【信号放大】（`_amp`）；C# 没有那张卡，这里不放大。
        ["代谢耦联"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is not { } ally || !CoupleAllies(s, cell).Contains(ally)) return s;
            if (CoupleDirections(s, cell.Id, ally).Count == 0) return s;   // 落空
            return s.WithTurn(s.Turn.WithPendingCouple(cell.Id, ally, null));
        },
        // 【基质重塑】= GD `_remodel`（cw_card_fx.gd:934-969，**三问零随机**）：先拆选定的第 1 格（crack_to_cancer），再挂起追问 ——
        // 「还可再拆 1 格」（候选 = 重算后的 2 环内固化，为空就不问）、「选择要转健康的癌组织」×2（候选 = 拆过的格自身 + 相邻格里无细胞占据的普通癌组织，
        // DIRS 序、跨格去重，为空就不问也不再问）。每一段都可「停」，停不是取消：卡照常离手。
        // 此前 C# 一次性同步跑完：强制拆第 2 格（(Q,R) 最小的那格）、从「距施法者 ≤2 或挨着任一固化格」里**随机**转两格（两发随机、候选域是 GD 的超集），
        // 拆与转都只改 State / solid，不清 newborn / necrosis / ossify（2026-09-17 深夜）。
        ["基质重塑"] = (s, cell, rng, target, targetCell) =>
        {
            if (target is not { } first || !RemodelTargets(s, cell).Contains(first)) return s;   // 防御：Validate 已按 TileTargeted 拦下非法 / 缺失目标
            s = CrackToCancer(s, first);
            return s.WithTurn(s.Turn.WithPendingRemodel(cell.Id, first, null, 0));
        },
        // 【癌症转移】（PRD:1465）：「选择两环内任意格子传送，正常触发【定殖】」。
        // 「任意格子」不挑地形（健康 / 癌 / 固化都行）；唯一限制是**没有细胞占着** ——
        // 一格只能站一个，所以自己所在的中心格也自动被排除。
        // 「正常触发【定殖】」= 走 CellRules.Teleport：癌细胞落到健康组织上会把它转成
        // 新生癌组织，与 GDScript 侧 enter_tile 同口径。
        // 合法落点的枚举在 DecisionRouter（这张卡是 68 张里唯一需要选格的卡牌）。
        ["癌症转移"] = (s, cell, rng, target, targetCell) =>
            target is { } dest && MetastasisTargets(s, cell).Contains(dest)
                ? CellRules.EnterTile(s, cell.Id, dest, rng)   // GD 1709 行 `enter_tile`：定殖 + 特殊组织收取 + 标记刷新
                : s,
        // 【放疗】：起点由玩家在全盘癌性组织里选（GD 一格一条）；区域按 GD 的多重集 frontier 一轮一发地长（RadioRegion）；
        // 翻格段零随机，整格走 to_necrotic（含清库存）
        ["放疗"] = (s, cell, rng, target, targetCell) =>
        {
            if (target is not { } start || !RadiotherapyTargets(s).Contains(start)) return s;
            foreach (var pos in RadioRegion(s, start, RadioRegionSize, rng))
                s = Necrotize(s, pos, NecrosisRadio);
            return s;
        },
        // 【克隆增殖】：相邻、**没有免疫细胞**占着的健康组织（癌细胞站着的照样算），随机 1/2/3 格（分期）转**新生**癌组织（GD `to_cancer(t, true)`）
        ["克隆增殖"] = (s, cell, rng, target, targetCell) =>
        {
            var count = CancerPhase(s.Turn.WorldRound) + 1;
            foreach (var pick in rng.PickRandom(ClonalGrowthTargets(s, cell), count))
                s = ToCancer(s, pick, newborn: true);
            return s;
        },
        ["炎症风暴"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Immune)
            {
                var tiles = t.Position.GetNeighbors()
                    .Where(n => s.Board.Tissues.TryGetValue(n, out var x) && x.State == TissueState.Cancer && x.OccupyingCell == null)
                    .ToArray();
                foreach (var pick in tiles) s = s.UpdateTissueState(pick, TissueState.Healthy);
                foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(t.Position) <= 1).ToArray())
                    s = Damage(s, c.Id, 5, LossSource.ImmuneEffect);
            }
            return s;
        },
        // 【趋化募集】/【效应细胞浸润】：抽到即走的免费连走，GD `_free_walk` 每步问一次「走哪 / 停」（`kind: free_move`, tag = 卡名）。
        // 此前 C# 做成两条「免费移动」修饰，等玩家用「移动」行动去花 —— 选项形状和 GD 完全不同（L1 2p 第 6 步就分叉在这）。
        // 挂起后由 Execute 出口的 NormalizeChemotaxis 收口：没有候选就当场摘掉（GD「没有可进入的相邻格，提前结束」不问）
        ["趋化募集"] = (s, cell, rng, target, targetCell) =>
            s.WithTurn(s.Turn.PushWalk(cell.Id, CellRules.FreeWalkMaxSteps, "趋化募集")),   // 压栈：在别的连走当中抽到就是内层
        ["效应细胞浸润"] = (s, cell, rng, target, targetCell) =>
            s.WithTurn(s.Turn.PushWalk(cell.Id, CellRules.FreeWalkMaxSteps, "效应细胞浸润")),
        // 【炎症性趋化】：连走最多 3 步，每步起价 0.2。
        //
        // 不是「本回合 3 次迁移改价 0.2」的修饰（2026-09-16 前 C# 是那么写的）：
        // 一是 GD 的 0.2 是这三步**自己的起价**（`ctx.base_cost`），而 `Phase.REPLACE`
        // 排在它之后、会盖掉它 —— 做成 Replace 修饰覆盖方向正好反了；
        // 二是修饰会让本回合别的普通【迁移】也变 0.2；
        // 三是决策点数量不对：GD 是 1 个打出选项（第 1 步的落点烤在里面）+ 最多 2 次追问。
        //
        // 第 1 步**无条件执行**，不给「停在这里」；第 2/3 步走挂起态（见 DecisionRouter）。
        ["炎症性趋化"] = (s, cell, rng, target, targetCell) =>
        {
            if (target is not { } first) return s;
            s = s.WithTurn(s.Turn.PushWalk(cell.Id, CellRules.ChemotaxisMaxSteps, "炎症性趋化"));
            // 这里丢掉了这一步的事件（攻击/净化）—— 卡牌效果表的签名只吐 WorldState，
            // 整张表都是这样（如【炎症风暴】改地形也不发事件），不为一张卡单开一条通路。
            return CellRules.ChemotaxisMove(s, cell.Id, first, rng).NewState;
        },
        ["基因组不稳定"] = (s, cell, rng, target, targetCell) =>
        {
            // 掷 **d3（1..3）**，逐位对齐 GD 的 `roll_shown(3, "突变", …)` = `randi_range(1, 3)`。
            // 原来写的是 `NextInt(3)`（0..2）—— 结果映射一样、**抽取区间差一**，对拍带子会分叉。
            var a = rng.NextIntRange(1, 4);
            var b = rng.NextIntRange(1, 4);
            // GD `_genome_instability`（cw_card_fx.gd:771-788）：两次判定**相同就不问**、直接结算（批扫 60 条轨迹撞了 9 条，2026-09-18）
            if (a == b) return ApplyMutationOutcome(s, cell.Id, a, rng, charge: false);
            return s.WithTurn(s.Turn.WithPendingMutation(cell.OwnerSeat, cell.Id, a, b));
        },
        ["I型干扰素"] = (s, cell, rng, target, targetCell) =>
        {
            foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune).ToArray())
                s = AddModifier(s, s.Cells[c.Id], new("I型干扰素", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 10, 0, 1, ModifierDuration.Round));   // I型干扰素：挡下 1.0（原 1 = 0.1）
            return s;
        },
        ["TNF-α局部炎症"] = (s, cell, rng, target, targetCell) =>
        {
            // GD `_tnf`：面积 = 脚下 + 相邻（DIRS 序）。先按面积序扣普通癌组织的固化计数并记进冻结名单，再打面积内的癌细胞，
            // 最后 install_event("TNF-α局部炎症", 1, frozen) —— 冻结名单是事件容器里的一条（left=1，E 阶段第 8 步解冻）。
            var area = new[] { cell.Position }.Concat(GdNeighbors(s, cell.Position)).ToArray();
            var frozen = new SortedDictionary<string, int>(StringComparer.Ordinal);
            foreach (var p in area)
            {
                var tile = s.Board.Tissues[p];
                if (tile.State != TissueState.Cancer) continue;
                s = s.UpdateTissueSolidification(p, Math.Max(0, tile.SolidificationCount - 10));
                frozen[WorldEffects.TileKey(p)] = 1;
            }
            foreach (var p in area)
                if (s.GetCellAt(p) is { IsAlive: true, Faction: Faction.Cancer } victim)
                    s = Damage(s, victim.Id, 10, LossSource.ImmuneEffect);   // TNF-α局部炎症：1.0 能量（原 1 = 0.1）
            return s.InstallEffect("TNF-α局部炎症", 1, 1, frozen);
        }
    };

    /// <summary>按卡名结算。未登记的名字返回原状态（与旧 switch 的 default 一致）。</summary>
    public static WorldState Resolve(WorldState s, Cell cell, string name, IDeterministicRng rng, HexPosition? target = null, EntityId? targetCell = null)
        => Registry.TryGetValue(name, out var effect) ? effect(s, cell, rng, target, targetCell) : s;

    public static bool IsRegistered(string name) => Registry.ContainsKey(name);

    /// <summary>已登记效果的卡名集合（供契约测试核对目录覆盖）。</summary>
    internal static IReadOnlyCollection<string> RegisteredNames => Registry.Keys;

    // ── 抽卡 / 手牌 / 突变 / 打牌 ─────────────────────────────────────

    private const int DrawMaxPerTurn = 3;
    private const int ImmuneDrawCost = 5;
    private const int CancerDrawCost = 10;
    private const int MutateCost = 5;

    private static CardPool PoolFor(WorldState s, Cell c) => c.Faction == Faction.Cancer ? CardPool.Cancer :
        s.Players[c.OwnerSeat].ImmuneLevel switch
        {
            ImmuneLevel.I => CardPool.ImmuneI, ImmuneLevel.II => CardPool.ImmuneII,
            ImmuneLevel.III => CardPool.ImmuneIII, _ => CardPool.ImmuneX
        };

    /// <summary>抽卡合法性（PRD §193-199）：等级卡池、移除手中同名技能与已装备同名永久技能。</summary>
    /// <summary>
    /// 候选**必须按卡名码点序**：GD 的卡池是 `gen_card_data.py` 里 `sorted(cards)` 生成的 CARDS 表的文件序，
    /// 抽卡是「掷一个 1..total 的数、按这个顺序累减」—— 顺序不同，同一个骰子落到的就是另一张牌。
    /// L1 对拍第 10 步就是这么分叉的：GD 抽到【代谢适应】进手，C# 同一个骰抽到一张事件卡当场结算。
    /// 卡名全是 BMP 字符，C# 的 Ordinal（UTF-16 码元）与 Python 的码点序一致。
    /// </summary>
    internal static List<CardDefinition> EligibleCards(WorldState s, Cell cell)   // internal：对拍测试要拿它和 GD 卡表比顺序
        => CardCatalog.Pool(PoolFor(s, cell))
            .Where(CardImplementation.IsImplemented)
            .Where(d => !cell.Hand.Contains(d.Name) && !cell.Equipped.Contains(d.Name))
            .OrderBy(d => d.Name, StringComparer.Ordinal)
            .ToList();

    private static CardDefinition? PickWeighted(WorldState s, List<CardDefinition> eligible, IDeterministicRng rng)
    {
        if (eligible.Count == 0) return null;
        var phase = CancerPhase(s.Turn.WorldRound);
        var total = eligible.Sum(d => d.Weight(phase));
        if (total <= 0) return null;
        var roll = rng.NextInt(total);
        foreach (var d in eligible)
        {
            roll -= d.Weight(phase);
            if (roll < 0) return d;
        }
        return eligible[^1];
    }

    public static ValidationResult ValidateDraw(WorldState s, DrawDecision d)
    {
        if (s.Turn.Phase != Phase.PlayerAction) return new(false, "当前阶段不允许玩家操作");
        if (d.PlayerSeat != s.Turn.ActivePlayerSeat) return new(false, "不是该玩家的回合");
        if (!s.Players.TryGetValue(d.PlayerSeat, out var player) || !player.IsAlive) return new(false, "玩家已死亡或不存在");
        if (!s.Cells.TryGetValue(d.CellId, out var cell) || !cell.IsAlive || cell.OwnerSeat != d.PlayerSeat)
            return new(false, "细胞不存在或不可控制");
        if (cell.DrawsThisTurn >= DrawMaxPerTurn) return new(false, "本行动回合抽卡次数已用尽");
        var cost = cell.Faction == Faction.Cancer ? CancerDrawCost : ImmuneDrawCost;
        if (!Settlement.CanPay(cell.Energy, cost)) return new(false, "能量不足，非自毁费用必须保留正能量");
        if (EligibleCards(s, cell).Count == 0) return new(false, "当前卡池没有可抽取的卡牌");
        return new(true);
    }

    public static RulesResult Draw(WorldState s, DrawDecision d, IDeterministicRng rng)
    {
        var cell = s.Cells[d.CellId];
        var cost = cell.Faction == Faction.Cancer ? CancerDrawCost : ImmuneDrawCost;
        s = s.UpdateCell(cell.Id, cell.Copy(energy: cell.Energy - cost, draws: cell.DrawsThisTurn + 1));
        s = DrawOne(s, s.Cells[cell.Id], rng);
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    public static WorldState DrawOne(WorldState s, Cell cell, IDeterministicRng rng)
    {
        var def = PickWeighted(s, EligibleCards(s, cell), rng);
        if (def == null) return s;
        if (def.Category != CardCategory.Event) return AddToHand(s, cell, def.Name);
        // 抽到的事件卡立即结算，GD `draw()` 同样用 card_resolve_depth 包住（里头可能再抽一张，会套娃）
        s = s.WithTurn(s.Turn.WithCardResolveDepth(s.Turn.CardResolveDepth + 1));
        s = Resolve(s, s.Cells[cell.Id], def.Name, rng);
        return s.WithTurn(s.Turn.WithCardResolveDepth(s.Turn.CardResolveDepth - 1));
    }

    /// <summary>
    /// 弃置有**两路**，共用这一条谓词：
    /// 手牌超限挂起时的**强制**弃置（GD `cw_cards.gd:70 discard_to_limit`），
    /// 与行动栏里的**自愿**弃置（GD `cw_actions.gd:_discard_options`，不花钱、不计行动）。
    ///
    /// 挂起时只认那一席；没挂起就是自愿那路，阶段与轮次由 `DecisionRouter` 的前置守着
    /// （云端 PRD 2026-09-10 把「随时可弃」改成「只能在自己的行动回合弃」）。
    /// </summary>
    public static bool ValidateDiscard(WorldState s, DiscardDecision d)
    {
        if (s.Turn.PendingDiscardSeat is { } pending && pending != d.PlayerSeat) return false;
        if (s.Turn.PendingDiscardCell is { } pendingCell && pendingCell != d.CellId) return false;   // GD 只问超限的那一只
        if (!s.Cells.TryGetValue(d.CellId, out var cell) || !cell.IsAlive || cell.OwnerSeat != d.PlayerSeat) return false;
        return cell.Hand.Contains(d.Card);
    }

    public static RulesResult Discard(WorldState s, DiscardDecision d)
    {
        var cell = s.Cells[d.CellId];
        var hand = cell.Hand.ToList();
        hand.Remove(d.Card);
        cell = cell.Copy(hand: hand);
        s = s.UpdateCell(cell.Id, cell);
        // 摘挂起看的是**挂起的那只**降到上限没有（Validate 已把别只细胞的弃置拦在外面）
        if (hand.Count <= cell.HandMax && (s.Turn.PendingDiscardCell is not { } pendingCell || pendingCell == cell.Id))
            s = s.WithTurn(s.Turn.WithPendingDiscard(null));
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    public static ValidationResult ValidateMutate(WorldState s, MutateDecision d)
    {
        if (s.Turn.Phase != Phase.PlayerAction) return new(false, "当前阶段不允许玩家操作");
        if (d.PlayerSeat != s.Turn.ActivePlayerSeat) return new(false, "不是该玩家的回合");
        if (!s.Players.TryGetValue(d.PlayerSeat, out var player) || !player.IsAlive) return new(false, "玩家已死亡或不存在");
        if (!s.Cells.TryGetValue(d.CellId, out var cell) || !cell.IsAlive || cell.OwnerSeat != d.PlayerSeat)
            return new(false, "细胞不存在或不可控制");
        if (cell.Faction != Faction.Cancer) return new(false, "只有癌细胞可以【突变】");
        if (cell.MutateUsedThisRound) return new(false, "每个癌细胞每世界回合最多突变 1 次");
        if (!Settlement.CanPay(cell.Energy, MutateCost)) return new(false, "能量不足，非自毁费用必须保留正能量");
        return new(true);
    }

    public static RulesResult Mutate(WorldState s, MutateDecision d, IDeterministicRng rng)
    {
        s = ApplyMutationOutcome(s, d.CellId, rng.NextIntRange(1, 4), rng, charge: true);
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    /// <summary>
    /// 结算一次【突变】结果，**点数是 d3 的 1/2/3**（与 GD 的 `apply_mutation` 同一套）：
    /// 1 无事 / 2 抽卡并削 1 记忆 / 3 再扣 0.8 能量并削 2 记忆。
    /// </summary>
    private static WorldState ApplyMutationOutcome(WorldState s, EntityId cellId, int roll, IDeterministicRng rng, bool charge)
    {
        if (charge)
        {
            var current = s.Cells[cellId];
            s = s.UpdateCell(cellId, current.Copy(energy: current.Energy - MutateCost, mutateUsed: true));
        }
        if (roll == 2)
        {
            s = DrawOne(s, s.Cells[cellId], rng);
            s = ReduceMemory(s, 1);
        }
        else if (roll == 3)
        {
            // GD `apply_mutation` 直接 `energy -= MUTATE_EXTRA_LOSS`、**不进伤害管线**（cw_actions.gd:1392）：
            // 护盾、【标记】、【囊性护甲】【BCL-2抗凋亡】都不看它，扣到 0 以下就 kill。
            // 此前 C# 走 Damage：2p 第 52 步【突变】的自损把只挡免疫方的【DNA损伤修复】吃掉了（2026-09-17）
            var mutated = s.Cells[cellId];
            s = s.UpdateCell(cellId, mutated.Copy(energy: mutated.Energy - 8));   // MUTATE_EXTRA_LOSS = 0.8
            s = ReduceMemory(s, 2);
            if (s.Cells[cellId].Energy <= 0) s = Kill(s, cellId);
        }
        return s;
    }

    public static RulesResult ChooseMutation(WorldState s, ChooseMutationDecision d, IDeterministicRng rng)
    {
        var roll = d.Choice == 0 ? s.Turn.PendingMutationA : s.Turn.PendingMutationB;
        s = s.WithTurn(s.Turn.ClearPendingMutation());
        s = ApplyMutationOutcome(s, d.CellId, roll, rng, charge: false);
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    public static ValidationResult ValidatePlayCard(WorldState s, PlayCardDecision d)
    {
        if (s.Turn.Phase != Phase.PlayerAction) return new(false, "当前阶段不允许玩家操作");
        if (d.PlayerSeat != s.Turn.ActivePlayerSeat) return new(false, "不是该玩家的回合");
        if (!s.Players.TryGetValue(d.PlayerSeat, out var player) || !player.IsAlive) return new(false, "玩家已死亡或不存在");
        if (!s.Cells.TryGetValue(d.CellId, out var cell) || !cell.IsAlive || cell.OwnerSeat != d.PlayerSeat)
            return new(false, "细胞不存在或不可控制");
        if (!cell.Hand.Contains(d.Card)) return new(false, "手牌中没有该卡");
        var definitions = CardCatalog.ByCardName(d.Card).Where(x => x.Category != CardCategory.Event).ToArray();
        if (definitions.Length == 0 || definitions.All(x => !CardImplementation.IsImplemented(x))) return new(false, "该卡效果尚未实现");
        if (definitions.Any(x => x.Category == CardCategory.Permanent) && cell.Equipped.Contains(d.Card)) return new(false, "同名永久技能已装备");
        // 【炎症性趋化】的第 1 步落点烤在打出选项里，必须是一个合法的趋化落点 ——
        // 不在这里校验，`Available` 之外的调用方（AI / 对拍）就能递进来一个非法落点
        if (d.Card == "炎症性趋化" && (d.Target is not { } first || !CellRules.ChemotaxisSteps(s, cell).Contains(first)))
            return new(false, "【炎症性趋化】必须指定一个合法的第一步");
        // 【代谢耦联】：打出时就选定队友（GD 一个队友一条选项），随后的方向 / 档位走挂起态
        if (d.Card == "代谢耦联" && (d.TargetCell is not { } ally || !CoupleAllies(s, cell).Contains(ally)))
            return new(false, "【代谢耦联】必须指定一个付得起的队友");
        // 无目标但「打了什么都不发生」的卡在选项层就拦（GD hand_options 那几条闸：局部吞噬 / 溶酶体强化 / 克隆增殖 / TNF-α）
        if (Playable.TryGetValue(d.Card, out var playable) && !playable(s, cell))
            return new(false, $"【{d.Card}】此刻没有可作用的目标");
        // 带目标的卡（2026-09-17，GD hand_options 逐条对照）：目标必须在各自的候选表里，没给目标 = 非法。
        // 不在这里校验，Available 之外的调用方（AI / 对拍）就能递进来一个非法目标、让结算里静默吞掉
        if (TileTargeted.TryGetValue(d.Card, out var tilesOf) && (d.Target is not { } to || !tilesOf(s, cell).Contains(to)))
            return new(false, $"【{d.Card}】必须指定一个合法的目标格");
        if (CellTargeted.TryGetValue(d.Card, out var cellsOf) && (d.TargetCell is not { } tc || !cellsOf(s, cell).Contains(tc)))
            return new(false, $"【{d.Card}】必须指定一个合法的目标细胞");
        return new(true);
    }

    public static RulesResult PlayCard(WorldState s, PlayCardDecision d, IDeterministicRng rng)
    {
        var cell = s.Cells[d.CellId];
        var definition = CardCatalog.ByCardName(d.Card).First(x => x.Category != CardCategory.Event);
        if (definition.Category == CardCategory.Permanent)
        {
            // 永久技能：GD 在自己那条分支里打出即装备、即离手（cw_card_fx.gd:270 附近）
            var hand = cell.Hand.ToList();
            hand.Remove(d.Card);
            cell = cell.Copy(hand: hand);
            s = s.UpdateCell(cell.Id, cell);
            // 装备这一刻要**盖戳**（2026-09-15 补）：PRD:182-184「同一阶段内…同层级再按
            // 打出/装备的先后顺序」。永久技能与即时卡混在同一条「打出先后」队列里结算，
            // 所以用的是同一把尺（PlayCounter），对齐 GDScript 的 cw_card_fx.gd:275-276。
            // 此前 C# 只往 Equipped 里塞个名字、**没有任何时刻记录**，两张同阶段的永久技能排不出先后。
            var owner = s.Cells[cell.Id];
            var equipped = owner.Equipped.ToList();
            equipped.Add(d.Card);
            var stamp = owner.PlayCounter + 1;
            s = s.UpdateCell(cell.Id, owner.Copy(
                equipped: equipped,
                playCounter: stamp,
                equipSeq: owner.EquipSeq.Append(new KeyValuePair<string, int>(d.Card, stamp))
                    .ToDictionary(kv => kv.Key, kv => kv.Value)));
            // GD 在这条分支里就 `return`（cw_card_fx.gd:280）：永久卡不进结算、不碰 card_resolve_depth、不走细胞因子链
            return new(s, Array.Empty<IGameEvent>(), true);
        }
        var caller = s.Cells[cell.Id];
        // GD `play()` 用 card_resolve_depth 把整段结算包起来：卡牌引发的净化不给记忆
        s = s.WithTurn(s.Turn.WithCardResolveDepth(s.Turn.CardResolveDepth + 1));
        s = Resolve(s, caller, d.Card, rng, d.Target, d.TargetCell);
        s = s.WithTurn(s.Turn.WithCardResolveDepth(s.Turn.CardResolveDepth - 1));
        if (definition.Category != CardCategory.Instant) return new(s, Array.Empty<IGameEvent>(), true);
        // 即时卡**结算完**才离手、才走细胞因子链（GD `_resolve_played` 的尾巴，cw_card_fx.gd:399-402）。
        // 【炎症性趋化】的结算跨两个挂起决策点：挂起还在就先不收尾，等 DecisionRouter 在挂起被摘掉那一刻补上 ——
        // 不然第 2/3 步那两问上两边手牌差一张，手牌到上限时还少一个强制弃置决策点（L1 对拍会在那儿分叉）。
        // 结算里骨髓抽卡撑爆手牌的强制弃置也一样：GD 在结算内部 await 问完才 erase + 走链（cw_cards.gd:63 → cw_card_fx.gd:408-411），
        // 所以刚打出的这张还在手里、也在可弃选项里
        if (s.Turn.PendingChemotaxisCell == cell.Id || s.Turn.PendingCoupleCell == cell.Id || s.Turn.PendingRemodelCell == cell.Id || s.Turn.PendingDiscardSeat is not null || s.Turn.PendingLandCell is not null || s.Turn.PendingMarrow.Count > 0)
            return new(s.WithTurn(s.Turn.WithPendingCard(d.Card, cell.Id)), Array.Empty<IGameEvent>(), true);
        return new(FinishInstant(s, cell.Id, d.Card), Array.Empty<IGameEvent>(), true);
    }

    /// <summary>
    /// 即时卡的收尾：离手 + 【细胞因子网络】。与 GD 同序：先 `erase`，再 `_cytokine_chain`。
    /// 离手用「还在就摘」—— 结算中途的强制弃置可能已经把这张牌弃掉了（GD 的 `erase` 同样是空操作）。
    /// </summary>
    public static WorldState FinishInstant(WorldState s, EntityId cellId, string card)
    {
        s = s.WithTurn(s.Turn.WithPendingCard(null, null));
        var cell = s.Cells[cellId];
        if (cell.Hand.Contains(card))
        {
            var hand = cell.Hand.ToList();
            hand.Remove(card);   // GD `hand.erase(card)`：只摘第一张同名（此前 Where(x != card) 把同名全摘了）
            s = s.UpdateCell(cellId, cell.Copy(hand: hand));
        }
        // 【细胞因子网络】= GD `_cytokine_chain`（cw_card_fx.gd:1063-1073），只有免疫细胞打的即时卡走链（410 的阵营闸）：
        //   ① 先领别人的赏 —— 按 id 序遍历活着的**其他**免疫细胞，谁身上有「细胞因子网络·待发」就花掉（同名一起扣），**打出者** +0.5；
        //   ② 再给自己上膛 —— 装备了（被【中和抗体】压住不算）且身上还没有待发条目，才挂一条 uses=1、本世界回合到期的条目（占一个打出序号）。
        //   已上膛的条目不因装备者被中和而失效（GD 触发侧只调 spend_mods），装备者死了就哑（mods 随死亡消散）。
        // 此前 C# 是一个全局席位槽（2026-09-16 复核四条之二）：没有阵营闸、装备者一有技能就先上膛并 return（永远领不到赏）、
        // +5 给的是网络主人席位的第一只活细胞、永不过期、同席位另一只细胞打牌不触发、全场只能有一张上膛。
        if (s.Cells[cellId].Faction != Faction.Immune) return s;
        foreach (var other in s.Cells.Values.Where(c => c.IsAlive && c.Faction == Faction.Immune && c.Id != cellId).OrderBy(c => c.Id.Value).ToArray())
        {
            if (!CellRules.HasModifier(s.Cells[other.Id], CytokinePrimed)) continue;
            s = CellRules.SpendModifiers(s, other.Id, CytokinePrimed);
            s = s.UpdateCell(cellId, s.Cells[cellId].WithEnergy(s.Cells[cellId].Energy + SkillHeal));
        }
        var caller = s.Cells[cellId];
        if (RulePolicies.HasSkill(s, caller, "细胞因子网络") && !CellRules.HasModifier(caller, CytokinePrimed))
            s = CellRules.AddModifier(s, caller, new ActiveModifier(CytokinePrimed, ModifierTarget.Flag, ModifierStage.Add, SourceLayer.Skill, 0, 0, null, 1, ModifierDuration.Round));
        return s;
    }

    /// <summary>【细胞因子网络】的「上膛」条目名（GD `add_mod(cell, "细胞因子网络·待发", 1, "round")`）；进 L1 视图的 `mods`。</summary>
    internal const string CytokinePrimed = "细胞因子网络·待发";
    /// <summary>GD `CWData.SKILL_HEAL`：永久技能的那种「恢复 0.5」。</summary>
    private const int SkillHeal = 5;

    /// <summary>【代谢耦联】payer 付得起哪几档（GD `_couple_tiers`）：转 1.0/1.5/2.0，接收方得 1.2/2.0/2.5；付完要留正能量。</summary>
    internal static IReadOnlyList<(int Pay, int Get)> CoupleTiers(WorldState s, EntityId payer)
    {
        var energy = s.Cells[payer].Energy;
        return new[] { (Pay: 10, Get: 12), (Pay: 15, Get: 20), (Pay: 20, Get: 25) }.Where(t => energy > t.Pay).ToList();
    }

    /// <summary>能选的队友：同阵营、别的席位、活着，且**至少一侧**付得起最低一档（GD `hand_options` 那条）。</summary>
    internal static IReadOnlyList<EntityId> CoupleAllies(WorldState s, Cell cell)
        => Cells(s).Where(t => t.IsAlive && t.Faction == cell.Faction && t.OwnerSeat != cell.OwnerSeat
                && (CoupleTiers(s, cell.Id).Count > 0 || CoupleTiers(s, t.Id).Count > 0))
            .OrderBy(t => t.Id.Value).Select(t => t.Id).ToList();

    /// <summary>方向：送给（自己付）/ 索取（队友付），各自只在那一侧付得起时才出现（GD `_couple` 的 dirs）。</summary>
    internal static IReadOnlyList<(EntityId Payer, EntityId Getter)> CoupleDirections(WorldState s, EntityId cell, EntityId ally)
    {
        var dirs = new List<(EntityId Payer, EntityId Getter)>();
        if (CoupleTiers(s, cell).Count > 0) dirs.Add((cell, ally));
        if (CoupleTiers(s, ally).Count > 0) dirs.Add((ally, cell));
        return dirs;
    }

    /// <summary>档位选定：payer 付、getter 得，挂起摘掉（这张卡的收尾由 Execute 出口补）。付不出 = 落空。</summary>
    public static WorldState CoupleTransfer(WorldState s, EntityId payer, EntityId getter, int pay, int get)
    {
        s = s.WithTurn(s.Turn.WithPendingCouple(null, null, null));
        if (!Settlement.CanPay(s.Cells[payer].Energy, pay)) return s;
        s = s.UpdateCell(payer, s.Cells[payer].WithEnergy(s.Cells[payer].Energy - pay));
        return s.UpdateCell(getter, s.Cells[getter].WithEnergy(s.Cells[getter].Energy + get));
    }

    /// <summary>【癌症转移】的合法落点：两环内、盘上、**没有细胞占着**的任意格（不挑地形）。</summary>
    internal const int MetastasisRange = 2;

    // ======== 带目标的卡：候选目标的枚举（GD cw_card_fx.gd `hand_options` 逐条对照，2026-09-17）========
    // 一律「一个目标一条选项、没有候选就不出这张牌」（GD 没有「落空」那条路）；
    // 选项层（DecisionRouter.Available）、Validate、结算三处共用同一份表，判据只写一遍。

    /// <summary>需要选格的卡 → 候选表（`to=`）。</summary>
    internal static readonly IReadOnlyDictionary<string, Func<WorldState, Cell, IReadOnlyList<HexPosition>>> TileTargeted =
        new Dictionary<string, Func<WorldState, Cell, IReadOnlyList<HexPosition>>>(StringComparer.Ordinal)
        {
            ["基质降解"] = DegradeTargets,
            ["基质硬化"] = HardenTargets,
            ["基质重塑"] = RemodelTargets,
            ["放疗"] = (s, _) => RadiotherapyTargets(s),
            ["癌症转移"] = MetastasisTargets,
        };

    /// <summary>需要选细胞的卡 → 候选表（`cid=`，语义键里换算成席位）。</summary>
    internal static readonly IReadOnlyDictionary<string, Func<WorldState, Cell, IReadOnlyList<EntityId>>> CellTargeted =
        new Dictionary<string, Func<WorldState, Cell, IReadOnlyList<EntityId>>>(StringComparer.Ordinal)
        {
            ["交叉呈递"] = CrossPresentTargets,
            ["抗体依赖细胞毒作用"] = AdccTargets,
            ["IFN-γ高峰"] = IfnPeakTargets,
            ["免疫增援"] = ReinforceAllies,
            ["乳酸酸化"] = LacticAcidTargets,
            ["肿瘤细胞募集"] = RecruitTargets,
            ["肿瘤增援"] = TumorReinforceTargets,
            ["代谢耦联"] = CoupleAllies,
        };

    /// <summary>无目标卡的「有效果才出选项」闸（GD hand_options：候选为空 / 没效果就一条都不 append，落空的卡不该出现在行动栏里）。</summary>
    internal static readonly IReadOnlyDictionary<string, Func<WorldState, Cell, bool>> Playable =
        new Dictionary<string, Func<WorldState, Cell, bool>>(StringComparer.Ordinal)
        {
            ["局部吞噬"] = (s, c) => PhagocytosisTargets(s, c).Count > 0,
            ["溶酶体强化"] = (s, c) => AdjacentPlainCancerEmpty(s, c.Position).Count > 0,
            ["克隆增殖"] = (s, c) => ClonalGrowthTargets(s, c).Count > 0,
            ["TNF-α局部炎症"] = (s, c) => TnfHasEffect(s, c),
        };

    /// <summary>GD `_adjacent_plain_cancer_empty`：相邻（DIRS 序）、无细胞占据的**普通**癌组织。【溶酶体强化】【局部吞噬】共用。</summary>
    internal static IReadOnlyList<HexPosition> AdjacentPlainCancerEmpty(WorldState s, HexPosition pos)
        => GdNeighbors(s, pos).Where(n => s.Board.Tissues[n] is { State: TissueState.Cancer, OccupyingCell: null }).ToList();

    /// <summary>GD `_phagocytosis_targets`：与 `_adjacent_plain_cancer_empty` 同一条规则（不看黏液）。</summary>
    internal static IReadOnlyList<HexPosition> PhagocytosisTargets(WorldState s, Cell cell) => AdjacentPlainCancerEmpty(s, cell.Position);

    /// <summary>GD `_clonal_growth_targets`：相邻健康组织，且**没有免疫细胞**站着（癌细胞站着的照样算）。</summary>
    internal static IReadOnlyList<HexPosition> ClonalGrowthTargets(WorldState s, Cell cell)
        => GdNeighbors(s, cell.Position)
            .Where(n => s.Board.Tissues[n].State == TissueState.Healthy && s.GetCellAt(n) is not { IsAlive: true, Faction: Faction.Immune })
            .ToList();

    /// <summary>GD `_tnf_has_effect`：自身格 + 相邻格里有普通癌组织或活着的癌细胞。</summary>
    internal static bool TnfHasEffect(WorldState s, Cell cell)
        => new[] { cell.Position }.Concat(GdNeighbors(s, cell.Position))
            .Any(p => s.Board.Tissues[p].State == TissueState.Cancer || s.GetCellAt(p) is { IsAlive: true, Faction: Faction.Cancer });

    /// <summary>【基质降解】：相邻（GD DIRS 序）的固化癌组织，不看占据。</summary>
    internal static IReadOnlyList<HexPosition> DegradeTargets(WorldState s, Cell cell)
        => GdNeighbors(s, cell.Position).Where(n => s.Board.Tissues[n].State == TissueState.SolidifiedCancer).ToList();

    /// <summary>【基质硬化】：脚下 + 相邻的**普通**癌组织，且能加固化计数 —— 新生保护（旋钮）、TNF-α 冻结、血管三道闸
    /// 都在**选项层**拦（GD 注释点名：只在结算处拦就是「卡吃掉、什么也没发生」）。</summary>
    internal static IReadOnlyList<HexPosition> HardenTargets(WorldState s, Cell cell)
        => new[] { cell.Position }.Concat(GdNeighbors(s, cell.Position))
            .Where(p => s.Board.Tissues[p] is { State: TissueState.Cancer } t
                        && !(s.Tuning.NewbornProtect && t.Newborn)
                        && !WorldEffects.SolidFrozen(s, p)
                        && t.Type != TissueType.BloodVessel)
            .ToList();

    /// <summary>【基质重塑】第一格：2 环内（含脚下）的固化癌组织。</summary>
    internal static IReadOnlyList<HexPosition> RemodelTargets(WorldState s, Cell cell)
        => Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer && t.Position.DistanceTo(cell.Position) <= 2).Select(t => t.Position).ToList();

    /// <summary>GD `_remodel_heal_cands`（cw_card_fx.gd:974-986）：按 [第 1 格, 第 2 格] 顺序，每格展开「自身 + DIRS 序相邻格」，跨格去重（**先记 seen 再判谓词**），
    /// 留下无细胞占据的普通癌组织。施法者的位置不参与 —— 此前 C# 的候选域「距施法者 ≤2 或挨着任一固化格」是它的严格超集。</summary>
    internal static IReadOnlyList<HexPosition> RemodelHealCands(WorldState s, HexPosition first, HexPosition? second)
    {
        var seen = new HashSet<HexPosition>();
        var cands = new List<HexPosition>();
        foreach (var b in second is { } sec ? new[] { first, sec } : new[] { first })
            foreach (var c in new[] { b }.Concat(GdNeighbors(s, b)))
            {
                if (!seen.Add(c)) continue;
                if (s.Board.Tissues[c].State == TissueState.Cancer && s.Board.Tissues[c].OccupyingCell == null) cands.Add(c);
            }
        return cands;
    }

    /// <summary>【基质重塑】当前这一问的候选：Step 0 = 重算后的 2 环内固化（GD 939，第 1 格已不是固化，自动出局）；Step 1/2 = <see cref="RemodelHealCands"/>。</summary>
    internal static IReadOnlyList<HexPosition> RemodelOptions(WorldState s)
        => s.Turn.PendingRemodelStep == 0
            ? RemodelTargets(s, s.Cells[s.Turn.PendingRemodelCell!.Value])
            : RemodelHealCands(s, s.Turn.PendingRemodelFirst!.Value, s.Turn.PendingRemodelSecond);

    /// <summary>【基质重塑】答一格：Step 0 再拆（crack_to_cancer）→ 进第 1 次转健康；Step 1/2 转健康（to_healthy）→ 下一问。零随机。</summary>
    internal static WorldState RemodelPick(WorldState s, HexPosition target)
    {
        var t = s.Turn;
        if (t.PendingRemodelStep == 0)
            return CrackToCancer(s, target).WithTurn(t.WithPendingRemodel(t.PendingRemodelCell, t.PendingRemodelFirst, target, 1));
        return ToHealthy(s, target).WithTurn(t.WithPendingRemodel(t.PendingRemodelCell, t.PendingRemodelFirst, t.PendingRemodelSecond, t.PendingRemodelStep + 1));
    }

    /// <summary>【基质重塑】的「停」：Step 0「只拆这一格」→ 直接进转健康那一段；Step 1/2「到此为止」→ 摘挂起。都不是取消。</summary>
    internal static WorldState RemodelStop(WorldState s)
    {
        var t = s.Turn;
        return t.PendingRemodelStep == 0
            ? s.WithTurn(t.WithPendingRemodel(t.PendingRemodelCell, t.PendingRemodelFirst, null, 1))
            : s.WithTurn(t.WithPendingRemodel(null, null, null, 0));
    }

    /// <summary>GD `_remodel` 的两道「候选为空就不问」闸（941 与 955-956，互相独立、可以连着命中）+ 「两格都转完」：出口归一化，**跑到稳定**。
    /// 单趟判断会把状态停在「Available 为空」的死点上。</summary>
    internal static WorldState NormalizeRemodel(WorldState s)
    {
        while (s.Turn.PendingRemodelCell is not null)
        {
            var t = s.Turn;
            var options = t.PendingRemodelStep >= 3 ? Array.Empty<HexPosition>() : RemodelOptions(s);
            if (options.Count > 0) return s;
            s = s.WithTurn(t.PendingRemodelStep == 0
                ? t.WithPendingRemodel(t.PendingRemodelCell, t.PendingRemodelFirst, null, 1)
                : t.WithPendingRemodel(null, null, null, 0));
        }
        return s;
    }

    /// <summary>【放疗】：全盘任意癌性组织（含固化）作起点，不限范围。</summary>
    internal static IReadOnlyList<HexPosition> RadiotherapyTargets(WorldState s)
        => Tiles(s).Where(Cancerous).Select(t => t.Position).ToList();

    /// <summary>【交叉呈递】：N 环内、活着、**还没带标记**、且**本回合没给过标记**的癌细胞（ApplyMark 对后者直接 return，出了选项就是空打）；
    /// N = 树突 4 / 其余 2。</summary>
    internal static IReadOnlyList<EntityId> CrossPresentTargets(WorldState s, Cell cell)
    {
        var rings = cell.Type == CellType.Dendritic ? 4 : 2;
        return Cells(s).Where(t => t.IsAlive && t.Faction == Faction.Cancer && !t.Marked && t.MarkRound != s.Turn.WorldRound
                                   && t.Position.DistanceTo(cell.Position) <= rings)
                       .Select(t => t.Id).ToList();
    }

    /// <summary>【抗体依赖细胞毒作用】：2 环内、与健康组织相邻的癌细胞。射程恒为 2，B 细胞只改伤害。</summary>
    internal static IReadOnlyList<EntityId> AdccTargets(WorldState s, Cell cell)
        => Cells(s).Where(t => t.IsAlive && t.Faction == Faction.Cancer && t.Position.DistanceTo(cell.Position) <= 2 && AdjacentHealthy(s, t.Position))
                   .Select(t => t.Id).ToList();

    /// <summary>【IFN-γ高峰】：全场任意存活免疫细胞（**含自己**、不限距离），且其 2 环内这一下不会完全落空。</summary>
    internal static IReadOnlyList<EntityId> IfnPeakTargets(WorldState s, Cell cell)
        => Cells(s).Where(t => t.IsAlive && t.Faction == Faction.Immune && IfnHasEffect(s, t.Position)).Select(t => t.Id).ToList();

    /// <summary>GD `_ifn_has_effect`：2 环内有存活癌细胞，或有 solid&gt;0 的**普通**癌组织（固化格不算，它的计数不再降）。</summary>
    internal static bool IfnHasEffect(WorldState s, HexPosition center)
        => Cells(s).Any(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(center) <= 2)
        || Tiles(s).Any(t => t.State == TissueState.Cancer && t.SolidificationCount > 0 && t.Position.DistanceTo(center) <= 2);

    /// <summary>【免疫增援】：**别的席位**的存活免疫细胞，且其 2 环内有无细胞占据的健康组织（以对方为心逐个判）。</summary>
    internal static IReadOnlyList<EntityId> ReinforceAllies(WorldState s, Cell cell)
        => Cells(s).Where(t => t.IsAlive && t.Faction == Faction.Immune && t.OwnerSeat != cell.OwnerSeat && EmptyHealthyWithin(s, t.Position, 2).Count > 0)
                   .Select(t => t.Id).ToList();

    /// <summary>【乳酸酸化】：自身**相邻一格**上的存活免疫细胞（GD 用 neighbors，不含中心格）。</summary>
    internal static IReadOnlyList<EntityId> LacticAcidTargets(WorldState s, Cell cell)
        => Cells(s).Where(t => t.IsAlive && t.Faction == Faction.Immune && t.Position.DistanceTo(cell.Position) == 1).Select(t => t.Id).ToList();

    /// <summary>【肿瘤细胞募集】/【肿瘤增援】的落点半径：GD `[3, 2, 2][_phase()]`。</summary>
    internal static int TumorTeleportRings(WorldState s) => CancerPhase(s.Turn.WorldRound) == 0 ? 3 : 2;

    /// <summary>【肿瘤细胞募集】：先以**施法者**为心判一次有没有落点（一次全局闸），有才列出所有别席位的活癌细胞（不限距离）。</summary>
    internal static IReadOnlyList<EntityId> RecruitTargets(WorldState s, Cell cell)
        => CancerousLandings(s, cell.Position, TumorTeleportRings(s)).Count == 0
            ? Array.Empty<EntityId>()
            : Cells(s).Where(t => t.IsAlive && t.Faction == Faction.Cancer && t.OwnerSeat != cell.OwnerSeat).Select(t => t.Id).ToList();

    /// <summary>【肿瘤增援】：别席位的活癌细胞，且**以该目标为心** N 环内有落点（逐目标判）—— 与【肿瘤细胞募集】互为镜像，别合并。</summary>
    internal static IReadOnlyList<EntityId> TumorReinforceTargets(WorldState s, Cell cell)
        => Cells(s).Where(t => t.IsAlive && t.Faction == Faction.Cancer && t.OwnerSeat != cell.OwnerSeat
                            && CancerousLandings(s, t.Position, TumorTeleportRings(s)).Count > 0)
                   .Select(t => t.Id).ToList();

    /// <summary>GD `_ifn_burst`：事件卡【IFN-γ释放】（圆心 = 自己）与技能卡【IFN-γ高峰】（圆心 = 所选免疫细胞）共用同一份。
    /// 先伤害后降固化，顺序别反；固化只降**普通**癌组织。零随机。</summary>
    private static WorldState IfnBurst(WorldState s, HexPosition center)
    {
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(center) <= 2).ToArray())
            s = Damage(s, c.Id, 10, LossSource.ImmuneEffect);   // 1.0 能量（十分位）
        foreach (var t in Tiles(s).Where(t => t.State == TissueState.Cancer && t.Position.DistanceTo(center) <= 2).ToArray())
            s = s.UpdateTissueSolidification(t.Position, Math.Max(0, t.SolidificationCount - 10));   // 固化计数 -1.0
        return s;
    }

    /// <summary>GD `CWTissue.to_cancer(tile, newborn)`：转成普通癌组织 —— solid / necrosis / ossify 一起清，newborn 按参数，库存不动。</summary>
    internal static WorldState ToCancer(WorldState s, HexPosition pos, bool newborn)
        => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithState(TissueState.Cancer).WithSolidificationCount(0).WithNewborn(newborn).WithNecrosis(0).WithOssifyAt(0)));

    /// <summary>GD `CWTissue.crack_to_cancer`：固化格拆回普通癌组织（= to_cancer 且不算新生）。</summary>
    internal static WorldState CrackToCancer(WorldState s, HexPosition pos) => ToCancer(s, pos, newborn: false);

    /// <summary>GD `CWTissue.to_healthy`（cw_tissue.gd:10-15）：转健康 —— solid / newborn / necrosis / ossify 四项全清，库存不动。
    /// 与 <see cref="ToCancer"/> 一起是 C# 侧组织翻面的**唯一入口**：`WithState` 只按目标状态选择性清字段、从不碰 necrosis，
    /// 此前 Move / Teleport 两条定殖路和净化路都是裸 `UpdateTissueState`，定殖不清坏死（GD `is_valid`：癌组织身上永远没有坏死），
    /// 2p 夹具里没坏死源才一直没撞上（2026-09-17 晚）。</summary>
    internal static WorldState ToHealthy(WorldState s, HexPosition pos)
        => s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithState(TissueState.Healthy).WithSolidificationCount(0).WithNewborn(false).WithNecrosis(0).WithOssifyAt(0)));

    private const int RadioRegionSize = 10;   // CWData.RADIO_REGION（2026-09-09 由 15 改 10）
    private const int NecrosisRadio = 2;      // CWData.NECROSIS_RADIO

    /// <summary>GD `CWTissue.to_necrotic`：先 to_healthy（solid / newborn / ossify 清零），坏死时长取 max(原, rounds)，
    /// 再把代谢核心 / 骨髓的库存与产出进度一起清掉（Kevin 2026-09-13 issue #31）。区域里的健康格也照走这一遭。</summary>
    internal static WorldState Necrotize(WorldState s, HexPosition pos, int rounds)
    {
        var t = s.Board.Tissues[pos];
        var dead = t.WithState(TissueState.Healthy).WithNecrosis(Math.Max(t.NecrosisRounds, rounds)).WithProductionCounter(0);
        if (t.Charge is not null) dead = dead.WithCharge(0);
        return s.WithBoard(s.Board.UpdateTissue(pos, dead));
    }

    internal static IReadOnlyList<HexPosition> MetastasisTargets(WorldState s, Cell cell)
        => RulePolicies.Tiles(s)
            .Where(t => t.Position.DistanceTo(cell.Position) <= MetastasisRange && t.OccupyingCell == null)
            .Select(t => t.Position)
            .OrderBy(p => p.Q).ThenBy(p => p.R)
            .ToArray();
}
