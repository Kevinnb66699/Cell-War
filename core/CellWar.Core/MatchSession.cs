using System.Collections.Immutable;

namespace CellWar.Core;

public sealed record CellObservation(EntityId Id, int OwnerSeat, Faction Faction, CellType Type, HexPosition Position, double Energy, bool IsAlive,
    ImmutableArray<string> Hand, ImmutableArray<string> Equipped, int AttacksThisTurn, bool Differentiated, bool Marked = false, int MarkLeft = 0, int CampRound = -1);
public sealed record TissueObservation(HexPosition Position, TissueType Type, TissueState State, double SolidificationCount, EntityId? OccupyingCell, double? Charge, double StoreFraction, double SolidFraction, bool Mucus = false, int NecrosisRounds = 0, int OssifyAtRound = 0, int ProductionCounter = 0);
public sealed record PlayerObservation(int Seat, Faction Faction, bool IsAlive, double Energy,
    ImmutableArray<CellObservation> Cells, int DrawCount, int AntigenMemory, int ImmuneLevel, string? CancerType,
    int HandCount, double Income);
public sealed record VisibleOption(int Id, string Kind, EntityId? CellId, HexPosition? Position, double? Cost, CellType? CellType = null, string? Card = null, string? Skill = null);
public sealed record MessageEntry(long Cursor, string Text);
public sealed record MatchObservation(Revision Revision, int Radius, int WorldRound, Phase Phase, int ActiveSeat,
    Faction? Winner, ImmutableArray<PlayerObservation> Players, ImmutableArray<CellObservation> Cells, ImmutableArray<TissueObservation> Tissues,
    long? RequestId, ImmutableArray<VisibleOption> Options, ImmutableArray<MessageEntry> Messages, string? ResultReason = null);

