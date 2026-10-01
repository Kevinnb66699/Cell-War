namespace CellWar.Ai;

/// <summary>
/// 意图 / 搜索档的三个打分式（GD <c>MechBridge._cancer_score / _immune_score</c> 与 <c>MechValue.position_eval</c>）。
///
/// **浮点运算的次序逐字照抄 GD**（GDScript 的 float 是 double）：搜索档按快评分排序取前 K，
/// 两个候选在 GD 里恰好相等、换个加法次序在 C# 里差 1e-15，排序就换了位、取到的根就不同。
/// 权重是 GD 的手拍值 / 拟合系数，改一个对拍测试必须红（变异检验钉着）。
/// </summary>
internal static class MechScores
{
    /// <summary>击杀一个免疫的重权（GD <c>W_KILL</c>）。</summary>
    internal const double WKill = 50.0;
    /// <summary>持续压迫每点的权重（GD <c>W_PRESSURE</c>）。</summary>
    internal const double WPressure = 2.0;
    /// <summary>封一个骨髓复活点的权重（GD <c>W_MARROW</c>）。</summary>
    internal const double WMarrow = 15.0;
    /// <summary>癌方视角：地盘 + 供给 + 能量差，叠固化潜力 / 生存 / 威胁 v2 / 击杀·压迫·封骨髓。
    /// 威胁 v2 的两个旋钮（GD 的静态 W_THREAT / THREAT_REACH）在 <see cref="AiConfig"/> 上。</summary>
    public static double Cancer(MechMetrics m, AiConfig cfg)
    {
        var s = (double)m.WinProgress + m.CancerSupply + (double)m.CancerEnergy - m.ImmuneEnergy;
        var sr = m.ActorSolidRounds;
        if (sr >= 0 && sr <= 2) s += 3 - sr;
        var ae = m.ActorEnergy;
        if (ae < 20) s -= (20 - ae) * 2.0;
        var reach = m.ActorImmuneReachCost;
        if (reach < cfg.ThreatReach)
        {
            var danger = 1.0 - (double)reach / cfg.ThreatReach;
            var hpScale = Math.Clamp((40.0 - ae) / 30.0, 0.0, 1.0);
            s -= danger * hpScale * cfg.ThreatWeight;
        }
        s += m.ImmuneLethalCount * WKill;
        s += m.ImmunePressureTotal * WPressure;
        s += m.CancerMarrows * WMarrow;
        return s;
    }

    /// <summary>免疫方视角：与癌方相反 + 免疫能量 + 记忆（权重全 1）。</summary>
    public static double Immune(MechMetrics m)
        => (double)m.ImmuneEnergy - m.CancerEnergy - m.CancerSupply - m.WinProgress + m.Memory;

    /// <summary>GD <c>MechValue.FIT_B</c>。</summary>
    internal const double FitB = 6.9190;

    /// <summary>
    /// 数据拟合的零和位置估值 E(s) = log-odds(免疫胜)（GD <c>MechValue.position_eval</c>，E5 系数）。
    ///
    /// ⚠ **照搬 GD 的一个缺陷**：倒数第二项读的键是 <c>"lc"</c>，而 <c>_read_metrics</c> 产出的是 <c>immune_lethal_count</c> ——
    /// GD 里这一项恒为 log(1+0) = 0。搬过来照样恒为 0（先对拍一致，修它是另一次有意的 AI 改动，要升版本、重录语料）。
    /// </summary>
    public static double PositionEval(MechMetrics m)
    {
        var e = FitB;
        e += 1.5552 * Lf(m.ImmuneLevel);
        e += 0.7571 * Lf(m.Memory);
        e += 2.2572 * Lf(m.ImmuneAlive);
        e -= 2.5598 * Lf(m.CancerTiles);
        e -= 1.4590 * Lf(m.SolidTiles);
        e += 1.1400 * Lf(m.CancerAlive);
        e -= 0.5243 * Lf(m.CancerEnergy);
        e -= 0.0606 * Lf(m.ImmuneEnergy);
        e += 0.0698 * Lf(m.CancerSupply);
        e -= 0.0733 * Lf(m.ImmunePressureTotal);
        e -= 0.2334 * Lf(0);                   // GD 读 "lc"（键不存在）—— 见上
        e += 0.3793 * Lf(m.HealthyMarrows);
        return e;
    }

    /// <summary>GD <c>MechValue._lf</c>：log(1 + max(x, 0))。</summary>
    private static double Lf(int x) => Math.Log(1.0 + Math.Max((double)x, 0.0));
}
