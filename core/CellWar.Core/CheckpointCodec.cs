using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CellWar.Core;

internal static class PayloadCodec
{
    internal static readonly Type[] Types =
    {
        typeof(string), typeof(int), typeof(long), typeof(double), typeof(bool), typeof(decimal),
        typeof(MoveDecision), typeof(EndTurnDecision), typeof(PassDecision), typeof(ReviveDecision), typeof(PlaceDecision), typeof(DifferentiateDecision),
        typeof(DrawDecision), typeof(DiscardDecision), typeof(MutateDecision), typeof(PlayCardDecision), typeof(ChooseMutationDecision), typeof(TypeSkillDecision),
        // 挂起态的选项也会进 `Runtime` 的待答选项表（Runtime.cs:230 逐条 Validate），漏登记
        // 不会编译报错，是运行时的 `Unknown payload type.`。【连续吞噬】那一对就这么漏了一阵 ——
        // 巨噬的连锁追问挂起时存一次档就炸。现在有一条反射护栏（PayloadCodecGuardTests）盯着这张表。
        typeof(ChainMoveDecision), typeof(StopChainDecision), typeof(SkipReviveDecision),
        typeof(CoupleDirectionDecision), typeof(CoupleTierDecision), typeof(CancelCoupleDecision),
        typeof(ChemotaxisStepDecision), typeof(StopChemotaxisDecision),
        typeof(RemodelPickDecision), typeof(StopRemodelDecision)
    };
    public static void Validate(object? value)
    {
        if (value != null && !Types.Contains(value.GetType()))
            throw new ArgumentException($"Unsupported mutable or unregistered payload: {value.GetType().Name}");
    }
    internal sealed class Converter : JsonConverter<object>
    {
        public override object? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            using var document = JsonDocument.ParseValue(ref reader);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Null) return null;
            var name = root.GetProperty("type").GetString();
            var target = Types.SingleOrDefault(t => t.Name == name) ?? throw new JsonException("Unknown payload type.");
            return root.GetProperty("value").Deserialize(target, options);
        }
        public override void Write(Utf8JsonWriter writer, object value, JsonSerializerOptions options)
        {
            Validate(value);
            writer.WriteStartObject();
            writer.WriteString("type", value.GetType().Name);
            writer.WritePropertyName("value");
            JsonSerializer.Serialize(writer, value, value.GetType(), options);
            writer.WriteEndObject();
        }
    }
}

