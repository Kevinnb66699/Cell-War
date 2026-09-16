using System.Reflection;
using CellWar.Core;

namespace CellWar.Core.Tests.L1;

/// <summary>
/// 语义键的三道判据：**每个决策都有键**（完备性）、**键长什么样钉死**（回归）、
/// **整张选项表能拍平**（探针可用）。
///
/// 第一道是这里最要紧的一条。映射表写错了不会红 —— 写**漏**了才会，
/// 而写漏正是这类表的常见死法：`IRulesEngine.cs` 新加一个 record，
/// 没人记得回来补一行，对拍那天它静默地一步都没比过。
/// </summary>
public class SemanticKeyTests
{
    [Fact]
    public void 每个决策类型要么有语义键要么明确列为死代码()
    {
        var world = Fixture();
        var missing = new List<string>();
        foreach (var t in typeof(IDecision).Assembly.GetTypes()
                     .Where(t => t is { IsAbstract: false, IsInterface: false } && typeof(IDecision).IsAssignableFrom(t))
                     .OrderBy(t => t.Name, StringComparer.Ordinal))
        {
            var sample = (IDecision)Activator.CreateInstance(t, ArgsFor(t, world))!;
            if (SemanticKey.DeadCode.Contains(sample.DecisionType)) continue;
            try { SemanticKey.Of(world, sample); }
            catch (InvalidOperationException e) { missing.Add($"{t.Name}：{e.Message}"); }
        }
        Assert.True(missing.Count == 0,
            "下面这些决策没有语义键 —— 补进 SemanticKey.Of，或者确认它是死代码后写进 DeadCode："
            + Environment.NewLine + "  " + string.Join(Environment.NewLine + "  ", missing));
    }

    /// <summary>
    /// 键的样子钉死。三条取自对拍规格的真实样例，其余是容易写歪的那几处：
    /// 复活分两个 kind、卡牌的细胞目标是 `cid` 不是 `to_cid`、强制弃置走 `pick` 不是 `action`。
    /// </summary>
    [Fact]
    public void 键的拼法钉死()
    {
        var s = Fixture();
        var immune = s.Cells[new EntityId(1)];
        var cancer = s.Cells[new EntityId(2)];

        Assert.Equal("k=setup_place|to=-6,0", SemanticKey.Of(s, new PlaceDecision(0, new HexPosition(-6, 0, 6))));
        Assert.Equal("k=action|act=move|to=-2,0", SemanticKey.Of(s, new MoveDecision(0, immune.Id, new HexPosition(-2, 0, 2))));
        Assert.Equal("k=action|act=play|card=癌症转移|to=-3,3",
            SemanticKey.Of(s, new PlayCardDecision(1, cancer.Id, "癌症转移", new HexPosition(-3, 3, 0))));
        Assert.Equal("k=action|act=play|card=交叉呈递|cid=1",
            SemanticKey.Of(s, new PlayCardDecision(0, immune.Id, "交叉呈递", null, cancer.Id)));
        Assert.Equal("k=action|act=end", SemanticKey.Of(s, new EndTurnDecision(0)));
        Assert.Equal(SemanticKey.PassKey, SemanticKey.Of(s, new PassDecision(0)));
        Assert.Equal("k=action|act=differentiate|type=2",
            SemanticKey.Of(s, new DifferentiateDecision(0, immune.Id, CellType.TCell)));

        // 复活是两问：免疫回骨髓、癌方靠固化癌组织。癌方那问的 `anchor` 按规矩 1 剔除，
        // 所以同一格的不同依托压成同一个键 —— 这是**故意的**，依托是引擎按坐标最小值挑的。
        Assert.Equal("k=immune_revive|to=0,0", SemanticKey.Of(s, new ReviveDecision(0, immune.Id, new HexPosition(0, 0, 0))));
        Assert.Equal("k=revive|to=0,0",
            SemanticKey.Of(s, new ReviveDecision(1, cancer.Id, new HexPosition(0, 0, 0), new HexPosition(1, 0, -1))));

        // 强制弃置走 GD 的 `discard_to_limit`（kind=pick、tag=手牌上限），不是行动栏那条自愿弃置
        Assert.Equal("k=pick|g=手牌上限|card=缺氧适应", SemanticKey.Of(s, new DiscardDecision(1, cancer.Id, "缺氧适应")));

        // 【连续吞噬】的连锁带 tag
        Assert.Equal("k=free_move|g=连续吞噬|to=1,0", SemanticKey.Of(s, new ChainMoveDecision(0, immune.Id, new HexPosition(1, 0, -1))));
        Assert.Equal("k=free_move|g=连续吞噬|stop=1", SemanticKey.Of(s, new StopChainDecision(0, immune.Id)));
    }