/// <summary>Projects a fixed revision. No scheduler, RNG or other seat's legal input is exposed.</summary>
public sealed class MatchObservationProvider : IObservationProvider
{
    private readonly BasicRulesEngine rules;
    public MatchObservationProvider(BasicRulesEngine rules) => this.rules = rules;
    public MatchObservation Observe(ReadLease lease, int? authorizedSeat)
    {
        var s = lease.Snapshot.State;
        var pending = lease.Snapshot.Simulation.Input;
        var visible = pending != null && pending.PlayerSeat == authorizedSeat;
        var options = visible ? pending!.Options.Select((d, index) => d switch
        {
            MoveDecision m => new VisibleOption(index, d.DecisionType, m.CellId, m.TargetPosition, rules.QuoteMove(s, s.Cells[m.CellId], m.TargetPosition) is { } q ? q / 10.0 : null),
            ReviveDecision r => new VisibleOption(index, d.DecisionType, r.CellId, r.TargetPosition, null),
            SkipReviveDecision r => new VisibleOption(index, d.DecisionType, r.CellId, null, null),
            PlaceDecision p => new VisibleOption(index, d.DecisionType, null, p.TargetPosition, null),
            DifferentiateDecision f => new VisibleOption(index, d.DecisionType, f.CellId, null, null, f.Type),
            DrawDecision w => new VisibleOption(index, d.DecisionType, w.CellId, null, null, null),
            MutateDecision m => new VisibleOption(index, d.DecisionType, m.CellId, null, null, null),
            PlayCardDecision p => new VisibleOption(index, d.DecisionType, p.CellId, p.Target, null, null, p.Card),
            DiscardDecision x => new VisibleOption(index, d.DecisionType, x.CellId, null, null, null, x.Card),
            ChooseMutationDecision m => new VisibleOption(index, d.DecisionType, m.CellId, null, null, null),
            TypeSkillDecision t => new VisibleOption(index, d.DecisionType, t.CellId, t.Target, null, null, null, t.Skill),
            // 两组挂起态的追问：候选**只靠目标格区分**，落进默认分支就是 N 条一模一样的选项，客户端画不出「走到哪」。
            // 连锁跳是真免费；趋化每步是 0.2 起价过完管线的报价（与 MoveDecision 那条同样按十分能量折成小数）。
            ChainMoveDecision h => new VisibleOption(index, d.DecisionType, h.CellId, h.Target, 0.0),
            StopChainDecision h => new VisibleOption(index, d.DecisionType, h.CellId, null, null),
            ChemotaxisStepDecision c => new VisibleOption(index, d.DecisionType, c.CellId, c.Target,
                RulePolicies.BaseMoveCost(s, s.Cells[c.CellId], c.Target, CellRules.ChemotaxisStepCost) / 10.0),
            StopChemotaxisDecision c => new VisibleOption(index, d.DecisionType, c.CellId, null, null),
            // 风暴选中心：候选只靠**被选中的那只细胞**区分（落进默认分支就是 N 条一模一样的选项）
            PickCellDecision pk => new VisibleOption(index, d.DecisionType, pk.TargetCellId, s.Cells[pk.TargetCellId].Position, null, null, s.Turn.PendingPickCellCard),
            // 【基质重塑】的三问：再拆 / 转健康都只靠目标格区分
            RemodelPickDecision rp => new VisibleOption(index, d.DecisionType, rp.CellId, rp.Target, null),
            StopRemodelDecision sr => new VisibleOption(index, d.DecisionType, sr.CellId, null, null),
            // 【代谢耦联】两问：方向按付方细胞区分，档位按转出量区分（十分能量折成小数）
            CoupleDirectionDecision cd => new VisibleOption(index, d.DecisionType, cd.Payer, null, null, null, "代谢耦联"),
            CoupleTierDecision ct => new VisibleOption(index, d.DecisionType, ct.CellId, null, ct.Pay / 10.0, null, "代谢耦联"),
            CancelCoupleDecision cc => new VisibleOption(index, d.DecisionType, cc.CellId, null, null),
            _ => new VisibleOption(index, d.DecisionType, null, null, null)
        }).ToImmutableArray() : ImmutableArray<VisibleOption>.Empty;
        var players = s.Players.Values.OrderBy(p => p.Seat).Select(p =>
        {
            // 2026-09-15 修：这里原来**无条件**导出每个细胞的 Hand —— authorizedSeat 只门控了
            // 上面的 options。于是每个人都能看见所有人的牌，而且不报错、不崩。
            // 本类的文档注释写着「other seat's legal input is exposed 不会发生」，
            // 手牌显然属于同一类东西，这是没做到自己声明的事。
            //
            // 裁剪语义照抄 GDScript 侧的 CWNet.view_for：**换成占位符、保留张数** ——
            // 「他有几张牌」是公开信息，「是哪几张」不是。
            var mine = authorizedSeat is { } seat && p.Seat == seat;
            var cells = s.Cells.Values.Where(c => c.OwnerSeat == p.Seat).OrderBy(c => c.Id.Value)
                .Select(c => new CellObservation(c.Id, c.OwnerSeat, c.Faction, c.Type, c.Position, c.Energy / 10.0, c.IsAlive,
                    mine ? c.Hand.ToImmutableArray() : MaskHand(c.Hand), c.Equipped.ToImmutableArray(), c.AttacksThisTurn, c.Differentiated,
                    c.Marked, c.MarkLeft, c.CampRound)).ToImmutableArray();
            return new PlayerObservation(p.Seat, p.Faction, p.IsAlive, cells.Where(c => c.IsAlive).Sum(c => c.Energy),
                cells, p.DrawCount, p.AntigenMemory, (int)p.ImmuneLevel,
                p.CancerType?.ToString(), cells.Sum(c => c.Hand.Length), IncomeFor(s, p.Seat));
        }).ToImmutableArray();
        // 日志原文（换内核 P2）：Cursor = 绝对下标；别人的秘密行（抽到的牌名）给公开替身，同 SeatFilter / GD `CWNet.logs_for`
        var messages = lease.Snapshot.Simulation.Logs.Select(l => new MessageEntry(l.Index,
            l.SecretSeat < 0 || l.SecretSeat == authorizedSeat ? l.Text : l.PublicText)).ToImmutableArray();
        var reason = s.Turn.Winner is { } w ? (w == Faction.Immune ? "免疫方获胜" : "癌症方获胜") : null;
        return new(lease.Revision, s.Board.Radius, s.Turn.WorldRound, s.Turn.Phase, s.Turn.ActivePlayerSeat, s.Turn.Winner,
            players,
            players.SelectMany(p => p.Cells).ToImmutableArray(),
            s.Board.Tissues.Values.OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R).Select(t => new TissueObservation(t.Position, t.Type, t.State, t.SolidificationCount / 10.0, t.OccupyingCell, t.Type == TissueType.BoneMarrow ? t.Charge : t.Charge / 10.0, rules.StoreFraction(t), rules.SolidFraction(s, t), t.Mucus, t.NecrosisRounds, t.OssifyAtRound, t.ProductionCounter)).ToImmutableArray(),
            visible ? pending!.RequestId : null, options, messages, reason);
    }

    /// <summary>别人的手牌：只留张数，不留是哪几张。与 GDScript 侧 CWNet.HIDDEN_CARD 同一个占位符。</summary>
    public const string HiddenCard = "？";

    private static ImmutableArray<string> MaskHand(IReadOnlyList<string> hand)
        => Enumerable.Repeat(HiddenCard, hand.Count).ToImmutableArray();

    /// <summary>
    /// 「预计收入」——**必须走 RulePolicies，不许在这里自己算一遍**。
    ///
    /// 2026-09-15 修：这里原来免疫那一半把基数 20/30/45/50 与两张装备的 +5/+8 写成了字面量，
    /// 而癌症那一半走的是 RulePolicies.AnaerobicShare —— **同一个函数里两种做法**。
    /// 而且那份手抄的还**抄漏了两条**：【TGF-β释放】每层 -20%、站在坏死格上减半，
    /// 二者都在 RulePolicies.AerobicShare 里。所以它不只是重复，是**重复且算错**。
    ///
    /// 这正是拍板记录决策 9（「UI 一个规则数值都不留」）要消灭的病，
    /// 只是它从 GDScript 的 UI 搬进了 C# 的观测层 —— 而它恰好就是 Kevin 点名的那条「预计收入」。
    /// </summary>
    private static double IncomeFor(WorldState s, int seat)
    {
        if (!s.Players.TryGetValue(seat, out var p)) return 0;
        var cells = s.Cells.Values.Where(c => c.OwnerSeat == seat && c.IsAlive).ToArray();
        if (cells.Length == 0) return 0;
        return cells.Sum(c => p.Faction == Faction.Immune
            ? RulePolicies.AerobicShare(s, c)
            : RulePolicies.AnaerobicShare(s, c)) / 10.0;
    }
}

