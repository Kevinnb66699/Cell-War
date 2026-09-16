using static CellWar.Core.CellRules;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 棋盘与组织演化所有权域（对应三层设计的 BoardRules）：
/// S 阶段特殊组织生产/血管传送，E 阶段微环境压迫、增生、侵蚀、无氧呼吸、蹲守净化、固化与特殊状态计时。
/// 只做棋盘/组织层演化，不决定阶段转换与胜负（分别由 PhaseRules 编排与 <see cref="OutcomeRules"/> 判定）。
/// </summary>
internal static class BoardRules
{
    /// <summary>S.1/S.2：特殊组织生产（含产出即收取）与血管传送。</summary>
    public static WorldState ProduceAndTransport(WorldState s)
    {
        s = ResetRoundFlags(s);
        foreach (var t in Tiles(s))
        {
            var current = t.Charge ?? 0;
            var prod = t.ProductionCounter;
            var nextProd = prod;
            var gain = 0;
            switch (t.Type)
            {
                case TissueType.MetabolicCore:
                    if (t.State == TissueState.Healthy)
                    {
                        nextProd = prod + 1;
                        if (nextProd >= 2) { nextProd = 0; gain = 10; }
                    }
                    else gain = 4;  // 癌性：每世界回合 +0.4
                    break;
                case TissueType.BoneMarrow:
                    nextProd = prod + 1;
                    if (nextProd >= (t.State == TissueState.Healthy ? 3 : 2)) { nextProd = 0; gain = 1; }
                    break;
            }
            if (nextProd == prod && gain == 0) continue;
            var cap = t.Type == TissueType.MetabolicCore ? MetabolicCoreStoreMax : BoneMarrowStoreMax;
            var charge = Math.Min(cap, current + gain);
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithProductionCounter(nextProd).WithCharge(charge)));
            // 产出瞬间站在其上的细胞立即收取（旧实现 collect_special）
            if (charge > 0 && s.GetCellAt(t.Position) is { IsAlive: true } occupant)
                s = CollectEnergy(s, occupant.Id);
        }
        return Transport(s);
    }

    public static WorldState Transport(WorldState s)
    {
        var vessels = Tiles(s).Where(t => t.Type == TissueType.BloodVessel).ToArray();
        if (vessels.Length != 2) return s;
        var a = s.GetCellAt(vessels[0].Position);
        var b = s.GetCellAt(vessels[1].Position);
        if (a != null && b != null && a.Faction != b.Faction) return s;
        s = s.UpdateTissueOccupant(vessels[0].Position, b?.Id).UpdateTissueOccupant(vessels[1].Position, a?.Id);
        if (a != null) s = s.UpdateCell(a.Id, a.WithPosition(vessels[1].Position));
        if (b != null) s = s.UpdateCell(b.Id, b.WithPosition(vessels[0].Position));
        foreach (var c in new[] { a, b }.OfType<Cell>())
        {
            var position = s.Cells[c.Id].Position;
            if (c.Faction == Faction.Cancer && s.Board.Tissues[position].State == TissueState.Healthy)
            {
                s = s.UpdateTissueState(position, TissueState.Cancer);
                s = s.WithBoard(s.Board.UpdateTissue(position, s.Board.Tissues[position].WithNewborn(true)));
            }
            else if (c.Faction == Faction.Immune && s.Board.Tissues[position].State == TissueState.Cancer)
                s = s.UpdateTissueState(position, TissueState.Healthy);
            s = CollectEnergy(s, c.Id);
        }
        return s;
    }

    /// <summary>
    /// E 阶段组织演化：微环境压迫→增生→侵蚀→无氧呼吸→蹲守净化→固化→骨样硬化→根深蒂固→状态计时。
    /// 不改变 Turn.Phase，也不决定胜负（由 <see cref="OutcomeRules.Evaluate"/> 负责）。
    /// </summary>
    public static WorldState EvolveEndOfRound(WorldState s, IDeterministicRng rng)
    {
        var stage = Stage(s);
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune))
        {
            var pressure = s.Board.GetAdjacentPositions(c.Position).Sum(p => s.Board.Tissues[p].State switch
                { TissueState.Healthy => -1, TissueState.Cancer => 1, _ => 2 });
            var loss = Settlement.RoundTenth(Math.Max(0, pressure) * 10.0 / 4);
            if (stage == 2) loss = loss * 3 / 2;
            else if (stage == 3) loss = loss * 2;
            s = Damage(s, c.Id, loss);
        }
        var beforeGrowth = s;
        var cancerBlocks = Blocks(s, true);
        foreach (var t in Tiles(beforeGrowth).Where(t => !Cancerous(t) && s.GetCellAt(t.Position)?.Faction != Faction.Immune && !Watched(s, t.Position)))
        {
            var adjacent = t.Position.GetNeighbors().Where(p => beforeGrowth.Board.Tissues.TryGetValue(p, out var n) && Cancerous(n)).ToArray();
            if (adjacent.Length == 0) continue;
            var solid = cancerBlocks.Where(b => adjacent.Any(b.Contains)).Sum(b => b.Count(p => beforeGrowth.Board.Tissues[p].State == TissueState.SolidifiedCancer));
            // 2026-09-15 改：原来是 `rng.NextDouble() < adjacent.Length * rate`（rate 是 double）。
            //
            // 改成**整数千分位掷点**，对齐 GDScript 侧 cw_world.gd:709-722 的
            // `n_adj * (rate + per_solid * solids)` 再 `randi_range(1, 1000) <= chance`。
            // 两边的数本来就一样（30/35/40‰ 与 5/10/10‰ ↔ 0.03/0.035/0.04 与 0.005/0.01/0.01），
            // 差的只是表示法。
            //
            // **为什么必须改**：这是双内核对拍的硬阻塞。我们的随机数带子记的是整数区间抽取，
            // 浮点抽取在带子上**没有任何对应物** —— 实测不改的话 2 人局跑 40 步就撞
            // 64 条 RNG_NO_COUNTERPART，而 E 阶段 100% 走这一行、每回合约 27 次，
            // 于是任何跨 E 阶段的对拍结果整段作废。（docs/对拍规格_CWX.md）
            //
            // 比较方向也对齐：`randi_range(1,1000)` 出 1..1000、判 `<= chance`；
            // 这里 `NextIntRange(1, 1001)`（半开）同样出 1..1000，同样判 `<=`。
            var permille = (stage == 1 ? 30 : stage == 2 ? 35 : 40) + solid * (stage == 1 ? 5 : 10);
            if (rng.NextIntRange(1, 1001) <= adjacent.Length * permille)
            {
                s = s.UpdateTissueState(t.Position, TissueState.Cancer);
                s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithNewborn(true)));
            }
        }
        foreach (var block in Blocks(s, false))
        {
            if (block.Any(p => p.GetNeighbors().Any(n => !s.Board.Tissues.ContainsKey(n)))) continue;
            var candidates = block.OrderBy(p => p.Q).ThenBy(p => p.R).Where(p => s.GetCellAt(p)?.Faction != Faction.Immune && !Watched(s, p) &&
                p.GetNeighbors().Any(n => beforeGrowth.Board.Tissues.TryGetValue(n, out var t) && Cancerous(t))).ToArray();
            if (candidates.Length == 0) continue;
            var count = rng.NextInt(3) < 2 ? (stage == 3 ? 3 : 2) : (stage == 3 ? 5 : 3);
            foreach (var p in rng.Shuffle(candidates).Take(count))
            {
                s = s.UpdateTissueState(p, TissueState.Cancer);
                s = s.WithBoard(s.Board.UpdateTissue(p, s.Board.Tissues[p].WithNewborn(true)));
            }
        }
        cancerBlocks = Blocks(s, true);
        foreach (var c in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer))
        {
            var block = cancerBlocks.FirstOrDefault(b => b.Contains(c.Position));
            if (block == null) continue;
            var income = AnaerobicShare(s, c);
            s = s.UpdateCell(c.Id, c.WithEnergy(c.Energy + income));
        }
        // 骨样硬化标记格上的蹲守净化（E 阶段，排在【固化】之前）
        foreach (var loopCell in Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune && c.CampRound >= 0).ToArray())
        {
            var at = loopCell.CampPosition;
            var cell = s.Cells[loopCell.Id].Copy(campRound: -1);
            s = s.UpdateCell(loopCell.Id, cell);
            if (at is not { } atPos || cell.Position != atPos) continue;
            if (s.Board.Tissues[atPos].State != TissueState.Cancer) continue;
            s = s.UpdateTissueState(atPos, TissueState.Healthy);
            s = AddMemory(s, 1);
        }
        // E.5 【固化】；E.6 无癌细胞停留的癌组织固化计数衰减
        foreach (var t in Tiles(s).Where(t => t.State == TissueState.Cancer && t.Type != TissueType.BloodVessel))
        {
            var c = s.GetCellAt(t.Position);
            var cellPresent = c is { IsAlive: true, Faction: Faction.Cancer };
            var count = cellPresent && t.SolidLockRound != s.Turn.WorldRound ? t.SolidificationCount + 10
                : cellPresent ? t.SolidificationCount
                : s.Turn.PausedDecayRound == s.Turn.WorldRound ? t.SolidificationCount
                : Math.Max(0, t.SolidificationCount - 5);
            s = s.UpdateTissueSolidification(t.Position, count);
            if (count >= (stage == 1 ? 30 : 20)) s = s.UpdateTissueState(t.Position, TissueState.SolidifiedCancer);
        }
        // 骨肉瘤【骨样硬化】标记到期转固化癌组织
        foreach (var t in Tiles(s).Where(t => t.OssifyAtRound > 0).ToArray())
        {
            if (s.Turn.WorldRound < t.OssifyAtRound) continue;
            if (s.Board.Tissues[t.Position].State == TissueState.Cancer)
                s = s.UpdateTissueState(t.Position, TissueState.SolidifiedCancer);
            else
                s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithOssifyAt(0)));
        }
        // 环境恶化 II/III【根深蒂固】：固化癌组织每回合随机使相邻最多 1/3 格癌组织固化计数 +1
        if (stage >= 2)
        {
            var limit = stage == 2 ? 1 : 3;
            foreach (var t in Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer).ToArray())
            {
                var targets = t.Position.GetNeighbors()
                    .Where(n => s.Board.Tissues.TryGetValue(n, out var x) && x.State == TissueState.Cancer).ToArray();
                if (targets.Length == 0) continue;
                foreach (var n in rng.Shuffle(targets).Take(limit))
                    s = s.UpdateTissueSolidification(n, s.Board.Tissues[n].SolidificationCount + 10);
            }
        }
        // E.8 更新持续状态：「坏死」倒计时、移除「新生」标记
        foreach (var t in Tiles(s))
        {
            if (t.NecrosisRounds > 0) s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithNecrosis(t.NecrosisRounds - 1)));
            if (t.Newborn) s = s.WithBoard(s.Board.UpdateTissue(t.Position, s.Board.Tissues[t.Position].WithNewborn(false)));
        }
        if (s.Turn.ChemoRounds > 0)
        {
            var rounds = s.Turn.ChemoRounds - 1;
            s = s.WithTurn(s.Turn.WithChemo(rounds > 0 ? s.Turn.ChemoAt : null, rounds, rounds > 0 ? s.Turn.ChemoOwner : -1));
        }
        return s;
    }
}
