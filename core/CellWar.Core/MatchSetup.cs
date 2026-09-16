namespace CellWar.Core;

/// <summary>
/// 开局初始化（PRD「游戏开始」）：确定性铺初始癌组织、分配癌细胞种类、建立棋盘与席位。
/// 只负责 Setup 阶段开始前的无决策部分；落子由规则引擎的 PlaceDecision 驱动。
///
/// 特殊组织布局与初始癌组织生成方式均按原项目代码对齐（PRD 只给数量、未给坐标/算法）：
/// 见旧 `CWData.CORES/MARROWS/VESSELS` 与 `CWSetup._place_initial_cancer`。
/// </summary>
public static class MatchSetup
{
    public const int BoardRadius = 6;

    // 特殊组织坐标（轴坐标，中央 (0,0)）。布局为 3 重旋转对称，中央格非特殊组织。
    private static readonly HexPosition[] Cores =
        [new(0, -3, 3), new(3, 0, -3), new(-3, 3, 0)];
    private static readonly HexPosition[] Marrows =
        [new(3, -3, 0), new(0, 3, -3), new(-3, 0, 3), new(6, -3, -3), new(-3, 6, -3), new(-3, -3, 6)];
    private static readonly HexPosition[] Vessels =
        [new(6, 0, -6), new(-6, 0, 6)];

    public static WorldState Create(int playerCount, ulong seed)
    {
        var rng = new Xoshiro256StarStar(seed);
        var tissues = new Dictionary<HexPosition, Tissue>();
        foreach (var p in AllCoords(BoardRadius))
            tissues[p] = new Tissue
            {
                Position = p, Type = TissueType.Normal, State = TissueState.Healthy,
                SolidificationCount = 0, OccupyingCell = null, Charge = 0
            };
        foreach (var p in Cores) tissues[p] = tissues[p].WithType(TissueType.MetabolicCore);
        foreach (var p in Marrows) tissues[p] = tissues[p].WithType(TissueType.BoneMarrow);
        foreach (var p in Vessels) tissues[p] = tissues[p].WithType(TissueType.BloodVessel);

        foreach (var p in InitialCancer(tissues, playerCount))
            tissues[p] = tissues[p].WithState(TissueState.Cancer);

        var players = new Dictionary<int, Player>();
        var cancerPool = new List<CellType> { CellType.Melanoma, CellType.SignetRing, CellType.Osteosarcoma, CellType.SmallCellLung };
        var shuffledTypes = rng.Shuffle(cancerPool);
        var typeIndex = 0;
        for (var seat = 0; seat < playerCount; seat++)
        {
            var faction = seat % 2 == 0 ? Faction.Immune : Faction.Cancer;
            players[seat] = new Player
            {
                Seat = seat, Faction = faction, IsAlive = true, DrawCount = 0,
                AntigenMemory = 0, ImmuneLevel = ImmuneLevel.I,
                CancerType = faction == Faction.Cancer ? shuffledTypes[typeIndex++] : null
            };
        }

        return new WorldState
        {
            Board = new Board { Radius = BoardRadius, Tissues = tissues },
            Cells = new Dictionary<EntityId, Cell>(),
            Players = players,
            Turn = new TurnState { WorldRound = 1, Phase = Phase.Setup, ActivePlayerSeat = 0 }
        };
    }

    /// <summary>
    /// 初始癌组织：自中央格起确定性 BFS（frontier FIFO、neighbors 固定顺序），
    /// 跳过特殊组织，铺到目标格数。满足连通、含中央、不与特殊组织重合。不掷骰。
    /// </summary>
    private static List<HexPosition> InitialCancer(Dictionary<HexPosition, Tissue> tissues, int playerCount)
    {
        var target = playerCount >= 6 ? 24 : 15;
        var center = new HexPosition(0, 0, 0);
        var chosen = new List<HexPosition> { center };
        var seen = new HashSet<HexPosition> { center };
        var frontier = new Queue<HexPosition>();
        frontier.Enqueue(center);
        while (chosen.Count < target && frontier.Count > 0)
        {
            var current = frontier.Dequeue();
            foreach (var next in current.GetNeighbors())
            {
                if (chosen.Count >= target) break;
                if (!seen.Add(next)) continue;
                if (!tissues.TryGetValue(next, out var tile) || tile.Type != TissueType.Normal) continue;
                chosen.Add(next);
                frontier.Enqueue(next);
            }
        }
        return chosen;
    }

    private static IEnumerable<HexPosition> AllCoords(int radius)
    {
        for (var q = -radius; q <= radius; q++)
            for (var r = -radius; r <= radius; r++)
                if (Math.Abs(q + r) <= radius)
                    yield return new HexPosition(q, r, -q - r);
    }
}
