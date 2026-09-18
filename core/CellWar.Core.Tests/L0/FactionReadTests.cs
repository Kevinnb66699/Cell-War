using CellWar.Core;

namespace CellWar.Core.Tests.L0;

/// <summary>
/// E-5（Kevin 2026-09-19 接受）的闸：**阵营级读法**的两个查询。
///
/// 背景：抗原记忆与免疫等级在 GD 是**阵营共享的全局量**（`cw_game.gd` 的 `memory` / `immune_level`），
/// 在这边是 per-Player 存（`Player.AntigenMemory` / `Player.ImmuneLevel`）。Kevin 拍板**存法不动**，
/// 只在读侧补两个具名查询 —— 口径照抄 `Observation/ObservationV1Codec.cs` 今天就在写的那一句
/// （`.Where(阵营).OrderBy(Seat).FirstOrDefault()`），**零行为改动**。
///
/// 写侧本批一行不改：`CellRules.AddMemory` / `ReduceMemory` 本来就是 `foreach 全体免疫席` 逐席写
/// （E-5 里「若只写动作者就是规则结果差」这条前提不成立）。
///
/// 「多免疫席不同值」这个场景两侧装载器都判 UNLOADABLE（`cw_world_loader.gd:_load_immune_globals`
/// ↔ `L0/WorldLoader.cs`），所以这里只验得出「同值」那一种 —— 这正是 L0 装得进来的全部。
///
/// 零行为改动的机器证据在 <c>PreParityTests</c>：codec 改写前后同一份 `pre_envelopes` 逐字节相同。
/// </summary>
public class FactionReadTests
{
    [Fact]
    public void 单免疫席_读的就是那一席()
    {
        var s = WorldLoader.Load(new L0World
        {
            Players = [new L0Player(0, "immune", Level: "II", Memory: 7), new L0Player(1, "cancer", CancerType: "Melanoma")],
        });

        var seat = s.Players[0];
        Assert.Equal(seat.AntigenMemory, s.FactionMemory(Faction.Immune));
        Assert.Equal(seat.ImmuneLevel, s.FactionImmuneLevel(Faction.Immune));
        Assert.Equal(7, s.FactionMemory(Faction.Immune));
        Assert.Equal(ImmuneLevel.II, s.FactionImmuneLevel(Faction.Immune));
    }

    [Fact]
    public void 双免疫席同值_读的是两席的共同值()
    {
        var s = WorldLoader.Load(new L0World
        {
            Players =
            [
                new L0Player(0, "immune", Level: "II", Memory: 7),
                new L0Player(1, "immune", Level: "II", Memory: 7),
            ],
        });

        Assert.Equal(2, s.Players.Values.Count(p => p.Faction == Faction.Immune));
        Assert.Equal(7, s.FactionMemory(Faction.Immune));
        Assert.Equal(ImmuneLevel.II, s.FactionImmuneLevel(Faction.Immune));
    }

    [Fact]
    public void 纯癌盘面_给缺省值而不是抛()
    {
        var s = WorldLoader.Load(new L0World
        {
            Players = [new L0Player(0, "cancer", CancerType: "Melanoma")],
        });

        Assert.DoesNotContain(s.Players.Values, p => p.Faction == Faction.Immune);
        Assert.Equal(0, s.FactionMemory(Faction.Immune));
        Assert.Equal(ImmuneLevel.I, s.FactionImmuneLevel(Faction.Immune));
    }
}