    /// <summary>
    /// 字段顺序是**和 GD 的线上约定**，取自 GD `data` 的 13 个键（对拍规格 §死结一）。
    ///
    /// 单独钉一条，是因为它在现有用例上**改了也不红**：今天没有哪个键同时带两个可换位的字段
    /// （`cid` 与 `dir` 从不同时出现）。等哪天有了，错位会是一条对不上的字符串，
    /// 而不是一条读得懂的差异 —— 那时再回头找就晚了。
    /// </summary>
    [Fact]
    public void 字段顺序照GD的13个data键()
    {
        Assert.Equal(
            new[] { "act", "card", "type", "to", "cid", "dir", "r", "pay", "get", "from", "to_cid", "stop", "skip" },
            SemanticKey.FieldOrder);
    }

    /// <summary>
    /// 【基因组不稳定】：GD 的 data 是**骰面值**，C# 存的是「选第几个」——
    /// 照 `Choice` 直接写进键，两边永远对不上（GD 那边根本没有 0/1 这个数）。
    /// </summary>
    [Fact]
    public void 基因组不稳定的键写骰面值而不是下标()
    {
        var s = Fixture();
        var cancer = s.Cells[new EntityId(2)];
        s = s.WithTurn(s.Turn.WithPendingMutation(1, cancer.Id, 2, 3));

        Assert.Equal("k=pick|g=基因组不稳定|r=2", SemanticKey.Of(s, new ChooseMutationDecision(1, cancer.Id, 0)));
        Assert.Equal("k=pick|g=基因组不稳定|r=3", SemanticKey.Of(s, new ChooseMutationDecision(1, cancer.Id, 1)));
    }

    /// <summary>
    /// Excalibur 的 `dir` 是 GD `CWData.DIRS` 的下标。
    /// C# `GetNeighbors()` 是另一套次序 —— 照自己的枚举序写下标，六个方向全错位，
    /// 而且错得很安静：键的形状对、字段齐全，只是指着别的方向。
    /// </summary>
    [Theory]
    [InlineData(1, 0, 0)]
    [InlineData(1, -1, 1)]
    [InlineData(0, -1, 2)]
    [InlineData(-1, 0, 3)]
    [InlineData(-1, 1, 4)]
    [InlineData(0, 1, 5)]
    public void Excalibur的方向下标照GD的DIRS表(int dq, int dr, int expected)
    {
        var s = Fixture();
        var t = s.Cells[new EntityId(1)];
        var to = new HexPosition(t.Position.Q + dq, t.Position.R + dr, -(t.Position.Q + dq) - (t.Position.R + dr));

        var key = SemanticKey.Of(s, new TypeSkillDecision(0, t.Id, "Excalibur", to));

        Assert.Equal($"k=action+effector_target|act=effector|to={to.Q},{to.R}|dir={expected}", key);
    }

    /// <summary>
    /// 「选项集合差」那条探针跑得通，并且**真走到了该走的地方**。
    ///
    /// 只断言「一条都不抛」是假绿灯：第一版这么写，四人局只推阶段不做决策，
    /// 28 个键里只有 draw/end/move/mucus/mutate/pass 六种形状 ——
    /// 开局落子、复活、打牌、分化、种类技能一次都没碰到，
    /// 「`Available` 能给出而 `Of` 认不出」那类漏网之鱼**根本走不到跟前**。
    ///
    /// 所以判据是两条：整张表拍得平，**且**这几种形状必须出现过。
    /// 少一种就是走子器退化了（或者那类选项自己没了），两样都得有人知道。
    /// </summary>
    [Fact]
    public void 走完一局的选项表都能拍成语义键()
    {
        var trace = KeyWalk.Walk(MatchSetup.Create(4, 20260916), 400, 7);

        Assert.All(trace.Seen, k => Assert.StartsWith("k=", k));
        var shapes = trace.Seen.Select(Shape).ToHashSet(StringComparer.Ordinal);
        Assert.Subset(shapes, new HashSet<string>(StringComparer.Ordinal)
        {
            "k=setup_place", "k=immune_revive",
            "k=action|act=move", "k=action|act=draw", "k=action|act=mutate", "k=action|act=play",
            "k=action|act=differentiate", "k=action|act=antibody", "k=action|act=ossify",
            "k=action|act=jump", "k=action|act=end", "k=action|act=pass",
            "k=action+chemo_target|act=chemo",
        });
        Assert.True(trace.Picked.Count > 300, $"只挑了 {trace.Picked.Count} 次，覆盖率没意义了");
    }