/// <summary>宿主读到的一帧：权威世界 + 挂起的询问（没有 = null）+ 修订号。见 <see cref="MatchSession.Peek"/>。</summary>
public sealed record HostSnapshot(WorldState State, PendingInput? Input, Revision Revision);

/// <summary>Host lifecycle and authorization boundary. Caller supplies a trusted seat binding.</summary>
public sealed class MatchSession : ISession
{
    private readonly Runtime runtime;
    private readonly MatchObservationProvider observation;
    private readonly object gate = new();
    private readonly Dictionary<int, long> controllerEpochs = new();
    private readonly CancellationTokenSource lifetime = new();
    private bool disposed;
    public MatchSession(WorldState initial, ulong seed = 12345) : this(new WorldImage(initial), new Xoshiro256StarStar(seed), resume: false) { }

    /// <summary>
    /// 从装载好的世界续跑（换内核 P5：教程关首 / 关内换盘，以后的读档也走这里）。不排 TurnStart（那会从阶段开头推、
    /// 把世界里写好的「第 N 席行动中」结束掉），排一个 Resume 直接问当前席位。随机源可注入（教程挂 <see cref="ScriptedRng"/> 脚本骰子）。
    /// </summary>
    public static MatchSession Resume(WorldState world, IDeterministicRng rng) => new(new WorldImage(world), rng, resume: true);

