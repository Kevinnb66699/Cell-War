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
        ["局部吞噬"] = (s, cell, rng, target, targetCell) =>
        {
            var targets = cell.Position.GetNeighbors()
                .Where(n => s.Board.Tissues.TryGetValue(n, out var t) && t.State == TissueState.Cancer && t.OccupyingCell == null && !t.Mucus)
                .ToArray();
            if (targets.Length > 0)
            {
                s = s.UpdateTissueState(targets[rng.NextInt(targets.Length)], TissueState.Healthy);
                s = AddMemory(s, 1);
            }
            return s;
        },
        ["基质降解"] = (s, cell, rng, target, targetCell) =>
        {
            var targets = cell.Position.GetNeighbors()
                .Where(n => s.Board.Tissues.TryGetValue(n, out var t) && t.State == TissueState.SolidifiedCancer).ToArray();
            if (targets.Length > 0)
            {
                var pick = targets[rng.NextInt(targets.Length)];
                s = s.UpdateTissueState(pick, TissueState.Cancer).UpdateTissueSolidification(pick, 0);
            }
            return s;
        },
        ["溶酶体强化"] = (s, cell, rng, target, targetCell) =>
        {
            var targets = cell.Position.GetNeighbors()
                .Where(n => s.Board.Tissues.TryGetValue(n, out var t) && t.State == TissueState.Cancer && t.OccupyingCell == null && !t.Mucus)
                .ToArray();
            foreach (var pick in rng.Shuffle(targets).Take(4))
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
            foreach (var t in Tiles(s).Where(t => t.Type == TissueType.BoneMarrow && t.State == TissueState.Healthy && (t.Charge ?? 0) < BoneMarrowStoreMax).ToArray())
                s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithCharge(BoneMarrowStoreMax)));
            return s;
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
            foreach (var pick in rng.Shuffle(candidates).Take(5))
                s = s.UpdateTissueState(pick.Position, TissueState.Healthy);
            return s;
        },
        ["IFN-γ释放"] = (s, cell, rng, target, targetCell) =>
        {
            foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(cell.Position) <= 2).ToArray())
                s = Damage(s, c.Id, 10);   // 1.0 能量（十分位）
            foreach (var t in Tiles(s).Where(t => t.State == TissueState.Cancer && t.Position.DistanceTo(cell.Position) <= 2).ToArray())
                s = s.UpdateTissueSolidification(t.Position, Math.Max(0, t.SolidificationCount - 10));   // 固化计数 -1.0
            return s;
        },
        ["糖酵解爆发"] = (s, cell, rng, target, targetCell) =>
        {
            s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + AnaerobicShare(s, cell)));
            return s;
        },
        ["基质稳定"] = (s, cell, rng, target, targetCell) => s.WithTurn(s.Turn.Copy(pausedDecay: s.Turn.WorldRound)),
        ["TGF-β释放"] = (s, cell, rng, target, targetCell) => s.WithTurn(s.Turn.Copy(tgf: s.Turn.TgfStacks + 1)),
        ["缺氧适应"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("缺氧适应", ModifierTarget.EnergyLoss, ModifierStage.Subtract, SourceLayer.Card, 0, 10, 0, 1, ModifierDuration.Game));   // 缺氧适应：挡下 1.0（原 1 = 0.1）
            return s;
        },
        ["DNA损伤修复"] = (s, cell, rng, target, targetCell) =>
        {
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
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Immune
                && t.Position.DistanceTo(cell.Position) <= 1)
            {
                var loss = CancerPhase(s.Turn.WorldRound) switch { 0 => 8, 1 => 15, _ => 20 };
                if (AdjacentCancerous(s, t.Position, 3)) loss += 5;
                s = Damage(s, tid, loss);
            }
            return s;
        },
        ["基质硬化"] = (s, cell, rng, target, targetCell) =>
        {
            if (target is { } pos && pos.DistanceTo(cell.Position) <= 1 && s.Board.Tissues.TryGetValue(pos, out var t) && t.State == TissueState.Cancer)
            {
                var add = CancerPhase(s.Turn.WorldRound) switch { 0 => 10, 1 => 15, _ => 20 };
                s = s.UpdateTissueSolidification(pos, t.SolidificationCount + add);
            }
            return s;
        },
        ["交叉呈递"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Cancer
                && t.Position.DistanceTo(cell.Position) <= 2)
                s = ApplyMark(s, tid, s.Cells[cell.Id]);
            return s;
        },
        ["抗体依赖细胞毒作用"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Cancer
                && t.Position.DistanceTo(cell.Position) <= 2 && AdjacentHealthy(s, t.Position))
                s = Damage(s, tid, cell.Type == CellType.BCell ? 15 : 10);
            return s;
        },
        ["IFN-γ高峰"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Immune)
            {
                foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(t.Position) <= 2).ToArray())
                    s = Damage(s, c.Id, 10);   // IFN-γ高峰：1.0 能量（原 1 = 0.1）
                foreach (var tile in Tiles(s).Where(x => x.State == TissueState.Cancer && x.Position.DistanceTo(t.Position) <= 2).ToArray())
                    s = s.UpdateTissueSolidification(tile.Position, Math.Max(0, tile.SolidificationCount - 10));
            }
            return s;
        },
        ["免疫风暴"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Immune)
            {
                foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(t.Position) <= 2).ToArray())
                    s = Damage(s, c.Id, 10);   // 免疫风暴：1.0 能量（原 1 = 0.1）
                foreach (var tile in Tiles(s).Where(x => x.State == TissueState.Cancer && x.OccupyingCell == null && x.Position.DistanceTo(t.Position) <= 2).ToArray())
                    s = s.UpdateTissueState(tile.Position, TissueState.Healthy);
            }
            return s;
        },
        ["免疫增援"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Immune
                && RandomHealthyWithin(s, t.Position, 2, rng) is { } dest)
                s = Teleport(s, cell.Id, dest);
            return s;
        },
        ["肿瘤细胞募集"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Cancer
                && RandomCancerousWithin(s, cell.Position, CancerPhase(s.Turn.WorldRound) switch { 0 => 3, 1 => 2, _ => 2 }, rng) is { } dest)
                s = Teleport(s, tid, dest);
            return s;
        },
        ["肿瘤增援"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.Faction == Faction.Cancer
                && RandomCancerousWithin(s, t.Position, CancerPhase(s.Turn.WorldRound) switch { 0 => 3, 1 => 2, _ => 2 }, rng) is { } dest)
                s = Teleport(s, cell.Id, dest);
            return s;
        },
        ["代谢耦联"] = (s, cell, rng, target, targetCell) =>
        {
            if (targetCell is { } tid && s.Cells.TryGetValue(tid, out var t) && t.IsAlive && t.OwnerSeat != cell.OwnerSeat
                && t.Faction == cell.Faction)
            {
                var phase = CancerPhase(s.Turn.WorldRound);
                var send = new[] { 10, 15, 20 }[phase];
                var receive = new[] { 12, 20, 25 }[phase];
                send = Math.Min(send, s.Cells[cell.Id].Energy);
                s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy - send));
                s = s.UpdateCell(tid, s.Cells[tid].WithEnergy(s.Cells[tid].Energy + receive));
            }
            return s;
        },
        ["基质重塑"] = (s, cell, rng, target, targetCell) =>
        {
            var solidified = Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer && t.Position.DistanceTo(cell.Position) <= 2)
                .Select(t => t.Position).ToList();
            if (target is { } chosen && solidified.Remove(chosen)) solidified.Insert(0, chosen);
            foreach (var pick in solidified.Take(2))
                s = s.UpdateTissueState(pick, TissueState.Cancer).UpdateTissueSolidification(pick, 0);
            var ordinary = Tiles(s).Where(t => t.State == TissueState.Cancer && t.OccupyingCell == null &&
                    (t.Position.DistanceTo(cell.Position) <= 2 || t.Position.GetNeighbors().Any(n => solidified.Contains(n))))
                .Select(t => t.Position).ToArray();
            foreach (var pick in rng.Shuffle(ordinary).Take(2))
                s = s.UpdateTissueState(pick, TissueState.Healthy);
            return s;
        },
        // 【癌症转移】（PRD:1465）：「选择两环内任意格子传送，正常触发【定殖】」。
        // 「任意格子」不挑地形（健康 / 癌 / 固化都行）；唯一限制是**没有细胞占着** ——
        // 一格只能站一个，所以自己所在的中心格也自动被排除。
        // 「正常触发【定殖】」= 走 CellRules.Teleport：癌细胞落到健康组织上会把它转成
        // 新生癌组织，与 GDScript 侧 enter_tile 同口径。
        // 合法落点的枚举在 DecisionRouter（这张卡是 68 张里唯一需要选格的卡牌）。
        ["癌症转移"] = (s, cell, rng, target, targetCell) =>
            target is { } dest && MetastasisTargets(s, cell).Contains(dest)
                ? CellRules.Teleport(s, cell.Id, dest)
                : s,
        ["放疗"] = (s, cell, rng, target, targetCell) =>
        {
            var start = target ?? cell.Position;
            if (s.Board.Tissues.TryGetValue(start, out var st) && Cancerous(st))
            {
                var region = ConnectedRegion(s, start, 10, rng);
                foreach (var pos in region)
                {
                    if (s.Board.Tissues[pos].State != TissueState.Healthy)
                        s = s.UpdateTissueState(pos, TissueState.Healthy);
                    s = s.WithBoard(s.Board.UpdateTissue(pos, s.Board.Tissues[pos].WithNecrosis(2)));
                }
            }
            return s;
        },
        ["克隆增殖"] = (s, cell, rng, target, targetCell) =>
        {
            var count = CancerPhase(s.Turn.WorldRound) + 1;
            var targets = cell.Position.GetNeighbors()
                .Where(n => s.Board.Tissues.TryGetValue(n, out var t) && t.State == TissueState.Healthy && t.OccupyingCell == null)
                .ToArray();
            foreach (var pick in rng.Shuffle(targets).Take(count))
                s = s.UpdateTissueState(pick, TissueState.Cancer);
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
                    s = Damage(s, c.Id, 5);
            }
            return s;
        },
        ["趋化募集"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("趋化募集", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Card, 0, 0, null, 2, ModifierDuration.Turn, ModifierRequirement.MoveToHealthy));
            return s;
        },
        ["效应细胞浸润"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("效应细胞浸润", ModifierTarget.Move, ModifierStage.Free, SourceLayer.Card, 0, 0, null, 2, ModifierDuration.Turn));
            return s;
        },
        ["炎症性趋化"] = (s, cell, rng, target, targetCell) =>
        {
            s = AddModifier(s, s.Cells[cell.Id], new("炎症性趋化", ModifierTarget.Move, ModifierStage.Replace, SourceLayer.Card, 0, 2, null, 3, ModifierDuration.Turn));
            return s;
        },
        ["基因组不稳定"] = (s, cell, rng, target, targetCell) =>
        {
            var a = rng.NextInt(3);
            var b = rng.NextInt(3);
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
            foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && c.Position.DistanceTo(cell.Position) <= 1).ToArray())
                s = Damage(s, c.Id, 10);   // TNF-α局部炎症：1.0 能量（原 1 = 0.1）
            foreach (var tile in Tiles(s).Where(t => t.State == TissueState.Cancer && t.Position.DistanceTo(cell.Position) <= 1).ToArray())
            {
                s = s.UpdateTissueSolidification(tile.Position, Math.Max(0, tile.SolidificationCount - 10));
                s = s.WithBoard(s.Board.UpdateTissue(tile.Position, s.Board.Tissues[tile.Position].WithSolidLockRound(s.Turn.WorldRound)));
            }
            return s;
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
    private static List<CardDefinition> EligibleCards(WorldState s, Cell cell)
        => CardCatalog.Pool(PoolFor(s, cell))
            .Where(CardImplementation.IsImplemented)
            .Where(d => !cell.Hand.Contains(d.Name) && !cell.Equipped.Contains(d.Name))
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
        return def.Category == CardCategory.Event
            ? Resolve(s, s.Cells[cell.Id], def.Name, rng)
            : AddToHand(s, cell, def.Name);
    }

    public static bool ValidateDiscard(WorldState s, DiscardDecision d)
    {
        if (s.Turn.PendingDiscardSeat != d.PlayerSeat) return false;
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
        if (hand.Count <= cell.HandMax) s = s.WithTurn(s.Turn.WithPendingDiscard(null));
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
        s = ApplyMutationOutcome(s, d.CellId, rng.NextInt(3), rng, charge: true);
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    /// <summary>结算一次【突变】结果：0 无事 / 1 抽卡并削 1 记忆 / 2 再扣 0.8 能量并削 2 记忆。</summary>
    private static WorldState ApplyMutationOutcome(WorldState s, EntityId cellId, int roll, IDeterministicRng rng, bool charge)
    {
        if (charge)
        {
            var current = s.Cells[cellId];
            s = s.UpdateCell(cellId, current.Copy(energy: current.Energy - MutateCost, mutateUsed: true));
        }
        if (roll == 1)
        {
            s = DrawOne(s, s.Cells[cellId], rng);
            s = ReduceMemory(s, 1);
        }
        else if (roll == 2)
        {
            s = Damage(s, cellId, 8);
            s = ReduceMemory(s, 2);
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
        return new(true);
    }

    public static RulesResult PlayCard(WorldState s, PlayCardDecision d, IDeterministicRng rng)
    {
        var cell = s.Cells[d.CellId];
        var definition = CardCatalog.ByCardName(d.Card).First(x => x.Category != CardCategory.Event);
        var hand = cell.Hand.ToList();
        hand.Remove(d.Card);
        cell = cell.Copy(hand: hand);
        s = s.UpdateCell(cell.Id, cell);
        if (definition.Category == CardCategory.Permanent)
        {
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
        }
        var caller = s.Cells[cell.Id];
        var isInstant = definition.Category == CardCategory.Instant;
        var networkOwner = s.Turn.CytokineNetworkSeat;
        s = Resolve(s, caller, d.Card, rng, d.Target, d.TargetCell);
        // 【细胞因子网络】：本回合下一名其他免疫细胞发动即时技能后恢复 0.5
        if (isInstant && RulePolicies.HasSkill(s, caller, "细胞因子网络"))
            s = s.WithTurn(s.Turn.WithCytokineNetwork(caller.OwnerSeat));
        else if (isInstant && networkOwner >= 0 && networkOwner != caller.OwnerSeat)
        {
            var beneficiary = s.Cells.Values.FirstOrDefault(x => x.IsAlive && x.Faction == Faction.Immune && x.OwnerSeat == networkOwner);
            if (beneficiary != null) s = s.UpdateCell(beneficiary.Id, s.Cells[beneficiary.Id].WithEnergy(s.Cells[beneficiary.Id].Energy + 5));
            s = s.WithTurn(s.Turn.WithCytokineNetwork(-1));
        }
        return new(s, Array.Empty<IGameEvent>(), true);
    }

    /// <summary>【癌症转移】的合法落点：两环内、盘上、**没有细胞占着**的任意格（不挑地形）。</summary>
    internal const int MetastasisRange = 2;

    internal static IReadOnlyList<HexPosition> MetastasisTargets(WorldState s, Cell cell)
        => RulePolicies.Tiles(s)
            .Where(t => t.Position.DistanceTo(cell.Position) <= MetastasisRange && t.OccupyingCell == null)
            .Select(t => t.Position)
            .OrderBy(p => p.Q).ThenBy(p => p.R)
            .ToArray();
}
