using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CellWar.Core.Observation;

/// <summary>
/// 观测协议 v1 的 C# 生产者（docs/观测协议_v1.md；口径二 · 批 0 步 4）。
///
/// 只读一份 <see cref="WorldImage"/>（世界状态 + 模拟状态）产出 <b>viewer = -2 全知</b>的 envelope；按席位裁剪是 <see cref="SeatFilter"/> 的事。
/// 数值全按协议口径：能量 / 费用 / 固化计数是十分位整数，比例是千分点，枚举是 GD 的整数值（附录 A），细胞引用是 cell id（= EntityId − 1）。
/// 派生量只交 tier A（Kevin 拍 E-4）：每一项都必须走 <see cref="RulePolicies"/> / <see cref="BoardRules"/> / <see cref="WorldEffects"/> 里已有的函数，
/// **这里不许自己算规则**（拍板 9）。
/// </summary>
public static class ObservationV1Codec
{
    public const int Protocol = 2;   // 2026-09-19 批 1 步 1（观测协议 §九）
    public const int HostAbi = 1;
    public const string RulesBuild = "core-slice-1+b0";
    public const int ViewerWatcher = -1;      // GD CWKernel.VIEWER_WATCHER
    public const int ViewerOmniscient = -2;   // GD CWKernel.VIEWER_OMNISCIENT，禁止过网

    // ---- C# 今天没有旋钮、引擎里是字面量的那几个 tune 键（GD 默认值逐个核对过：cw_data.gd:41,46）----
    // `world_events_on` / `cancer_win_hold_rounds` / `osteo_ossify_cost` 2026-09-19 起有旋钮了（K2），改从 `s.Tuning` 现读；
    // 默认值与原来的字面量逐个相同（false / 2 / 20），编码结果不变。
    private const int CancerWinWeighted = OutcomeRules.CancerWinWeighted;   // 同一个数，别抄第二份
    private const int LimitRound = 15;             // OutcomeRules：WorldRound >= 15

    /// <summary>协议 JSON 的唯一一套选项：snake_case 键名、中文不转义、**未知键硬错**。字典键不套命名策略（技能名 / 事件数据键原样）。</summary>
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static string Serialize(ObsEnvelope envelope) => JsonSerializer.Serialize(envelope, Json);

    public static ObsEnvelope Deserialize(string json)
        => JsonSerializer.Deserialize<ObsEnvelope>(json, Json) ?? throw new JsonException("envelope 是空的");

    /// <summary>全知 envelope。<paramref name="logsFrom"/> = 日志游标（`logs.from`），只带这一行之后的。</summary>
    public static ObsEnvelope Encode(WorldImage image, Revision revision, long logsFrom = 0)
    {
        var s = image.State;
        var sim = image.Simulation;
        var cells = s.Cells.Values.OrderBy(c => c.Id.Value).ToArray();
        for (var i = 0; i < cells.Length; i++)
            if ((int)cells[i].Id.Value != i + 1)
                throw new InvalidOperationException($"cells 不是稠密的：第 {i} 个是 EntityId {cells[i].Id.Value}，协议要求下标即 id");

        var tiles = s.Board.Tissues.Values.OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R).Select(t => new ObsTile(
            Pos(t.Position), (int)t.State, (int)t.Type, t.SolidificationCount, t.NecrosisRounds, t.Mucus, t.Newborn,
            t.OssifyAtRound, t.ToxinRound, t.ProductionCounter,
            t.Type == TissueType.BoneMarrow ? 0 : t.Charge ?? 0,   // store：骨髓格恒 0
            t.Type == TissueType.BoneMarrow ? t.Charge ?? 0 : 0,   // cards：只有骨髓格
            t.OccupyingCell is { } occ ? Id(occ) : -1,
            new ObsTileD(RulePolicies.PressureAt(s, t.Position), Permille(RulePolicies.SolidFraction(s, t)), Permille(RulePolicies.StoreFraction(t)),
                RulePolicies.ProliferateChanceRaw(s, t.Position), null, null, null, null))).ToArray();   // 不带闸：与 GD 公开查询同口径