    private MatchSession(WorldImage initial, IDeterministicRng rng, bool resume)
    {
        var rules = new BasicRulesEngine();
        var store = new InMemoryStateStore();
        runtime = new(store, store.Allocate(initial), Handlers(rules), rng);
        observation = new(rules);
        runtime.Schedule(0, resume ? "Resume" : "TurnStart");
        runtime.Run();
    }
    private MatchSession(Runtime runtime, BasicRulesEngine rules)
        => (this.runtime, observation) = (runtime, new(rules));

    /// <summary>正式开局：确定性初始化棋盘与席位，进入 Setup 选址阶段。</summary>
    public static MatchSession Start(int playerCount, ulong seed) => Start(seed, () => MatchSetup.Create(playerCount, seed));

    /// <summary>同上，开局世界由调用方建（sidecar 要钉癌种、注入显示名）。<paramref name="setup"/> 里写的日志一并收下。</summary>
    public static MatchSession Start(ulong seed, Func<WorldState> setup)
    {
        // 开局的无决策部分（GD `setup.begin()`）写的那几行日志（「初始癌组织：…」）发生在 Runtime 起来之前：
        // 开一个演出作用域收下来，铺进初始的 SimulationState —— 句柄条目流里它们照样排在第一问之前（同 GD InProc）
        WorldState world;
        IPresentationEvent[] boot;
        using (var stage = Stage.Open())
        {
            world = setup();
            boot = stage.Drain().ToArray();
        }
        return new(new WorldImage(world) { Simulation = boot.Aggregate(new SimulationState(), (sim, ev) => sim.Emit(ev)) }, new Xoshiro256StarStar(seed), resume: false);
    }
    private static IRuleHandler[] Handlers(BasicRulesEngine rules) => new IRuleHandler[]
        { new PlayerDecisionHandler(rules), new AdvancePhaseHandler(rules), new TurnStartHandler(), new ResumeHandler(rules) };
    /// <summary>
    /// 规划路径的下一步可达格：从 fromPos 出发、按当前世界规则能「移动/穿过友军」落脚的**空格**。
    /// 规划器只规划移动（攻击不进路线），所以排除被占据格。纯查询。
    /// </summary>
    public ImmutableArray<HexPosition> PlanNextDests(int authorizedSeat, EntityId cellId, HexPosition fromPos)
    {
        lock (gate)
        {
            using var lease = runtime.Read();
            var s = lease.Snapshot.State;
            if (!s.Cells.TryGetValue(cellId, out var cell) || cell.OwnerSeat != authorizedSeat || !cell.IsAlive)
                return ImmutableArray<HexPosition>.Empty;
            var moved = cell.WithPosition(fromPos);
            var seen = new HashSet<HexPosition>();
            foreach (var n in RulePolicies.PassThroughDests(s, moved))
            {
                if (s.GetCellAt(n) == null && RulePolicies.QuoteMove(s, moved, n) != null) seen.Add(n);
            }
            return seen.ToImmutableArray();
        }
    }

    /// <summary>
    /// 路径规划报价：对当前权威世界按 path 逐格报价（纯查询，不提交、不消耗额度）。
    /// cellId 必须属于 authorizedSeat，否则返回空报价。
    /// </summary>
    public PathQuote QuotePath(int authorizedSeat, EntityId cellId, IReadOnlyList<HexPosition> path)
    {
        lock (gate)
        {
            using var lease = runtime.Read();
            var s = lease.Snapshot.State;
            if (!s.Cells.TryGetValue(cellId, out var cell) || cell.OwnerSeat != authorizedSeat || !cell.IsAlive)
                return new(ImmutableArray<PathStep>.Empty, 0, 0, false, 0, -1);
            return RulePolicies.QuotePath(s, cell, path);
        }
    }
    public MatchObservation Observe(int? authorizedSeat)
    {
        lock (gate) { using var lease = runtime.Read(); return observation.Observe(lease, authorizedSeat); }
    }
    /// <summary>观测协议 v1（docs/观测协议_v1.md）：按 viewer 裁剪过的 envelope。viewer >= 0 席位 / -1 观众（openHands = 房主开的「观众全见」）/ -2 全知（**禁止过网**）。</summary>
    public Observation.ObsEnvelope ObserveV1(int viewer, bool openHands = false, long logsFrom = 0)
    {
        lock (gate) { using var lease = runtime.Read(); return Observation.SeatFilter.Crop(Observation.ObservationV1Codec.Encode(lease.Snapshot, lease.Revision, logsFrom), viewer, openHands); }
    }
    public ValidationResult Submit(int authorizedSeat, InputAnswer answer)
    {
        lock (gate)
        {
            using var lease = runtime.Read();
            if (lease.Snapshot.Simulation.Input?.PlayerSeat != authorizedSeat) return new(false, "Seat does not own this request.");
            var result = runtime.Answer(answer);
            if (result.IsValid) runtime.Run();
            return result;
        }
    }
    public int Advance(int budget = 256) { lock (gate) return runtime.Run(budget); }

