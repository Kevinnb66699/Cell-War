using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>卡牌类别（PRD「卡牌设定」§637-647）。</summary>
public enum CardCategory
{
    Event,      // 【事件】：抽取后立即结算并弃置
    Instant,    // 【即时技能】：可在行动回合发动，结算后弃置
    Permanent   // 【永久技能】：只能在自身行动回合打出，置于角色面板持续生效
}

/// <summary>卡池（PRD 免疫 I/II/III/X 级卡池 + 癌症单一卡池）。</summary>
public enum CardPool
{
    ImmuneI,
    ImmuneII,
    ImmuneIII,
    ImmuneX,
    Cancer
}

/// <summary>
/// 卡牌定义。Weights 对免疫卡为单值；对癌症卡为「肿瘤 I/II/III 期」三档权重。
/// </summary>
public sealed record CardDefinition(string Name, CardCategory Category, CardPool Pool, int[] Weights)
{
    public int Weight(int phase) => Weights.Length == 1 ? Weights[0] : Weights[Math.Clamp(phase, 0, Weights.Length - 1)];
}

/// <summary>
/// 卡牌目录（PRD「免疫卡池」「癌症卡池」，全部卡名/类别/权重）。
/// </summary>
public static class CardCatalog
{
    public static readonly ImmutableArray<CardDefinition> All =
    [
        // ── 免疫 I 级卡池 ──
        new("急性炎症反应", CardCategory.Event, CardPool.ImmuneI, [4]),
        new("抗原摄取", CardCategory.Event, CardPool.ImmuneI, [3]),
        new("趋化募集", CardCategory.Event, CardPool.ImmuneI, [2]),
        new("局部吞噬", CardCategory.Instant, CardPool.ImmuneI, [2]),
        new("I型干扰素", CardCategory.Event, CardPool.ImmuneI, [3]),
        new("补体调理", CardCategory.Instant, CardPool.ImmuneI, [4]),
        new("炎症趋化", CardCategory.Instant, CardPool.ImmuneI, [4]),
        new("细胞膜修复", CardCategory.Instant, CardPool.ImmuneI, [4]),
        new("组织驻留", CardCategory.Permanent, CardPool.ImmuneI, [3]),
        new("代谢适应", CardCategory.Permanent, CardPool.ImmuneI, [3]),
        new("模式识别增强", CardCategory.Permanent, CardPool.ImmuneI, [3]),

        // ── 免疫 II 级卡池 ──
        new("趋化募集", CardCategory.Event, CardPool.ImmuneII, [2]),
        new("免疫增援", CardCategory.Instant, CardPool.ImmuneII, [1]),
        new("补体调理", CardCategory.Instant, CardPool.ImmuneII, [2]),
        new("细胞膜修复", CardCategory.Instant, CardPool.ImmuneII, [2]),
        new("抗原呈递增强", CardCategory.Event, CardPool.ImmuneII, [3]),
        new("骨髓动员", CardCategory.Event, CardPool.ImmuneII, [3]),
        new("TNF-α局部炎症", CardCategory.Instant, CardPool.ImmuneII, [3]),
        new("基质降解", CardCategory.Instant, CardPool.ImmuneII, [2]),
        new("补体级联", CardCategory.Instant, CardPool.ImmuneII, [4]),
        new("CXCR3趋化", CardCategory.Instant, CardPool.ImmuneII, [4]),
        new("缺氧适应", CardCategory.Instant, CardPool.ImmuneII, [3]),
        new("LFA-1黏附", CardCategory.Permanent, CardPool.ImmuneII, [3]),
        new("效应记忆形成", CardCategory.Permanent, CardPool.ImmuneII, [3]),
        new("自分泌生存信号", CardCategory.Permanent, CardPool.ImmuneII, [2]),

        // ── 免疫 III 级卡池 ──
        new("效应细胞浸润", CardCategory.Event, CardPool.ImmuneIII, [2]),
        new("克隆扩增", CardCategory.Event, CardPool.ImmuneIII, [3]),
        new("抗原呈递增强", CardCategory.Event, CardPool.ImmuneIII, [2]),
        new("IFN-γ释放", CardCategory.Event, CardPool.ImmuneIII, [3]),
        new("炎症风暴", CardCategory.Event, CardPool.ImmuneIII, [2]),
        new("基质降解", CardCategory.Instant, CardPool.ImmuneIII, [2]),
        new("补体级联", CardCategory.Instant, CardPool.ImmuneIII, [4]),
        new("穿孔素-颗粒酶", CardCategory.Instant, CardPool.ImmuneIII, [4]),
        new("抗体依赖细胞毒作用", CardCategory.Instant, CardPool.ImmuneIII, [3]),
        new("代谢耦联", CardCategory.Instant, CardPool.ImmuneIII, [2]),
        new("免疫增援", CardCategory.Instant, CardPool.ImmuneIII, [2]),
        new("溶酶体强化", CardCategory.Instant, CardPool.ImmuneIII, [3]),
        new("交叉呈递", CardCategory.Instant, CardPool.ImmuneIII, [3]),
        new("炎症性趋化", CardCategory.Instant, CardPool.ImmuneIII, [4]),
        new("免疫突触成熟", CardCategory.Permanent, CardPool.ImmuneIII, [3]),
        new("组织浸润", CardCategory.Permanent, CardPool.ImmuneIII, [3]),
        new("细胞因子网络", CardCategory.Permanent, CardPool.ImmuneIII, [2]),

        // ── 免疫 X 级卡池 ──
        new("克隆扩增", CardCategory.Event, CardPool.ImmuneX, [2]),
        new("全身免疫动员", CardCategory.Event, CardPool.ImmuneX, [2]),
        new("全身性免疫清除", CardCategory.Event, CardPool.ImmuneX, [1]),
        new("免疫风暴", CardCategory.Event, CardPool.ImmuneX, [2]),
        new("代谢耦联", CardCategory.Instant, CardPool.ImmuneX, [2]),
        new("高亲和力克隆", CardCategory.Instant, CardPool.ImmuneX, [4]),
        new("IFN-γ高峰", CardCategory.Instant, CardPool.ImmuneX, [3]),
        new("基质重塑", CardCategory.Instant, CardPool.ImmuneX, [3]),
        new("补体级联", CardCategory.Instant, CardPool.ImmuneX, [3]),
        new("基质降解", CardCategory.Instant, CardPool.ImmuneX, [2]),
        new("免疫增援", CardCategory.Instant, CardPool.ImmuneX, [3]),
        new("放疗", CardCategory.Instant, CardPool.ImmuneX, [1]),
        new("缺氧适应", CardCategory.Instant, CardPool.ImmuneX, [3]),
        new("免疫监视", CardCategory.Permanent, CardPool.ImmuneX, [3]),
        new("组织巡航", CardCategory.Permanent, CardPool.ImmuneX, [2]),
        new("耗竭抵抗", CardCategory.Permanent, CardPool.ImmuneX, [2]),
        new("免疫记忆库", CardCategory.Permanent, CardPool.ImmuneX, [2]),
        new("细胞因子网络", CardCategory.Permanent, CardPool.ImmuneX, [2]),
        new("抗原呈递强化", CardCategory.Permanent, CardPool.ImmuneX, [2]),
        new("抗体亲和力成熟", CardCategory.Permanent, CardPool.ImmuneX, [2]),
        new("吞噬体成熟", CardCategory.Permanent, CardPool.ImmuneX, [2]),
        new("细胞毒性增强", CardCategory.Permanent, CardPool.ImmuneX, [2]),

        // ── 癌症卡池（权重 = 肿瘤 I / II / III 期）──
        // 权重 2026-09-15 校正：PRD:1377 写的是 2 / 3 / 4，这里原来是 [3, 4, 6]。
        // （GDScript 侧 cw_card_data.gd:128 早就是 [2,3,4] —— issue #41 改过，C# 没跟。）
        new("糖酵解爆发", CardCategory.Event, CardPool.Cancer, [2, 3, 4]),
        new("克隆增殖", CardCategory.Instant, CardPool.Cancer, [5, 4, 3]),
        // 2026-09-15 补：PRD:1465 的【癌症转移】此前 C# 侧整张缺失（68 张里唯一一张）。
        // GDScript 侧 2026-09-14 随 issue #42 上线（cw_card_data.gd:124，权重同为 3/2/2）。
        new("癌症转移", CardCategory.Instant, CardPool.Cancer, [3, 2, 2]),
        new("基因组不稳定", CardCategory.Event, CardPool.Cancer, [3, 3, 3]),
        new("肿瘤血管生成", CardCategory.Event, CardPool.Cancer, [3, 3, 2]),
        new("基质稳定", CardCategory.Event, CardPool.Cancer, [1, 3, 2]),
        new("TGF-β释放", CardCategory.Event, CardPool.Cancer, [1, 2, 4]),
        new("上皮—间质转化", CardCategory.Instant, CardPool.Cancer, [5, 4, 3]),
        new("乳酸酸化", CardCategory.Instant, CardPool.Cancer, [2, 3, 4]),
        new("PD-L1表达", CardCategory.Instant, CardPool.Cancer, [2, 3, 4]),
        new("基质硬化", CardCategory.Instant, CardPool.Cancer, [2, 4, 5]),
        new("肿瘤细胞募集", CardCategory.Instant, CardPool.Cancer, [3, 3, 3]),
        new("肿瘤增援", CardCategory.Instant, CardPool.Cancer, [3, 3, 3]),
        new("DNA损伤修复", CardCategory.Instant, CardPool.Cancer, [2, 3, 4]),
        new("代谢耦联", CardCategory.Instant, CardPool.Cancer, [3, 3, 2]),
        new("GLUT1高表达", CardCategory.Permanent, CardPool.Cancer, [4, 3, 2]),
        new("RAS持续激活", CardCategory.Permanent, CardPool.Cancer, [4, 3, 2]),
        new("BCL-2抗凋亡", CardCategory.Instant, CardPool.Cancer, [2, 3, 3]),
        new("癌症干性", CardCategory.Permanent, CardPool.Cancer, [1, 2, 4])
    ];

