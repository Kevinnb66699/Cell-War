using System.Text.RegularExpressions;
using CellWar.Core.Observation;

namespace CellWar.Core.Tests;

/// <summary>
/// 口径二 · 批 0 步 4：按席位裁剪（docs/观测协议_v1.md §七 三档）。
/// 占位符与 GD `cw_net.gd` 同字符；本席明文、他人换占位且张数保留；ask.options 只给主人；观众按 open_hands；全知原样。
/// </summary>
public class SeatCropGuardTests
{
    private static MatchSession WithHands()
    {
        var world = DemoScenario.Create();
        foreach (var c in world.Cells.Values.ToArray())
            world = world.UpdateCell(c.Id, c.Copy(hand: Enumerable.Range(0, c.OwnerSeat + 1).Select(i => $"卡{c.OwnerSeat}-{i}").ToArray()));
        return new MatchSession(world);
    }

    [Fact]
    public void 占位符与GD的HIDDEN_CARD同字符()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "game", "scripts", "net", "cw_net.gd");
        var text = File.ReadAllText(path);
        var m = Regex.Match(text, "const HIDDEN_CARD := \"(.+?)\"");
        Assert.True(m.Success, "cw_net.gd 里找不到 HIDDEN_CARD");
        Assert.Equal(m.Groups[1].Value, SeatFilter.HiddenCard);
        Assert.Equal(MatchObservationProvider.HiddenCard, SeatFilter.HiddenCard);
    }

    [Fact]
    public void 本席明文_他人占位且张数保留_options只给主人()
    {
        using var session = WithHands();
        var mine = session.ObserveV1(0);
        var theirs = session.ObserveV1(1);
        Assert.Equal(0, mine.Viewer);
        foreach (var c in mine.State.Cells)
        {
            Assert.Equal(c.Pid + 1, c.Hand.Length);
            if (c.Pid == 0) Assert.All(c.Hand, h => Assert.StartsWith("卡0-", h));
            else Assert.All(c.Hand, h => Assert.Equal(SeatFilter.HiddenCard, h));
        }
        Assert.True(mine.Ask!.Mine); Assert.NotEmpty(mine.Ask.Options);
        Assert.False(theirs.Ask!.Mine); Assert.Empty(theirs.Ask.Options);
        Assert.Equal(("action", 0, -1), (theirs.Ask.Kind, theirs.Ask.Seat, theirs.Ask.StopIndex));   // kind / seat / stop_index 照给
        Assert.All(theirs.State.Cells.Where(c => c.Pid == 1), c => Assert.All(c.Hand, h => Assert.StartsWith("卡1-", h)));
        // 装备 / 修饰 / 其余状态不裁
        Assert.Equal(mine.State.Board.Tiles, theirs.State.Board.Tiles);
        Assert.Equal(System.Text.Json.JsonSerializer.Serialize(mine.State.G, ObservationV1Codec.Json), System.Text.Json.JsonSerializer.Serialize(theirs.State.G, ObservationV1Codec.Json));   // 记录里带数组，按 JSON 比
    }

    [Fact]
    public void 观众_默认全占位_开手牌照实_options恒空()
    {
        using var session = WithHands();
        var closed = session.ObserveV1(ObservationV1Codec.ViewerWatcher);
        var open = session.ObserveV1(ObservationV1Codec.ViewerWatcher, openHands: true);
        Assert.False(closed.OpenHands); Assert.True(open.OpenHands);
        Assert.All(closed.State.Cells, c => Assert.All(c.Hand, h => Assert.Equal(SeatFilter.HiddenCard, h)));
        Assert.All(open.State.Cells, c => Assert.All(c.Hand, h => Assert.StartsWith("卡", h)));
        Assert.Empty(closed.Ask!.Options); Assert.Empty(open.Ask!.Options);
        Assert.False(open.Ask.Mine);
    }

    [Fact]
    public void 全知_原样_open_hands恒假()
    {
        using var session = WithHands();
        var full = session.ObserveV1(ObservationV1Codec.ViewerOmniscient, openHands: true);
        Assert.Equal(-2, full.Viewer); Assert.False(full.OpenHands);
        Assert.All(full.State.Cells, c => Assert.All(c.Hand, h => Assert.StartsWith("卡", h)));
        Assert.True(full.Ask!.Mine); Assert.NotEmpty(full.Ask.Options);
    }
}
