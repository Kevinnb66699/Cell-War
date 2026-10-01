using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// AI 三档（Kevin 10-01 拍板：单机、联机房间、网页单机统一「普通 / 意图 / 搜索」三档；「较强」「树搜索」下架不移植）。
/// 对应 GD：普通 = CWHeuristicBridge；意图 = MechBridge（贪心 best_by + 手拍 scorer）；
/// 搜索 = MechBridge(use_search, use_fit_eval)（意图级 alpha-beta，叶 = 拟合估值，match.gd 的 AI_ABS 档 / 联机代打）。
/// </summary>
public enum AiTier
{
    Normal,
    Intent,
    Search,
}

/// <summary>
/// 一档 AI 的全部参数。默认值 = GD 线上值（mech_bridge.gd 的 cfg：depth 2 / top_k 6、mech_intent.gd 的 OPP_TOP_K 3 / SECOND_STEP_MAX 3）。
/// </summary>
public sealed record AiConfig
{
    public AiTier Tier { get; init; } = AiTier.Normal;
    /// <summary>惜命（GD v2 起默认开；<c>set_version("v1")</c> 才关）。推演里的陪练同值（GD <c>sim_no_lifecare = false</c>）。</summary>
    public bool Lifecare { get; init; } = true;
    /// <summary>分化永远拿第一种（GD v1 行为，对局里不拨）。</summary>
    public bool FixedLineup { get; init; }
    public int SearchDepth { get; init; } = 2;
    public int TopK { get; init; } = 6;
    public int OppTopK { get; init; } = 3;
    public int SecondStepMax { get; init; } = 3;
    /// <summary>癌方手拍 scorer 的「威胁 v2」峰值与能量距离半径（GD <c>MechBridge.W_THREAT / THREAT_REACH</c>：GD 那边就是静态旋钮，
    /// 云扫描的注入口，线上值 15 / 6.0 能量）。意图档的 scorer 与搜索档的快评分都读它。</summary>
    public double ThreatWeight { get; init; } = 15.0;
    public int ThreatReach { get; init; } = 60;
    /// <summary>
    /// 一问的思考预算（毫秒，0 = 不限）。超时只截**搜索档的根候选循环**：已评完的根里取最好的；一个都没评完就回落普通档。
    /// 截断点不可复现（墙钟），所以对拍时必须为 0；产品默认给一个兜底上限，防一问卡死整局（换内核 P3 性能节）。
    /// </summary>
    public int BudgetMs { get; init; }

    public static AiConfig For(AiTier tier) => new() { Tier = tier };

    /// <summary>sidecar 报文里的档名 ↔ 档位（"normal" / "intent" / "search"）。</summary>
    public static AiTier ParseTier(string name) => name switch
    {
        "normal" => AiTier.Normal,
        "intent" => AiTier.Intent,
        "search" => AiTier.Search,
        _ => throw new ArgumentException($"不认识的 AI 档名「{name}」（只认 normal / intent / search）"),
    };
}

/// <summary>
/// 一档 AI 的入口：给一问（世界 + 席位 + 这一问的全部合法决策 + 推演随机流），答一个**语义键**。
/// 返回键而不是下标：两个内核的选项表次序不同（SemanticKey 头注），宿主按键作答（MatchSession.SubmitByKey）。
/// </summary>
public interface IPolicy
{
    /// <param name="rng">这一问的推演随机流。**不会被推进**：试走在它的副本上跑；普通档的并列决胜读它的状态。</param>
    /// <param name="trace">对拍用的读数记录（意图档的候选读数、搜索档的根读数 / 对手节点 / 叶值）；产品路径传 null。</param>
    string Choose(WorldState state, int seat, IReadOnlyList<IDecision> options, IDeterministicRng rng,
        CancellationToken cancellation = default, AiTrace? trace = null);
}

public static class AiPolicies
{
    public static IPolicy Create(AiConfig config) => config.Tier switch
    {
        AiTier.Normal => new NormalPolicy(config),
        AiTier.Intent => new IntentPolicy(config),
        AiTier.Search => new SearchPolicy(config),
        _ => throw new ArgumentOutOfRangeException(nameof(config)),
    };

    /// <summary>推演流的起点：只认 SplitMix64（两边同式的那一条）；别的实现折成一个状态再起一条，保证「不推进调用方那条流」。</summary>
    internal static ulong RootState(IDeterministicRng rng) => rng switch
    {
        SplitMix64Rng sm => sm.State,
        _ => SplitMix64Rng.Mix(rng.GetState().Seed ^ rng.GetState().Counter ^ rng.GetState().S1),
    };
}
