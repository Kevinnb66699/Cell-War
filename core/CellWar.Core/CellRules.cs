namespace CellWar.Core;

/// <summary>
/// 一次能量损失**谁造成的** —— GD 伤害事件 `tags` / `source_kind` 的最小投影（cw_damage.gd `Tag` / `Kind`，cw_game.gd 四个薄壳）。
/// 护盾按它认账（<see cref="CellRules.ShieldApplies"/>）、树突【标记】只认免疫来源。
/// </summary>
public enum LossSource
{
    /// <summary>中立 / 世界来源：GD `cancer_hit(skill=false)` = Kind.WORLD + Tag.CANCER —— 攻击失败的反弹、【微环境压迫】、世界事件【增殖抑制】。</summary>
    World,
    /// <summary>免疫细胞的普通攻击：GD `immune_hit(attack=true)` = Tag.IMMUNE + Tag.ATTACK。</summary>
    ImmuneAttack,
    /// <summary>免疫方的卡牌 / 技能（非攻击）：GD `immune_hit(attack=false)` / `immune_hit_area` = Tag.IMMUNE —— 免疫卡、【抗体】【细胞毒素】。</summary>
    ImmuneEffect,
    /// <summary>癌细胞技能与癌方即时卡：GD `cancer_hit(skill=true)` = Kind.CELL_SKILL + Tag.CANCER —— 【黏液破裂】Excalibur【乳酸酸化】。</summary>
    CancerSkill,
}

/// <summary>
/// 细胞域状态变更：能量损失/死亡、座位存活、抗原记忆、运行期修饰、标记、传送、能量收取。
/// 对应离散事件架构三层设计的 CellRules 所有权域。所有规则域与卡牌共用这些原子变更，
/// 避免各自复制“扣血/死亡/记忆”逻辑；本类不负责决策合法性（由各域 Validate 负责）。
/// </summary>
internal static class CellRules
{
    /// <summary>
    /// 能量损失的唯一入口（GD `CWDamage` 五步管线的 C# 投影，cw_damage.gd:180-291）：
    /// ③④ 倍率（【刚性屏障】×40% 不限来源、树突【标记】×2 只认免疫来源）合成一次整数除法 →
    /// ⑤ 固定减免按**组**结算（<see cref="ShieldGroups"/>：同名合并、按打出先后、每组 ON_BENEFIT、挡光即停、各盾只认自己的来源）→
    /// 【BCL-2抗凋亡】免死 → 扣能量 / 死亡。
    /// GD 里**不进管线**的损失（【突变】第 3 点、【过载】【代谢消耗】、【吞噬体成熟】的处决）在 C# 也不许走这里。
    /// </summary>
    /// <param name="source">这一下**谁造成的**（GD 伤害事件 Tag/Kind 的投影，见 <see cref="LossSource"/>）：护盾按来源认账。</param>
    /// <param name="ability">
    /// 这一下是**哪条效果**（GD 伤害事件的 `ability` 字段）。只有【微环境压迫】要报名：
    /// 【缺氧适应】挡它、【耗竭抵抗】结算它时额外 −0.5 —— GD 两处判的都是 `ev["ability"] == "微环境压迫"`。
    /// </param>
    public static WorldState Damage(WorldState s, EntityId id, int amount, LossSource source, string ability = "")
    {
        var c = s.Cells[id];
        // ③④ 倍率层。**所有倍率合成一次整数除法**（Settlement.ApplyEnergyLoss，逐位对齐 cw_damage.gd:218-223）
        var multipliers = new List<ValueModifier>();
        if (c.Type == CellType.Osteosarcoma && RulePolicies.TypeAbilityOn(s, c) && s.Board.Tissues[c.Position].State == TissueState.SolidifiedCancer)
            multipliers.Add(new ValueModifier(ModifierStage.Multiply, SourceLayer.Passive, 0, 40));  // 【刚性屏障】×40%，不限来源

        // 树突【I-标记】：被标记的癌细胞下一次受到**免疫细胞造成的**能量损失时 ×2，随后移除一层标记（PRD:573）。
        // **只认免疫来源**（Kevin 2026-09-15 拍板；GD cw_damage.gd:194 判 `Tag.IMMUNE in tags`）。
        // 此前 C# 不看来源 —— 那时【突变】自扣还走这条管线，被标记的癌细胞会把自己的损失翻倍。
        // ON_BENEFIT：只有确实有伤害可翻倍时才消耗（`amount > 0`）；MarkLeft 可能 >1（【抗原呈递强化】给 2 层），耗尽才清 Marked。
        var markApplies = c.Marked && amount > 0 && source is LossSource.ImmuneAttack or LossSource.ImmuneEffect;
        if (markApplies)
            multipliers.Add(new ValueModifier(ModifierStage.Multiply, SourceLayer.Skill, 0, 200));
        amount = Settlement.ApplyEnergyLoss(amount, multipliers);
        if (markApplies)
        {
            var left = c.MarkLeft - 1;
            s = s.UpdateCell(id, c.Copy(markLeft: left, marked: left > 0));
        }

        // ⑤ 固定减免 —— 逐位对齐 GD `_reduce` / `_shield_groups`（cw_damage.gd:232-291）：
        //   · 护盾按**组**：同名条目合并成一组，减免 = 单值 × 条数（定案 #57：两张「下一次 −1.5」= 这一次减 3.0）；
        //   · 组间按打出先后（【囊性护甲】最先、【耗竭抵抗】最后）；
        //   · 每组 ON_BENEFIT：这一组没把伤害压低就不消耗；已经挡光了就停，后面的盾留着；
        //   · 各盾只认自己的来源（<see cref="ShieldApplies"/>）—— 此前 C# 对目标身上全部 EnergyLoss 修饰一律套用、一律消耗，
        //     2p 第 52 步【突变】的自损把只挡免疫方的【DNA损伤修复】吃掉了（2026-09-17）。
        foreach (var g in ShieldGroups(s, s.Cells[id], source, ability))
        {
            if (amount <= 0) break;
            var after = Math.Max(0, amount - g.Cut);
            if (after == amount) continue;
            amount = after;
            s = g.Kind switch
            {
                ShieldKind.Armor => s.UpdateCell(id, s.Cells[id].Copy(armor: true)),
                ShieldKind.Modifier => SpendModifiers(s, id, g.Name),
                _ => BurnRoundGate(s, id, "耗竭抵抗"),
            };
        }
        c = s.Cells[id];
        // 【BCL-2抗凋亡】：即将受到致命能量损失时免疫该次损失，能量改为 0.5/0.8/1
        if (amount >= c.Energy && HasModifier(c, "BCL-2抗凋亡"))
        {
            var survive = RulePolicies.CancerPhase(s.Turn.WorldRound) switch { 0 => 5, 1 => 8, _ => 10 };
            s = s.UpdateCell(id, c.Copy(energy: survive));
            return RemoveModifiers(s, id, "BCL-2抗凋亡");
        }
        var energy = Math.Max(0, c.Energy - amount);
        return energy == 0 ? Kill(s, id) : s.UpdateCell(id, c.Copy(energy: energy));
    }