    /// <summary>键 → 形状（丢掉具体坐标/卡名，只留 kind 与 act），用来看覆盖到哪几类。</summary>
    private static string Shape(string key)
    {
        var parts = key.Split('|');
        var act = parts.FirstOrDefault(p => p.StartsWith("act=", StringComparison.Ordinal));
        return act == null ? parts[0] : $"{parts[0]}|{act}";
    }

    /// <summary>
    /// 【早期血行转移】曾经和四个无目标技能摆在一起枚举，`Target` 恒为 null、
    /// `Validate` 条条驳回 —— 整个技能**在选项表里根本不存在**。
    /// 黑色素瘤站上血管格，它就该出得来。
    /// </summary>
    [Fact]
    public void 早期血行转移在选项表里出得来()
    {
        var s = Fixture();
        var melanoma = s.Cells[new EntityId(2)];
        s = s.WithBoard(s.Board.UpdateTissue(melanoma.Position, s.Board.Tissues[melanoma.Position].WithType(TissueType.BloodVessel)))
             .WithTurn(s.Turn.Copy(phase: Phase.PlayerAction, seat: 1));

        var keys = OptionKeys(s, 1);

        Assert.Contains(keys, k => k.StartsWith("k=action|act=homing|to=", StringComparison.Ordinal));
    }

    /// <summary>
    /// 探针本体：一个世界 + 一个席位 → 排好序的语义键集合。
    /// 比**集合**不比顺序 —— `DecisionRouter.Available` 走 `PagedMap` 的迭代序，
    /// 而 GD 的选项表是另一套次序，顺序本来就不该进判据。
    /// </summary>
    public static IReadOnlyList<string> OptionKeys(WorldState s, int seat) =>
        new BasicRulesEngine().GetAvailableDecisions(s, seat)
            .Select(d => SemanticKey.Of(s, d))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(k => k, StringComparer.Ordinal)
            .ToArray();

    /// <summary>
    /// 四席的 DemoScenario：0/2 免疫、1 黑色素瘤、3 印戒。
    /// 键的拼法只吃「阵营 / 位置 / 挂起态」，摆好盘面就够，不用真推进。
    /// </summary>
    private static WorldState Fixture() => DemoScenario.Create();

    /// <summary>
    /// 反射构造样本：完备性护栏要的是「这个类型有没有键」，不是「这个实例合不合法」，
    /// 所以参数只要类型对得上就行。新加的决策记录会自动被这里接住。
    /// </summary>
    private static object?[] ArgsFor(Type t, WorldState s) =>
        t.GetConstructors().OrderByDescending(c => c.GetParameters().Length).First()
            .GetParameters().Select(p => Sample(p, s)).ToArray();

    private static object? Sample(ParameterInfo p, WorldState s)
    {
        var type = Nullable.GetUnderlyingType(p.ParameterType) ?? p.ParameterType;
        if (type == typeof(int)) return 0;
        if (type == typeof(EntityId)) return new EntityId(1);
        if (type == typeof(HexPosition)) return s.Cells[new EntityId(1)].Position;
        if (type == typeof(CellType)) return CellType.TCell;
        // 种类技能的 Skill 串是**第二层分派**，完备性这一层只需要一个认得的串
        if (type == typeof(string)) return p.Name == "Skill" ? "抗体" : "缺氧适应";
        throw new InvalidOperationException($"决策参数 {p.Name}（{type.Name}）还没有样本值");
    }
}
