using static CellWar.Core.CellRules;
using static CellWar.Core.RulePolicies;

namespace CellWar.Core;

/// <summary>
/// 决策分发器（等价于三层设计的 RuleCatalog + Dispatcher）：把 IDecision 路由到对应所有权域。
/// 不承载任何规则语义，只负责「哪类决策交给哪个域」与公共前提（阶段/回合/存活）校验。
/// </summary>
internal static class DecisionRouter
{
    public static ValidationResult Validate(WorldState state, IDecision decision)
    {
        if (state.Turn.PendingDiscardSeat is { } pendingSeat)
            return decision is DiscardDecision discard && CardRules.ValidateDiscard(state, discard)
                ? new(true)
                : new(false, "手牌超过上限，必须先弃置");
        if (state.Turn.PendingMutationSeat is { } mutationSeat)
            return decision is ChooseMutationDecision choose && choose.PlayerSeat == mutationSeat && choose.Choice is 0 or 1
                ? new(true)
                : new(false, "等待突变结算选择");
        // 【连续吞噬】的连锁：挂起期间只接这只巨噬的「再走一跳」或「不连了」
        if (state.Turn.PendingChainCell is { } chainCell)
        {
            if (decision is StopChainDecision stop && stop.CellId == chainCell) return new(true);
            return decision is ChainMoveDecision hop && hop.CellId == chainCell
                    && CellRules.ChainTargets(state, state.Cells[chainCell]).Contains(hop.Target)
                ? new(true)
                : new(false, "等待【连续吞噬】选择下一跳");
        }
        if (decision is PlaceDecision placement) return PlacementRules.ValidatePlacement(state, placement);
        if (decision is ReviveDecision revival)
            return new(PhaseRules.GetRevivalOptions(state).Contains(revival), "Invalid revival option.");
        if (decision is DifferentiateDecision differentiation) return PlacementRules.ValidateDifferentiate(state, differentiation);
        if (decision is DrawDecision draw) return CardRules.ValidateDraw(state, draw);
        if (decision is MutateDecision mutate) return CardRules.ValidateMutate(state, mutate);
        if (decision is PlayCardDecision play) return CardRules.ValidatePlayCard(state, play);
        if (decision is TypeSkillDecision typeSkill) return SkillRules.Validate(state, typeSkill);
        if (state.Turn.Phase != Phase.PlayerAction) return new(false, "当前阶段不允许玩家操作");
        if (decision.PlayerSeat != state.Turn.ActivePlayerSeat) return new(false, "不是该玩家的回合");
        if (!PhaseRules.AliveSeat(state, decision.PlayerSeat)) return new(false, "玩家已死亡或不存在");
        if (decision is EndTurnDecision or PassDecision) return new(true);
        if (decision is not MoveDecision move) return new(false, "Unsupported decision.");
        return CellRules.ValidateMove(state, move);
    }

    public static RulesResult Execute(WorldState state, IDecision decision, IDeterministicRng rng)
    {
        var valid = Validate(state, decision);
        if (!valid.IsValid) return new(state, Array.Empty<IGameEvent>(), false, valid.ErrorMessage);
        if (decision is PlaceDecision placement) return PlacementRules.PlaceCell(state, placement);
        if (decision is DifferentiateDecision differentiation) return PlacementRules.Differentiate(state, differentiation);
        if (decision is DiscardDecision discard) return CardRules.Discard(state, discard);
        if (decision is ChooseMutationDecision choose) return CardRules.ChooseMutation(state, choose, rng);
        if (decision is ChainMoveDecision hop) return CellRules.ChainMove(state, hop, rng);
        if (decision is StopChainDecision)
            return new(state.WithTurn(state.Turn.WithPendingChain(null)), Array.Empty<IGameEvent>(), true);
        if (decision is DrawDecision draw) return CardRules.Draw(state, draw, rng);
        if (decision is MutateDecision mutate) return CardRules.Mutate(state, mutate, rng);
        if (decision is PlayCardDecision play) return CardRules.PlayCard(state, play, rng);
        if (decision is TypeSkillDecision typeSkill) return SkillRules.Execute(state, typeSkill, rng);
        if (decision is EndTurnDecision) return PhaseRules.AdvancePhase(state, rng);
        if (decision is PassDecision) return new(state, Array.Empty<IGameEvent>(), true);
        if (decision is ReviveDecision revival) return PhaseRules.Revive(state, revival);
        return CellRules.Move(state, (MoveDecision)decision, rng);
    }

