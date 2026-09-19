namespace CellWar.Core;

/// <summary>
/// 一次能量损失**谁造成的** —— GD 伤害事件 `tags` / `source_kind` 的最小投影（cw_damage.gd `Tag` / `Kind`，cw_game.gd 四个薄壳）。
/// 护盾按它认账（<see cref="CellRules.ShieldApplies"/>）、树突【标记】只认免疫来源。
/// </summary>
public enum LossSource
{
    /// <summary>中立 / 世界来源：GD `cancer_hit(skill=false)` = Kind.WORLD + Tag.CANCER —— 攻击失败的反弹、【微环境压迫】。</summary>
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
        => Damage(s, id, amount, source, ability, 0, out _, out _);

    public static WorldState Damage(WorldState s, EntityId id, int amount, LossSource source, string ability, int direct, out int dealt)
        => Damage(s, id, amount, source, ability, direct, out dealt, out _);

    /// <param name="direct">同批的第二笔「直击」（GD 攻击里 Tag.DIRECT + UNPREVENTABLE + NO_LIFESTEAL 的那条事件：T 细胞【细胞毒性增强】的 1.0）：
    /// 走倍率层（【标记】各自 ×2 并各扣一层、【刚性屏障】照吃），**跳过第 ⑤ 层固定减免、一个盾都不消耗**，与主笔合计判【BCL-2抗凋亡】、合计落地。0 = 没有。</param>
    /// <param name="dealt">这一批目标**实际失去**的能量（GD `actual` 之和：min(calculated, 结算前能量)；被 BCL-2 整批免掉就是 0）。抗原记忆、【吞噬体成熟】的「造成了伤害」都读它。</param>
    /// <param name="mainDealt">主笔单独的实际失去（GD 逐事件的 `actual`：巨噬【吞噬】吸血只认主笔 —— 直击带 NO_LIFESTEAL）。</param>
    public static WorldState Damage(WorldState s, EntityId id, int amount, LossSource source, string ability, int direct, out int dealt, out int mainDealt)
    {
        var c = s.Cells[id];
        // ③④ 倍率层。**所有倍率合成一次整数除法**（Settlement.ApplyEnergyLoss，逐位对齐 cw_damage.gd:218-223）
        var multipliers = new List<ValueModifier>();
        if (c.Type == CellType.Osteosarcoma && RulePolicies.TypeAbilityOn(s, c) && s.Board.Tissues[c.Position].State == TissueState.SolidifiedCancer)
            multipliers.Add(new ValueModifier(ModifierStage.Multiply, SourceLayer.Passive, 0, 40));  // 【刚性屏障】×40%，不限来源

        // 树突【I-标记】：被标记的癌细胞下一次受到**免疫细胞造成的**能量损失时 ×2，随后移除一层标记（PRD:573）。
        // **只认免疫来源**（Kevin 2026-09-15 拍板；GD cw_damage.gd:194 判 `Tag.IMMUNE in tags`）。
        // ON_BENEFIT：只有确实有伤害可翻倍时才消耗（`amount > 0`）；MarkLeft 可能 >1（【抗原呈递强化】给 2 层），耗尽才清 Marked。
        // 同批两笔（主笔 + 直击）GD 是**先算后扣**（`_submit_batch`：逐条 _plan 再逐条 _apply）：两笔读到的都是批前的 marked，各自 ×2、各扣一层。
        var immune = source is LossSource.ImmuneAttack or LossSource.ImmuneEffect;
        var markApplies = c.Marked && amount > 0 && immune;
        var markDirect = c.Marked && direct > 0 && immune;
        var withMark = multipliers.Append(new ValueModifier(ModifierStage.Multiply, SourceLayer.Skill, 0, 200)).ToList();
        amount = Settlement.ApplyEnergyLoss(amount, markApplies ? withMark : multipliers);
        var directCalc = direct > 0 ? Settlement.ApplyEnergyLoss(direct, markDirect ? withMark : multipliers) : 0;
        foreach (var _ in Enumerable.Range(0, (markApplies ? 1 : 0) + (markDirect ? 1 : 0)))
        {
            var marked = s.Cells[id];
            var left = marked.MarkLeft - 1;   // GD `_consume` "mark"：mark_left -= 1，≤ 0 就摘（可以扣成负数，L1 视图逐位比）
            s = s.UpdateCell(id, marked.Copy(markLeft: left, marked: left > 0));
        }

        // ⑤ 固定减免 —— 逐位对齐 GD `_reduce` / `_shield_groups`（cw_damage.gd:232-291）：
        //   · 护盾按**组**：同名条目合并成一组，减免 = 单值 × 条数（定案 #57：两张「下一次 −1.5」= 这一次减 3.0）；
        //   · 组间按打出先后（【囊性护甲】最先、【耗竭抵抗】最后）；
        //   · 每组 ON_BENEFIT：这一组没把伤害压低就不消耗；已经挡光了就停，后面的盾留着；
        //   · 各盾只认自己的来源（<see cref="ShieldApplies"/>）—— 此前 C# 对目标身上全部 EnergyLoss 修饰一律套用、一律消耗，
        //     2p 第 52 步【突变】的自损把只挡免疫方的【DNA损伤修复】吃掉了（2026-09-17）。
        //   · 直击那一笔 UNPREVENTABLE：整层跳过（GD cw_damage.gd `_calculate` 末尾的 `return maxi(dmg, 0)`），不减也不消耗
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
        var total = amount + directCalc;
        // 【BCL-2抗凋亡】：即将受到致命能量损失时免疫该次损失，能量改为 0.5/0.8/1。GD `_bcl2_pass` 按**整批合计**判（`energy - total <= 0` 且 total > 0），
        // 免掉的是整批（两笔都清零，`actual` 归 0 → 记忆、斩杀、吸血一律落空）
        if (total > 0 && total >= c.Energy && HasModifier(c, "BCL-2抗凋亡"))
        {
            var survive = RulePolicies.CancerPhase(s.Turn.WorldRound) switch { 0 => 5, 1 => 8, _ => 10 };
            s = s.UpdateCell(id, c.Copy(energy: survive));
            dealt = 0; mainDealt = 0;
            Stage.Emit(Stage.Fx(s, "card_survive", ("at", c.Position)));   // GD cw_damage.gd:485：散开再回拢（免死不是复活，人还在原格）
            return RemoveModifiers(s, id, "BCL-2抗凋亡");
        }
        dealt = Math.Min(total, Math.Max(c.Energy, 0));
        mainDealt = Math.Min(amount, Math.Max(c.Energy, 0));   // GD `_apply` 逐条：主笔先落地，actual = min(calculated, 落地前能量)
        var energy = Math.Max(0, c.Energy - total);
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

    /// <summary>GD `spend_one_mod`：同名里只扣**最早打出**（seq 最小）的那一条，耗尽才移除（【PD-L1表达】多层时一次攻击只吃一层）。</summary>
    internal static WorldState SpendOneModifier(WorldState s, EntityId id, string card)
    {
        var c = s.Cells[id];
        var pick = c.Modifiers.Where(m => m.Card == card).OrderBy(m => m.Sequence).FirstOrDefault();
        if (pick is null) return s;
        var used = pick.Consume();
        var kept = c.Modifiers.Select(m => ReferenceEquals(m, pick) ? used : m).Where(m => !m.Expired).ToList();
        return s.UpdateCell(id, c.Copy(modifiers: kept));
    }

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

    /// <summary>I/II/III/X 的抗原记忆门槛 = GD `CWData.LEVEL_MIN_MEMORY`（**六人档兼缺省**）与
    /// `LEVEL_MIN_MEMORY_BY_PLAYERS`（四人档），下标 0/1/2/3 = I/II/III/X，常量不是旋钮。
    /// 分档的理由见 GD 原注：记忆是全阵营共用一个计数器，而进账靠免疫细胞各自净化 ——
    /// 四人局只有 2 个免疫、六人局有 3 个，同样门槛下四人局要多花约一半回合才升得上去。
    /// **2 人局沿用缺省（六人）那张**，GD 注释明写「这不是待办」。</summary>
    /// **2026-09-19 issue #55**：X 级门槛四人 50→100、六人 70→120，II / III 两档不动。
    internal static readonly IReadOnlyList<int> LevelMinMemory = [0, 10, 30, 120];
    internal static readonly IReadOnlyDictionary<int, IReadOnlyList<int>> LevelMinMemoryByPlayers =
        new Dictionary<int, IReadOnlyList<int>> { [4] = [0, 10, 20, 100] };

    /// <summary>GD `cw_game.gd:gain_memory`（门槛那一段）。**门槛按人数分档**：
    /// `CWData.level_min_memory(order.size())` = 四人 `[0,10,20,50]` / 其余（含 2 人与 balance_scan 的 5、7 人）`[0,10,30,70]`。
    ///
    /// 2026-09-19 合（Kevin §十五 Q1：规则结果差）：此前 C# 行内写死 `Count==6 ? 70/30 : 50/20` ——
    /// 4 人 / 6 人对得上，**2 人局分叉**（GD 走缺省的六人档 30/70，C# 给 20/50），而 L0 绝大多数盘面是 2 席。
    /// COVERAGE 空档 immune-level-threshold-table 就此收。**签名不变**。
    ///
    /// 升级那一句 GD 写的是 `while lv &lt; 3 and memory &gt;= tiers[lv+1]`，从当前等级往上一级级走；
    /// 门槛表升序 ⇒ 等价于「满足门槛的最高一级、且不低于当前等级」，就是下面这两行。
    /// **X 级就地清零**：PRD「抗原记忆升级为【效应记忆】重新从零计数」，只在**这一次升**到 X 时清。</summary>
    public static WorldState AddMemory(WorldState s, int amount)
    {
        var tiers = LevelMinMemoryByPlayers.TryGetValue(s.Players.Count, out var byPlayers) ? byPlayers : LevelMinMemory;
        foreach (var p in s.Players.Values.Where(p => p.Faction == Faction.Immune).OrderBy(p => p.Seat))
        {
            var memory = p.AntigenMemory + amount;
            var level = memory >= tiers[3] ? ImmuneLevel.X :
                memory >= tiers[2] ? ImmuneLevel.III : memory >= tiers[1] ? ImmuneLevel.II : ImmuneLevel.I;
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
        {
            var appliedMods = RulePolicies.AppliedMoveModifiers(s, c, dest, rawCostOverride);
            applied = appliedMods.Select(m => (m.Name, m.Sequence)).ToHashSet();
            // 永久技能的闸门额度（GD Store.GATE → `usage_marks` → `first_this_turn`）：不是 mods 条目，烧的是 fx_turn（同一次报价一个名字只烧一次）
            foreach (var name in appliedMods.Where(RulePolicies.IsGateMoveModifier).Select(m => m.Name).Distinct().ToArray())
                s = BurnTurnGate(s, id, name);
            c = s.Cells[id];
        }
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

    /// <summary>【细胞毒性增强】攻击成功的额外 1.0（GD `CWData.CYTOTOX_EXTRA`）。</summary>
    internal const int CytotoxExtra = 10;

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
    /// 「这个细胞此刻走不走得到那一格」的具名谓词（规格 §0.6.7 的具名入口之一），
    /// 逐条对 GD `cw_actions.gd:_is_move_legal_now(cell, to)`（392-419）的每一个分支：
    ///
    /// <list type="number">
    /// <item>存活 + 在棋盘上（GD `cell["alive"]` / `game.is_on_board`；C# 的「在棋盘上」就是这一格有组织，
    ///       与 <see cref="RulePolicies.QuoteMove"/> 同一道闸）；</item>
    /// <item>不与自己相邻 ⇒ 只能是**借道前进**：借不到（GD `pass_through_mid(cell, to) == Vector2i.MAX`）不合法；
    ///       借得到则落点必须**完全空着** —— 不能停在人身上，也不允许穿过去发起攻击。
    ///       `to` 正是自己脚下那格也落在这一支：GD 的 `pass_through_mid` 与
    ///       <see cref="RulePolicies.PassThroughMid"/> 对原地都给「借不到」，两边同为不合法；</item>
    /// <item>相邻那五条（癌方一格一细胞 / 免疫踩免疫 / 免疫走空格 / 树突【I-各司其职】/
    ///       每行动回合攻击次数上限）就是 <see cref="CommitLegal"/> 一字不差的那一份 —— 共用它，不抄第二遍。</item>
    /// </list>
    ///
    /// **纯查询，不改任何现有调用路径**：<see cref="ValidateMove"/> 与【炎症性趋化】的提交复验
    /// 今天各走各的（`QuoteMove` + <see cref="AttackCapReached"/> / <see cref="CommitLegal"/>），这一步一行没动。
    ///
    /// 一处口径差登记在这里：GD `cells_at()` 只数**存活**细胞，C# 的占位是 `Tissue.OccupyingCell`、
    /// 而 <see cref="Kill"/> 当场就把占位清掉 —— 正常状态下两边同义。真出现「死细胞还占着格」的坏状态时，
    /// 借道那一支按存活判（同 GD），相邻那一支跟 <see cref="CommitLegal"/> 的既有行为走，不在这一步改。
    /// </summary>
    internal static bool MoveLegal(WorldState s, Cell cell, HexPosition to)
    {
        if (!cell.IsAlive || !s.Board.Tissues.ContainsKey(to)) return false;
        if (!RulePolicies.GdNeighbors(s, cell.Position).Contains(to))
            // 后半句照抄 GD 的那一句：两边的借道表（`pass_through_map` / <see cref="RulePolicies.PassThroughRoutes"/>）
            // **本来就只收空落点**，所以它今天一次也不会真的拦下什么。留着是为了与 GD 逐句对得上 ——
            // 那张表的口径要是哪天松了，这一句就是最后一道闸。
            return RulePolicies.PassThroughMid(s, cell, to) is not null && s.GetCellAt(to) is not { IsAlive: true };
        return CommitLegal(s, cell, to);
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
            if (s.Turn.PendingChainCell is not null && !ChainDeferred(s)) return s;   // 连锁先排干，它在 GD 里嵌在这一步内部（压在这条走位底下的除外）
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
        Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, "连续吞噬", d.Target));   // GD cw_actions.gd:1708：扑之前报（挪完起点就取不到了）
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
        s = s.UpdateCell(id, c.Copy(position: dest));
        return Arrive(s, id, dest, paid: -1, rng, c.Position);
    }

    /// <summary>脚已经放到格上（位置与占位由调用方写好）之后的整条 `enter_tile`：定殖 / 蹲守 / 净化 → 黏液 → collect_special → 标记。
    /// 复活落地（GD `revive_*`）与血管传送（GD `_vessel_teleport`）用它 —— 它们不能走 Teleport 的占位交接。</summary>
    internal static WorldState ArriveAndLand(WorldState s, EntityId id, HexPosition dest, IDeterministicRng rng, HexPosition? from = null)
    {
        var depth = WalkDepth(s);
        return LandOrDefer(Arrive(s, id, dest, paid: -1, rng, from), id, dest, depth, rng);
    }

    /// <summary>GD `enter_tile` 的三条分支（cw_actions.gd:1009-1026）：癌进健康 → 【定殖】（`to_cancer(t, true)`：solid / necrosis / ossify 一起清、newborn=true）；
    /// 免疫进骨样硬化标记格 → 登记蹲守、不净化；免疫进癌组织 → <see cref="PurifyHere"/>。Move 与 Teleport 共用这一份 ——
    /// 此前两条路各写一遍裸 `UpdateTissueState`：定殖不清坏死，传送落到标记格也当场净化、还没有净化连锁（2026-09-17 晚）。</summary>
    /// <param name="from">来路（GD enter_tile 的 `from = cell["pos"]`）：【定殖】过场要说癌从哪一侧来；复活那种原地落地没有来路，不演。</param>
    private static WorldState Arrive(WorldState s, EntityId id, HexPosition dest, int paid, IDeterministicRng rng, HexPosition? from = null)
    {
        var c = s.Cells[id];
        // GD enter_tile 1006-1008：挪了窝，上一格的「蹲守」就作废 —— 只清免疫、只在落点不是蹲守格时清（此前 C# 在 Move / Teleport 里无条件清）
        if (c.Faction == Faction.Immune && c.CampRound >= 0 && c.CampPosition != dest)
        {
            s = s.UpdateCell(id, c.Copy(campRound: -1));
            c = s.Cells[id];
        }
        var tile = s.Board.Tissues[dest];
        if (c.Faction == Faction.Cancer && tile.State == TissueState.Healthy)
        {
            // GD enter_tile:1016：过场方向 = 这一步的前进方向（来路那一侧）；原地不动没有方向，不演
            if (from is { } origin && Stage.DirToward(dest, origin) is var dir && dir >= 0)
                Stage.Emit(new TissueConverted(s.Turn.WorldRound, s.Turn.Phase, dest, dir, "定殖"));
            return CardRules.ToCancer(s, dest, newborn: true);
        }
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
        var walkDepthBefore = WalkDepth(s);   // 记忆库抽到连走卡会压一层：那条走位在 GD 里嵌在 draw() 内部、排在连锁之前
        s = FactRouter.Emit(s, new PurifyResolvedFact(s.Turn.WorldRound, id), rng);
        // 巨噬【连续吞噬】：净化之后**当场**接着走（PRD:605）。GD 是 await 循环 + `chain_running` 再入闸；
        // 这里每一跳是一个独立决策，所以挂起等玩家选就行，不需要那道闸。
        if (chain && s.Cells[id].Type == CellType.Macrophage && s.Cells[id].ChainLeft > 0 && ChainTargets(s, s.Cells[id]).Count > 0)
            s = s.WithTurn(s.Turn.WithPendingChain(id, walkDepthBefore));
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
    {
        var depth = WalkDepth(s);
        return LandOrDefer(Teleport(s, id, dest, rng), id, dest, depth, rng);
    }

    /// <summary>`enter_tile` 的后半截（脚已经放到格上之后）：免疫踩黏液即清 → `collect_special` → 刷新标记。
    /// 复活也走这一截（GD `revive_*` 同样 `enter_tile`）—— 但复活不能走 Teleport：死亡格早就交出了占位，别人可能已经站上去。</summary>
    public static WorldState Land(WorldState s, EntityId id, IDeterministicRng rng) => LandTail(s, id, s.Cells[id].Position, WalkDepth(s), rng);

    /// <summary>`enter_tile` 的后半截，在 <paramref name="at"/> 那一格做：免疫踩黏液即清 → `collect_special(cell, dest)` → `update_marks`。
    /// 连锁把细胞挪走了也仍在 dest 收取（GD cw_actions.gd:1031 显式传 dest）。</summary>
    internal static WorldState LandTail(WorldState s, EntityId id, HexPosition at, int walkDepthBefore, IDeterministicRng rng)
    {
        var c = s.Cells[id];
        var t = s.Board.Tissues[at];
        if (c.Faction == Faction.Immune && t.Mucus)
            s = s.WithBoard(s.Board.UpdateTissue(at, t.WithMucus(false)));
        s = CollectSpecialAt(s, id, at, rng);
        // 骨髓那一抽追出了问答、或抽到【骨髓动员】的收取循环挂起了：GD 的 `await collect_special` 还没回来，update_marks 要等它 —— 记成第 1 步，
        // 出口补做时只刷标记、**不重收**（GD 的 enter_tile 尾巴只跑一次；重收会把【骨髓动员】刚给脚下格存的那张提前抽走）
        if (LandBlocked(s, walkDepthBefore) || (s.Turn.PendingMarrow.Count > 0 && s.Turn.PendingMarrowWalkDepth >= walkDepthBefore))
            return s.WithTurn(s.Turn.WithPendingLand(id, at, walkDepthBefore, step: 1));
        return UpdateMarks(s);
    }

    /// <summary>连走栈有多深（0 = 没在走）：判断「这次落地追出来的连走」走完了没有。</summary>
    internal static int WalkDepth(WorldState s) => s.Turn.PendingChemotaxisCell is null ? 0 : 1 + s.Turn.WalkOuter.Count;

    /// <summary>连锁挂起之后又压上了一层走位（净化抽到【趋化募集】/【效应细胞浸润】）：GD 那条走位嵌在 draw() 里，先走完才回到连锁循环问下一跳。</summary>
    internal static bool ChainDeferred(WorldState s) => s.Turn.PendingChainCell is not null && WalkDepth(s) > s.Turn.PendingChainWalkDepth;

    /// <summary>走位弹掉之后连锁露出来，但已经没有下一跳（或跳数用完 / 细胞死了）：GD 的 while 循环当场退出，没有「不连了」那一问。</summary>
    internal static WorldState NormalizeChain(WorldState s)
    {
        if (s.Turn.PendingChainCell is not { } id || ChainDeferred(s)) return s;
        var c = s.Cells[id];
        return c.IsAlive && c.ChainLeft > 0 && ChainTargets(s, c).Count > 0 ? s : s.WithTurn(s.Turn.WithPendingChain(null));
    }

    /// <summary>定殖 / 净化追出来的问答还没问完（GD 那是 `enter_tile` 里一段 await）：弃置 / 连锁 / 二选一 / 风暴选中心，或者连走栈比落地前更深。</summary>
    internal static bool LandBlocked(WorldState s, int walkDepthBefore)
        => s.Turn.PendingDiscardSeat is not null || s.Turn.PendingChainCell is not null || s.Turn.PendingMutationSeat is not null
           || s.Turn.PendingPickCellSeat is not null   // 骨髓 / 记忆库那一抽抽到风暴：GD 先把中心问完才回到 enter_tile 的后半截
           || WalkDepth(s) > walkDepthBefore;

    /// <summary>落地：定殖 / 净化没追出问答就当场做完后半截；追出来了就推迟（记 PendingLand），等 DecisionRouter 的出口把问答摘干净再补做。
    /// 此前 C# 一律当场做完：净化抽到的卡撑爆手牌时骨髓那张也一起抽进手（第一次弃置比 GD 多摊一张）、连锁问在骨髓抽卡之后（抽牌的等级与带子位次都不同）。</summary>
    internal static WorldState LandOrDefer(WorldState s, EntityId id, HexPosition at, int walkDepthBefore, IDeterministicRng rng)
        => LandBlocked(s, walkDepthBefore)
            ? s.WithTurn(s.Turn.WithPendingLand(id, at, walkDepthBefore))
            : LandTail(s, id, at, walkDepthBefore, rng);

    /// <summary>出口：推迟的后半截能补做了吗（弃置 / 连锁 / 二选一都摘干净、连走栈回到落地前的深度）。</summary>
    internal static bool LandReady(WorldState s)
        => s.Turn.PendingLandCell is not null && !LandBlocked(s, s.Turn.PendingLandWalkDepth)
           && !(s.Turn.PendingMarrow.Count > 0 && s.Turn.PendingMarrowWalkDepth >= s.Turn.PendingLandWalkDepth);   // 这次落地追出的骨髓循环嵌在 collect_special 里，先收完

    internal static WorldState ResumeLand(WorldState s, IDeterministicRng rng)
    {
        var id = s.Turn.PendingLandCell!.Value;
        var at = s.Turn.PendingLandAt!.Value;
        var depth = s.Turn.PendingLandWalkDepth;
        var step = s.Turn.PendingLandStep;
        s = s.WithTurn(s.Turn.WithPendingLand(null, null, 0));
        if (step == 1) return UpdateMarks(s);   // collect_special 早做过了，只欠 update_marks
        if (!s.Cells[id].IsAlive) return s;   // 连锁途中死了：GD 的 collect_special 也不会给死细胞发卡（cells_at 只数活的）
        return LandTail(s, id, at, depth, rng);
    }

    /// <summary>GD `collect_special`（cw_actions.gd:1096-1107）：代谢核心有存储就收能量并清库存，
    /// **否则**（if / elif，不是两件都做）骨髓有卡就清库存并抽一张 —— 那一抽是带子上的一发，**不判阵营**。</summary>
    public static WorldState CollectSpecial(WorldState s, EntityId id, IDeterministicRng rng) => CollectSpecialAt(s, id, s.Cells[id].Position, rng);

    /// <summary>在指定的格上收取（GD `collect_special(cell, dest)` 的 dest 不一定是细胞此刻站的格：连锁跳走之后仍回来收落地那一格）。</summary>
    public static WorldState CollectSpecialAt(WorldState s, EntityId id, HexPosition at, IDeterministicRng rng)
    {
        var t = s.Board.Tissues[at];
        if (t.Type == TissueType.MetabolicCore && t.Charge > 0)
        {
            var c = s.Cells[id];
            s = s.UpdateCell(id, c.WithEnergy(c.Energy + t.Charge.Value));
            return s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithCharge(0)));
        }
        if (t.Type == TissueType.BoneMarrow && t.Charge > 0)
        {
            s = s.WithBoard(s.Board.UpdateTissue(t.Position, t.WithCharge(0)));
            return CardRules.DrawOne(s, s.Cells[id], rng, "骨髓");
        }
        return s;
    }

