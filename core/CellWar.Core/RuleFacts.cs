namespace CellWar.Core;

/// <summary>
/// 已提交规则事实基类：驱动确定性的规则反应（跨所有权交互经 <see cref="FactRouter"/> 分派）。
/// 事实是对“已经发生什么”的结构化记录，不带业务回调；反应由 FactRouter 按目录稳定顺序执行。
/// </summary>
public abstract record RuleFact(int WorldRound);

/// <summary>免疫细胞【净化】已成功结算：目标癌组织转为健康组织并 +1 抗原记忆。</summary>
public sealed record PurifyResolvedFact(int WorldRound, EntityId CellId) : RuleFact(WorldRound);