    /// <summary>按席位生成全部合法选项：先处理开局/复活/强制弃置/突变选择等特殊状态，再枚举行动阶段决策。</summary>
    public static IReadOnlyList<IDecision> Available(WorldState s, int seat)
    {
        if (s.Turn.Phase == Phase.Setup)
        {
            if (seat != s.Turn.ActivePlayerSeat || !s.Players.TryGetValue(seat, out var p)) return Array.Empty<IDecision>();
            if (Cells(s).Any(c => c.OwnerSeat == seat)) return Array.Empty<IDecision>();
            var want = p.Faction == Faction.Cancer ? TissueState.Cancer : TissueState.Healthy;
            return Tiles(s).Where(t => t.State == want && t.OccupyingCell == null)
                .Select(t => (IDecision)new PlaceDecision(seat, t.Position)).ToArray();
        }
        if (s.Turn.Phase == Phase.S) return PhaseRules.GetRevivalOptions(s).Where(d => d.PlayerSeat == seat).Cast<IDecision>().ToArray();
        if (s.Turn.PendingDiscardSeat is { } pending)
        {
            if (pending != seat) return Array.Empty<IDecision>();
            return Cells(s).Where(c => c.OwnerSeat == seat && c.IsAlive)
                .SelectMany(c => c.Hand.Select(card => (IDecision)new DiscardDecision(seat, c.Id, card))).ToArray();
        }
        if (s.Turn.PendingMutationSeat is { } mutationSeat)
        {
            if (mutationSeat != seat) return Array.Empty<IDecision>();
            var mutationCell = s.Turn.PendingMutationCell!.Value;
            return new IDecision[] { new ChooseMutationDecision(seat, mutationCell, 0), new ChooseMutationDecision(seat, mutationCell, 1) };
        }
        if (s.Turn.PendingChainCell is { } chainCell)
        {
            var macro = s.Cells[chainCell];
            if (macro.OwnerSeat != seat) return Array.Empty<IDecision>();
            var hops = CellRules.ChainTargets(s, macro)
                .Select(t => (IDecision)new ChainMoveDecision(seat, chainCell, t)).ToList();
            hops.Add(new StopChainDecision(seat, chainCell));   // 「结束连续吞噬」永远给得出来
            return hops;
        }
        if (s.Turn.Phase != Phase.PlayerAction || seat != s.Turn.ActivePlayerSeat || !PhaseRules.AliveSeat(s, seat)) return Array.Empty<IDecision>();
        var result = new List<IDecision> { new PassDecision(seat), new EndTurnDecision(seat) };
        foreach (var c in Cells(s).Where(c => c.OwnerSeat == seat && c.IsAlive))
            foreach (var t in Tiles(s))
            {
                var move = new MoveDecision(seat, c.Id, t.Position);
                if (Validate(s, move).IsValid) result.Add(move);
            }
        foreach (var c in Cells(s).Where(c => c.OwnerSeat == seat && c.IsAlive && !c.Differentiated))
            foreach (var type in PlacementRules.ImmuneTypes)
            {
                var differentiation = new DifferentiateDecision(seat, c.Id, type);
                if (Validate(s, differentiation).IsValid) result.Add(differentiation);
            }
        foreach (var c in Cells(s).Where(c => c.OwnerSeat == seat && c.IsAlive))
        {
            var draw = new DrawDecision(seat, c.Id);
            if (Validate(s, draw).IsValid) result.Add(draw);
            var mutate = new MutateDecision(seat, c.Id);
            if (Validate(s, mutate).IsValid) result.Add(mutate);
            foreach (var card in c.Hand)
            {
                // 【癌症转移】是 68 张里**唯一需要选格**的卡牌：PRD:1465「选择两环内任意格子传送」。
                // 其余卡要么无目标、要么目标能从状态里唯一推出来，所以这里只为它逐格展开。
                if (card == "癌症转移")
                {
                    foreach (var dest in CardRules.MetastasisTargets(s, c))
                    {
                        var jump = new PlayCardDecision(seat, c.Id, card, dest);
                        if (Validate(s, jump).IsValid) result.Add(jump);
                    }
                    continue;
                }
                var play = new PlayCardDecision(seat, c.Id, card);
                if (Validate(s, play).IsValid) result.Add(play);
            }
            foreach (var skill in new[] { "抗体", "细胞毒素", "骨样硬化", "黏液破裂" })
            {
                var decision = new TypeSkillDecision(seat, c.Id, skill);
                if (Validate(s, decision).IsValid) result.Add(decision);
            }
            // 【早期血行转移】要选落点（GD `_homing_targets()` = 全场无细胞的健康组织），
            // 曾经和上面那四个无目标技能摆在一起 —— `Target` 恒为 null，`Validate` 条条驳回，
            // 于是这个技能**在选项表里根本不存在**。逐格摊开，合法性照旧交给 Validate。
            if (c.Type == CellType.Melanoma)
            {
                foreach (var t in Tiles(s))
                {
                    var homing = new TypeSkillDecision(seat, c.Id, "早期血行转移", t.Position);
                    if (Validate(s, homing).IsValid) result.Add(homing);
                }
            }
            if (c.Type == CellType.TCell)
            {
                foreach (var t in Tiles(s).Where(t => t.State == TissueState.SolidifiedCancer && t.Position.DistanceTo(c.Position) <= 1))
                {
                    var lyse = new TypeSkillDecision(seat, c.Id, "裂解", t.Position);
                    if (Validate(s, lyse).IsValid) result.Add(lyse);
                }
            }
            if (c.Type == CellType.SmallCellLung)
            {
                foreach (var t in Tiles(s).Where(t => t.OccupyingCell == null && t.Position.DistanceTo(c.Position) == 5))
                {
                    var jump = new TypeSkillDecision(seat, c.Id, "转移", t.Position);
                    if (Validate(s, jump).IsValid) result.Add(jump);
                }
            }
            if (c.Type == CellType.Dendritic)
            {
                foreach (var t in Tiles(s))
                {
                    var chemo = new TypeSkillDecision(seat, c.Id, "趋化源", t.Position);
                    if (Validate(s, chemo).IsValid) result.Add(chemo);
                }
                foreach (var target in Cells(s).Where(x => x.IsAlive && x.Faction == Faction.Cancer).ToArray())
                {
                    var hunt = new TypeSkillDecision(seat, c.Id, "免疫猎杀", null, target.Id);
                    if (Validate(s, hunt).IsValid) result.Add(hunt);
                }
            }
            if (c.Type == CellType.Macrophage)
            {
                var chain = new TypeSkillDecision(seat, c.Id, "连续吞噬");
                if (Validate(s, chain).IsValid) result.Add(chain);
            }
            if (c.Type == CellType.BCell)
            {
                var neutralize = new TypeSkillDecision(seat, c.Id, "中和抗体");
                if (Validate(s, neutralize).IsValid) result.Add(neutralize);
            }
            if (c.Type == CellType.TCell)
                foreach (var neighbor in c.Position.GetNeighbors())
                {
                    var excalibur = new TypeSkillDecision(seat, c.Id, "Excalibur", neighbor);
                    if (Validate(s, excalibur).IsValid) result.Add(excalibur);
                }
        }
        return result;
    }
}