    /// <summary>护盾组的三种消耗方式：【囊性护甲】烧本回合护甲、四张护盾卡扣同名修饰、【耗竭抵抗】烧「本世界回合首次」闸。</summary>
    internal enum ShieldKind { Armor, Modifier, Exhaust }
    internal readonly record struct ShieldGroup(string Name, int Cut, int Seq, ShieldKind Kind);

    /// <summary>GD `MEMBRANE_CUT` / `IFN1_CUT` / `HYPOXIA_CUT` / `ARMOR_REDUCTION`（cw_data.gd）。</summary>
    internal const int MembraneCut = 15, Ifn1Cut = 10, HypoxiaCut = 10, ArmorReduction = 5;
    /// <summary>GD `_shield_groups` 只认这四张（顺序也是它的）。</summary>
    private static readonly string[] ShieldCards = { "细胞膜修复", "I型干扰素", "缺氧适应", "DNA损伤修复" };

    /// <summary>GD `_shield_groups`：这次事件上受击方有哪些减免可用，按「打出先后」排（同名合并成一组，减免 = 单值 × 条数）。</summary>
    internal static IReadOnlyList<ShieldGroup> ShieldGroups(WorldState s, Cell c, LossSource source, string ability)
    {
        var groups = new List<ShieldGroup>();
        // 印戒【囊性护甲】：每世界回合第一次能量损失 −0.5，不限来源（口径 #76）
        if (c.Type == CellType.SignetRing && RulePolicies.TypeAbilityOn(s, c) && !c.ArmorUsedThisRound)
            groups.Add(new("囊性护甲", ArmorReduction, -1, ShieldKind.Armor));
        foreach (var name in ShieldCards)
        {
            if (!ShieldApplies(name, source, ability)) continue;
            var entries = c.Modifiers.Where(m => m.Card == name).ToList();
            if (entries.Count == 0) continue;
            groups.Add(new(name, ShieldValue(s, name) * entries.Count, entries[0].Sequence, ShieldKind.Modifier));
        }
        // 【耗竭抵抗】（PRD:1277）是永久技能，没有「打出先后」，排在最后。**两句合成一个 cut 一次减掉**（Kevin 2026-09-16 裁定跟 GD）：
        //   ① 每世界回合自身第一次受到能量损失：该次 −1.0；② 结算【微环境压迫】时：额外 −0.5
        if (RulePolicies.HasSkill(s, c, "耗竭抵抗"))
        {
            var cut = (RoundGateOpen(c, "耗竭抵抗") ? ExhaustFirstCut : 0) + (ability == "微环境压迫" ? ExhaustPressureCut : 0);
            if (cut > 0) groups.Add(new("耗竭抵抗", cut, int.MaxValue, ShieldKind.Exhaust));
        }
        return groups.OrderBy(g => g.Seq).ToList();   // OrderBy 是稳定排序；序号本就互不相同
    }

    /// <summary>GD `_shield_applies`：各护盾认哪些来源（设计 §6.5，按标签语义识别，不靠布尔分叉）。</summary>
    internal static bool ShieldApplies(string name, LossSource source, string ability) => name switch
    {
        "细胞膜修复" or "I型干扰素" => true,                                        // 任何来源的能量损失
        "缺氧适应" => ability == "微环境压迫" || source == LossSource.CancerSkill,   // 癌细胞技能（含癌方即时卡）**或**【微环境压迫】（口径 #62/#72）
        "DNA损伤修复" => source == LossSource.ImmuneEffect,                          // 只挡免疫方的【事件】/【技能】，普通攻击是 PD-L1 的领地（口径 #62）
        _ => false,
    };

    /// <summary>GD `_shield_value` 的单张值。【DNA损伤修复】按**结算当刻**的分期取 1.0/1.5/2.0（定案 #64），不是打出时存的那份。</summary>
    private static int ShieldValue(WorldState s, string name) => name switch
    {
        "细胞膜修复" => MembraneCut,
        "I型干扰素" => Ifn1Cut,
        "缺氧适应" => HypoxiaCut,
        _ => RulePolicies.CancerPhase(s.Turn.WorldRound) switch { 0 => 10, 1 => 15, _ => 20 },
    };

    /// <summary>GD `spend_mods`：同名条目各扣一次，耗尽的移除（定案 #57 同名一起扣）。Uses=-1 不受影响。</summary>
    internal static WorldState SpendModifiers(WorldState s, EntityId id, string card)
    {
        var c = s.Cells[id];
        var kept = new List<ActiveModifier>();
        foreach (var m in c.Modifiers)
        {
            if (m.Card != card || m.Uses < 0) { kept.Add(m); continue; }
            var used = m.Consume();
            if (!used.Expired) kept.Add(used);
        }
        return s.UpdateCell(id, c.Copy(modifiers: kept));
    }

    /// <summary>GD `game.kill`（cw_game.gd）—— 死亡的唯一入口：能量清零、alive=false、**自身修饰随之消散**（`mods = []`，复活是新生），
    /// 占位交接、席位存活标记，【免疫猎杀】的趋化源冻在死亡格（位置平时不存在状态里，只有这一刻要冻）。
    /// 伤害管线打死的与自毁型技能（【黏液破裂】）都走这一条 —— 自毁**不能**走 Damage：【囊性护甲】【BCL-2抗凋亡】那些减免
    /// 会让它「自杀未遂」，印戒剩 0.5 能量活着继续占着回合（L1 第 56 步就停在这儿，2026-09-17）。</summary>
    public static WorldState Kill(WorldState s, EntityId id)
    {
        var c = s.Cells[id];
        // 免疫细胞记下「哪一回合起可以复活」（GD kill：`respawn_round = round_no + 1 + delay`，delay < 0 = 不再复活）；
        // 它进 state_hash 与 L1 视图（6p 第 45 步就是差在这一格）。癌细胞的复活看固化癌组织，不用这个字段
        var respawn = c.Faction == Faction.Immune && s.Tuning.ImmuneRespawnDelay >= 0 ? s.Turn.WorldRound + 1 + s.Tuning.ImmuneRespawnDelay : -1;
        s = s.UpdateCell(id, c.Copy(energy: 0, alive: false, deathRound: s.Turn.WorldRound, respawnRound: respawn, modifiers: Array.Empty<ActiveModifier>()));
        if (s.Turn.TrackCell == id)
            s = s.WithTurn(s.Turn.WithTrack(null, c.Position, s.Turn.TrackRounds));
        s = s.UpdateTissueOccupant(c.Position, null);
        return SetSeatAlive(s, c.OwnerSeat, s.Cells.Values.Any(x => x.OwnerSeat == c.OwnerSeat && x.IsAlive));
    }

