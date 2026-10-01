using CellWar.Core;

namespace CellWar.Ai;

/// <summary>
/// 对拍读数（GD 侧 <c>agree_rng.gd</c> 的 <c>AGREE.trace</c>，结构一一对应，C# 测试逐条比）：
/// · <see cref="Cands"/>：意图档 best_by 评过的每个候选 / 搜索档根上快评的每个候选（路径 + 读数 + 分）；
/// · <see cref="Roots"/>：搜索档每个根候选的线值；<see cref="Nodes"/>：每次展开对手 / 友军节点时排好序的子候选；
/// · <see cref="Leaves"/>：搜索树的叶值，按求值次序（剪枝一致 ⇔ 这串数逐个相等）；
/// · <see cref="Best"/> / <see cref="Plan0"/>：搜索档选中的根路径、计划的第一手。
/// 产品路径不建它（null），零开销。
/// </summary>
public sealed class AiTrace
{
    public List<(IReadOnlyList<HexPosition> Path, MechMetrics Metrics, double Score)> Cands { get; } = [];
    public List<(IReadOnlyList<HexPosition> Path, double V)> Roots { get; } = [];
    public List<(int Seat, IReadOnlyList<(IReadOnlyList<HexPosition> Path, double Q)> Subs)> Nodes { get; } = [];
    public List<double> Leaves { get; } = [];
    public IReadOnlyList<HexPosition>? Best { get; set; }
    public AiOption? Plan0 { get; set; }
}