    /// <summary>
    /// 宿主专用的只读口（2026-10-01 换内核 P1：sidecar 宿主拆问、合成 ask / game_over 条目要读决策本身；P3 的同进程 AI 也走它）。
    /// ★ 全知：世界里是全部明文手牌，**别过网** —— 过网的只有 <see cref="ObserveV1"/> 裁过的 envelope。
    /// </summary>
    public HostSnapshot Peek()
    {
        lock (gate)
        {
            using var lease = runtime.Read();
            return new(lease.Snapshot.State, lease.Snapshot.Simulation.Input, lease.Revision);
        }
    }
    public long ReplaceController(int seat)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var epoch = controllerEpochs.GetValueOrDefault(seat) + 1;
            controllerEpochs[seat] = epoch;
            return epoch;
        }
    }
    public async ValueTask<ValidationResult> RequestAsync(int seat, IDecisionSource source, CancellationToken cancellationToken = default)
    {
        DecisionRequest request;
        CancellationTokenSource linked;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            request = new(Observe(seat), controllerEpochs.GetValueOrDefault(seat));
            if (request.Observation.RequestId == null) return new(false, "No authorized input request.");
            linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
        }
        using (linked)
        {
            InputAnswer? answer;
            try { answer = await source.RequestAsync(request, linked.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return new(false, "Decision request cancelled."); }
            lock (gate)
            {
                if (disposed || linked.IsCancellationRequested || controllerEpochs.GetValueOrDefault(seat) != request.ControllerEpoch || answer == null)
                    return new(false, "Decision source result expired or unavailable.");
                if (answer.Value.RequestId != request.Observation.RequestId || answer.Value.ExpectedRevision != request.Observation.Revision)
                    return new(false, "Decision source answered a different request.");
                return Submit(seat, answer.Value);
            }
        }
    }
    /// <summary>观测协议附录 B：seq > <paramref name="sinceSeq"/> 的演出条目（换内核 P2 起含 `log` 条目）。
    /// 按 <paramref name="viewer"/> 裁的只有日志的秘密行：别人抽到的牌名换成公开替身（同 GD `cw_kernel_inproc.gd:_crop`；card_drawn 本来就不带牌名）。</summary>
    public Observation.PresentationPage PullPresentation(int viewer, long sinceSeq, int limit = 64)
    {
        lock (gate)
        {
            using var lease = runtime.Read();
            var sim = lease.Snapshot.Simulation;
            var entries = sim.Presentation.Where(e => e.Seq > sinceSeq).Take(Math.Max(0, limit))
                .Select(e => e.Event is LogWritten l && viewer != Observation.ObservationV1Codec.ViewerOmniscient && l.SecretSeat >= 0 && l.SecretSeat != viewer
                    ? e with { Event = l with { Text = l.PublicText } } : e)
                .Select(Observation.PresentationCodec.Encode).ToArray();
            return new(entries, sim.PresentationDroppedBefore, sim.NextPresentationSeq);
        }
    }

    /// <summary>作答：**语义键为准、下标兜底**（Kevin 拍 E-2；回放只有下标）。键在当前选项表里找不到才看下标；两者都对不上 = 拒答，不钳位。</summary>
    public ValidationResult SubmitByKey(int seat, long askId, string? key, int index)
    {
        InputAnswer answer;
        lock (gate)
        {
            using var lease = runtime.Read();
            var input = lease.Snapshot.Simulation.Input;
            if (input is null || input.RequestId != askId) return new(false, "No such request.");
            if (input.PlayerSeat != seat) return new(false, "Seat does not own this request.");
            var s = lease.Snapshot.State;
            var idx = -1;
            if (!string.IsNullOrEmpty(key))
                for (var i = 0; i < input.Options.Length && idx < 0; i++)
                    if (SemanticKey.Of(s, input.Options[i]) == key) idx = i;
            if (idx < 0 && index >= 0 && index < input.Options.Length) idx = index;
            if (idx < 0) return new(false, "Neither key nor index matches an option.");
            answer = new(askId, lease.Revision, idx);
        }
        return Submit(seat, answer);
    }

    /// <summary>观测协议 §5.3 查询式（不进每帧观测）：`plan_next_dests` / `quote_path` 走已有的两个方法；tier B 那两条（`cost_effects_for` / `move_block_reason`）2026-10-01 起走 Observation.Queries；未知 kind 返回 null。</summary>
    public System.Text.Json.JsonElement? QueryV1(int seat, string kind, System.Text.Json.JsonElement args)
    {
        static HexPosition At(System.Text.Json.JsonElement e) { var q = e.GetProperty("q").GetInt32(); var r = e.GetProperty("r").GetInt32(); return new(q, r, -q - r); }
        static EntityId Cell(System.Text.Json.JsonElement e) => new((ulong)(e.GetProperty("cid").GetInt32() + 1));
        object? result = kind switch
        {
            "plan_next_dests" => PlanNextDests(seat, Cell(args), At(args.GetProperty("from"))).Select(Observation.ObservationV1Codec.Pos).ToArray(),
            "quote_path" => Observation.ObservationV1Codec.PathQuote(QuotePath(seat, Cell(args), args.GetProperty("path").EnumerateArray().Select(At).ToArray())),
            // tier B 两条（换内核 P2，2026-10-01）：照 GD 只给自己的细胞问；批量形态 `acts[]` 一次问完整排按钮（协议 p=2）
            "cost_effects_for" => Own(seat, Cell(args)) is { } c1
                ? args.TryGetProperty("acts", out var acts)
                    ? acts.EnumerateArray().Select(a => a.GetString()!).Distinct().ToDictionary(a => a, a => Read(s => Observation.Queries.CostEffectsFor(s, c1(s), a)), StringComparer.Ordinal)
                    : args.TryGetProperty("act", out var act) ? Read(s => Observation.Queries.CostEffectsFor(s, c1(s), act.GetString()!)) : null
                : null,
            "move_block_reason" => Own(seat, Cell(args)) is { } c2 && args.TryGetProperty("to", out var to) ? Read(s => Observation.Queries.MoveBlockReason(s, c2(s), At(to))) : null,
            _ => null,
        };
        return result is null ? null : System.Text.Json.JsonSerializer.SerializeToElement(result, Observation.ObservationV1Codec.Json);
    }

    /// <summary>改显示名（GD `mark_player` / 联机昵称同一个字段）。纯装饰，不进规则；之后的观测与日志都用新名字。</summary>
    public void Rename(int seat, string name)
    {
        lock (gate)
            runtime.EditWorld(s => s.Players.TryGetValue(seat, out var p) ? s.UpdatePlayer(seat, With(p, name)) : s);
    }

    private static Player With(Player p, string name) => new()
    {
        Seat = p.Seat, Faction = p.Faction, IsAlive = p.IsAlive, DrawCount = p.DrawCount,
        AntigenMemory = p.AntigenMemory, ImmuneLevel = p.ImmuneLevel, CancerType = p.CancerType, Name = name,
    };

    /// <summary>
    /// 投降（GD `cw_game.gd surrender`）：对方阵营直接获胜，`win_kind` = surrender_cancer / surrender_immune。已经分出胜负、或阵营不对（观战席）就什么都不做。
    /// 返回是否真的结束了对局。GD 那句「=== X投降：Y胜利 ===」的日志等日志通道落地后补（P2 日志那一段）。
    /// </summary>
    public bool Surrender(Faction faction)
    {
        lock (gate)
        {
            using (var lease = runtime.Read())
                if (lease.Snapshot.State.Turn.Winner is not null) return false;
            var winner = faction == Faction.Immune ? Faction.Cancer : Faction.Immune;
            var kind = winner == Faction.Cancer ? "surrender_cancer" : "surrender_immune";
            // GD 两句：`surrender()` 自己写「=== 免疫方投降：癌症胜利 ===」（cw_game.gd:1148），随后驱动循环跳出、写终局那句（cw_game.gd:169）。
            // C# 的驱动循环（RuleFlow.Continue）在 EditWorld 收局之后不会再跑，终局那句由这里一并写
            runtime.EditWorld(s => s.WithTurn(s.Turn.Copy(phase: Phase.Finished, winner: winner, winKind: kind)), endMatch: true,
                emit: s => [Line(s, $"=== {Observation.ObservationV1Codec.WinReason(s)} ==="), Line(s, $"=== 对局结束：{Observation.ObservationV1Codec.WinReason(s)} ===")]);
            return true;
        }
    }

    /// <summary>
    /// 宿主往对局日志里插一行（GD `CWKernel.log_msg` → `CWGame.log_msg`；服务器投降投票那两行）。不碰规则、不改盘面。
    /// <paramref name="secretSeat"/> ≥ 0 = 只有那一席看原文，别人看 <paramref name="publicText"/>。
    /// </summary>
    public void LogMessage(string text, int secretSeat = -1, string? publicText = null)
    {
        lock (gate) runtime.EditWorld(s => s, emit: s => [Line(s, text, secretSeat, publicText)]);
    }

    private static LogLine Line(WorldState s, string text, int secretSeat = -1, string? publicText = null)
        => new(s.Turn.WorldRound, s.Turn.Phase, text, secretSeat, publicText);

    /// <summary>查询式的读法：拿一份当前世界跑纯函数（锁里读、锁外不碰 runtime）。</summary>
    private T Read<T>(Func<WorldState, T> f)
    {
        lock (gate) { using var lease = runtime.Read(); return f(lease.Snapshot.State); }
    }

    /// <summary>这只细胞归 <paramref name="seat"/> 管且活着 → 返回「从世界里取它」的函数；否则 null（同 PlanNextDests / QuotePath 的授权口径）。</summary>
    private Func<WorldState, Cell>? Own(int seat, EntityId id)
    {
        var ok = Read(s => s.Cells.TryGetValue(id, out var c) && c.OwnerSeat == seat);
        return ok ? s => s.Cells[id] : null;
    }

    /// <summary>三个字段分开（迁移计划 §三 硬不变量③）。`digest` 批 0 先与 `rules_build` 同值，sidecar 那一批定稿。</summary>
    public Observation.ObsVersion Version() => new(Observation.ObservationV1Codec.HostAbi, Observation.ObservationV1Codec.RulesBuild, Observation.ObservationV1Codec.RulesBuild);

    /// <summary>★ 含 rng 与全部明文手牌：**宿主专用、绝不过网、绝不裁剪**（观测协议 §七）。客户端能拿到的只有 <see cref="ObserveV1"/> 裁过的 envelope。</summary>
    public Checkpoint Save() { lock (gate) return runtime.Checkpoint(); }
    public MatchSession Fork()
    {
        lock (gate) return new((Runtime)runtime.Fork(), new BasicRulesEngine());
    }
    public static MatchSession Restore(Checkpoint checkpoint)
    {
        var store = new InMemoryStateStore();
        if (store.Import(checkpoint) is not Result<StoreKey, SnapshotError>.Ok imported)
            throw new ArgumentException("Invalid checkpoint.", nameof(checkpoint));
        var rules = new BasicRulesEngine();
        return new(new Runtime(store, imported.Value, Handlers(rules), new Xoshiro256StarStar(1)), rules);
    }
    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            runtime.Dispose();
        }
        // External cancellation callbacks must not run while holding the session mailbox lock.
        lifetime.Cancel();
        lifetime.Dispose();
    }
}
