namespace CellWar.Core;

/// <summary>修饰持续时间。Turn=本行动回合结束清除；Round=本世界回合结束清除；Game=永久。</summary>
public enum ModifierDuration
{
    Turn,
    Round,
    Game
}

/// <summary>修饰作用的目标数值。</summary>
public enum ModifierTarget
{
    Move,
    EnergyLoss,
    Attack
}

/// <summary>修饰生效的目标条件（无 → 无条件）。</summary>
public enum ModifierRequirement
{
    None,
    MoveToHealthy,
    MoveToCancerous
}

/// <summary>
/// 挂在细胞上的运行期修饰（对应旧实现 cell["mods"]）。Uses = -1 表示不限次数。
/// </summary>
public sealed record ActiveModifier(
    string Card,
    ModifierTarget Target,
    ModifierStage Stage,
    SourceLayer Layer,
    int Sequence,
    int Value,
    int? Floor,
    int Uses,
    ModifierDuration Duration,
    ModifierRequirement Requirement = ModifierRequirement.None)
{
    public const int Unlimited = -1;

    public bool Expired => Uses == 0;
    public ActiveModifier Consume() => this with { Uses = Uses - 1 };
    public ValueModifier ToValueModifier() => new(Stage, Layer, Sequence, Value, Floor, Card);
}