internal static class CheckpointCodec
{
    private sealed record InputData(long RequestId, int Seat, object[] Options);
    private sealed record FutureData(EventOrder Order, ScheduledEvent Event);
    private sealed record ImageData(int Schema, string Ruleset, long Revision, WorldState State,
        long Tick, int NextSequence, long NextRequest, RngState? Rng, FutureData[] Future,
        ScheduledEvent[] Immediate, InputData? Input, string[] Outbox, bool Terminated,
        long NextPresentationSeq,   // Schema 2（2026-09-18，Kevin 拍 E-5）：演出条目本身不进档，只持久化序号，续档后 seq 续得上（水位线是派生的）
        long FeedSeq, FeedEntry[] FeedLog);   // 出牌流水是状态（观测协议 g.feed_log），与 Outbox 一样进档；Schema 2 尚未发布，直接并入
    private static readonly JsonSerializerOptions Options = CreateOptions();
    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions();
        options.Converters.Add(new MapConverterFactory());
        options.Converters.Add(new PayloadCodec.Converter());
        return options;
    }
    public static Checkpoint Encode(WorldImage image, Revision revision)
    {
        var s = image.Simulation;
        return new(JsonSerializer.Serialize(new ImageData(2, "core-slice-1", revision.Value, image.State,
            s.Tick, s.NextSequence, s.NextRequest, s.Rng,
            s.Future.Select(p => new FutureData(p.Key, p.Value)).ToArray(), s.Immediate.ToArray(),
            s.Input is null ? null : new(s.Input.RequestId, s.Input.PlayerSeat, s.Input.Options.Cast<object>().ToArray()),
            s.Outbox.ToArray(), s.Terminated, s.NextPresentationSeq, s.FeedSeq, s.FeedLog.ToArray()), Options));
    }
    public static (WorldImage, Revision) Decode(Checkpoint checkpoint)
    {
        var data = JsonSerializer.Deserialize<ImageData>(checkpoint.Json, Options) ?? throw new JsonException("Empty checkpoint.");
        // Schema 1 没有演出计数器；C# 侧今天没有任何玩家存档（服务器跑的是整份 Godot 工程），所以直接只认 2
        if (data.Schema != 2 || data.Ruleset != "core-slice-1" || data.Revision < 0 || data.Tick < 0 || data.NextSequence < 0 || data.NextRequest < 1
            || data.NextPresentationSeq < 1 || data.FeedSeq < 0)
            throw new JsonException("Unsupported checkpoint schema, ruleset or counters.");
        if (data.State?.Board?.Tissues == null || data.State.Cells == null || data.State.Players == null || data.State.Turn == null ||
            data.Future == null || data.Immediate == null || data.Outbox == null || data.FeedLog == null)
            throw new JsonException("Incomplete checkpoint.");
        if (data.State.Board.Radius < 0 || data.State.Turn.WorldRound < 1 || !Enum.IsDefined(data.State.Turn.Phase))
            throw new JsonException("Invalid world calendar or board.");
        foreach (var pair in data.State.Cells)
        {
            var c = pair.Value;
            if (c == null || c.Id != pair.Key || !c.Position.IsValid || !double.IsFinite(c.Energy) || c.Energy < 0 ||
                !Enum.IsDefined(c.Type) || !data.State.Players.ContainsKey(c.OwnerSeat)) throw new JsonException("Invalid cell state.");
        }
        foreach (var pair in data.State.Board.Tissues)
        {
            var t = pair.Value;
            if (t == null || t.Position != pair.Key || !t.Position.IsValid || !double.IsFinite(t.SolidificationCount) ||
                t.SolidificationCount < 0 || t.Charge is { } charge && (!double.IsFinite(charge) || charge < 0))
                throw new JsonException("Invalid tissue state.");
        }
        foreach (var pair in data.State.Players)
            if (pair.Value == null || pair.Key != pair.Value.Seat) throw new JsonException("Invalid player state.");
        if (data.Rng is { } rng) new Xoshiro256StarStar(1).SetState(rng);
        var future = ImmutableSortedDictionary<EventOrder, ScheduledEvent>.Empty;
        var sequences = new HashSet<int>();
        foreach (var entry in data.Future)
        {
            ValidateEvent(entry.Event);
            if (entry.Order.Tick != entry.Event.Tick || entry.Order.Sequence != entry.Event.SequenceId)
                throw new JsonException("Invalid event ordering key.");
            future = future.Add(entry.Order, entry.Event);
        }
        foreach (var entry in data.Immediate) ValidateEvent(entry);
        if (data.Immediate.Any(e => e.Tick != data.Tick)) throw new JsonException("Immediate events must belong to the current time.");
        void ValidateEvent(ScheduledEvent entry)
        {
            if (entry.Tick < data.Tick || entry.SequenceId < 0 || entry.SequenceId >= data.NextSequence ||
                !sequences.Add(entry.SequenceId) || string.IsNullOrWhiteSpace(entry.EventType))
                throw new JsonException("Invalid scheduled event.");
            PayloadCodec.Validate(entry.Payload);
        }
        PendingInput? input = null;
        if (data.Input is { } pending)
        {
            if (pending.RequestId < 1 || pending.RequestId >= data.NextRequest || pending.Options == null ||
                pending.Options.Length == 0 || pending.Options.Any(o => o is not IDecision d || d.PlayerSeat != pending.Seat))
                throw new JsonException("Invalid pending input.");
            input = new(pending.RequestId, pending.Seat, pending.Options.Cast<IDecision>().ToImmutableArray());
        }
        return (new WorldImage(data.State)
        {
            Simulation = new SimulationState
            {
                Tick = data.Tick, NextSequence = data.NextSequence, NextRequest = data.NextRequest,
                Rng = data.Rng, Future = future, Immediate = ImmutableStack.CreateRange(data.Immediate.Reverse()),
                Input = input, Outbox = data.Outbox.ToImmutableList(), Terminated = data.Terminated,
                NextPresentationSeq = data.NextPresentationSeq,
                FeedSeq = data.FeedSeq, FeedLog = ImmutableList.CreateRange(data.FeedLog),
            }
        }, new(data.Revision));
    }

    private sealed class MapConverterFactory : JsonConverterFactory
    {
        public override bool CanConvert(Type type) => type.IsGenericType && type.GetGenericTypeDefinition() == typeof(PagedMap<,>);
        public override JsonConverter CreateConverter(Type type, JsonSerializerOptions options)
            => (JsonConverter)Activator.CreateInstance(typeof(MapConverter<,>).MakeGenericType(type.GetGenericArguments()))!;
    }
    private sealed class MapConverter<K, V> : JsonConverter<PagedMap<K, V>> where K : notnull
    {
        public override PagedMap<K, V> Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            var pairs = JsonSerializer.Deserialize<KeyValuePair<K, V>[]>(ref reader, options) ?? throw new JsonException("Null map.");
            var builder = PagedMap<K, V>.Empty.ToBuilder();
            foreach (var pair in pairs)
            {
                if (builder.TryGetValue(pair.Key, out _)) throw new JsonException("Duplicate map key.");
                builder[pair.Key] = pair.Value;
            }
            return builder;
        }
        public override void Write(Utf8JsonWriter writer, PagedMap<K, V> value, JsonSerializerOptions options)
            => JsonSerializer.Serialize(writer, value.OrderBy(p => p.Key switch
            {
                EntityId id => id.Value.ToString("D20"),
                int id => id.ToString("D10"),
                HexPosition pos => $"{pos.Q + 32768:D5}:{pos.R + 32768:D5}",
                _ => p.Key.ToString()
            }, StringComparer.Ordinal).ToArray(), options);
    }
}