    /// <summary>
    /// GD `_marrow_mobilization` 的 await 循环（GD 侧 2026-09-18 补上了漏掉的 await，协议 v29）：按 CWData.MARROWS 的序逐格
    /// 「判健康空仓 → 存 1 张 → 站着的细胞当场收（抽卡）」，**判据在走到那一格时现读**（上一格的抽卡可能改了盘面：套娃的【骨髓动员】、
    /// 【全身性免疫清除】翻面）。一次抽卡追出了问答（弃置 / 二选一 / 连锁，或抽到连走卡把栈压深）就停在**下一格之前**，
    /// 还没判的骨髓挂到 <see cref="TurnState.PendingMarrow"/>，DecisionRouter 出口答完再 <see cref="ResumeMarrow"/> 从那一格接着现判。
    /// 进循环时已经挂着的外层连走不算打断（骨髓循环嵌在那一步的 collect_special 里），所以只看栈有没有**比进来时更深**。
    /// 套娃（抽到的又是【骨髓动员】）时内层先收：内层挂起的排在前面。
    /// </summary>
    internal static WorldState CollectMarrows(WorldState s, IReadOnlyList<HexPosition> marrows, IDeterministicRng rng)
    {
        var depthBefore = WalkDepth(s);
        var i = 0;
        for (; i < marrows.Count; i++)
        {
            if (LandBlocked(s, depthBefore)) break;   // 上一格的抽卡追出了问答：这一格还没判，留给续收
            var m = marrows[i];
            if (!s.Board.Tissues.TryGetValue(m, out var t) || t.Type != TissueType.BoneMarrow || t.State != TissueState.Healthy || (t.Charge ?? 0) > 0) continue;
            s = s.WithBoard(s.Board.UpdateTissue(m, t.WithCharge(RulePolicies.BoneMarrowStoreMax)));
            if (s.GetCellAt(m) is { IsAlive: true } standing) s = CollectSpecialAt(s, standing.Id, m, rng);
        }
        if (i >= marrows.Count) return s;
        var rest = marrows.Skip(i).ToArray();
        var depth = s.Turn.PendingMarrow.Count > 0 ? s.Turn.PendingMarrowWalkDepth : depthBefore;
        return s.WithTurn(s.Turn.WithPendingMarrow([.. s.Turn.PendingMarrow, .. rest], depth));
    }

