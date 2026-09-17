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
        if (state.Turn.PendingChainCell is { } chainCell && !CellRules.ChainDeferred(state))
        {
            // 这一问是问**这只细胞的主人**的：GD 的 ask(pid) 只会送到那一个桥，别的席位根本答不到；
            // C# 的决策带着 PlayerSeat 从网络进来，不查主人就等于让对手替你「不连了」
            var chainOwner = state.Cells[chainCell].OwnerSeat;
            if (decision is StopChainDecision stop && stop.CellId == chainCell && stop.PlayerSeat == chainOwner) return new(true);
            return decision is ChainMoveDecision hop && hop.CellId == chainCell && hop.PlayerSeat == chainOwner
                    && CellRules.ChainTargets(state, state.Cells[chainCell]).Contains(hop.Target)
                ? new(true)
                : new(false, "等待【连续吞噬】选择下一跳");
        }
        // 【炎症性趋化】的第 2/3 步：挂起期间只接这只细胞的「再走一步」或「停在这里」。
        // 排在【连续吞噬】**之后** —— GD 那边连锁问答嵌在 `_do_move` 内部，整条排干了才轮到这里问。
        if (state.Turn.PendingChemotaxisCell is { } chemotaxisCell)
        {
            var walkOwner = state.Cells[chemotaxisCell].OwnerSeat;   // 同上：只有主人能答
            if (decision is StopChemotaxisDecision stopWalk && stopWalk.CellId == chemotaxisCell && stopWalk.PlayerSeat == walkOwner) return new(true);
            return decision is ChemotaxisStepDecision step && step.CellId == chemotaxisCell && step.PlayerSeat == walkOwner
                    && CellRules.WalkSteps(state, state.Cells[chemotaxisCell]).Contains(step.Target)
                ? new(true)
                : new(false, $"等待【{state.Turn.PendingWalkCard ?? "炎症性趋化"}】选择下一步");
        }
        // 【代谢耦联】的两次追问（方向 → 档位）：只接主人；两问都能「取消」
        if (state.Turn.PendingCoupleCell is { } coupleCell && state.Turn.PendingCoupleAlly is { } coupleAlly)
        {
            if (decision.PlayerSeat != state.Cells[coupleCell].OwnerSeat) return new(false, "等待【代谢耦联】的选择");
            if (decision is CancelCoupleDecision cancel && cancel.CellId == coupleCell) return new(true);
            if (state.Turn.PendingCouplePayer is { } payer)
                return decision is CoupleTierDecision tier && tier.CellId == coupleCell
                        && CardRules.CoupleTiers(state, payer).Contains((tier.Pay, tier.Get))
                    ? new(true)
                    : new(false, "等待【代谢耦联】选择档位");
            return decision is CoupleDirectionDecision dir && dir.CellId == coupleCell
                    && CardRules.CoupleDirections(state, coupleCell, coupleAlly).Contains((dir.Payer, dir.Getter))
                ? new(true)
                : new(false, "等待【代谢耦联】选择转移方向");
        }
        // 【基质重塑】的追问（再拆一格 → 转健康 ×2）：只接主人；每段都可「停」（停不是取消，卡照常离手）
        if (state.Turn.PendingRemodelCell is { } remodelCell)
        {
            if (decision.PlayerSeat != state.Cells[remodelCell].OwnerSeat) return new(false, "等待【基质重塑】的选择");
            if (decision is StopRemodelDecision stopRemodel && stopRemodel.CellId == remodelCell) return new(true);
            return decision is RemodelPickDecision pick && pick.CellId == remodelCell && CardRules.RemodelOptions(state).Contains(pick.Target)
                ? new(true)
                : new(false, "等待【基质重塑】选格");
        }
        if (decision is PlaceDecision placement) return PlacementRules.ValidatePlacement(state, placement);
        if (decision is ReviveDecision or SkipReviveDecision)
            return new(PhaseRules.GetRevivalOptions(state).Contains(decision), "Invalid revival option.");
        if (decision is DifferentiateDecision differentiation) return PlacementRules.ValidateDifferentiate(state, differentiation);
        if (decision is DrawDecision draw) return CardRules.ValidateDraw(state, draw);
        if (decision is MutateDecision mutate) return CardRules.ValidateMutate(state, mutate);
        if (decision is PlayCardDecision play) return CardRules.ValidatePlayCard(state, play);
        if (decision is TypeSkillDecision typeSkill) return SkillRules.Validate(state, typeSkill);
        if (state.Turn.Phase != Phase.PlayerAction) return new(false, "当前阶段不允许玩家操作");
        if (decision.PlayerSeat != state.Turn.ActivePlayerSeat) return new(false, "不是该玩家的回合");
        if (!PhaseRules.AliveSeat(state, decision.PlayerSeat)) return new(false, "玩家已死亡或不存在");
        if (decision is EndTurnDecision or PassDecision) return new(true);
        // 行动栏里的**自愿**弃置：不花钱、不计行动，只能在自己的行动回合弃（上面三条前置已经守住）
        if (decision is DiscardDecision toss)
            return CardRules.ValidateDiscard(state, toss) ? new(true) : new(false, "手里没有这张牌");
        if (decision is not MoveDecision move) return new(false, "Unsupported decision.");
        return CellRules.ValidateMove(state, move);
    }

    public static RulesResult Execute(WorldState state, IDecision decision, IDeterministicRng rng)
    {
        var result = Dispatch(state, decision, rng);
        if (!result.Success) return result;
        // 【炎症性趋化】的三条退出（细胞死了 / 没有可走的下一步 / 步数走满）在 GD 里是
        // 下一轮循环开头判的，且一定排在连锁之后。这里统一收口，Available 才不会
        // 停在「只剩一个『停在这里』」上 —— GD 没有那个决策点。
        var s = result.NewState;
        // 收口跑到稳定：连走弹栈 → 基质重塑滑段 → 推迟的落地后半截（它自己又可能追出新的问答，再来一轮）
        for (var guard = 0; guard < 8; guard++)
        {
            var before = s;
            if (s.Turn.PendingChemotaxisCell is not null) s = CellRules.NormalizeChemotaxis(s);
            s = CellRules.NormalizeChain(s);                                               // 走位弹掉露出的连锁若已无下一跳，当场摘掉
            if (s.Turn.PendingRemodelCell is not null) s = CardRules.NormalizeRemodel(s);   // GD 的「候选为空就不问」两道闸
            if (CellRules.LandReady(s)) s = CellRules.ResumeLand(s, rng);                  // GD enter_tile 的 await 回来了：收特殊组织、刷标记
            if (ReferenceEquals(s, before)) break;
        }
        // S 阶段的追问答完了：产出那一步 → 接着血管传送、复活、有氧、开打；复活落地那一步 → 接着问下一席复活或开打（GD round_start / revive_* 的 await 回来了）
        if (s.Turn.Phase == Phase.S && !PhaseRules.StartPending(s))
        {
            if (s.Turn.StartStep == 3) s = PhaseRules.ResumeStart(s, rng);
            else if (s.Turn.StartStep == 1 && PhaseRules.GetRevivalOptions(s).Count == 0) s = PhaseRules.ContinueStart(s);
        }
        // E 阶段蹲守净化追出的问答答完了：接着做 5 → 9.5、判胜负、翻到下一回合的 S（GD `_resolve_camping` 的 await 回来了）
        if (s.Turn.Phase == Phase.E && s.Turn.EndStep == 1 && !PhaseRules.EndPending(s)) s = PhaseRules.FinishEndOfRound(s, rng);
        // 中途的挂起摘干净的这一刻 = 那张卡「结算完」：GD 是整段 await 回来才离手、才走细胞因子链。
        // 卡是哪张由 PendingCard 记着（打出时挂上），不用猜；打出当步就结束的（没有下一步 / 走死）同样走到这里。
        if (s.Turn.PendingCard is { } card && s.Turn.PendingCardCell is { } owner
                && s.Turn.PendingChemotaxisCell is null && s.Turn.PendingCoupleCell is null && s.Turn.PendingRemodelCell is null && s.Turn.PendingDiscardSeat is null
                && s.Turn.PendingLandCell is null)
            s = CardRules.FinishInstant(s, owner, card);
        return result with { NewState = s };
    }

    private static RulesResult Dispatch(WorldState state, IDecision decision, IDeterministicRng rng)
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
        if (decision is ChemotaxisStepDecision step) return CellRules.WalkMove(state, step.CellId, step.Target, rng);
        if (decision is StopChemotaxisDecision)   // GD `_free_walk` 的 `return` 只退一层：外层还有步就接着问（出口的 NormalizeChemotaxis 会再判外层）
            return new(state.WithTurn(state.Turn.PopWalk()), Array.Empty<IGameEvent>(), true);
        if (decision is CoupleDirectionDecision dir)
            return new(state.WithTurn(state.Turn.WithPendingCouple(dir.CellId, state.Turn.PendingCoupleAlly, dir.Payer)), Array.Empty<IGameEvent>(), true);
        if (decision is CoupleTierDecision tier)
        {
            var payer = state.Turn.PendingCouplePayer!.Value;
            var getter = payer == tier.CellId ? state.Turn.PendingCoupleAlly!.Value : tier.CellId;
            return new(CardRules.CoupleTransfer(state, payer, getter, tier.Pay, tier.Get), Array.Empty<IGameEvent>(), true);
        }
        if (decision is CancelCoupleDecision)
            // 取消：无效果、卡不弃置 —— 连 PendingCard 一起摘，Execute 出口就不会给这张卡收尾
            return new(state.WithTurn(state.Turn.WithPendingCouple(null, null, null).WithPendingCard(null, null)), Array.Empty<IGameEvent>(), true);
        if (decision is RemodelPickDecision remodelPick) return new(CardRules.RemodelPick(state, remodelPick.Target), Array.Empty<IGameEvent>(), true);
        if (decision is StopRemodelDecision) return new(CardRules.RemodelStop(state), Array.Empty<IGameEvent>(), true);
        if (decision is DrawDecision draw) return CardRules.Draw(state, draw, rng);
        if (decision is MutateDecision mutate) return CardRules.Mutate(state, mutate, rng);
        if (decision is PlayCardDecision play) return CardRules.PlayCard(state, play, rng);
        if (decision is TypeSkillDecision typeSkill) return SkillRules.Execute(state, typeSkill, rng);
        if (decision is EndTurnDecision) return PhaseRules.AdvancePhase(state, rng);
        if (decision is PassDecision) return new(state, Array.Empty<IGameEvent>(), true);
        if (decision is ReviveDecision revival) return PhaseRules.Revive(state, revival, rng);
        if (decision is SkipReviveDecision skip) return PhaseRules.SkipRevive(state, skip);
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
        if (s.Turn.PendingDiscardSeat is { } pending)
        {
            if (pending != seat) return Array.Empty<IDecision>();
            // GD `discard_to_limit(cell)` 只摊超限的那一只细胞的手牌；席位级枚举在一席多胞时会给出 GD 没有的选项
            return Cells(s).Where(c => c.OwnerSeat == seat && c.IsAlive && (s.Turn.PendingDiscardCell is not { } pc || c.Id == pc))
                .SelectMany(c => c.Hand.Select(card => (IDecision)new DiscardDecision(seat, c.Id, card))).ToArray();
        }
        if (s.Turn.PendingMutationSeat is { } mutationSeat)
        {
            if (mutationSeat != seat) return Array.Empty<IDecision>();
            var mutationCell = s.Turn.PendingMutationCell!.Value;
            return new IDecision[] { new ChooseMutationDecision(seat, mutationCell, 0), new ChooseMutationDecision(seat, mutationCell, 1) };
        }
        if (s.Turn.PendingChainCell is { } chainCell && !CellRules.ChainDeferred(s))
        {
            var macro = s.Cells[chainCell];
            if (macro.OwnerSeat != seat) return Array.Empty<IDecision>();
            var hops = CellRules.ChainTargets(s, macro)
                .Select(t => (IDecision)new ChainMoveDecision(seat, chainCell, t)).ToList();
            hops.Add(new StopChainDecision(seat, chainCell));   // 「结束连续吞噬」永远给得出来
            return hops;
        }
        if (s.Turn.PendingChemotaxisCell is { } chemotaxisCell)
        {
            var walker = s.Cells[chemotaxisCell];
            if (walker.OwnerSeat != seat) return Array.Empty<IDecision>();
            // 「停在这里」排在最前：GD `game.ask` 的约定是「可以不做」的那条放下标 0（中止对局时固定答 0）。
            // 候选为空这种情况到不了这里 —— NormalizeChemotaxis 已经把挂起摘掉了。
            var steps = new List<IDecision> { new StopChemotaxisDecision(seat, chemotaxisCell) };
            steps.AddRange(CellRules.WalkSteps(s, walker).Select(t => (IDecision)new ChemotaxisStepDecision(seat, chemotaxisCell, t)));
            return steps;
        }
        if (s.Turn.PendingCoupleCell is { } coupleCell && s.Turn.PendingCoupleAlly is { } coupleAlly)
        {
            if (s.Cells[coupleCell].OwnerSeat != seat) return Array.Empty<IDecision>();
            var opts = new List<IDecision> { new CancelCoupleDecision(seat, coupleCell) };   // GD 下标 0：「取消」
            if (s.Turn.PendingCouplePayer is { } payer)
                opts.AddRange(CardRules.CoupleTiers(s, payer).Select(t => (IDecision)new CoupleTierDecision(seat, coupleCell, t.Pay, t.Get)));
            else
                opts.AddRange(CardRules.CoupleDirections(s, coupleCell, coupleAlly).Select(d => (IDecision)new CoupleDirectionDecision(seat, coupleCell, d.Payer, d.Getter)));
            return opts;
        }
        if (s.Turn.PendingRemodelCell is { } remodelCell)
        {
            if (s.Cells[remodelCell].OwnerSeat != seat) return Array.Empty<IDecision>();
            var opts = new List<IDecision> { new StopRemodelDecision(seat, remodelCell) };   // GD 下标 0：「只拆这一格」/「到此为止」
            opts.AddRange(CardRules.RemodelOptions(s).Select(p => (IDecision)new RemodelPickDecision(seat, remodelCell, p)));
            return opts;   // 候选为空到不了这里：NormalizeRemodel 已经滑段 / 摘掉
        }
        // S 阶段的复活问答排在各种挂起之后：产出时踩骨髓抽出来的连走 / 弃置 / 二选一 GD 都是当场问完（round_start 的 await 链）
        if (s.Turn.Phase == Phase.S) return PhaseRules.GetRevivalOptions(s).Where(d => d.PlayerSeat == seat).ToArray();
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
                // 自愿弃置：**每张手牌都给**，所以摆在打出之前 —— 摆在后面会被
                // 【癌症转移】那条 `continue` 跳过，那张牌就成了唯一弃不掉的牌
                var toss = new DiscardDecision(seat, c.Id, card);
                if (Validate(s, toss).IsValid) result.Add(toss);
                // 带目标的卡逐个摊开（GD hand_options：一个目标一条；没有候选就不出这张牌，落空的卡不该出现在行动栏里）。
                // 候选表在 CardRules.TileTargeted / CellTargeted —— 选项层、Validate、结算三处共用同一份（2026-09-17 从 3 张扩到 13 张）
                if (CardRules.TileTargeted.TryGetValue(card, out var tilesOf))
                {
                    foreach (var dest in tilesOf(s, c))
                    {
                        var targeted = new PlayCardDecision(seat, c.Id, card, dest);
                        if (Validate(s, targeted).IsValid) result.Add(targeted);
                    }
                    continue;
                }
                if (CardRules.CellTargeted.TryGetValue(card, out var cellsOf))
                {
                    foreach (var tid in cellsOf(s, c))
                    {
                        var targeted = new PlayCardDecision(seat, c.Id, card, null, tid);
                        if (Validate(s, targeted).IsValid) result.Add(targeted);
                    }
                    continue;
                }
                // 【炎症性趋化】：第 1 步的落点烤在打出选项里；一个合法第一步都没有时不出（GD cw_card_fx.gd:167-169）
                if (card == "炎症性趋化")
                {
                    foreach (var first in CellRules.ChemotaxisSteps(s, c))
                    {
                        var walk = new PlayCardDecision(seat, c.Id, card, first);
                        if (Validate(s, walk).IsValid) result.Add(walk);
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
                foreach (var p in SkillRules.JumpTargets(s, c))   // 六个方向的直线落点（GD _jump_targets），不是整个 5 环
                {
                    var jump = new TypeSkillDecision(seat, c.Id, "转移", p);
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
