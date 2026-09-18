namespace CellWar.Core.Observation;

/// <summary>
/// 按席位裁剪 envelope（docs/观测协议_v1.md §七 三档，照抄 GD `cw_net.gd view_for / view_for_watcher`）。
///
/// * `viewer >= 0`：自己的手牌明文，他人逐张换占位符、张数保留；`ask.options` 只给主人，别人只留 kind / tag / seat / prompt / stop_index。
/// * `viewer = -1` 观众：`openHands`（房主开的「观众全见」）时手牌照实，否则全占位；`ask.options` 恒空。
/// * `viewer = -2` 全知：原样 —— **禁止过网**，只给本地宿主 / 热座。
///
/// C# 的日志（`Outbox`）今天没有秘密行（抽到哪张牌不写进日志），所以 `logs` 不裁；演出条目 `card_drawn` 本来就不带牌名。
/// 手牌 / 装备 / 修饰之外的状态都是公开的；`save()` 不经过这里（宿主专用，绝不裁剪、绝不下发）。
/// </summary>
public static class SeatFilter
{
    /// <summary>别人手牌的占位符，与 GD `CWNet.HIDDEN_CARD` 同一个字符（SeatCropGuardTests 钉死）。</summary>
    public const string HiddenCard = MatchObservationProvider.HiddenCard;

    public static ObsEnvelope Crop(ObsEnvelope full, int viewer, bool openHands = false)
    {
        if (viewer == ObservationV1Codec.ViewerOmniscient) return full with { Viewer = viewer, OpenHands = false };
        var watcher = viewer == ObservationV1Codec.ViewerWatcher;
        var cells = full.State.Cells.Select(c => watcher ? (openHands ? c : Mask(c)) : c.Pid == viewer ? c : Mask(c)).ToArray();
        var ask = full.Ask is null ? null
            : !watcher && full.Ask.Seat == viewer ? full.Ask with { Mine = true }
            : full.Ask with { Mine = false, Options = [] };
        return full with { Viewer = viewer, OpenHands = watcher && openHands, State = full.State with { Cells = cells }, Ask = ask };
    }

    private static ObsCell Mask(ObsCell c) => c with { Hand = Enumerable.Repeat(HiddenCard, c.Hand.Length).ToArray() };
}
