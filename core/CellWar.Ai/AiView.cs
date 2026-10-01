using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// 一个世界的 **GD 形状读法**：GD 策略代码里的 <c>game.cell_of / living_cells / cells_at / tile / is_cancerous /
/// count_tissue / memory / immune_level</c> 逐个对到这里，搬过来的策略照着 GD 的写法读。
///
/// 两处口径差要在这里抹平（审计 10-01）：
/// · 免疫等级 GD 是 0..3（I/II/III/X），C# 枚举是 1..4 —— <see cref="ImmuneLevelGd"/> 给 GD 的数，
///   GD 拿它当 <c>tune.immune_move_*</c> 的下标、也当拟合估值的特征（log(1 + 等级)），差一就全错；
/// · GD 的 <c>cells</c> 下标 = 席位，C# 的细胞按 <see cref="Cell.OwnerSeat"/> 找（id = 席位 + 1 只是惯例，不靠它）。
///
/// 只读、按世界缓存（同一个世界在一问里被读几百次）。格子抄进一张稠密数组：<c>WorldState</c> 的 PagedMap
/// 每查一格是两层不可变字典，推演里一问要查上万次，直接查它占了读数的七成（2026-10-01 实测）。
/// </summary>
internal sealed class AiView
{
    public WorldState S { get; }
    private readonly Dictionary<int, Cell> bySeat = new();
    private readonly List<Cell> livingImmune = [];
    private readonly List<Cell> livingCancer = [];
    private readonly Dictionary<HexPosition, List<Cell>> livingAt = new();
    private readonly int radius;
    private readonly int side;
    private readonly Tissue?[] grid;
    private readonly List<HexPosition> all = [];
    private List<HexPosition>? cancerous;

    public AiView(WorldState s)
    {
        S = s;
        foreach (var c in RulePolicies.Cells(s))   // 按席位排：GD living_cells 的次序（cells 数组 = 席位序）
        {
            bySeat.TryAdd(c.OwnerSeat, c);
            if (!c.IsAlive) continue;
            (c.Faction == Faction.Immune ? livingImmune : livingCancer).Add(c);
            if (!livingAt.TryGetValue(c.Position, out var list)) livingAt[c.Position] = list = [];
            list.Add(c);
        }
        radius = s.Board.Radius;
        side = 2 * radius + 1;
        grid = new Tissue?[side * side];
        foreach (var t in s.Board.Tissues.Values)
        {
            var i = Index(t.Position);
            if (i < 0) continue;   // 半径之外的格（手摆的夹具）：AI 读不到它，等同于 GD 的盘外
            grid[i] = t;
            all.Add(t.Position);
        }
    }

    private int Index(HexPosition p)
    {
        var q = p.Q + radius;
        var r = p.R + radius;
        return q < 0 || r < 0 || q >= side || r >= side ? -1 : q * side + r;
    }

    public Cell? CellOf(int seat) => bySeat.GetValueOrDefault(seat);
    public Faction FactionOf(int seat) => S.Players[seat].Faction;
    public IReadOnlyList<Cell> Living(Faction f) => f == Faction.Immune ? livingImmune : livingCancer;

    public int CellsAtCount(HexPosition p) => livingAt.TryGetValue(p, out var l) ? l.Count : 0;
    public bool AnyAt(HexPosition p, Faction f) => livingAt.TryGetValue(p, out var l) && l.Any(c => c.Faction == f);
    public IEnumerable<Cell> CellsAt(HexPosition p, Faction f)
        => livingAt.TryGetValue(p, out var l) ? l.Where(c => c.Faction == f) : [];

    public Tissue Tile(HexPosition p) => (Index(p) is var i && i >= 0 ? grid[i] : null)
        ?? throw new KeyNotFoundException($"({p.Q},{p.R}) 不在棋盘上");
    public bool OnBoard(HexPosition p) => Index(p) is var i && i >= 0 && grid[i] != null;
    public bool IsCancerous(HexPosition p) => Tile(p).State != TissueState.Healthy;
    public int CountTissue(TissueState st)
    {
        var n = 0;
        foreach (var t in grid) if (t != null && t.State == st) n++;
        return n;
    }

    /// <summary>GD <c>game.memory</c>（阵营共享的抗原记忆）。</summary>
    public int Memory => S.FactionMemory(Faction.Immune);
    /// <summary>GD <c>game.immune_level</c>：**0..3**（C# 枚举是 1..4）。</summary>
    public int ImmuneLevelGd => (int)S.FactionImmuneLevel(Faction.Immune) - 1;
    public RuleTuning Tune => S.Tuning;
    public int SolidifyThreshold => BoardRules.SolidifyThreshold(S);
    public int Round => S.Turn.WorldRound;

    /// <summary>GD <c>CWData.neighbors(c)</c>：DIRS 序、裁掉盘外。</summary>
    public IEnumerable<HexPosition> Neighbors(HexPosition p)
    {
        foreach (var (dq, dr) in SemanticKey.GdDirs)
        {
            var n = new HexPosition(p.Q + dq, p.R + dr, -(p.Q + dq) - (p.R + dr));
            if (OnBoard(n)) yield return n;
        }
    }

    public IReadOnlyList<HexPosition> AllTiles => all;

    public static int Dist(HexPosition a, HexPosition b) => a.DistanceTo(b);

    /// <summary>全盘癌性组织（普通 + 固化）的坐标，惰性算一次。</summary>
    public IReadOnlyList<HexPosition> Cancerous
        => cancerous ??= all.Where(p => Tile(p).State != TissueState.Healthy).ToList();

    public int DistToNearestCancerous(HexPosition from)
    {
        var best = 99;
        foreach (var c in Cancerous) best = Math.Min(best, Dist(from, c));
        return best;
    }

    public int DistToNearestImmune(HexPosition from)
    {
        var best = 99;
        foreach (var c in livingImmune) best = Math.Min(best, Dist(from, c.Position));
        return best;
    }

    public int CancerousNeighbors(HexPosition p)
    {
        var n = 0;
        foreach (var nb in Neighbors(p)) if (IsCancerous(nb)) n++;
        return n;
    }

    public static HexPosition Hex(int q, int r) => new(q, r, -q - r);
}
