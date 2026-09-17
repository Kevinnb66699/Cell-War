using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>
/// 规则代码往演出通道投递的口子（口径二 · 批 0 步 6）。
///
/// 规则函数大多只返回 <see cref="WorldState"/>、没有事件列表；改签名等于把整个内核重排一遍（Kevin 09-18 口径：保留架构）。
/// 所以用一个**按线程的作用域**：<see cref="BasicRulesEngine"/> 的 ExecuteDecision / AdvancePhase 进来时 <see cref="Open"/> 一个，
/// 规则代码里 <see cref="Emit"/> 往当前作用域投递，退出时攒下的条目并进 <see cref="RulesResult.Events"/>（排在规则事件之后，彼此保持发生顺序）。
/// 没有作用域（测试直接调纯函数、L1 重放的 KeyWalk）就丢弃 —— 演出不是规则的一部分，丢了不影响任何结算、不进 canon、不进 state_hash。
/// 嵌套（推演里再开一层）各自成栈，互不串。
/// </summary>
internal static class Stage
{
    [ThreadStatic] private static List<IPresentationEvent>? current;

    public static void Emit(IPresentationEvent ev) => current?.Add(ev);

    public static Scope Open() => new();

    /// <summary>把作用域里攒下的演出并进结算结果；失败的结算什么都不带（事务本来就不提交）。</summary>
    public static RulesResult Merge(RulesResult result, Scope scope)
    {
        var staged = scope.Drain();
        if (!result.Success || staged.Count == 0) return result;
        return result with { Events = [.. result.Events, .. staged] };
    }

    public sealed class Scope : IDisposable
    {
        private readonly List<IPresentationEvent>? outer;
        private readonly List<IPresentationEvent> mine = new();
        public Scope() { outer = current; current = mine; }
        public IReadOnlyList<IPresentationEvent> Drain() => mine;
        public void Dispose() => current = outer;
    }

    /// <summary>`show_fx(kind, data)` 的便捷构造：data 只装 int / bool / 坐标 / 坐标数组（cw_game.gd:819-821）。</summary>
    public static SkillFx Fx(WorldState s, string kind, params (string Key, object Value)[] data)
        => new(s.Turn.WorldRound, s.Turn.Phase, kind, data.ToImmutableDictionary(d => d.Key, d => d.Value, StringComparer.Ordinal));

    /// <summary>
    /// GD `CWData.dir_toward(dest, from)`（cw_data.gd:945-960）：癌从 <paramref name="from"/> 那一侧漫入 <paramref name="dest"/>，
    /// 返回 `DIRS` 下标。相邻就是那一侧；跃进 / 传送取最接近来路的一侧（六方向里点积最大的）；原地不动 -1（不演）。
    /// </summary>
    public static int DirToward(HexPosition dest, HexPosition from)
    {
        var dq = from.Q - dest.Q;
        var dr = from.R - dest.R;
        if (dq == 0 && dr == 0) return -1;
        // **单精度**：Godot 的 Vector2 是 float32，正对角来路（d = (-k,-k)）上 DIRS[2] 与 DIRS[3] 的点积在 float32 下恰好打平（0.8660254f² 舍成 0.75f），
        // `>` 严格于是取在前的下标 2；用 double 算会取 3 —— 复核 2026-09-18 实测。所以这里逐字照 GD 用 float。
        var vx = (float)(dq + dr * 0.5);
        var vy = (float)(dr * 0.8660254);
        var best = -1;
        var bestDot = float.NegativeInfinity;
        for (var i = 0; i < SemanticKey.GdDirs.Count; i++)
        {
            var (q, r) = SemanticKey.GdDirs[i];
            if (q == dq && r == dr) return i;
            var ux = (float)(q + r * 0.5);
            var uy = (float)(r * 0.8660254);
            var dot = vx * ux + vy * uy;
            if (dot > bestDot) { bestDot = dot; best = i; }
        }
        return best;
    }

    /// <summary>GD `CWData.fmt(e)`：十分位整数 → "x.y"（负数也照 GD：`%d.%d % [e / 10, abs(e) % 10]`）。</summary>
    public static string Fmt(int tenths) => $"{tenths / 10}.{Math.Abs(tenths) % 10}";

    /// <summary>GD `CWCardFx._evt(card, text, at)`：事件卡的一句话通报（试玩后定：必须带上造成了什么效果），停得久些（linger）。</summary>
    public static void Evt(WorldState s, string card, string text, HexPosition at)
        => Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, $"事件【{card}】{text}", at, true));

    /// <summary>GD `CWGame.announce(text, at, linger)`。</summary>
    public static void Announce(WorldState s, string text, HexPosition at, bool linger = false)
        => Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, text, at, linger));

    /// <summary>GD `CWGame.cell_name(c)`：席位名 + 「(种类名)」，种类名照 CWData.IMMUNE_TYPE_NAMES / CANCER_TYPE_NAMES。</summary>
    public static string CellName(WorldState s, Cell c) => $"{SeatName(s, c.OwnerSeat)}({TypeName(c.Type)})";

    public static string TypeName(CellType type) => type switch
    {
        CellType.ImmuneBasic => "免疫细胞", CellType.BCell => "B细胞", CellType.TCell => "T细胞", CellType.Macrophage => "巨噬细胞", CellType.Dendritic => "树突状细胞",
        CellType.Melanoma => "恶性黑色素瘤", CellType.SignetRing => "印戒细胞癌", CellType.Osteosarcoma => "骨肉瘤", CellType.SmallCellLung => "小细胞肺癌",
        _ => type.ToString(),
    };

    /// <summary>GD `CWGame.init`（cw_game.gd:140-152）的默认席位名：阵营词 + 同阵营内的序号字母（免疫A / 癌症B…）。宿主可另注入名字，这里只是内核文案的底。</summary>
    public static string SeatName(WorldState s, int seat)
    {
        if (!s.Players.TryGetValue(seat, out var p)) return $"席位{seat}";
        var index = s.Players.Values.Count(x => x.Faction == p.Faction && x.Seat < seat);
        return (p.Faction == Faction.Immune ? "免疫" : "癌症") + (char)('A' + index);
    }
}
