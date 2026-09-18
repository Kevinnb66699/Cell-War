using System.Text.Json;

namespace CellWar.Core.Observation;

/// <summary>一页演出条目（`kernel.pull` 的返回）：条目 + 水位线（比它小的 seq 已不可得）+ 下一个序号。</summary>
public sealed record PresentationPage(Dictionary<string, JsonElement>[] Entries, long DroppedBefore, long NextSeq);

/// <summary>
/// 演出条目 → 内核句柄条目（docs/观测协议_v1.md 附录 B）。字段名逐字照 GD `cw_net_bridge.gd` 的报文键；
/// 每条另带 `t` / `seq` / `barrier`（只有 roll 为 true）。C# 记录上的 WorldRound / Phase 不上线（GD 报文没有）。
/// 值编码与观测协议同一套：坐标 `{q,r}`、细胞引用 cell id、枚举 GD 值（`immune_attack` 的 itype / ctype 在 emit 点就已经是 GD 值，见 <see cref="GdEnum"/>）。
/// </summary>
public static class PresentationCodec
{
    public static Dictionary<string, JsonElement> Encode(StagedEvent staged)
    {
        var d = new Dictionary<string, object?>(StringComparer.Ordinal);
        switch (staged.Event)
        {
            case DiceRolled r:
                d["t"] = "roll"; d["reason"] = r.Reason; d["value"] = r.Value; d["sides"] = r.Sides; d["pid"] = r.Seat; d["at"] = r.At; break;
            case AttackResolved a:
                d["t"] = "attack"; d["attacker"] = a.Attacker; d["defender"] = a.Defender; d["roll"] = a.Roll; d["rerolled"] = a.Rerolled;
                d["outcome"] = a.Outcome; d["dealt"] = a.Dealt; d["shielded"] = a.Shielded; d["is_kill"] = a.IsKill; break;
            case ResultAnnounced x:
                d["t"] = "result"; d["text"] = x.Text; d["at"] = x.At; d["linger"] = x.Linger; break;
            case NoticeAnnounced n:
                d["t"] = "notice"; d["text"] = n.Text; break;
            case CardPlayed c:
                d["t"] = "card_played"; d["pid"] = c.Seat; d["text"] = c.Text; d["cell_id"] = c.CellId; d["pos"] = c.Pos; d["faction"] = (int)c.Faction; d["card"] = c.Card; break;
            case EventCardDrawn e:
                d["t"] = "event_drawn"; d["pid"] = e.Seat; d["cell_id"] = e.CellId; d["pos"] = e.Pos; d["faction"] = (int)e.Faction; d["card"] = e.Card; break;
            case CardDrawn c:   // 刻意不带牌名（cw_game.gd:785）
                d["t"] = "card_drawn"; d["pid"] = c.Seat; d["cell_id"] = c.CellId; d["pos"] = c.Pos; d["source"] = c.Source; break;
            case WorldEventDrawn w:
                d["t"] = "world_event"; d["ev"] = w.Name; d["left"] = w.Left; break;
            case TissueConverted t:
                d["t"] = "erosion"; d["at"] = t.At; d["dir"] = t.Dir; break;
            case BeamFired b:
                d["t"] = "beam"; d["from"] = b.From; d["to"] = b.To; d["splash"] = b.Splash; break;
            case SkillFx f:
                d["t"] = "fx"; d["kind"] = f.Kind; d["data"] = f.Data; break;
            default:
                throw new InvalidOperationException($"演出记录 {staged.Event.GetType().Name} 还没有条目编码 —— 加一条，别让它静默缺席");
        }
        d["seq"] = staged.Seq;
        d["barrier"] = staged.Event is DiceRolled;
        return d.ToDictionary(kv => kv.Key, kv => JsonSerializer.SerializeToElement(Value(kv.Value), ObservationV1Codec.Json), StringComparer.Ordinal);
    }

    /// <summary>fx 的 data 值没有固定形状（坐标 / 坐标列表 / 细胞引用 / 标量），按运行时类型换成协议编码。</summary>
    private static object? Value(object? v) => v switch
    {
        HexPosition p => ObservationV1Codec.Pos(p),
        EntityId id => ObservationV1Codec.Id(id),
        IEnumerable<HexPosition> ps => ps.Select(ObservationV1Codec.Pos).ToArray(),
        IReadOnlyDictionary<string, object> dict => dict.ToDictionary(kv => kv.Key, kv => Value(kv.Value), StringComparer.Ordinal),
        _ => v,
    };
}