    public static WorldState SetSeatAlive(WorldState s, int seat, bool alive)
        => s.UpdatePlayer(seat, s.Players[seat].WithIsAlive(alive));

    public static WorldState AddMemory(WorldState s, int amount)
    {
        foreach (var p in s.Players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat))
        {
            var memory = p.AntigenMemory + amount;
            var level = memory >= (s.Players.Count == 6 ? 70 : 50) ? ImmuneLevel.X :
                memory >= (s.Players.Count == 6 ? 30 : 20) ? ImmuneLevel.III : memory >= 10 ? ImmuneLevel.II : ImmuneLevel.I;
            if (level < p.ImmuneLevel) level = p.ImmuneLevel;
            if (level == ImmuneLevel.X && p.ImmuneLevel != ImmuneLevel.X) memory = 0;
            s = s.UpdatePlayer(p.Seat, p.WithAntigenMemory(memory).WithImmuneLevel(level));
        }
        return s;
    }

    public static WorldState ReduceMemory(WorldState s, int amount)
    {
        foreach (var p in s.Players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat).ToArray())
            s = s.UpdatePlayer(p.Seat, p.WithAntigenMemory(Math.Max(0, p.AntigenMemory - amount)));
        return s;
    }

    /// <summary>挂上一条运行期修饰，序号取自该细胞的打出计数。</summary>
    public static WorldState AddModifier(WorldState s, Cell cell, ActiveModifier modifier)
    {
        var current = s.Cells[cell.Id];
        var list = current.Modifiers.ToList();
        list.Add(modifier with { Sequence = current.PlayCounter + 1 });
        return s.UpdateCell(cell.Id, current.Copy(playCounter: current.PlayCounter + 1, modifiers: list));
    }

    public static bool HasModifier(Cell c, string card) => c.Modifiers.Any(m => m.Card == card);

    public static WorldState RemoveModifiers(WorldState s, EntityId id, string card)
    {
        var c = s.Cells[id];
        return s.UpdateCell(id, c.Copy(modifiers: c.Modifiers.Where(m => m.Card != card).ToList()));
    }

    /// <summary>
    /// 消耗一次目标数值的修饰（次数-1，耗尽即移除）；Uses=-1 不受影响。
    ///
    /// **移动那一路是 ON_BENEFIT**（GD cw_cost.gd:238，Kevin 2026-09-16 拍板跟 GD）：只消耗这一步**真改了价**的那些 ——
    /// 「费用改为 X」改成了原价、免费豁免时费用已经是 0、同一竞争组里没被选中的第二条免费，都不扣。
    /// 按 (卡名, 打出序号) 认条目：GD 是按名字扣最早那条，序号本就是打出先后。
    /// 攻击那一路照旧；**伤害那一路 2026-09-17 起不走这里** —— 护盾在 `Damage` 里逐组 ON_BENEFIT（`ShieldGroups` / `SpendModifiers`）。
    /// </summary>
    public static WorldState ConsumeModifiers(WorldState s, EntityId id, ModifierTarget target, HexPosition? destination = null, int? rawCostOverride = null)
    {
        var c = s.Cells[id];
        HashSet<(string, int)>? applied = null;
        if (target == ModifierTarget.Move && destination is { } dest)
            applied = RulePolicies.AppliedMoveModifiers(s, c, dest, rawCostOverride).Select(m => (m.Name, m.Sequence)).ToHashSet();
        var kept = new List<ActiveModifier>();
        foreach (var m in c.Modifiers)
        {
            var touched = m.Target == target && m.Uses >= 0 && (applied == null || applied.Contains((m.Card, m.Sequence)));
            if (!touched) { kept.Add(m); continue; }
            var used = m.Consume();
            if (!used.Expired) kept.Add(used);
        }
        return s.UpdateCell(id, c.Copy(modifiers: kept));
    }

    /// <summary>【耗竭抵抗】两句的减免值（GD `EXHAUST_FIRST_CUT` / `EXHAUST_PRESSURE_CUT`）。</summary>
    internal const int ExhaustFirstCut = 10;
    internal const int ExhaustPressureCut = 5;

    /// <summary>【连续吞噬】最多连几次 / 每连一格下一次攻击的加成（GD `CHAIN_PHAGO_MAX` / `CHAIN_PHAGO_BONUS`）。</summary>
    internal const int ChainPhagoMax = 5;
    internal const int ChainPhagoBonus = 5;

    /// <summary>【连续吞噬】这一跳能落在哪：相邻的**癌组织**、且没有细胞占着。</summary>
    public static IReadOnlyList<HexPosition> ChainTargets(WorldState s, Cell c)
        => c.Position.GetNeighbors()
            .Where(n => s.Board.Tissues.TryGetValue(n, out var t)
                && t.State == TissueState.Cancer && s.GetCellAt(n) == null)
            .OrderBy(n => n.Q).ThenBy(n => n.R).ToArray();

    /// <summary>
    /// 【炎症性趋化】每步的起价 0.2 与最多 3 步。
    /// 是**常量不是旋钮** —— GD 侧写在 `CWData.CHEMOTAX_STEP_COST` 里、不过 tune，
    /// 照 `SkillRules.MelanomaHomingCost` 那条先例办。
    /// </summary>
    internal const int ChemotaxisStepCost = 2;
    internal const int ChemotaxisMaxSteps = 3;

    /// <summary>
    /// 【炎症性趋化】这一步能落在哪：相邻的健康/普通癌组织（固化不行）、没有**存活**免疫细胞占着
    /// （癌细胞占着的格是合法落点 —— 走进去就是攻击，卡面明写「正常触发…攻击」）、
    /// 且付得起 0.2 过完整条管线之后的价（`can_pay`：付完至少留 0.1）。
    ///
    /// 刻意**不复用** <see cref="RulePolicies.QuoteMove"/>：那里还带着树突【各司其职】、
    /// 同阵营占位、借道前进三条 GD 选项层没有的判断，一用就多给/少给落点。
    /// 树突与攻击上限这两条 GD 只在提交复验里查（见 <see cref="CommitLegal"/>），
    /// 于是「选项给得出来、走不成、步数照减」是 GD 的实际行为，这里照抄。
    ///
    /// 枚举序是 `GetNeighbors()` 的，与 GD `game.neighbors` 的方向序**不同、集合相同**；
    /// 对拍比的是语义键的集合，所以无碍 —— 但别误以为下标能直接对上。
    /// </summary>
    public static IReadOnlyList<HexPosition> ChemotaxisSteps(WorldState s, Cell c)
        => c.Position.GetNeighbors()
            .Where(n => s.Board.Tissues.TryGetValue(n, out var t)
                && t.State != TissueState.SolidifiedCancer
                && s.GetCellAt(n) is not { IsAlive: true, Faction: Faction.Immune }
                && c.Energy > RulePolicies.BaseMoveCost(s, c, n, ChemotaxisStepCost))
            .ToArray();

    /// <summary>
    /// GD 提交复验 `_is_move_legal_now` 里、而候选生成里**没有**的那两条：
    /// 树突【I-各司其职】不得向癌细胞占据的格移动、本回合攻击次数上限。
    /// 不满足时 GD 的 `commit` 返回空字典 —— 整步静默作废（不移动、不扣能量、无日志），
    /// 但外层循环照常推进到下一步，所以这里只报「走不走得成」，不负责终止整套。
    /// </summary>
    private static bool CommitLegal(WorldState s, Cell cell, HexPosition to)
    {
        if (s.GetCellAt(to) is not { } occupant) return true;   // 空格永远走得进
        if (cell.Faction != Faction.Immune) return false;       // 癌方：一格一细胞
        if (occupant.Faction != Faction.Cancer) return false;   // 免疫踩免疫：不是攻击，也走不进
        // 树突【I-各司其职】：不能通过【迁移】攻击癌细胞（cw_actions.gd:406-408）。
        // 少了这一行不是「多打一下」—— `QuoteMove` 对树突 + 有占位返回 null，`Move` 里 `!.Value` 当场抛。
        if (cell.Type == CellType.Dendritic) return false;
        // 攻击次数上限（cw_actions.gd:415-418）：用完只是这一格进不去，别的迁移照常。与 ValidateMove 同一份判据。
        if (AttackCapReached(s, cell)) return false;
        return true;
    }

    /// <summary>
    /// 【炎症性趋化】走一步：起价换成 0.2，其余**照常走完整条费用管线**（扣能量、消耗限次修饰），
    /// 与【连续吞噬】的 `free: true` 正好相反。走成走不成，剩余步数都减一。
    /// </summary>
    public static RulesResult ChemotaxisMove(WorldState s, EntityId cellId, HexPosition to, IDeterministicRng rng)
    {
        var cell = s.Cells[cellId];
        var left = s.Turn.ChemotaxisStepsLeft - 1;
        s = s.WithTurn(s.Turn.WithPendingChemotaxis(cellId, left, s.Turn.PendingWalkCard));
        if (!CommitLegal(s, cell, to)) return new(s, Array.Empty<IGameEvent>(), true);
        return Move(s, new MoveDecision(cell.OwnerSeat, cellId, to), rng, rawCostOverride: ChemotaxisStepCost);
    }

    /// <summary>【趋化募集】/【效应细胞浸润】每次走几步（GD `_free_walk(cell, 2, …)`）。</summary>
    public const int FreeWalkMaxSteps = 2;

    /// <summary>这两张事件卡是不是免费连走（GD `_free_walk`：不进费用管线、直接 enter_tile）；其余是【炎症性趋化】那条付费连走。</summary>
    public static bool IsFreeWalk(string? card) => card is "趋化募集" or "效应细胞浸润";

    /// <summary>GD `_free_walk` 每一步的候选：相邻（DIRS 序）、**无任何存活细胞**占据、健康组织；【效应细胞浸润】还可进**普通**癌组织（固化不行）。</summary>
    public static IReadOnlyList<HexPosition> FreeWalkSteps(WorldState s, Cell c, bool intoCancer)
        => RulePolicies.GdNeighbors(s, c.Position)
            .Where(n => s.GetCellAt(n) is not { IsAlive: true }
                && (s.Board.Tissues[n].State == TissueState.Healthy || (intoCancer && s.Board.Tissues[n].State == TissueState.Cancer)))
            .ToList();

    /// <summary>当前这段连走（看 <see cref="TurnState.PendingWalkCard"/>）下一步能落哪：三张卡各自的规则。</summary>
    public static IReadOnlyList<HexPosition> WalkSteps(WorldState s, Cell c) => s.Turn.PendingWalkCard switch
    {
        "趋化募集" => FreeWalkSteps(s, c, intoCancer: false),
        "效应细胞浸润" => FreeWalkSteps(s, c, intoCancer: true),
        _ => ChemotaxisSteps(s, c),
    };

    /// <summary>走一步：免费连走直接 `EnterTile`（GD `_free_walk` → `enter_tile`，不扣能量、不碰移动修饰）；【炎症性趋化】走付费那条。</summary>
    public static RulesResult WalkMove(WorldState s, EntityId cellId, HexPosition to, IDeterministicRng rng)
    {
        if (!IsFreeWalk(s.Turn.PendingWalkCard)) return ChemotaxisMove(s, cellId, to, rng);
        var left = s.Turn.ChemotaxisStepsLeft - 1;
        s = s.WithTurn(s.Turn.WithPendingChemotaxis(cellId, left, s.Turn.PendingWalkCard));
        return new(EnterTile(s, cellId, to, rng), Array.Empty<IGameEvent>(), true);
    }

    /// <summary>
    /// 把【炎症性趋化】的挂起态归一化：GD 的三条退出（细胞死了 / 没有可走的下一步 / 步数走满）
    /// 是在下一轮循环**开头**判的，而那时【连续吞噬】的连锁早已在 `_do_move` 内部排干。
    /// C# 没有那个循环，所以每次推进之后统一判一次 —— 不这么做，
    /// `Available` 就会返回「只剩一个『停在这里』」这种 GD 里不存在的决策点。
    /// </summary>
    internal static WorldState NormalizeChemotaxis(WorldState s)
    {
        // 嵌套连走是栈：栈顶这段走完 / 停了 / 没路了就弹掉，露出外层那段，从新位置按**外层的卡名**重算候选；一层都不剩才真正摘干净
        while (s.Turn.PendingChemotaxisCell is { } id)
        {
            // 手牌撑爆的强制弃置在 GD 是这一步内部 `draw()` 里 await 问完的（cw_cards.gd:63），先于下一轮循环开头的退出判断，
            // 也先于打出的即时卡离手 —— 弃置挂着就什么都别摘
            if (s.Turn.PendingDiscardSeat is not null) return s;
            if (s.Turn.PendingChainCell is not null) return s;   // 连锁先排干，它在 GD 里嵌在这一步内部
            var c = s.Cells[id];
            if (s.Turn.ChemotaxisStepsLeft > 0 && c.IsAlive && WalkSteps(s, c).Count > 0) return s;
            s = s.WithTurn(s.Turn.PopWalk());
        }
        return s;
    }

    /// <summary>
    /// 【连续吞噬】走一跳：**免费**迁移（不进费用管线），随后照常触发净化 ——
    /// 于是能不能再连由那一步自己决定（`Move` 里净化之后会重新挂起）。
    /// </summary>
    public static RulesResult ChainMove(WorldState s, ChainMoveDecision d, IDeterministicRng rng)
    {
        var c = s.Cells[d.CellId];
        s = s.UpdateCell(d.CellId, c.Copy(chainLeft: c.ChainLeft - 1, chainBonus: c.ChainBonus + ChainPhagoBonus));
        s = s.WithTurn(s.Turn.WithPendingChain(null));   // 先摘挂起；这一跳的净化会视情况重新挂上
        return Move(s, new MoveDecision(d.PlayerSeat, d.CellId, d.Target), rng, free: true);
    }

    /// <summary>树突【I-标记】光环：任意时刻处于树突 2 环内的癌细胞自动获得标记。</summary>
    public static WorldState UpdateMarks(WorldState s)
    {
        foreach (var dendritic in RulePolicies.Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Immune && c.Type == CellType.Dendritic).ToArray())
            // GD `update_marks`（cw_game.gd:1081-1089）跳过的是**已带标记**的（`if c["marked"]: continue`），不是「本回合标过」的：
            // 上一回合标上、还没被消耗的标记不该被树突光环刷新寿命与次数（2026-09-17 随【交叉呈递】一起对齐）
            foreach (var cancer in RulePolicies.Cells(s).Where(c => c.IsAlive && c.Faction == Faction.Cancer && !c.Marked && c.Position.DistanceTo(dendritic.Position) <= 2).ToArray())
                s = ApplyMark(s, cancer.Id, dendritic);
        return s;
    }

    /// <summary>施加【标记】（同一世界回合同一癌细胞只能获得一次；树突【抗原呈递强化】为 2 次）。</summary>
    public static WorldState ApplyMark(WorldState s, EntityId targetId, Cell by)
    {
        var target = s.Cells[targetId];
        if (target.MarkRound == s.Turn.WorldRound) return s;
        var charges = by.Faction == Faction.Immune && by.Type == CellType.Dendritic && RulePolicies.HasSkill(s, by, "抗原呈递强化") ? 2 : 1;
        return s.UpdateCell(targetId, target.Copy(marked: true, markRound: s.Turn.WorldRound, markLeft: Math.Max(target.MarkLeft, charges)));
    }

    /// <summary>`enter_tile` 的前半截（GD cw_actions.gd:1001-1026）：占位交接、落脚，然后 <see cref="Arrive"/>（定殖 / 蹲守 / 净化）。
    /// 传送 / 跃进 / 免费连走在 GD 里都不传 paid（= -1，不是花钱走进来的：巨噬不回能）。只有 <see cref="EnterTile"/> 调它。</summary>
    private static WorldState Teleport(WorldState s, EntityId id, HexPosition dest, IDeterministicRng rng)
    {
        var c = s.Cells[id];
        s = s.UpdateTissueOccupant(c.Position, null).UpdateTissueOccupant(dest, id);
        s = s.UpdateCell(id, c.Copy(position: dest, campRound: -1));
        return Arrive(s, id, dest, paid: -1, rng);
    }

    /// <summary>GD `enter_tile` 的三条分支（cw_actions.gd:1009-1026）：癌进健康 → 【定殖】（`to_cancer(t, true)`：solid / necrosis / ossify 一起清、newborn=true）；
    /// 免疫进骨样硬化标记格 → 登记蹲守、不净化；免疫进癌组织 → <see cref="PurifyHere"/>。Move 与 Teleport 共用这一份 ——
    /// 此前两条路各写一遍裸 `UpdateTissueState`：定殖不清坏死，传送落到标记格也当场净化、还没有净化连锁（2026-09-17 晚）。</summary>
    private static WorldState Arrive(WorldState s, EntityId id, HexPosition dest, int paid, IDeterministicRng rng)
    {
        var c = s.Cells[id];
        var tile = s.Board.Tissues[dest];
        if (c.Faction == Faction.Cancer && tile.State == TissueState.Healthy)
            return CardRules.ToCancer(s, dest, newborn: true);
        if (c.Faction == Faction.Immune && tile.State == TissueState.Cancer)
        {
            // 骨肉瘤【骨样硬化】标记过的格：进来不能立刻净化，得停留到世界回合结束（下一回合由 BoardRules.ResolveCamping 兑现）
            if (tile.OssifyAtRound > 0)
                return s.UpdateCell(id, c.Copy(campRound: s.Turn.WorldRound, campPosition: dest));
            return PurifyHere(s, id, dest, paid, rng);
        }
        return s;
    }

    /// <summary>GD `purify_here`（cw_actions.gd:1037-1082）—— 【I-净化】本体，enter_tile 的正常进入与 `_resolve_camping` 的蹲守净化共用这一份：
    /// 转健康（`to_healthy`）→ 记忆（卡牌连锁出来的不给）→ 巨噬【I-吞噬】按实付回能 →
    /// `_on_purify` 的三张永久技能（模式识别增强 → 效应记忆形成 → 免疫记忆库抽卡，**就是这个顺序**：此前 C# 先抽卡再加记忆，
    /// 而记忆会抬等级、等级决定卡池，抽到的牌会不同）→ 巨噬【连续吞噬】挂起。</summary>
    /// <param name="paid">这一步的**实付**（GD `enter_tile` 的 paid）：-1 = 不是花钱走进来的（传送 / 复活 / 血管 / 卡牌位移 / 蹲守 / 连锁跳），
    /// 0 = 付费迁移被免费豁免盖成 0（【组织巡航】首移），&gt;0 = 真付了。</param>
    /// <param name="chain">要不要挂【连续吞噬】。E 阶段的蹲守净化没有决策点可挂，传 false（GD 会当场追问 —— KNOWN_GAP，极少见）。</param>
    internal static WorldState PurifyHere(WorldState s, EntityId id, HexPosition pos, int paid, IDeterministicRng rng, bool chain = true)
    {
        s = CardRules.ToHealthy(s, pos);
        // 卡牌引发的净化不积累抗原记忆（GD purify_gives_memory / card_resolve_depth；Kevin 2026-09-16 拍板跟 GD）
        if (RulePolicies.PurifyGivesMemory(s)) s = AddMemory(s, 1);
        if (s.Cells[id].Type == CellType.Macrophage)
        {
            var heal = MacroPurifyHeal(s, paid);
            if (heal > 0) s = s.UpdateCell(id, s.Cells[id].WithEnergy(s.Cells[id].Energy + heal));
        }
        // _on_purify（cw_actions.gd:1349-1360）
        // 【模式识别增强】：每世界回合第一次【净化】后恢复 0.5 能量
        if (RulePolicies.HasSkill(s, s.Cells[id], "模式识别增强") && RoundGateOpen(s.Cells[id], "模式识别增强"))
        {
            s = BurnRoundGate(s, id, "模式识别增强");
            s = s.UpdateCell(id, s.Cells[id].WithEnergy(s.Cells[id].Energy + 5));
        }
        // 【效应记忆形成】：每世界回合第一次【净化】后免疫方 +1 抗原记忆、自身恢复 0.5
        if (RulePolicies.HasSkill(s, s.Cells[id], "效应记忆形成") && RoundGateOpen(s.Cells[id], "效应记忆形成"))
        {
            s = BurnRoundGate(s, id, "效应记忆形成");
            s = AddMemory(s, 1);
            s = s.UpdateCell(id, s.Cells[id].WithEnergy(s.Cells[id].Energy + 5));
        }
        // 【免疫记忆库】等净化跨域反应：发出已提交事实，由 FactRouter 按目录稳定顺序分派（抽卡 —— 排在两张加记忆的技能之后）
        s = FactRouter.Emit(s, new PurifyResolvedFact(s.Turn.WorldRound, id), rng);
        // 巨噬【连续吞噬】：净化之后**当场**接着走（PRD:605）。GD 是 await 循环 + `chain_running` 再入闸；
        // 这里每一跳是一个独立决策，所以挂起等玩家选就行，不需要那道闸。
        if (chain && s.Cells[id].Type == CellType.Macrophage && s.Cells[id].ChainLeft > 0 && ChainTargets(s, s.Cells[id]).Count > 0)
            s = s.WithTurn(s.Turn.WithPendingChain(id));
        return s;
    }

    /// <summary>GD `CWData.MACRO_MOVE_NET_MIN`：一次付费迁移净支出至少 0.1（巨噬回能封顶 = 实付 − 它）。</summary>
    internal const int MacroMoveNetMin = 1;

    /// <summary>巨噬【I-吞噬】净化回能，逐行照抄 GD cw_actions.gd:1063-1067：不是花钱走进来的（paid &lt; 0）不回；
    /// 付费迁移封顶「实付 − 0.1」（治的是「靠移动赚钱」）；**付费迁移被免费豁免盖成 0（paid == 0，【组织巡航】首移）回满** ——
    /// GD 注释明写这两个边界曾经反过，C# 此前的 `Math.Min(full, cost - 1)` 正是那个反的旧形状。回多少走旋钮 `macro_heal_purify`。</summary>
    internal static int MacroPurifyHeal(WorldState s, int paid)
    {
        var heal = s.Tuning.MacroHealPurify;
        if (paid < 0) return 0;
        if (paid > 0) heal = Math.Min(heal, Math.Max(paid - MacroMoveNetMin, 0));
        return heal;
    }

    /// <summary>GD `cw_actions.enter_tile`（1001-1032）—— 「进入一格」的唯一入口：占位交接与【定殖】/ 净化（<see cref="Teleport"/>）
    /// → 免疫踩黏液即清 → `collect_special`（代谢核心收能量 **或** 骨髓抽卡）→ 刷新树突【标记】。
    /// 三张传送卡（【免疫增援】【肿瘤细胞募集】【肿瘤增援】）、【癌症转移】与两条跃进技能都走它（2026-09-17）；
    /// 此前只有 Teleport，落到有卡的骨髓格上 GD 抽一张（带子多一发）、C# 什么也不抽。</summary>
    public static WorldState EnterTile(WorldState s, EntityId id, HexPosition dest, IDeterministicRng rng)
        => Land(Teleport(s, id, dest, rng), id, rng);

    /// <summary>`enter_tile` 的后半截（脚已经放到格上之后）：免疫踩黏液即清 → `collect_special` → 刷新标记。
    /// 复活也走这一截（GD `revive_*` 同样 `enter_tile`）—— 但复活不能走 Teleport：死亡格早就交出了占位，别人可能已经站上去。</summary>
    public static WorldState Land(WorldState s, EntityId id, IDeterministicRng rng)
    {
        var c = s.Cells[id];
        var t = s.Board.Tissues[c.Position];
        if (c.Faction == Faction.Immune && t.Mucus)
            s = s.WithBoard(s.Board.UpdateTissue(c.Position, t.WithMucus(false)));
        s = CollectSpecial(s, id, rng);
        return UpdateMarks(s);
    }

    /// <summary>GD `collect_special`（cw_actions.gd:1096-1107）：代谢核心有存储就收能量并清库存，
    /// **否则**（if / elif，不是两件都做）骨髓有卡就清库存并抽一张 —— 那一抽是带子上的一发，**不判阵营**。</summary>
    public static WorldState CollectSpecial(WorldState s, EntityId id, IDeterministicRng rng)
    {
        var c = s.Cells[id];
        var t = s.Board.Tissues[c.Position];
        if (t.Type == TissueType.MetabolicCore && t.Charge > 0) return CollectEnergy(s, id);
        if (t.Type == TissueType.BoneMarrow && t.Charge > 0)
        {
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithCharge(0)));
            return CardRules.DrawOne(s, s.Cells[id], rng);
        }
        return s;
    }

    public static WorldState CollectEnergy(WorldState s, EntityId id)
    {
        var c = s.Cells[id];
        var t = s.Board.Tissues[c.Position];
        if (t.Type == TissueType.MetabolicCore && t.Charge > 0)
        {
            s = s.UpdateCell(id, c.WithEnergy(c.Energy + t.Charge.Value));
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithCharge(0)));
        }
        return s;
    }

    public static WorldState AddToHand(WorldState s, Cell cell, string name)
    {
        var hand = cell.Hand.ToList();
        hand.Add(name);
        s = s.UpdateCell(cell.Id, cell.Copy(hand: hand));
        // GD `discard_to_limit(cell)`：只问超限的那一只、问到它降到上限为止 —— 所以挂起要记细胞，不只记席位
        return hand.Count > cell.HandMax ? s.WithTurn(s.Turn.WithPendingDiscard(cell.OwnerSeat, cell.Id)) : s;
    }

    /// <summary>世界回合 S 阶段开头：重置「每世界回合」额度与修饰（旧实现 _reset_round_flags）。</summary>
    public static WorldState ResetRoundFlags(WorldState s)
    {
        foreach (var c in RulePolicies.Cells(s))
            s = s.UpdateCell(c.Id, c.Copy(toxin: 0, mutateUsed: false, antibody: 0, metastasis: false, jump: 0, armor: false,
                fxRound: [],
                modifiers: c.Modifiers.Where(m => m.Duration != ModifierDuration.Round).ToList()));
        return s;
    }

    // ==== 永久技能的「第一次」闸门 ====
    //
    // 对齐 GDScript 的 `CWGame.first_this_turn` / `first_this_round`（cw_game.gd:596-612）。
    // 那边是「查+记账」一把做完并返回「这一次是不是第一次」；C# 状态不可变，
    // 所以拆成**只读的问**与**写状态的烧**两半 —— 报价、预演这类只读场合只调前者，
    // 免得把闸门白白烧掉（GD 那边专门为此写了警告注释）。

    /// <summary>
    /// 「每行动回合前 N 次」的额度，不写 = 1 次（GD 侧 CWCost.GATE_USES）。
    ///
    /// GD 那张表今天只有一行【组织驻留】= 2，而 C# 的【组织驻留】还没走闸门 ——
    /// 它是一条 `Uses: 2` 的 Free Move 修饰，**行为一致、只是额度记在 `mods` 里**。
    /// 搬它要连 GD 的 `Store.GATE`（修饰在表里、额度在 fx_turn 里）一起搬，是下一张工单；
    /// 在那之前这里不预先写死一个没人读的数。
    /// </summary>
    private static int GateUses(string key) => 1;

    /// <summary>这个「每行动回合」闸门还开着吗（只读，不记账）。</summary>
    public static bool TurnGateOpen(Cell c, string key) => c.FxTurn.GetValueOrDefault(key) < GateUses(key);

    /// <summary>这个「每世界回合」闸门还开着吗（只读，不记账）。</summary>
    public static bool RoundGateOpen(Cell c, string key) => !c.FxRound.Contains(key);

    /// <summary>烧掉一次「每行动回合」额度。</summary>
    public static WorldState BurnTurnGate(WorldState s, EntityId id, string key)
    {
        var c = s.Cells[id];
        return s.UpdateCell(id, c.Copy(fxTurn: new Dictionary<string, int>(c.FxTurn) { [key] = c.FxTurn.GetValueOrDefault(key) + 1 }));
    }

    /// <summary>关上一个「每世界回合」闸门。</summary>
    public static WorldState BurnRoundGate(WorldState s, EntityId id, string key)
    {
        var c = s.Cells[id];
        return s.UpdateCell(id, c.Copy(fxRound: [.. c.FxRound, key]));
    }

    /// <summary>
    /// 每行动回合攻击次数是否用完。走旋钮 `AttackMaxPerTurn`（GD `tune.attack_max_per_turn`），**0 = 不限**。
    /// 选项生成与提交复验共用同一份（GD 口径 #81），写两处必然漂移。
    /// </summary>
    internal static bool AttackCapReached(WorldState s, Cell cell)
        => s.Tuning.AttackMaxPerTurn > 0 && cell.AttacksThisTurn >= s.Tuning.AttackMaxPerTurn;

    /// <summary>移动合法性的域内校验（不包含阶段/回合/存活等公共前提，由编排层先行检查）。</summary>
    public static ValidationResult ValidateMove(WorldState s, MoveDecision move)
    {
        if (!s.Cells.TryGetValue(move.CellId, out var cell) || !cell.IsAlive)
            return new(false, "细胞不存在或已死亡");
        if (cell.OwnerSeat != move.PlayerSeat) return new(false, "不能移动其他玩家的细胞");
        if (!s.Board.Tissues.TryGetValue(move.TargetPosition, out var target)) return new(false, "目标位置不在棋盘内");
        var cost = RulePolicies.QuoteMove(s, cell, move.TargetPosition);
        if (cost == null) return new(false, "目标位置不可达或被占据");
        if (cell.Energy <= cost) return new(false, "能量不足，非自毁费用必须保留正能量");
        if (target.OccupyingCell.HasValue && AttackCapReached(s, cell)) return new(false, "攻击次数已达上限");
        return new(true);
    }

    /// <summary>
    /// 移动/攻击/净化/定殖结算（PRD J 组）。净化触发的跨域反应（如【免疫记忆库】免费抽卡）
    /// 通过发出 <see cref="PurifyResolvedFact"/> 交给 <see cref="FactRouter"/> 分派，保持 CellRules 不反向依赖卡域。
    /// </summary>
    /// <param name="free">
    /// 真免费：**不进费用管线**、也不消耗任何限次修饰（巨噬【连续吞噬】的连锁跳用它）。
    /// 它对应 GD `enter_tile` 不传 paid（-1）：巨噬**不**回能 —— 不是靠「实付 0 算出 0」；
    /// 付费迁移被【组织巡航】盖成 0 的那种 paid == 0，GD 反而回满（见 <see cref="MacroPurifyHeal"/>）。
    /// </param>
    /// <param name="rawCostOverride">
    /// 卡面自带的起价（【炎症性趋化】每步 0.2）。与 <paramref name="free"/> 语义相反：
    /// 这只是**换一个起价**，管线照跑、限次修饰照消耗、能量照扣。
    /// </param>
    public static RulesResult Move(WorldState s, MoveDecision move, IDeterministicRng rng, bool free = false, int? rawCostOverride = null)
    {
        var cell = s.Cells[move.CellId];
        var cost = free ? 0 : RulePolicies.QuoteMove(s, cell, move.TargetPosition, rawCostOverride)!.Value;
        var target = s.GetCellAt(move.TargetPosition);
        var events = new List<IGameEvent>();
        var attacker = cell.Copy(energy: cell.Energy - cost);
        s = s.UpdateCell(cell.Id, attacker);
        if (!free) s = ConsumeModifiers(s, cell.Id, ModifierTarget.Move, move.TargetPosition, rawCostOverride);
        if (target != null)
        {
            // 六面骰，**1..6**。原来写的是 NextInt(6)，那产出 0..5 —— 而 AttackOutcome 判
            // `roll == 6` 为暴击，于是暴击永远掷不出来（实测 60000 次 crit 0%，应为 16.7%）。
            // 用 NextIntRange(1, 7)（半开）而不是 NextInt(6) + 1：把「1..6」写进代码里，
            // 下一个人不用去推。PRD 只给概率不给面数，骰面值域由 Kevin 2026-09-15 裁定为 6 面。
            var roll = rng.NextIntRange(1, 7);
            var attackerCell = s.Cells[cell.Id];
            var attackMods = attackerCell.Modifiers.Where(m => m.Target == ModifierTarget.Attack).ToList();
            var attackExtra = attackMods.Sum(m => m.Value);
            var hasOpsonin = attackMods.Any(m => m.Card == "补体调理");
            var hasAffinity = attackMods.Any(m => m.Card == "高亲和力克隆");
            var hasCascade = attackMods.Any(m => m.Card == "补体级联");
            s = ConsumeModifiers(s, cell.Id, ModifierTarget.Attack);
            var outcome = hasAffinity ? "crit" : RulePolicies.AttackOutcome(s, roll, attackerCell);
            if (outcome == "fail" && hasOpsonin)
            {
                roll = rng.NextIntRange(1, 7);   // 【补体调理】的重掷，同样是 1..6
                outcome = RulePolicies.AttackOutcome(s, roll, s.Cells[cell.Id]);
            }
            if (HasModifier(s.Cells[target.Id], "PD-L1表达"))
            {
                outcome = outcome == "crit" ? "success" : "fail";  // 大成功→成功、成功/无效→无效
                s = RemoveModifiers(s, target.Id, "PD-L1表达");
            }
            var damage = outcome == "fail" ? 0 : outcome == "crit" ? 20 : 10;
            var extra = 0;
            if (outcome != "fail")
            {
                extra = attackExtra;
                // 【连续吞噬】连续净化攒的加成：**用掉即清**，不按回合过期
                var chain = s.Cells[cell.Id].ChainBonus;
                if (chain > 0)
                {
                    extra += chain;
                    s = s.UpdateCell(cell.Id, s.Cells[cell.Id].Copy(chainBonus: 0));
                }
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "抗体亲和力成熟") && RulePolicies.AdjacentHealthy(s, move.TargetPosition)) extra += 5;
            }
            attacker = s.Cells[cell.Id].Copy(attacks: cell.AttacksThisTurn + 1);
            s = s.UpdateCell(cell.Id, attacker);
            if (damage == 0) s = Damage(s, cell.Id, 5, LossSource.World);
            else
            {
                var actual = Math.Min(target.Energy, damage);
                s = Damage(s, target.Id, damage + extra, LossSource.ImmuneAttack);
                s = AddMemory(s, actual / 10);
                // 【吞噬体成熟】：攻击成功后目标余量不超过阈值则直接死亡
                var threshold = s.Cells[cell.Id].Type == CellType.Macrophage ? 15 : 5;
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "吞噬体成熟") && s.Cells[target.Id].IsAlive && s.Cells[target.Id].Energy <= threshold)
                {
                    // GD `lethal(target, "吞噬体成熟")`：处决**不进伤害管线**（护盾减不了、【BCL-2抗凋亡】救不回，口径 #68），直接 kill + update_marks
                    s = UpdateMarks(Kill(s, target.Id));
                    if (s.Cells[cell.Id].Type == CellType.Macrophage)
                        s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
                }
                // 【补体级联】：攻击成功后转化目标相邻最多 2 格无细胞占据的普通癌组织
                if (hasCascade)
                {
                    var cascade = target.Position.GetNeighbors()
                        .Where(n => s.Board.Tissues.TryGetValue(n, out var x) && x.State == TissueState.Cancer && x.OccupyingCell == null)
                        .ToArray();
                    foreach (var pick in rng.PickRandom(cascade, 2))
                        s = s.UpdateTissueState(pick, TissueState.Healthy);
                }
                // 【I-吞噬】：攻击成功造成能量损失后恢复受击方损失的 1/2（向上取整到十分位）
                if (s.Cells[cell.Id].Type == CellType.Macrophage)
                {
                    var loss = Math.Min(target.Energy, damage + extra);
                    var heal = (loss + 1) / 2;
                    if (heal > 0) s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
                }
            }
            events.Add(new CellAttackedEvent(s.Turn.WorldRound, s.Turn.Phase, cell.Id, target.Id, damage, !s.Cells[target.Id].IsAlive));
            if (s.Cells[target.Id].IsAlive || !s.Cells[cell.Id].IsAlive) return new(UpdateMarks(s), events, true);
        }
        s = s.UpdateTissueOccupant(cell.Position, null).UpdateTissueOccupant(move.TargetPosition, cell.Id);
        s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithPosition(move.TargetPosition).Copy(campRound: -1));
        var tissue = s.Board.Tissues[move.TargetPosition];
        // GD `enter_tile(cell, to, q.final)`：定殖 / 蹲守 / 净化 → 黏液 → collect_special → update_marks；RAS 在它整个跑完之后（cw_actions.gd:773-782）。
        // paid：连锁跳（free）在 GD 里不传 → -1；付费迁移传实付，被免费豁免盖成 0 的照传 0（巨噬回能三态看它，见 MacroPurifyHeal）
        s = Arrive(s, cell.Id, move.TargetPosition, free ? -1 : cost, rng);
        var landed = s.Board.Tissues[move.TargetPosition];
        if (landed.State != tissue.State)
            events.Add(new TissueStateChangedEvent(s.Turn.WorldRound, s.Turn.Phase, move.TargetPosition, tissue.State, landed.State));
        // 免疫踩黏液即清 —— GD 排在定殖 / 净化**之后**（cw_actions.gd:1028-1029），此前 C# 排在之前
        if (cell.Faction == Faction.Immune && landed.Mucus)
            s = s.WithBoard(s.Board.UpdateTissue(move.TargetPosition, landed.WithMucus(false)));
        s = CollectSpecial(s, cell.Id, rng);   // 代谢核心收能量 / 骨髓抽卡（GD enter_tile → collect_special，2026-09-17 补上骨髓那一支）
        s = UpdateMarks(s);
        // 【RAS持续激活】：每行动回合第一次通过【移动】触发【定殖】后恢复。GD 钩在 `_do_move` 里 enter_tile **之后**（cw_actions.gd:776-782），
        // 即 collect_special（骨髓可能抽一张并当场结算）与 update_marks 之后 —— 此前 C# 排在 CollectSpecial 之前（2026-09-17 晚对齐）。
        // GD `first_this_turn`（cw_game.gd）**每次都记一笔**、只在第一次返回 true：fx_turn 存的是「用了几次」，
        // 所以第二次定殖不回血、计数照样 +1（L1 第 184 步：GD 记 2、C# 记 1）。计数进 state_hash，得逐位同
        if (cell.Faction == Faction.Cancer && tissue.State == TissueState.Healthy && RulePolicies.HasSkill(s, s.Cells[cell.Id], "RAS持续激活"))
        {
            var first = TurnGateOpen(s.Cells[cell.Id], "RAS持续激活");
            s = BurnTurnGate(s, cell.Id, "RAS持续激活");
            if (first)
            {
                var heal = RulePolicies.CancerPhase(s.Turn.WorldRound) switch { 0 => 3, 1 => 5, _ => 7 };
                s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
            }
        }
        events.Add(new CellMovedEvent(s.Turn.WorldRound, s.Turn.Phase, cell.Id, cell.Position, move.TargetPosition, cost));
        return new(UpdateMarks(s), events, true);
    }
}