    /// <summary>出口：挂起的骨髓循环能接着收了吗（弃置 / 连锁 / 二选一都摘干净、连走栈回到挂起时的深度）。</summary>
    internal static bool MarrowReady(WorldState s)
        => s.Turn.PendingMarrow.Count > 0 && !LandBlocked(s, s.Turn.PendingMarrowWalkDepth);

    /// <summary>挂起的问答答完了：从还没判的那一格接着现判、存、收。</summary>
    internal static WorldState ResumeMarrow(WorldState s, IDeterministicRng rng)
    {
        var rest = s.Turn.PendingMarrow;
        return CollectMarrows(s.WithTurn(s.Turn.WithPendingMarrow(Array.Empty<HexPosition>(), 0)), rest, rng);
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
                fxRound: []));   // GD `_reset_round_flags` 不碰 mods：「本世界回合」修饰在 E 阶段第 8 步清（ExpireRoundModifiers）
        return s;
    }

    /// <summary>GD `CWWorldFx.tick_durations` 末尾 `clear_mods(cell, "round")`：「本世界回合」修饰在 **E 阶段第 8 步**过期 ——
    /// 此前 C# 放在下一个 S 阶段的 ResetRoundFlags，终局那一回合没有下一个 S，批扫 2p_1006 / 2p_1011 的终局视图里 C# 多一条【I型干扰素】（2026-09-18）。</summary>
    public static WorldState ExpireRoundModifiers(WorldState s)
    {
        foreach (var c in RulePolicies.Cells(s).Where(c => c.Modifiers.Any(m => m.Duration == ModifierDuration.Round)))
            s = s.UpdateCell(c.Id, c.Copy(modifiers: c.Modifiers.Where(m => m.Duration != ModifierDuration.Round).ToList()));
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
    /// <summary>GD `CWCost.GATE_USES`：【组织驻留】前两次向健康组织的迁移免费，其余闸门都是「每行动回合首次」。</summary>
    private static int GateUses(string key) => key == "组织驻留" ? 2 : 1;

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
        var attackHit = false;
        if (target != null)
        {
            if (cell.Type == CellType.Macrophage) Stage.Emit(Stage.Fx(s, "chomp", ("from", cell.Position), ("to", move.TargetPosition), ("cid", cell.Id)));   // GD cw_actions.gd:795：巨噬扑咬先演
            // GD cw_actions.gd:801-807：计数在**发动**时加（口径 #70），用掉最后一次就报一声「攻击次数已用尽」（口径 #93），否则攻击选项无声消失
            if (s.Tuning.AttackMaxPerTurn > 0 && cell.AttacksThisTurn + 1 >= s.Tuning.AttackMaxPerTurn)
                Stage.Announce(s, $"攻击次数已用尽（{cell.AttacksThisTurn + 1}/{s.Tuning.AttackMaxPerTurn}）", move.TargetPosition, true);
            var rerolled = false;
            // 六面骰，**1..6**。原来写的是 NextInt(6)，那产出 0..5 —— 而 AttackOutcome 判
            // `roll == 6` 为暴击，于是暴击永远掷不出来（实测 60000 次 crit 0%，应为 16.7%）。
            // 用 NextIntRange(1, 7)（半开）而不是 NextInt(6) + 1：把「1..6」写进代码里，
            // 下一个人不用去推。PRD 只给概率不给面数，骰面值域由 Kevin 2026-09-15 裁定为 6 面。
            var attackerCell = s.Cells[cell.Id];
            var attackMods = attackerCell.Modifiers.Where(m => m.Target == ModifierTarget.Attack).ToList();
            var attackExtra = attackMods.Sum(m => m.Value);
            var hasOpsonin = attackMods.Any(m => m.Card == "补体调理");
            var hasAffinity = attackMods.Any(m => m.Card == "高亲和力克隆");
            // GD cw_actions.gd:815-816：【补体调理】【高亲和力克隆】**判定前**无条件扣（「无论结果如何，这次攻击就把它们消耗掉」）；
            // 【穿孔素-颗粒酶】【补体级联】在**成功分支**里才扣（868 / 921）—— 攻击无效一次，它们还留着给下一次。此前 C# 判定前一律扣光
            var cascadeCount = attackMods.Count(m => m.Card == "补体级联");
            s = SpendModifiers(s, cell.Id, "补体调理");
            s = SpendModifiers(s, cell.Id, "高亲和力克隆");
            // 【高亲和力克隆】不进行随机判定、直接大成功（GD cw_actions.gd:826-829 **不掷骰**）—— 此前 C# 无条件先掷再判，多消耗一发 rng（步 6 接演出时发现，2026-09-18）
            var roll = hasAffinity ? 0 : rng.NextIntRange(1, 7);
            if (!hasAffinity) Stage.Emit(new DiceRolled(s.Turn.WorldRound, s.Turn.Phase, "攻击", roll, 6, cell.OwnerSeat, move.TargetPosition));   // GD roll_shown(6, "攻击", pid, to)
            var outcome = hasAffinity ? "crit" : RulePolicies.AttackOutcome(s, roll, attackerCell);
            if (outcome == "fail" && hasOpsonin)
            {
                roll = rng.NextIntRange(1, 7);   // 【补体调理】的重掷，同样是 1..6
                rerolled = true;
                Stage.Emit(new DiceRolled(s.Turn.WorldRound, s.Turn.Phase, "攻击", roll, 6, cell.OwnerSeat, move.TargetPosition));
                outcome = RulePolicies.AttackOutcome(s, roll, s.Cells[cell.Id]);
            }
            if (HasModifier(s.Cells[target.Id], "PD-L1表达"))
            {
                outcome = outcome == "crit" ? "success" : "fail";  // 大成功→成功、成功/无效→无效
                s = SpendOneModifier(s, target.Id, "PD-L1表达");   // GD `spend_one_mod`：一次攻击只吃**最早打出的一层**（团队 2026-09-01 裁定，刻意不走定案 #57）；此前 C# 全摘
            }
            var damage = outcome == "fail" ? 0 : outcome == "crit" ? 20 : s.Tuning.AttackDmgSuccess;   // GD cw_actions.gd:863 `tune.attack_dmg_crit if crit else tune.attack_dmg_success`：成功那一档改读旋钮；大成功那一档（GD 旋钮 attack_dmg_crit）不在这 12 个里，仍是字面量 20
            attackHit = outcome != "fail";
            Stage.Emit(new ResultAnnounced(s.Turn.WorldRound, s.Turn.Phase, outcome == "fail" ? "攻击无效" : outcome == "crit" ? "攻击大成功" : "攻击成功", move.TargetPosition));   // GD cw_actions.gd:850/864
            var dealtTotal = 0;
            var extra = 0;
            var cytotoxDirect = 0;
            if (outcome != "fail")
            {
                extra = attackExtra;
                if (attackMods.Any(m => m.Card == "穿孔素-颗粒酶")) Stage.Emit(Stage.Fx(s, "card_granule", ("from", cell.Position), ("to", target.Position)));   // GD cw_actions.gd:873：颗粒注入
                s = SpendModifiers(s, cell.Id, "穿孔素-颗粒酶");
                s = SpendModifiers(s, cell.Id, "补体级联");
                // 【连续吞噬】连续净化攒的加成：**用掉即清**，不按回合过期
                var chain = s.Cells[cell.Id].ChainBonus;
                if (chain > 0)
                {
                    extra += chain;
                    s = s.UpdateCell(cell.Id, s.Cells[cell.Id].Copy(chainBonus: 0));
                }
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "抗体亲和力成熟") && RulePolicies.AdjacentHealthy(s, move.TargetPosition)) extra += 5;
                // 【细胞毒性增强】（GD cw_actions.gd:878-883，攻击当刻现读、过【中和抗体】）：T 细胞每次攻击成功都追加一笔 1.0 的**直击**（同批第二笔，
                // Tag.DIRECT + UNPREVENTABLE + NO_LIFESTEAL：走倍率、跳过第 ⑤ 层减免、不给巨噬吸血、不动闸门）；非 T 每行动回合**首次攻击成功** +1.0 进主笔的固定加成，
                // 闸门 `first_this_turn` 只在成功分支烧（攻击无效一次，加成还留着给本回合下一次）。
                // 此前 C# 是 BeginTurn 发一条 Uses=1 的攻击修饰：判定前就被消耗、T 细胞一回合只吃一次、还在 L1 视图的 mods 里凭空多一条（2026-09-17 深夜）
                if (RulePolicies.HasSkill(s, s.Cells[cell.Id], "细胞毒性增强"))
                {
                    if (s.Cells[cell.Id].Type == CellType.TCell) cytotoxDirect = CytotoxExtra;
                    else
                    {
                        var firstCytotox = TurnGateOpen(s.Cells[cell.Id], "细胞毒性增强");
                        s = BurnTurnGate(s, cell.Id, "细胞毒性增强");
                        if (firstCytotox) extra += CytotoxExtra;
                    }
                }
            }
            attacker = s.Cells[cell.Id].Copy(attacks: s.Cells[cell.Id].AttacksThisTurn + 1);
            s = s.UpdateCell(cell.Id, attacker);
            // 攻击无效的反弹：GD cw_actions.gd:857-858 `if tune.counter_dmg_on_fail > 0: cancer_hit(cell, counter_dmg_on_fail, "反弹")`（Kind.WORLD：【缺氧适应】挡不住，口径 #62）。此前 C# 写死 0.5、不读旋钮
            if (damage == 0 && s.Tuning.CounterDamageOnFail > 0) s = Damage(s, cell.Id, s.Tuning.CounterDamageOnFail, LossSource.World, "反弹");
            else
            {
                s = Damage(s, target.Id, damage + extra, LossSource.ImmuneAttack, "攻击", cytotoxDirect, out var dealt, out var mainDealt);
                dealtTotal = dealt;
                // PRD【迁移】「累积与造成伤害的绝对值向下取整的抗原记忆」：GD cw_actions.gd:913-917 按这一批的 **actual 之和**（过完倍率与护盾、含直击、不超过目标余量），
                // `dealt >= 10` 才 gain_memory。此前 C# 用 min(目标能量, 裸基础伤害)：不含固定加成、不含【标记】×2、不扣护盾减免（2026-09-17 深夜）
                if (dealt >= 10) s = AddMemory(s, dealt / 10);
                // 【吞噬体成熟】：攻击成功后目标余量不超过阈值则直接死亡
                var threshold = s.Cells[cell.Id].Type == CellType.Macrophage ? 15 : 5;
                // GD `_queue_execution`：这一批对它**确实造成了伤害**（actual 合计 > 0）才入队 —— 被【BCL-2抗凋亡】整批免掉的不算
                if (dealt > 0 && RulePolicies.HasSkill(s, s.Cells[cell.Id], "吞噬体成熟") && s.Cells[target.Id].IsAlive && s.Cells[target.Id].Energy <= threshold)
                {
                    // GD `lethal(target, "吞噬体成熟")`：处决**不进伤害管线**（护盾减不了、【BCL-2抗凋亡】救不回，口径 #68），直接 kill + update_marks
                    s = UpdateMarks(Kill(s, target.Id));
                    if (s.Cells[cell.Id].Type == CellType.Macrophage)
                        s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + 5));
                }
                // 【补体级联】：攻击成功后转化目标相邻最多 2 格无细胞占据的普通癌组织 —— GD `for i in spend_mods(cell, "补体级联"): _cascade(cell, target)`：
                // 打了几张就跑几遍，候选按 DIRS 序（pick_n 抽的是下标），每遍现算候选、转健康走 to_healthy
                for (var i = 0; i < cascadeCount; i++)
                {
                    var cascade = RulePolicies.GdNeighbors(s, target.Position)
                        .Where(n => s.Board.Tissues[n].State == TissueState.Cancer && s.Board.Tissues[n].OccupyingCell == null)
                        .ToArray();
                    var picks = rng.PickRandom(cascade, 2).ToArray();
                    if (picks.Length > 0) Stage.Emit(Stage.Fx(s, "card_cascade", ("from", s.Cells[cell.Id].Position), ("to", target.Position), ("tiles", picks)));   // GD cw_actions.gd:990：命中连锁
                    foreach (var pick in picks) s = CardRules.ToHealthy(s, pick);
                }
                // 【I-吞噬】：攻击成功造成能量损失后恢复受击方损失的 1/2（向上取整到十分位）
                if (s.Cells[cell.Id].Type == CellType.Macrophage)
                {
                    // GD cw_damage.gd:568 `ceil(actual / 2.0)`：按主笔**实际失去**（过完倍率与护盾），直击那笔 NO_LIFESTEAL 不算。此前 C# 用未过管线的理论值
                    var heal = (mainDealt + 1) / 2;
                    if (heal > 0) s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithEnergy(s.Cells[cell.Id].Energy + heal));
                }
            }
            // 【抗原呈递强化】（GD cw_actions.gd:928-935）：每世界回合第一次攻击**未被标记**的癌细胞后施加【标记】。「攻击…后」按攻击发动读（口径 #70）：
            // 判定无效也算攻过、打死了额度也烧；目标还活着才 apply_mark。此前 C# 攻击路径整条没有它（复核 2026-09-18）
            if (s.Cells[cell.Id].IsAlive && RulePolicies.HasSkill(s, s.Cells[cell.Id], "抗原呈递强化") && !target.Marked && RoundGateOpen(s.Cells[cell.Id], "抗原呈递强化"))
            {
                s = BurnRoundGate(s, cell.Id, "抗原呈递强化");
                if (s.Cells[target.Id].IsAlive) s = ApplyMark(s, target.Id, s.Cells[cell.Id]);
            }
            Stage.Emit(new AttackResolved(s.Turn.WorldRound, s.Turn.Phase, cell.Id, target.Id, roll, rerolled, outcome, dealtTotal, attackHit && dealtTotal == 0, !s.Cells[target.Id].IsAlive));
            events.Add(new CellAttackedEvent(s.Turn.WorldRound, s.Turn.Phase, cell.Id, target.Id, damage, !s.Cells[target.Id].IsAlive));
            if (s.Cells[target.Id].IsAlive || !s.Cells[cell.Id].IsAlive)
            {
                s = UpdateMarks(s);
                EmitImmuneAttackFx(s, cell, target, move.TargetPosition, attackHit);   // 返回原格 / 攻击者死了：GD 在 enter_tile 的 else 之后照样演
                return new(s, events, true);
            }
        }
        // 癌种被动的移动演出（GD cw_actions.gd:760-772，enter_tile 之前）：黑色素瘤走折后价 = 邻格的伪足在拉；小细胞肺癌进健康格 = 细线疾行
        if (cell.Faction == Faction.Cancer && s.Board.Tissues[move.TargetPosition].State == TissueState.Healthy && RulePolicies.TypeAbilityOn(s, s.Cells[cell.Id]))
        {
            var around = RulePolicies.GdNeighbors(s, move.TargetPosition).ToArray();
            if (cell.Type == CellType.Melanoma && around.Count(n => RulePolicies.Cancerous(s.Board.Tissues[n])) >= RulePolicies.PseudopodMinAdjacent)
                Stage.Emit(Stage.Fx(s, "pseudopod", ("from", cell.Position), ("to", move.TargetPosition),
                    ("roots", around.Where(n => n != cell.Position && RulePolicies.Cancerous(s.Board.Tissues[n])).ToArray()), ("cid", cell.Id)));
            else if (cell.Type == CellType.SmallCellLung)
                Stage.Emit(Stage.Fx(s, "minimal", ("from", cell.Position), ("to", move.TargetPosition)));
        }
        s = s.UpdateTissueOccupant(cell.Position, null).UpdateTissueOccupant(move.TargetPosition, cell.Id);
        s = s.UpdateCell(cell.Id, s.Cells[cell.Id].WithPosition(move.TargetPosition));
        var tissue = s.Board.Tissues[move.TargetPosition];
        // GD `enter_tile(cell, to, q.final)`：定殖 / 蹲守 / 净化 → 黏液 → collect_special → update_marks；RAS 在它整个跑完之后（cw_actions.gd:773-782）。
        // paid：连锁跳（free）在 GD 里不传 → -1；付费迁移传实付，被免费豁免盖成 0 的照传 0（巨噬回能三态看它，见 MacroPurifyHeal）
        var walkDepth = WalkDepth(s);
        s = Arrive(s, cell.Id, move.TargetPosition, free ? -1 : cost, rng, cell.Position);
        var landed = s.Board.Tissues[move.TargetPosition];
        if (landed.State != tissue.State)
            events.Add(new TissueStateChangedEvent(s.Turn.WorldRound, s.Turn.Phase, move.TargetPosition, tissue.State, landed.State));
        // 后半截（黏液 → collect_special → update_marks）：定殖 / 净化追出问答就推迟到问完再做（GD 是 await 链）
        s = LandOrDefer(s, cell.Id, move.TargetPosition, walkDepth, rng);
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
        s = UpdateMarks(s);
        if (target != null) EmitImmuneAttackFx(s, cell, target, move.TargetPosition, attackHit);   // 击杀进格之后才演（GD cw_actions.gd:940-949）
        return new(s, events, true);
    }

    /// <summary>GD cw_actions.gd:944-949：非巨噬的免疫攻击，整段结算（含进格）之后演本体冲撞。<paramref name="attackerBefore"/> / <paramref name="targetBefore"/> 是攻击前的快照（起点、种类）。</summary>
    private static void EmitImmuneAttackFx(WorldState s, Cell attackerBefore, Cell targetBefore, HexPosition to, bool hit)
    {
        if (attackerBefore.Type == CellType.Macrophage) return;
        var attacker = s.Cells[attackerBefore.Id];
        var target = s.Cells[targetBefore.Id];
        Stage.Emit(Stage.Fx(s, "immune_attack", ("from", attackerBefore.Position), ("to", to), ("cid", attackerBefore.Id), ("target_id", targetBefore.Id),
            ("itype", GdEnum.Itype(attackerBefore.Type)), ("ctype", GdEnum.Ctype(targetBefore.Type)),   // GD 值（观测协议附录 A），别塞 C# 枚举 ("target_alive", target.IsAlive), ("attacker_alive", attacker.IsAlive),
            ("entered", attacker.IsAlive && attacker.Position == to), ("hit", hit)));
    }
}
