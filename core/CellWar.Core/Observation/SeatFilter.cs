namespace CellWar.Core.Observation;

/// <summary>
/// 按席位裁剪 envelope（docs/观测协议_v1.md §七 三档，照抄 GD `cw_net.gd view_for / view_for_watcher`）。
///
/// * `viewer >= 0`：自己的手牌明文，他人逐张换占位符、张数保留；`ask.options` 只给主人，别人只留 kind / tag / seat / prompt / stop_index。
/// * `viewer = -1` 观众：`openHands`（房主开的「观众全见」）时手牌照实，否则全占位；`ask.options` 恒空。
/// * `viewer = -2` 全知：原样 —— **禁止过网**，只给本地宿主 / 热座。
///
/// `logs` 的秘密行（别人抽到的牌名，GD cw_cards.gd:57）换成公开替身 —— 照 GD `cw_obs_codec.gd:_logs` → `CWNet.logs_for(open)`：
/// 主人看原文，「观众全见」（`openHands` 的观众）也看原文（手牌都看得见了，日志还说「抽了一张」只会自相矛盾），其余一律替身。演出条目 `card_drawn` 本来就不带牌名。
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
        return full with { Viewer = viewer, OpenHands = watcher && openHands, State = full.State with { Cells = cells }, Ask = ask,
            Logs = CropLogs(full.Logs, viewer, watcher && openHands) };
    }

    /// <summary>GD `CWNet.logs_for(game, pid, from, open)`：`open or who < 0 or who == pid` 给原文，否则给公开替身。</summary>
    private static ObsLogs CropLogs(ObsLogs logs, int viewer, bool open)
    {
        if (open || logs.Secret is not { Length: > 0 } secret) return logs;
        var lines = logs.Lines.ToArray();
        foreach (var x in secret)
            if (x.Seat != viewer) lines[x.At] = x.PublicText;
        return logs with { Lines = lines, Secret = secret.Where(x => x.Seat == viewer).ToArray() };
    }

    private static ObsCell Mask(ObsCell c) => c with { Hand = Enumerable.Repeat(HiddenCard, c.Hand.Length).ToArray() };
}
