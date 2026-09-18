using CellWar.Core;
using CellWar.Core.Tests.L1;

namespace CellWar.Core.Tests.L0;

/// <summary>批 3 规划（2026-09-19）在副本上坐实的两侧差异，逐条钉住（KG-1 / KG-2 / KG-3 / KG-4 / KG-5 / KG-8）。
/// 盘面走 <see cref="WorldLoader"/>（cwxworld/2），与 L0 用例同一条装载路。</summary>
public class Batch3ParityTests
{
    private static L0World Cancer(int round, Dictionary<string, int>? tuning = null, L0Events? events = null, params L0Tile[] tiles) => new()
    {
        Round = round,
        Players = [new L0Player(0, "immune"), new L0Player(1, "cancer", CancerType: "Melanoma")],
        Tiles = [.. tiles],
        Cells = [new L0Cell { Seat = 1, Type = "Melanoma", At = "0,0", Energy = 100 }],
        Tuning = tuning ?? [],
        Events = events,
    };

    private static readonly L0Tile[] Block =
    [
        new("0,0", "cancer"), new("1,0", "cancer"), new("1,-1", "solid", Solid: 30), new("0,1", "cancer"),
    ];

    [Fact]
    public void KG1_旋钮为0退回线性对照档_每癌组织04每固化10()
    {
        var s = WorldLoader.Load(Cancer(1, new() { ["anaerobic_block_coef"] = 0, ["anaerobic_floor"] = 0 }, null, Block));
        var block = Block.Select(t => WorldLoader.Pos(t.At)).ToArray();
        Assert.Equal(3 * 4 + 1 * 10, RulePolicies.AnaerobicPool(s, block));
    }

    [Fact]
    public void KG1_旋钮为负按人数取表_为正整体覆盖()
    {
        var byTable = WorldLoader.Load(Cancer(1, null, null, Block));
        var block = Block.Select(t => WorldLoader.Pos(t.At)).ToArray();
        var expected = Math.Pow(3, 0.30) * 28 + 1 * 10;   // 2 人局：表里 coef 28 / exp 30；固化全图 1 格 +1.0
        Assert.Equal(expected, RulePolicies.AnaerobicPool(byTable, block), 9);
        var overridden = WorldLoader.Load(Cancer(1, new() { ["anaerobic_block_coef"] = 5 }, null, Block));
        Assert.Equal(Math.Pow(3, 0.30) * 5 + 10, RulePolicies.AnaerobicPool(overridden, block), 9);
    }

    [Fact]
    public void KG2_增殖抑制在场_整步不掷骰不增生()
    {
        var spec = Cancer(3, new() { ["proliferate_per_adjacent[1]"] = 1000, ["proliferate_per_adjacent[2]"] = 1000, ["proliferate_per_adjacent[3]"] = 1000 },
            new L0Events(Active: [new L0Effect("增殖抑制", 1)]), new L0Tile("0,0", "cancer"));
        var s = WorldLoader.Load(spec);
        var rng = new TapeRng(Array.Empty<IReadOnlyList<long>>());   // 空带子：真抽了当场炸
        var fresh = BoardRules.Proliferate(s, rng, out var next);
        Assert.Empty(fresh);
        Assert.Equal(0, next.Board.Tissues.Values.Count(t => t.State == TissueState.Cancer && t.Newborn));
    }

    [Fact]
    public void KG3_异常增殖翻倍_单邻500变100必中()
    {
        var spec = Cancer(3, new() { ["proliferate_per_adjacent[1]"] = 500, ["proliferate_per_adjacent[2]"] = 500, ["proliferate_per_adjacent[3]"] = 500 },
            new L0Events(Active: [new L0Effect("异常增殖", 2)]), new L0Tile("0,0", "cancer"));
        var s = WorldLoader.Load(spec);
        var neighbours = WorldLoader.Pos("0,0").GetNeighbors().Count(p => s.Board.Tissues.ContainsKey(p));
        // 每格掷 1..1000，全掷 1000：500 的档一格都不中，翻倍到 1000 才六邻全转
        var rng = new TapeRng(Enumerable.Range(0, neighbours).Select(_ => (IReadOnlyList<long>)new long[] { 1, 1000, 1000 }).ToArray());
        var fresh = BoardRules.Proliferate(s, rng, out _);
        Assert.Equal(neighbours, fresh.Count);
    }

    [Fact]
    public void KG4_骨样硬化到期被免疫占着_不转固化标记留着()
    {
        var spec = new L0World
        {
            Round = 5,
            Players = [new L0Player(0, "immune"), new L0Player(1, "cancer", CancerType: "Osteosarcoma")],
            Tiles = [new L0Tile("0,0", "cancer", OssifyAt: 5), new L0Tile("1,0", "cancer", OssifyAt: 5)],
            Cells = [new L0Cell { Seat = 0, Type = "ImmuneBasic", At = "0,0", Energy = 100 }, new L0Cell { Seat = 1, Type = "Osteosarcoma", At = "3,0", Energy = 100 }],
        };
        var s = BoardRules.Ossify(WorldLoader.Load(spec));
        var occupied = s.Board.Tissues[WorldLoader.Pos("0,0")];
        var free = s.Board.Tissues[WorldLoader.Pos("1,0")];
        Assert.Equal((TissueState.Cancer, 5), (occupied.State, occupied.OssifyAtRound));
        Assert.Equal(TissueState.SolidifiedCancer, free.State);
    }

    [Fact]
    public void KG5_蹲守中没写camp_pos_装成原点_dump再省掉()
    {
        var spec = new L0World
        {
            Players = [new L0Player(0, "immune")],
            Cells = [new L0Cell { Seat = 0, Type = "ImmuneBasic", At = "0,0", Energy = 200, CampRound = 3 }],
        };
        var s = WorldLoader.Load(spec);
        Assert.Equal(WorldLoader.Pos("0,0"), s.Cells.Values.Single().CampPosition);
        Assert.Null(WorldLoader.Dump(s).Cells.Single().CampPos);
        var view = (Dictionary<string, object?>)((List<object?>)L1View.Of(s)["cells"]!)[0]!;
        Assert.NotNull(view["camp_pos"]);
    }

    [Fact]
    public void KG8_手摆的树突_旗标为假不算已分化_为真才算()
    {
        static L0World Spec(bool flag) => new()
        {
            Players = [new L0Player(0, "immune")],
            Cells = [new L0Cell { Seat = 0, Type = "Dendritic", At = "0,0", Energy = 200, Differentiated = flag }],
        };
        // 闸二 2b 比的是协议 envelope（`$.g.differentiated`），走 L0 runner 同一条 `Subset.Encode`
        static Dictionary<string, object?> G(WorldState s)
        {
            var env = Subset.Encode(s);
            var root = env.TryGetValue("state", out var st) ? (Dictionary<string, object?>)st! : env;
            return (Dictionary<string, object?>)root["g"]!;
        }
        var g0 = G(WorldLoader.Load(Spec(false)));
        var g1 = G(WorldLoader.Load(Spec(true)));
        Assert.Empty((List<object?>)g0["differentiated"]!);
        Assert.Single((List<object?>)g1["differentiated"]!);
    }
}