        var obsCells = cells.Select(c => new ObsCell(
            Id(c.Id), c.OwnerSeat, (int)c.Faction, Pos(c.Position), GdEnum.Itype(c.Type), GdEnum.Ctype(c.Type), c.Energy, c.IsAlive,
            c.Marked, c.MarkLeft, c.MarkRound, c.EffectorUsed, c.Hand.ToArray(), c.Equipped.ToArray(),
            c.Modifiers.Select(m => new ObsMod(m.Card, m.Uses, Until(m.Duration), m.Sequence)).ToArray(), c.PlayCounter,
            new Dictionary<string, int>(c.EquipSeq), new Dictionary<string, int>(c.FxTurn), c.FxRound.ToArray(), c.Differentiated, c.ChemoCooldown,
            c.ArmorUsedThisRound, c.MutateUsedThisRound, c.ToxinThisRound, c.AntibodyThisRound, c.MetastasisUsedThisRound, c.JumpUsedThisRound,
            c.DrawsThisTurn, c.AttacksThisTurn, c.RespawnRound, c.CampRound, c.CampRound >= 0 && c.CampPosition is { } cp ? Pos(cp) : null,
            c.ChainLeft, c.ChainBonus, c.NeutralUntil <= 0 ? -1 : c.NeutralUntil,   // 「从没被中和过」GD 记 -1、C# 记 0：协议统一 -1
            s.Turn.PendingChainCell == c.Id,
            new ObsCellD(Income(s, c),
                c.IsAlive && c.Type == CellType.BCell ? RulePolicies.AntibodyDamage(s.Tuning, c.AntibodyThisRound, RulePolicies.HasSkill(s, c, "抗体亲和力成熟")) : 0,
                c.IsAlive ? RulePolicies.OverloadLoss(s, c) : 0,
                null, null, null, null, null, null, null, null, null, null, null))).ToArray();

