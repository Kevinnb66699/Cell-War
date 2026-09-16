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
            PlaceDecision p => new VisibleOption(index, d.DecisionType, null, p.TargetPosition, null),
            DifferentiateDecision f => new VisibleOption(index, d.DecisionType, f.CellId, null, null, f.Type),
            DrawDecision w => new VisibleOption(index, d.DecisionType, w.CellId, null, null, null),
            MutateDecision m => new VisibleOption(index, d.DecisionType, m.CellId, null, null, null),
            PlayCardDecision p => new VisibleOption(index, d.DecisionType, p.CellId, p.Target, null, null, p.Card),
            DiscardDecision x => new VisibleOption(index, d.DecisionType, x.CellId, null, null, null, x.Card),
            ChooseMutationDecision m => new VisibleOption(index, d.DecisionType, m.CellId, null, null, null),
            TypeSkillDecision t => new VisibleOption(index, d.DecisionType, t.CellId, t.Target, null, null, null, t.Skill),
            _ => new VisibleOption(index, d.DecisionType, null, null, null)
        }).ToImmutableArray() : ImmutableArray<VisibleOption>.Empty;
        var players = s.Players.Values.OrderBy(p => p.Seat).Select(p =>
        {
            var cells = s.Cells.Values.Where(c => c.OwnerSeat == p.Seat).OrderBy(c => c.Id.Value)
                .Select(c => new CellObservation(c.Id, c.OwnerSeat, c.Faction, c.Type, c.Position, c.Energy / 10.0, c.IsAlive,
                    c.Hand.ToImmutableArray(), c.Equipped.ToImmutableArray(), c.AttacksThisTurn, c.Differentiated,
                    c.Marked, c.MarkLeft, c.CampRound)).ToImmutableArray();
            return new PlayerObservation(p.Seat, p.Faction, p.IsAlive, cells.Where(c => c.IsAlive).Sum(c => c.Energy),
                cells, p.DrawCount, p.AntigenMemory, (int)p.ImmuneLevel,
                p.CancerType?.ToString(), cells.Sum(c => c.Hand.Length), IncomeFor(s, p.Seat));
        }).ToImmutableArray();
        var messages = lease.Snapshot.Simulation.Outbox.Select((text, i) => new MessageEntry(i, text)).ToImmutableArray();
        var reason = s.Turn.Winner is { } w ? (w == Faction.Immune ? "免疫方获胜" : "癌症方获胜") : null;
        return new(lease.Revision, s.Board.Radius, s.Turn.WorldRound, s.Turn.Phase, s.Turn.ActivePlayerSeat, s.Turn.Winner,
            players,
            players.SelectMany(p => p.Cells).ToImmutableArray(),
            s.Board.Tissues.Values.OrderBy(t => t.Position.Q).ThenBy(t => t.Position.R).Select(t => new TissueObservation(t.Position, t.Type, t.State, t.SolidificationCount / 10.0, t.OccupyingCell, t.Type == TissueType.BoneMarrow ? t.Charge : t.Charge / 10.0, rules.StoreFraction(t), rules.SolidFraction(s, t), t.Mucus, t.NecrosisRounds, t.OssifyAtRound, t.ProductionCounter)).ToImmutableArray(),
            visible ? pending!.RequestId : null, options, messages, reason);
    }

    private static double IncomeFor(WorldState s, int seat)
    {
        if (!s.Players.TryGetValue(seat, out var p)) return 0;
        var cells = s.Cells.Values.Where(c => c.OwnerSeat == seat && c.IsAlive);
        if (!cells.Any()) return 0;
        if (p.Faction == Faction.Immune)
        {
            var baseIncome = p.ImmuneLevel switch { ImmuneLevel.I => 20, ImmuneLevel.II => 30, ImmuneLevel.III => 45, _ => 50 };
            return cells.Sum(c => (c.Equipped.Contains("代谢适应") ? 5 : 0) + (c.Equipped.Contains("自分泌生存信号") ? 8 : 0) + baseIncome) / 10.0;
        }
        return cells.Sum(c => RulePolicies.AnaerobicShare(s, c)) / 10.0;
    }
}

/// <summary>Host lifecycle and authorization boundary. Caller supplies a trusted seat binding.</summary>
public sealed class MatchSession : ISession
{
    private readonly Runtime runtime;
    private readonly MatchObservationProvider observation;
    private readonly object gate = new();
    private readonly Dictionary<int, long> controllerEpochs = new();
    private readonly CancellationTokenSource lifetime = new();
    private bool disposed;
    public MatchSession(WorldState initial, ulong seed = 12345)
    {
        var rules = new BasicRulesEngine();
        var store = new InMemoryStateStore();
        runtime = new(store, store.Allocate(new(initial)), Handlers(rules), new Xoshiro256StarStar(seed));
        observation = new(rules);
        runtime.Schedule(0, "TurnStart");
        runtime.Run();
    }
    private MatchSession(Runtime runtime, BasicRulesEngine rules)
        => (this.runtime, observation) = (runtime, new(rules));

    /// <summary>正式开局：确定性初始化棋盘与席位，进入 Setup 选址阶段。</summary>
    public static MatchSession Start(int playerCount, ulong seed)
        => new(MatchSetup.Create(playerCount, seed), seed);
    private static IRuleHandler[] Handlers(BasicRulesEngine rules) => new IRuleHandler[]
        { new PlayerDecisionHandler(rules), new AdvancePhaseHandler(rules), new TurnStartHandler() };
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