    private static readonly ImmutableDictionary<string, ImmutableArray<CardDefinition>> ByName =
        All.GroupBy(c => c.Name).ToImmutableDictionary(g => g.Key, g => g.ToImmutableArray());

    public static IEnumerable<CardDefinition> Pool(CardPool pool) => All.Where(c => c.Pool == pool);

    public static ImmutableArray<CardDefinition> ByCardName(string name) => ByName.GetValueOrDefault(name, []);
}

/// <summary>
/// 已实现效果的卡牌集合。抽卡只从「已实现」的卡中抽取，避免未实现的卡被悄悄结算成空操作。
/// 每实现一张，把它加进来（并在矩阵中登记）。
/// </summary>
public static class CardImplementation
{
    private static readonly HashSet<string> Implemented =
    [
        "急性炎症反应", "抗原摄取", "抗原呈递增强", "克隆扩增", "肿瘤血管生成",
        "局部吞噬", "基质降解", "溶酶体强化", "细胞膜修复",
        "骨髓动员", "全身免疫动员", "全身性免疫清除", "IFN-γ释放", "糖酵解爆发", "基质稳定", "TGF-β释放",
        "缺氧适应", "DNA损伤修复", "炎症趋化", "上皮—间质转化", "CXCR3趋化", "组织浸润", "穿孔素-颗粒酶",
        "组织驻留", "LFA-1黏附", "组织巡航", "耗竭抵抗", "免疫突触成熟", "抗体亲和力成熟", "吞噬体成熟", "细胞毒性增强",
        "乳酸酸化", "基质硬化", "交叉呈递", "抗体依赖细胞毒作用", "IFN-γ高峰", "免疫风暴", "免疫增援",
        "肿瘤细胞募集", "肿瘤增援", "代谢耦联", "基质重塑", "放疗", "高亲和力克隆", "补体调理", "补体级联",
        "PD-L1表达", "BCL-2抗凋亡", "免疫记忆库", "免疫监视", "RAS持续激活", "癌症干性", "抗原呈递强化",
        "模式识别增强", "效应记忆形成", "克隆增殖", "炎症风暴", "癌症转移",
        "趋化募集", "效应细胞浸润", "炎症性趋化", "基因组不稳定", "细胞因子网络",
        "I型干扰素", "代谢适应", "TNF-α局部炎症", "自分泌生存信号", "GLUT1高表达"
    ];

    public static bool IsImplemented(CardDefinition definition) => Implemented.Contains(definition.Name);
}