        var immune = s.Players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat).FirstOrDefault();
        var phase = PhaseWord(s.Turn.Phase);
        var g = new ObsGlobal(
            s.Turn.WorldRound, phase,
            phase == "turn" ? s.Turn.ActivePlayerSeat : -1,   // GD 换阶段不清零，协议按 L1 视图口径：非玩家回合恒 -1
            sim.Input?.PlayerSeat ?? -1,
            immune?.AntigenMemory ?? 0, (int)(immune?.ImmuneLevel ?? ImmuneLevel.I) - 1,
            s.Turn.EffectorRound <= 0 ? -1 : s.Turn.EffectorRound,   // 「从没发动过」GD 记 -1、C# 记 0：协议统一 -1
            cells.Where(c => c.Faction == Faction.Immune && c.Type != CellType.ImmuneBasic).Select(c => (int)c.Type).Distinct().OrderBy(x => x).ToArray(),
            s.Turn.Winner is { } w ? (int)w : -1, WinReason(s), s.Turn.WinKind,
            new ObsCancerAlarm(s.Turn.CancerWinStreak, s.Tuning.CancerWinHoldRounds),
            s.Turn.ChemoAt is { } ca ? new ObsChemo(Pos(ca), s.Turn.ChemoRounds, s.Turn.ChemoOwner, s.Turn.ChemoCreator is { } cc ? Id(cc) : -1) : null,
            Track(s),
            new ObsEvents(WorldEffects.WorldEventNames.ToArray(),   // 世界事件整块未迁：pool 恒全表、double_next 恒 false（夹具 world_events_on = false）
                s.Effects.Select(e => new ObsEffect(e.Name, e.Left, e.Stacks, e.Doubled, new Dictionary<string, int>(e.Data), new ObsEffectD(WorldEffects.IsWorldEvent(e.Name)))).ToArray(),
                false),
            sim.FeedLog.Select(f => new ObsFeed(f.Seq, f.Kind, f.Pid, f.Faction, f.Card, f.Left)).ToArray(), sim.FeedSeq,
            s.Turn.PendingChainCell is { } pc ? Id(pc) : -1,
            false, s.Turn.Winner is not null,
            s.Players.Keys.OrderBy(x => x).ToArray(),
            s.Players.Values.OrderBy(p => p.Seat).Select(p => new ObsPlayer(p.Seat, "", (int)p.Faction,
                cells.Where(c => c.OwnerSeat == p.Seat).Select(c => Id(c.Id)).DefaultIfEmpty(-1).First(),
                p.CancerType is { } ct ? GdEnum.Ctype(ct) : -1,
                new ObsPlayerD(cells.Where(c => c.OwnerSeat == p.Seat).Sum(c => Income(s, c))))).ToArray(),
            new ObsTune(s.Tuning.WorldEventsOn, CancerWinWeighted, s.Tuning.CancerWinHoldRounds, LimitRound, s.Board.Tissues.Count / 2,
                s.Tuning.MucusMoveSurcharge, s.Tuning.MetastasisCost, s.Tuning.OsteoOssifyCost, s.Tuning.SolidifyThreshold.ToArray()),
            new ObsGlobalD(BoardRules.SolidifyThreshold(s), RulePolicies.Stage(s), RulePolicies.CancerPhase(s.Turn.WorldRound), PhaseText(s.Turn.Phase),
                WorldEffects.IsWorldEventRound(s.Turn.WorldRound), null, null, null, null, null, null, null, null));

        return new ObsEnvelope(Protocol, new ObsRuleset(HostAbi, RulesBuild, RulesBuild), revision.Value, sim.NextPresentationSeq - 1,
            ViewerOmniscient, false, ["A"], true, null,
            new ObsState(new ObsBoard(s.Board.Radius, tiles), obsCells, g),
            Ask(s, sim.Input, revision),
            new ObsLogs(logsFrom, sim.Outbox.Skip((int)Math.Max(0, logsFrom)).ToArray()));
    }

    // ---------------- ask / options ----------------

    private static ObsAsk? Ask(WorldState s, PendingInput? input, Revision revision)
    {
        if (input is null) return null;
        var parts = input.Options.Select(d => SemanticKey.Describe(s, d)).ToArray();
        // kind / tag 取第一条不是 Pass 的选项（Pass 是 C# 每问固定多出的一条，GD 没有）；组键「action+chemo_target」的 ask.kind 是前半截
        var leadIndex = Array.FindIndex(input.Options.ToArray(), d => d is not PassDecision);
        var lead = parts[leadIndex < 0 ? 0 : leadIndex];
        var kind = lead.Kind.Split('+')[0];
        var options = input.Options.Select((d, i) =>
        {
            var p = parts[i];
            var price = Price(s, d);
            var cost = d is MoveDecision ? price : null;   // 协议 cost 只给迁移（GD 只有迁移选项的 data 带 cost）；技能价签走 label 与 d.*_cost
            var data = p.Fields.ToDictionary(f => f.Field, f => JsonSerializer.SerializeToElement(DataValue(f.Value), Json), StringComparer.Ordinal);
            if (cost is { } moveCost) data["cost"] = JsonSerializer.SerializeToElement(moveCost, Json);   // GD 迁移选项自带 cost
            var anchor = d is ReviveDecision { SourcePosition: { } sp } r && s.Cells[r.CellId].Faction == Faction.Cancer ? Pos(sp) : null;
            if (anchor is { } an) data["anchor"] = JsonSerializer.SerializeToElement(an, Json);   // GD 癌方复活的 data 带 anchor（语义键剔除它，data 保留）
            var isStop = p.Fields.Any(f => f.Field is "stop" or "skip");
            var isAttack = d is MoveDecision m && s.GetCellAt(m.TargetPosition) is { } other && other.Faction != s.Cells[m.CellId].Faction;
            var rows = d is MoveDecision mm
                ? RulePolicies.MoveCostSteps(s, s.Cells[mm.CellId], mm.TargetPosition).Select(st => new ObsCostRow(st.Modifier.Name, st.Before, st.After, "")).ToArray()
                : [];
            return new ObsOption(i, p.Key, Label(s, d, price), data, cost, rows, anchor, isStop, isAttack, null);
        }).ToArray();
        var stopIndex = Array.FindIndex(options, o => o.IsStop);
        return new ObsAsk(input.RequestId, revision.Value, kind, lead.Tag, input.PlayerSeat, Prompt(s, kind, lead.Tag, input), true, stopIndex, options);
    }

    /// <summary>`data` 的值编码（与语义键字符串里的写法不同：坐标是对象、细胞引用是 cell id、bool 是 true/false）。</summary>
    private static object DataValue(object v) => v switch
    {
        HexPosition p => Pos(p),
        EntityId id => Id(id),
        _ => v,
    };

    /// <summary>选项价签（十分能量，给 label 用；协议 `cost` 字段只取迁移那一条）；免费与无价 = null。每一处都走引擎结算时用的同一个数，不另抄。</summary>
    private static int? Price(WorldState s, IDecision d) => d switch
    {
        MoveDecision m => RulePolicies.QuoteMove(s, s.Cells[m.CellId], m.TargetPosition),
        ChemotaxisStepDecision c => RulePolicies.BaseMoveCost(s, s.Cells[c.CellId], c.Target, CellRules.ChemotaxisStepCost),
        ChainMoveDecision => 0,
        DrawDecision w => s.Cells[w.CellId].Faction == Faction.Immune ? CardRules.ImmuneDrawCost : CardRules.CancerDrawCost,
        MutateDecision => CardRules.MutateCost,
        CoupleTierDecision ct => ct.Pay,
        TypeSkillDecision t => t.Skill switch
        {
            "抗体" => RulePolicies.HasSkill(s, s.Cells[t.CellId], "抗体亲和力成熟") ? 5 : 10,
            "细胞毒素" or "裂解" => 10,
            "趋化源" => 30,
            "骨样硬化" => s.Tuning.OsteoOssifyCost,
            "早期血行转移" => SkillRules.MelanomaHomingCost,
            "转移" => s.Tuning.MetastasisCost,
            _ => null,
        },
        _ => null,
    };

    /// <summary>按钮文案，模板照 GD `cw_actions.gd build_options`；批 0 只求存在，文案对拍不进批 0（协议 §八 #6）。</summary>
    private static string Label(WorldState s, IDecision d, int? cost)
    {
        string Money(int? c) => c is { } v ? $"（{Stage.Fmt(v)} 能量）" : "";
        return d switch
        {
            EndTurnDecision => "结束回合",
            PassDecision => "跳过",
            MoveDecision m => $"{(s.GetCellAt(m.TargetPosition) is { } o && o.Faction != s.Cells[m.CellId].Faction ? "攻击" : "迁移")}→{P(m.TargetPosition)} {TissueTag(s, m.TargetPosition)}{Money(cost)}",
            DrawDecision => $"基因表达：抽卡{Money(cost)}",
            MutateDecision => $"突变{Money(cost)}",
            DifferentiateDecision df => $"分化为{Stage.TypeName(df.Type)}（免费）",
            PlayCardDecision pc => $"打出【{pc.Card}】" + (pc.Target is { } t ? $"→{P(t)}" : "") + (pc.TargetCell is { } tc ? $"→{Stage.CellName(s, s.Cells[tc])}" : ""),
            DiscardDecision dc => $"弃置【{dc.Card}】",
            PlaceDecision pl => $"落子 {P(pl.TargetPosition)}",
            ReviveDecision r => s.Cells[r.CellId].Faction == Faction.Immune ? $"复活于骨髓 {P(r.TargetPosition)}" : $"复活于 {P(r.TargetPosition)}",
            SkipReviveDecision => "放弃本回合复活",
            ChooseMutationDecision cm => $"按第 {cm.Choice + 1} 次判定结算",
            ChainMoveDecision ch => $"连续吞噬→{P(ch.Target)}（免费）",
            StopChainDecision => "结束连续吞噬",
            ChemotaxisStepDecision cx => $"移动→{P(cx.Target)}",
            StopChemotaxisDecision => "停在这里",
            CoupleDirectionDecision cd => $"{Stage.CellName(s, s.Cells[cd.Payer])} → {Stage.CellName(s, s.Cells[cd.Getter])}",
            CoupleTierDecision ct => $"转出 {Stage.Fmt(ct.Pay)} → 接收方得 {Stage.Fmt(ct.Get)}",
            CancelCoupleDecision => "取消",
            // GD `_pick_immune` 的按钮还带一句预览（「净化 N 格」），文案不进对拍（协议 §八 #6），这里只给名字
            PickCellDecision pk => $"选择 {Stage.CellName(s, s.Cells[pk.TargetCellId])}",
            RemodelPickDecision rp => $"{P(rp.Target)}",
            StopRemodelDecision => "到此为止",
            TypeSkillDecision t => t.Skill switch
            {
                "抗体" => $"抗体{Money(cost)}",
                "细胞毒素" => $"细胞毒素{Money(cost)}",
                "裂解" => $"裂解→{P(t.Target!.Value)}{Money(cost)}",
                "趋化源" => $"趋化源→{P(t.Target!.Value)}{Money(cost)}",
                "早期血行转移" => $"早期血行转移→{P(t.Target!.Value)}{Money(cost)}",
                "转移" => $"转移：跃进至 {P(t.Target!.Value)}{Money(cost)}",
                "骨样硬化" => $"骨样硬化{Money(cost)}",
                "黏液破裂" => "黏液破裂（耗尽能量并死亡）",
                _ => $"效应应答·{t.Skill}" + (t.Target is { } tt ? $"→{P(tt)}" : "") + (t.TargetCell is { } tc ? $"→{Stage.CellName(s, s.Cells[tc])}" : ""),
            },
            _ => d.DecisionType,
        };
    }

    /// <summary>询问文案，模板照 GD（`cw_game.gd PROMPTS` / 各中途询问的 prompt）；同样只求存在。</summary>
    private static string Prompt(WorldState s, string kind, string? tag, PendingInput input) => kind switch
    {
        "setup_place" => $"{Stage.SeatName(s, input.PlayerSeat)}：选择初始位置",
        "immune_revive" or "revive" => $"{Stage.SeatName(s, input.PlayerSeat)}：选择复活位置",
        "action" => "选择行动",
        _ => tag is null ? "请选择" : $"【{tag}】请选择",
    };

    // ---------------- 顶层派生 ----------------

    private static ObsTrack? Track(WorldState s)
    {
        if (s.Turn.TrackCell is { } tc)   // 活着：位置现读那只细胞（GD chemo_track_at）
            return new ObsTrack(Id(tc), Pos(s.Cells[tc].Position), s.Turn.TrackRounds);
        if (s.Turn.TrackFrozenAt is { } fa)   // 死了：冻在死亡格、cid = -1
            return new ObsTrack(-1, Pos(fa), s.Turn.TrackRounds);
        return null;
    }

    /// <summary>GD 的四句 `win_reason`（cw_game.gd:1111,1133 / cw_world.gd:1227,1232）。文案不进对拍（§八 #6），但格式照抄。</summary>
    private static string WinReason(WorldState s)
    {
        var tiles = s.Board.Tissues.Values;
        var weighted = tiles.Sum(t => t.State == TissueState.Cancer ? 1 : t.State == TissueState.SolidifiedCancer ? 2 : 0);
        var cancerous = tiles.Count(t => t.State != TissueState.Healthy);
        var limit = s.Board.Tissues.Count / 2;
        return s.Turn.WinKind switch
        {
            "immune_clear" => "免疫胜利：癌细胞全灭且无可复活的固化癌组织",
            "cancer_weighted" => $"癌症胜利：加权占地 {weighted} >= {CancerWinWeighted}",
            "limit_cancer" => $"{s.Turn.WorldRound} 回合到：癌性组织 {cancerous} >= {limit}，癌症胜利",
            "limit_immune" => $"{s.Turn.WorldRound} 回合到：癌性组织 {cancerous} < {limit}，免疫胜利",
            _ => "",
        };
    }

    private static int Income(WorldState s, Cell c)
        => !c.IsAlive ? 0 : c.Faction == Faction.Immune ? RulePolicies.AerobicShare(s, c) : RulePolicies.AnaerobicShare(s, c);

    /// <summary>`quote_path` 的返回形状（§5.3）：`blocked` ↔ C# `Reason`；`mid` = 借道第一跳（`RulePolicies.PassThroughMid`）。</summary>
    public static ObsPathQuote PathQuote(PathQuote q)
        => new(q.Steps.Select(st => new ObsPathStep(Pos(st.To), st.Cost, st.Mid is { } m ? Pos(m) : null, st.Legal, st.Afford, st.Reason, st.Gain)).ToArray(), q.Total, q.Gained, q.Ok, q.Left, q.Stop);

    // ---------------- 编码工具（附录 A） ----------------

    public static int Id(EntityId id) => (int)id.Value - 1;
    public static ObsPos Pos(HexPosition p) => new(p.Q, p.R);
    private static string P(HexPosition p) => $"({p.Q}, {p.R})";   // GD str(Vector2i)
    private static int Permille(double fraction) => fraction < 0 ? 0 : (int)Math.Round(fraction * 1000, MidpointRounding.AwayFromZero);
    private static string Until(ModifierDuration d) => d switch { ModifierDuration.Turn => "turn", ModifierDuration.Round => "round", _ => "" };
    private static string PhaseWord(Phase p) => p switch
    {
        Phase.Setup => "setup", Phase.S => "s", Phase.PlayerAction => "turn", Phase.E => "e", _ => "finished",
    };
    private static string PhaseText(Phase p) => p switch   // GD cw_game.gd PHASE_NAMES
    {
        Phase.Setup => "开局布置", Phase.S => "世界回合 S", Phase.PlayerAction => "玩家回合", _ => "世界回合 E",
    };
    private static string TissueTag(WorldState s, HexPosition at) => s.Board.Tissues[at].State switch   // GD cw_actions.gd tissue_tag
    {
        TissueState.Healthy => "健康", TissueState.SolidifiedCancer => "固化", _ => "癌",
    };
}
