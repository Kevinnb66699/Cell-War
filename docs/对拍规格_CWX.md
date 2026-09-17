<!-- 本文由 2026-09-15 的一次 12 agent 并行核查产出，全部事实为本机实测并标了 文件:行。 -->

> **状态：方案，未拍板。** 这是路线 A 阶段 0（对拍）的规格，还没有开工授权。
> 它要花我们约 6.5 人天、队友约 3.5 人天，且要求队友改 C# 侧的 RNG 抽法口径 ——
> 那两件事都得 Kevin 与队友先点头。
>
> **它已经付过的钱**：本轮为了验证方案可行，两边都真编真跑过原型
> （GD 侧 279 + 284 行、C# 侧 370 行），原型留档在 session scratchpad 的
> `gd/` 与 `xcheck/` 下，没有进仓库。工作树里**不留任何对拍代码** ——
> 上一轮有一个 `var rng: Object` 的引擎改动混进了 main，已由 c6e3754 退回，
> 补丁留档 `scratchpad/kept/rng_injectable.patch`。
>
> **它已经换来的东西**（就算对拍最终不做，这三条也是净赚的）：
> 1. C# 侧三条现成 bug，其中「攻击暴击永远掷不出来」实测 60000 次 crit 0%（应 16.7%）
> 2. 两仓 PRD 已经分叉 48 行、8 条锚点失配 —— 我们此前说的「四处规则偏离」至少三处
>    要改判为「PRD 未同步」，不是 C# 的错
> 3. 我们自己此前说错的两条（「C# 只有 37 张卡有效果」、「GD 的攻击是独立顶层行动」）

# Cell War 双内核对拍规格（CWX-2026-09-15）

> 适用范围：GDScript 内核（`D:/Projects/SpringSense/2026-2027/Cell War/Cell-War`，权威）与 C# 内核（`D:/Projects/SpringSense/2026-2027/Cell War/cellwar-next`，被测）。
> 目的：产出「C# 内核到底差什么、从哪一步开始分叉」的可执行差异清单，作为路线 A（C# 进程外权威内核）阶段 0 的出口证据。
> 本文所有事实均为本机实测，标注了 `文件:行`；被核查推翻的假设集中列在第 7 节，不在正文里装作没发生。

---

## 0. 一页结论

**用三层，不是选一套。三层解决的是三个不同的问题，互相不能替代。**

| 层 | 名字 | 回答什么问题 | 两边改动 | 单次耗时 | 状态 |
|---|---|---|---|---|---|
| **L0** | 契约靶场（Contract Target Range） | 「同一条规则，两边各算出什么数」 | GD 0 行；C# 0 行（扩探针时要抽纯查询） | **1.2 秒** | 原型已跑通：23 用例 19/4/4，另 8 张常量表 44 行 |
| **L1** | 教师强制单步重放（TFSC） | 「同一个真实局面 + 同一个动作，两边演化成什么」 | GD 4 行（已在 0239b48 入库）；C# 必须改 RNG 抽法口径 | 分钟级 | 原型已跑通 2p/4p/6p 各 40/60/60 步全程无中断 |
| **L2** | 整局/终局等价闸门 | 「发版前的端到端等价证据」 | 需要队友加 `Clamp` 入口 | — | **阶段 0 不做**，写进阶段 1 |

**排序理由（不是口味问题）**：

* L0 的每条用例**互相独立**——C# 少一条规则只污染那一行。L1 的每一步虽然被教师强制隔离了状态，但**带子（RNG）口径没对齐之前，凡是跨 E 阶段的步整段作废**（实测：不改 `BoardRules.cs:98` 的 `NextDouble`，2p 跑 40 步就撞 64 条 `RNG_NO_COUNTERPART`）。所以 L0 先出成果，L1 等队友的两条 RNG 改造。
* L0 **碰不到**流程编排、修饰器叠加顺序、组合效应；L1 能。所以 L0 全绿不是出口条件，只是必要条件。
* L2 现在做是负收益：C# 第 0 步就分叉（初盘生成算法两套），自由跑的对拍只会报「第 0 步不一样」然后全盘作废。

**阶段 0 出口条件写成**：`L0: MISMATCH=0 且 NOTIMPL=0 且 COVERAGE 无「未写用例」格` ＋ `L1: 核心子系统（移动/收入/攻击/E 阶段）BLOCKING=0`。**不是「dotnet test 绿」，也不是「清单清零」**——清单里的 `KNOWN_GAP` 与 `UNDEFINED` 是拿去排期的，不是拿去清零的。

---

## 1. 三个死结的确定解法

### 死结一 · 选项下标不通用

**解法：删掉「下标」这个概念。两层各删各的。**

**L0**：根本不推进，直接构造世界、直接调纯查询，没有决策也就没有下标。但「这个细胞此刻有哪些合法动作」本身是一条规则，必须单独打一次靶——用**语义元组集合差**，比集合不比顺序：

```
探针 action_options：
  GD  侧 → _pending["options"][i]["data"] 取语义子集 → 排序 → 拍平
  C#  侧 → BasicRulesEngine.GetAvailableDecisions(s, seat) 的 IDecision → 同一套语义键 → 排序 → 拍平
  比 GD-C# 与 C#-GD 两个方向的集合差
```

**L1**：动作用**语义键**运输，两边各在自己的选项表里查回下标。键的文法（两侧同一套，字符串比较）：

```
k=<kind>[|g=<tag>]|<field>=<v>|...
field 固定顺序，取自 GD data 的 13 个键：
  act, card, type, to, cid, dir, r, pay, get, from, to_cid, stop, skip
Vector2i → "q,r"；bool → 1/0
```

真实样例：`k=action|act=move|to=-2,0`、`k=action|act=play|card=癌症转移|to=-3,3`、`k=setup_place|to=-6,0`。

**三条硬规矩**：

1. **剔除 `cost` 与 `anchor`**。`cost` 是引擎算出来的报价（`cw_actions.gd:133 quote_path`），`anchor` 是引擎按坐标最小值挑的依托（`cw_world.gd:32-33`）——都不是玩家意图。留在键里，「C# 算费不同」会伪装成「动作不同」，而算费差异本该由 L0 的 `move_cost`/`quote_path` 探针单独报一条。
2. **cid 用席位不用 id**。GD 的 `cells` 下标从 0 起，C# `EntityId` 0 是 Invalid、从 1 起；正式局 `cells.append` 只出现在 `cw_setup.gd:209`（一席一胞），所以 seat 是稳定主键。C# 侧 `EntityId = seat + 1`。
3. **合并键**：GD 两问 ↔ C# 一决策的三处走组键，比对边界落在**组的末尾**：
   `k=action+chemo_target|act=chemo|to=q,r`（趋化源）、`k=action+effector_target|act=effector|cid=N`（免疫猎杀）、`k=action+effector_target|act=effector|dir=D|to=q,r`（Excalibur）。
   ~~**`free_move`（连续吞噬、炎症性趋化）暂不进组表，列为 `KNOWN_GAP`**~~ —— **2026-09-16 一半已合上**：
   C# 补了 `ChainMoveDecision` / `StopChainDecision`，形状与 GD 的一步一问对得上，键是 `k=free_move|g=连续吞噬|to=q,r` 与 `|stop=1`。
   **另一半 2026-09-16 晚也合上了**（Kevin 拍板「改 C# 跟上 GD」）：【炎症性趋化】改成 GD 的形状 ——
   打出选项烤第 1 步的落点（`k=action|act=play|card=炎症性趋化|to=`），第 2/3 步各一问
   `k=free_move|g=炎症性趋化|to=` / `|stop=1`。**`free_move` 整条不再是 KNOWN_GAP。**

**映射表（已逐条核对 `DecisionRouter.Available`）**：

| C# Decision | GD 语义键 |
|---|---|
| `PlaceDecision` | `k=setup_place\|to=` |
| `EndTurnDecision` | `k=action\|act=end` |
| `MoveDecision` | `k=action\|act=move\|to=`（**攻击折在这里，两边一致**） |
| `DrawDecision` / `MutateDecision` | `act=draw` / `act=mutate` |
| `DifferentiateDecision` | `act=differentiate\|type=0..4`（GD `ImmuneType` 与 C# `CellType` 前五项同序，直接取整数） |
| `PlayCardDecision` | `act=play\|card=`，格子目标 `\|to=`，**细胞目标 `\|cid=`**（改：原表没写细胞目标，写了也容易误用 `to_cid` —— `to_cid` 只属于【代谢耦联】的转出/转入二问） |
| `DiscardDecision` | **改**：`k=pick\|g=手牌上限\|card=`。C# 的弃置只有强制那一路（`Turn.PendingDiscardSeat` 挂起才给选项），对应 GD `cw_cards.gd:70 discard_to_limit`；原表写的 `act=discard` 是行动栏里那条**自愿**弃置 —— C# 原本整条缺失，2026-09-16 补上，所以这一格现在是**两个键**：挂起时 `k=pick\|g=手牌上限`，没挂起时 `k=action\|act=discard` |
| `ReviveDecision` | **改**：按阵营分两个 kind —— 免疫 `k=immune_revive\|to=`、癌方 `k=revive\|to=`。原表漏了这一条。癌方那问 GD 的 data 带 `anchor`，按规矩 1 剔除，所以同一落点的多个依托在 C# 侧压成同一个键 |
| `ChainMoveDecision` / `StopChainDecision` | `k=free_move\|g=连续吞噬\|to=` / `\|stop=1`（2026-09-16 新增） |
| `ChemotaxisStepDecision` / `StopChemotaxisDecision` | `k=free_move\|g=炎症性趋化\|to=` / `\|stop=1`（2026-09-16 新增）。第 1 步不在这里 —— 它是 `act=play\|card=炎症性趋化\|to=` |
| `ChooseMutationDecision` | `k=pick\|g=基因组不稳定\|r=`，**`r` 是骰面值不是下标** —— C# 存的是「选第几个」，GD 那边根本没有 0/1 这个数 |
| `TypeSkillDecision` | 按 Skill 串：抗体→`antibody`、细胞毒素→`toxin`、骨样硬化→`ossify`、黏液破裂→`mucus`、裂解→`lyse\|to=`、转移→`jump\|to=`、**早期血行转移→`homing\|to=`**；【效应应答】四种分化共用 GD 的一个入口 `act=effector`（B【中和抗体】、巨噬【连续吞噬】问完就结；树突【免疫猎杀】、T【Excalibur】走组键） |
| `PassDecision` | **无对应物** → 每个 action 询问固定一条 `OPTION_EXTRA` |
| `AttackDecision` / `DivideDecision` | **死代码**（`IRulesEngine.cs:93/191` 无 Validate/Execute/Available），不映射 |

**必须更正第一轮的一条错误结论**：攻击在**两边都折在 move 里**（`cw_actions.gd:_do_move` 第 786 行起判目标格有无敌细胞）。照旧结论把 `move`/`attack` 拆成两个键，每一步都会误报。映射表其余条目请队友复核一遍，同类错误可能还有。

**2026-09-16 复核结果**（实现在 `core/CellWar.Core.Tests/L1/SemanticKey.cs`，判据在 `SemanticKeyTests.cs`）：表上标「改」的四行就是复核查出来的同类错误，已就地改正。另外查出**一个 C# bug 并已修**：`DecisionRouter.Available` 把【早期血行转移】和四个无目标技能摆在一起枚举，`Target` 恒为 `null`、`Validate` 条条驳回 —— 这个技能**在选项表里根本不存在**（GD `_homing_targets()` 是逐格摊开的）。

还有一条**`dir` 的坑**：Excalibur 的方向下标是 GD `CWData.DIRS`（`cw_data.gd:870`）那张表的下标，而 C# `HexPosition.GetNeighbors()` 是另一套次序。照自己的枚举序写下标，六个方向全错位，而且错得很安静 —— 键的形状对、字段齐全，只是指着别的方向。`SemanticKey.GdDirs` 把 GD 那张表原样抄了一份，六个方向各钉一条用例。

**2026-09-16 深夜 · 拍板后**：攻击上限改走旋钮 `attack_max_per_turn`（视图 tune 块 18 键）。

**2026-09-16 晚 · L1 首次真比**（M3 的教师强制重放跑通）：4p seed 4242 轨迹重放 **28 步一致**。三处分叉：两处是视图定义（`players[].alive` / `players[].ctype` / `immune_level` 基数），一处是真规则 —— **抽卡候选顺序**（GD 卡表文件序 = `sorted(cards)` 码点序，C# 走目录序）已修并钉判据。第 29 步曾是 KNOWN_GAP【代谢耦联】—— **2026-09-16 深夜已跟 GD**（三问 + 取消，两边一起改，协议 v27），重放到 **32 步**。第 33 步是新的 **KNOWN_GAP：需要选格 / 选细胞的卡逐个摊开** —— GD `hand_options` 把【基质硬化】【放疗】【基质降解】【基质重塑】【交叉呈递】【IFN-γ高峰】【免疫增援】【乳酸酸化】【抗体依赖细胞毒作用】【肿瘤细胞募集】【肿瘤增援】按目标各出一条（`|to=` / `|cid=`），C# 除【癌症转移】【炎症性趋化】【代谢耦联】外都是一条无目标打出。另：GD 癌方复活多一条 `k=revive|skip=1`（放弃本回合复活）—— **2026-09-16 深夜已补进 C#**（`SkipReviveDecision` + 依托取最小 + 席位光标），重放不再减它。

**2026-09-17 · 11 张卡合上，夹具重录到 200 步整条一致**。候选表收在 `CardRules.TileTargeted / CellTargeted`（选项层 / Validate / 结算三处共用一份），
三路只读规格 + 一路带子口径复核先写清每张卡的候选条件、结算与剩余随机，再照着搬。顺着 L1 往下走又修掉六处 C# ≠ GD（都是 GD 不掷 / 掷一次而 C# 另有一套的形状）：
【黏液破裂】自毁走 Damage 被自己的【囊性护甲】减掉 0.5「自杀未遂」（改走 `Kill`，也是死亡的唯一入口、顺带清 mods）；【侵蚀】逐块各掷 d3（改成全盘一份候选、一次 d3、一次 pick_n，块序 / 块内序照 GD 的栈式深搜 `GdBlocks`）；
「本回合」修饰在下一次 BeginTurn 才清（改成结束回合那一刻清）；压迫为 0 也进 Damage 把一次性护盾吃掉（改成 GD 的 `loss <= 0: continue`）；【RAS持续激活】闸门只烧一次（GD `first_this_turn` 每次计数）；
`UpdateMarks` 过滤「本回合标过」（GD 过滤「已带标记」）。传送落地统一走 `CellRules.EnterTile`（Teleport + 黏液清除 + 代谢核心 / 骨髓二选一 + 标记刷新），骨髓抽卡那一发带子此前 C# 全局没有。
**还是 KNOWN_GAP 的**：【基质重塑】选定第一格之后的两段追问（再拆一格 / 转健康 ×2，GD 三问零随机；C# 现在只有第一格由玩家选、后面仍按 PickRandom）；
能量损失的限次修饰消耗不是 ON_BENEFIT（`ConsumeModifiers` 对 EnergyLoss 一律扣，GD `_shield_groups` 只扣真减了伤的）；【细胞毒性增强】GD 走 fx_turn 闸门、C# 是回合修饰；
【信号放大】【细胞应激】等世界事件；【交叉呈递】绕开 apply_mark 是 GD 的疏漏还是口径（待 Kevin 裁）。

**2026-09-17 晚 · 2p / 6p 夹具**（Kevin 要的）：`trace_2p_2222.jsonl`（173 步终局）、`trace_6p_6666.jsonl`（200 步），各自的水位线 51 / 186。
录出来即撞的、已合上的：【趋化募集】【效应细胞浸润】是抽到即走的免费连走（GD `_free_walk` 逐步追问；C# 此前是两条免费移动修饰），
挂起态加 `PendingWalkCard` 与【炎症性趋化】共用一套决策；小细胞【转移】只朝六个方向直线跃进 5 格（C# 曾给整个 5 环）+ `metastasis_max_per_round` 旋钮；
S 阶段骨髓产出时站在上面的细胞要抽卡（`collect_special`，带子一发）、复活落地也走 `enter_tile`（骨髓有卡就抽）；免疫死亡记 `respawn_round`（`immune_respawn_delay` 旋钮）；
无目标卡的「有效果才出」闸（局部吞噬 / 溶酶体强化 / 克隆增殖 / TNF-α）；【骨样硬化】已标过 / 血管不出选项。
**还开着的**：① 减免层不分来源 —— GD `_shield_applies`：【缺氧适应】只挡癌方技能 / 压迫，【DNA损伤修复】只挡免疫方的事件 / 技能（普通攻击不挡），
C# `Damage` 对目标身上全部 EnergyLoss 修饰一律套用且一律消耗（2p 第 52 步：【突变】的自损把【DNA损伤修复】吃掉了）。
（6p 第 187 步那 0.1 已合上：有氧收入的顺序 —— GD 先对等级份额打【TGF-β释放】折再加【代谢适应】【自分泌生存信号】的额外获得，C# 此前先加后折；6p 整条 200 步一致。）

**丢掉了什么（写进限制栏）**：选项的**顺序**与下标稳定性不再被验证（`DecisionRouter.cs:82` 的 `Tiles(s)` 走 `PagedMap` 迭代序而非排序序）。C# 真当权威内核时，这会以「客户端点了第 3 项、服务器执行了第 5 项」的形式复活——那要靠「按语义提交」的线上协议解决，不是靠对拍。**这条要单独立一条阶段 1 待办。**

---

### 死结二 · RNG 算法不同且不可调和

**解法：分两层处理。L0 把随机规则劈成「算式 × 掷骰」只验前一半；L1 用「一方录、一方念」的带子，并要求 C# 先做两条抽法口径改造。**

#### L0：劈开

| 规则 | 纯的那半（打靶） | 掷骰那半（L0 不验） |
|---|---|---|
| 增生 | 千分率 `proliferate_chance(c)` | `randi_range(1,1000)` |
| 侵蚀 | 候选格集合 + 本轮转化上限 | 从候选里抽哪几格 |
| 攻击 | `AttackOutcome(roll, cell)` 判定表（roll 1..6 逐个比）**＋ 骰面值域表** | 掷出的 roll |
| 根深蒂固 | 相邻可加计数格集合 + limit（II=1 / III=3） | 取哪几格 |
| 抽卡 | `(卡名 → 权重)` 全表 + total | 抽到第几张 |
| 开局癌组织 | **不劈**，两套算法，直接记成已知偏离 |

**「值域表」是这一层的命门**，不能省。实跑证据：`attack_verdict` 判定表 16/16 全绿，但 `roll_domain` 一测就红——

```
✗ roll_domain  攻击判定骰面值域   GD=1..6               C#=0..5
✗ roll_domain  实际可达的判词     GD=crit,fail,success  C#=fail,success
```

`RulePolicies.AttackOutcome` 本身完全正确，错的是调用点 `CellRules.cs:194/205` 的 `rng.NextInt(6)` 产出 0..5，`roll == 6` 那一面永远掷不到。20000 次与 60000 次两轮实掷：fail 50.2% / success 49.8% / **crit 0%**（应为 33.3/50.0/16.7）。**规矩：每条涉及掷骰的规则必须配一张值域表，只比判定函数会给假绿灯。**

#### L1：带子

**格式**：每次抽取一条 `[from, to, value]`，**全闭区间**，按「步」分段挂在该步记录的 `rng` 字段上；开局（`init` + `setup.begin()`）那一段挂在 header 的 `boot_rng`。实测 2p seed=4242 的 `boot_rng` 正好 15 条（14 条长癌组织 + 1 条癌种），与公式 `(init_cancer_tiles − 1) + 未被 tune.cancer_types 钉死的癌席数` 吻合（2p/4p/6p = 15/16/26）。

**三条硬规矩**：

1. **`from==to` 零消耗**。Godot 实测 `randi_range(3,3)` 不推进 PCG state（2 人局 515 次调用只前进 485 步）。C# 侧 `NextInt(1)` / `NextIntRange(n,n+1)` 必须同样定义成零消耗，否则从第一个单选项处就错位。
2. **只比跨度，不比基数**。`NextInt(max)` → 折算 `[0,max-1]`，`randi_range(1,n)` → `[1,n]`。跨度同、基数不同 = 纯口径，按偏移平移并记一条 `RNG_BASE`（实测 2p/4p/6p 各 5/7/3 条，全良性）；**跨度不同才报 `RNG_SPAN`，那是「候选集大小不一样」的免费断言**，在结算之前就报警。
3. 带子用完 C# 还要 = `RNG_OVERRUN`；一步走完带子有剩 = `RNG_UNUSED`。

**注入点（2026-09-16 更正）**：0239b48 那次是随「只改文档」的提交**误扫**进来的，c6e3754 已撤回；本日**有意**重开为 `var rng: Object = RandomNumberGenerator.new()`（鸭子对象只需 `seed` / `state` / `randi_range(int,int)->int`），并按 §4 D 补了护栏 `t_xcheck`。`bash tools/run_tests.sh` → **3519 项检查全过**。

> ⚠ **这条注入靠的是弱类型**。哪天有人「顺手恢复静态类型」，对拍会**静默失效**（脚本照跑，带子永远是空的）。必须加一条护栏测试钉死可替换性——见第 4 节 D 项。

**C# 侧必须改的两条抽法口径**（不改则带子永远对不上，与规则对错无关）：

* `BoardRules.cs:98` `rng.NextDouble() < adjacent.Length * rate` → `rng.NextIntRange(1, 1001) <= 千分数`，对齐 `cw_world.gd:618`。**浮点抽取在我们这边没有任何对应物**，E 阶段 100% 走它、实测每回合 27 次 → 不改则任何跨 E 阶段的步整段是废的。
* 11 处 `rng.Shuffle(xs).Take(k)` / `Choose` → 改成逐次 `RemoveAt(NextInt(remaining))` 取 k 个，对齐 `cw_game.gd:837 pick_random()`。命中点：`BoardRules.cs:111/166`、`CardRules.cs:78/104/287/312`、`CellRules.cs:242`、`SkillRules.cs:104/137/155`、`MatchSetup.cs:41`。

**对拍路径上不需要碰 `Runtime.cs`**：`BasicRulesEngine.ExecuteDecision(WorldState, IDecision, IDeterministicRng)` / `AdvancePhase(WorldState, IDeterministicRng)` 直接收 rng 作参数（`BasicRulesEngine.cs:23/25/27`），`Runtime.cs:77-78` 那句硬写死的 `new Xoshiro256StarStar(1)` 不在路径上。`CheckpointCodec.cs:92` 的校验只要求 `Seed|S1|S2|S3 != 0`，带子游标塞 `RngState.Counter`、Seed 填 1 就能过。**`Runtime.cs:77-78/164` 仍要改，但那是路线 A 生产内核的事，不是对拍的前置。**

**丢掉了什么**：L0 永远不验证「掷了几次骰、按什么次序掷」；L1 验了，但只在它覆盖到的步上。**两个内核可以每条算式全绿，一上线仍然分叉**——这是 L0 全绿不能当阶段 0 出口的根本原因。

---

### 死结三 · 规则完成度不同

**解法：缺失是一等公民。给结果四种结局，给污染做粘性标记，给两层各自的隔离机制。**

**四种结局**（`dotnet test` 只对 MISMATCH 和 BADFIXTURE 变红）：

| 结局 | 含义 | 红？ | 去向 |
|---|---|---|---|
| `PASS` | 一致 | — | — |
| `MISMATCH` / `BLOCKING` | 两边都有这条规则、结果不同 | **红** | 差异清单，要修 |
| `NOTIMPL` / `KNOWN_GAP` | C# 整块没有 | 否 | 「待实现」队列，只计数 |
| `BADFIXTURE` | 用例/装载本身是假的 | **红** | 修工具，不发工单 |
| `UNDEFINED` | 两份 PRD 都无明文 | 否 | **Kevin 待裁清单，不发工单** |

`BADFIXTURE` 必须与 `NOTIMPL` **分栏计数**——否则 loader 的静默丢字段会以「待实现」的面目长期存活（第 7 节反例 1 就是这么发生的）。

**L0 的隔离是结构性的**：每条用例是独立的一次函数调用，从干净的用例状态起步，上一条的结果不流进下一条。整局对拍里 C# 第 3 回合少触发一次【净化】、后面 12 回合全跟着错，1 条偏离变 3000 条噪音；L0 里 1 条偏离就是 1 条红。

**L1 的隔离靠教师强制**：每一步之后把 C# 的世界重置成黄金 post。实测 2p/4p/6p 各 40/60/60 步**全部跑到底**，没有一步因为前面错了而中断。

**七项白名单（C# 根本没有的状态维度）拆成两张表**——这是核查后的重要更正，原协议只有一张表是错的：

| 项 | 不比 | **不注入** |
|---|---|---|
| `events{pool,active,double_next}`（15 个世界事件 + 卡牌全局修饰容器） | 部分 | 部分 |
| `tune`（59 旋钮） | ✓ | ✓ |
| ~~`chemo_track`~~ **2026-09-16 起 C# 有了（`Turn.TrackCell/TrackFrozenAt/TrackRounds`）** | — | 照字段注入 |
| `differentiated`（分化种类全阵营去重） | ✓ | ✓ |
| ~~`equip_seq` + `fx_turn` / `fx_round`~~ **2026-09-15 起 C# 有了，这一行作废** | — | — |
| ~~`chemo_cd`~~ **2026-09-16 起 C# 有了（`Cell.ChemoCooldown`）；顺带把源的时钟改回「完整回合」制** | — | 照字段注入 |
| ~~`chain_bonus`~~ **2026-09-16 起 C# 有了（`Cell.ChainLeft` / `ChainBonus` + 挂起式连锁）** | — | 照字段注入 |
| ~~**`TgfStacks`**~~ **2026-09-16 起 C# 也住 `Effects` 容器，同名同形** | — | 照条目直接注入 |
| ~~**`PausedDecayRound`**~~ **2026-09-16 起 C# 也住 `Effects` 容器，同名同形** | — | 照条目直接注入 |
| **`SolidLockRound`** ← GD `events["active"]` 的【TNF-α局部炎症】 | ✓ | **必须注入** |
| **`CancerAlarmRound`** ← 由 GD `cancer_win_streak` 折算 | ✓ | **必须注入** |
| ~~**`CancerEffectsDisabledUntil`** ← 由 GD 每胞 `neutral_until` 折算~~ **2026-09-15 起 C# 改成每胞 `Cell.NeutralUntil`，同名同形，不再需要折算** | — | 照字段直接注入 |

**`equip_seq` / `fx_turn` / `fx_round` 这一行 2026-09-15 收回**：C# 侧已经建好
`Cell.EquipSeq`、`Cell.FxTurn`、`Cell.FxRound`，形状照 GD 抄（计数字典 / 名字集合，
清点分别在 `BeginTurn` 与 `ResetRoundFlags`）。**它们现在可比也可注入。**

更要紧的是顺带修掉的一个假差异源：那四个「每回合第一次…」的闸门此前是
**借住在 C# `mods` 里的 `Value=0` 假修饰**，而 GD 侧它们在 `fx_*` 里、`mods` 里什么都没有。
§2.2 要求 `mods` 逐条导九元组比对 —— 不搬走的话，这四条会在一个**被比对的字段**上
凭空报出四行假差异。

（仍未对齐：【组织驻留】的额度 GD 记在 `fx_turn`、C# 记在一条 `Uses:2` 的 Free Move 修饰里。
行为一致，但 `mods` 逐条比对时 C# 会多这一条。搬它要连 GD 的 `Store.GATE` 一起搬。）

**事件容器 2026-09-16 立起来了（EV-0）**：C# 侧 `WorldState.Effects` + `WorldEffects` 读写口，
形状照 GD 的 `events["active"]`（`{Name, Left, Stacks, Doubled, Data}`，E 阶段第 8 步倒计时）。

**已经搬进去的**：【TGF-β释放】（left=2，结算后同名整批消耗）、【基质稳定】（left=1）——
它们此前各用一个 `TurnState` 上的标量顶着，与 GD 对不上；现在两边同名同形，上表两行作废。

**还没搬**：15 个世界事件的**内容**（名字表与触发回合 3/6/10/14 已对齐，效果还没实现）、
`pool`（同局不重复的抽取）、`double_next`（【双重触发】的三档加倍）。
**【TNF-α局部炎症】也还没搬**：GD 把冻结的**格子**记在事件条目的 `data` 里，
C# 是每格一个 `Tissue.SolidLockRound` 回合戳 —— 行为等价（left=1 随回合末解冻 ≡ 戳 == 当前回合），
但形状不同，`mods` 那种逐条比对碰不到它，暂时不动。

后五项不注入的话不是漏报，**是错报**：C# 会在一个「TGF 层数为 0、衰减没暂停」的伪造世界上算数。

**污染标记必须是粘性的**（核查更正）：`events["active"]` 与细胞 `mods` 都是**跨步持续**的，一旦生效，后续每一步都受污染而其动作本身并不触及白名单。所以 `TAINTED` 的判据是「**当前状态里存在活跃的白名单条目**」，不是「本步动作触及白名单」。按后者做，假差异会从触发那一步一直流到局尾。

**收敛闸**：`NOTIMPL` 数量只许降不许升；某条从 `NOTIMPL` → `PASS` 是真实进度，`PASS` → `MISMATCH` 是回归。配 `COVERAGE.md` 全表（PRD 章节 + 68 张卡 + 9 个种类技能），**没写用例的格子是「未知」不是「对的」**。

---

## 2. 数据格式（真实字段名）

### 2.1 `cwxcase/1` —— L0 用例（稀疏补丁）

```json
{
  "schema": "cwxcase/1",
  "id": "anaerobic/block4_one_cell",
  "probe": "anaerobic_gain",
  "prd": { "sha": "3C367B76…", "line": 412, "text": "§E阶段·无氧呼吸 — 每个癌细胞块按…" },
  "subject": { "cell": 0 },
  "world": {
    "players": 4,
    "seats": [0, 1, 0, 1],
    "board_radius": 6,
    "round_no": 3,
    "memory": 0,
    "immune_level": 0,
    "effector_round": -1,
    "tgf_stacks": 0,
    "paused_decay_round": 0,
    "cancer_alarm_round": 0,
    "cancer_disabled_until": 0,
    "players_meta": [
      { "pid": 0, "faction": 0, "cancer_type": -1, "cell_id": 0 },
      { "pid": 1, "faction": 1, "cancer_type": 0,  "cell_id": 1 }
    ],
    "tiles": [
      { "q": 0, "r": 0, "tissue": 1 }, { "q": 1, "r": 0, "tissue": 1 },
      { "q": 0, "r": 1, "tissue": 1 }, { "q": 1, "r": -1, "tissue": 1 }
    ],
    "cells": [
      { "id": 0, "pid": 1, "faction": 1, "q": 0, "r": 0, "ctype": 0, "energy": 50 }
    ]
  },
  "expect": { "kind": "tenths", "value": 24, "trace": { "share": 20, "share_no_tgf": 20 } }
}
```

**词汇一律用 GD 字段名**（`cw_setup.gd:32-48 make_tile` 11 键 / `:51-88 make_cell` 30 键），映射负担压在 C# 侧唯一的 loader 里。

**规矩**：
1. **稀疏补丁**：底板 = 半径 6 的 127 格全健康 + 特殊组织按坐标表铺（GD 走 `CWSetup.build_board()`；C# 借 `MatchSetup.Create(n,1)` 的布局再清成 Healthy，**不在 loader 里抄第二份坐标表**——11 个特殊格坐标 `cw_data.gd:500-505` ↔ `MatchSetup.cs:16-22` 已逐个核对一致）。
2. **未知字段 = 硬错**：loader 里 `TileFields`/`CellFields` 白名单，未映射字段直接抛异常，不静默忽略。
3. **`players_meta` 必填，两边都不许自己编**。C# loader 现在硬写 `CancerType = CellType.Melanoma`，必须删掉改读用例。GD 生成器装载后断言 `g.cells[players[pid].cell_id]["pid"] == pid`。
4. **派生字段末尾重算，不是纯赋值**（核查更正）。schema 标 derived 的两项：C# 的 `Tissue.OccupyingCell`（从 cells 反推并双向自校验）、GD 的 `cell["marked"]`（装载末尾调一次 `cw_game.gd:1072 update_marks()`）。原协议那条「装载后不许有任何引擎后处理」在 derived 字段上站不住——它本意是挡 `update_marks` 改写用例语义，正确解法是把 derived 排除在「写什么就是什么」之外。
5. **`expect.trace` 只作参考、不参与判定**。

`expect` 两类：标量 `{kind: "tenths"|"permille", value: int}`；向量 `{kind:"path", steps:[{q,r,cost,gain,legal,afford}], total, gained, ok, stop, left}`（两边各自拍平成同一串文本再比）。

### 2.2 `canon` —— L1 规范化状态

**形状取我们的**（GD 字段更全），映射的活让 C# 干。**一个浮点都不许有**，全是 int/bool/string/null，所以两边能产出逐字节相同的文本。

```json
{"board":[{"p":[-6,0],"sp":3,"ts":0,"sol":0,"nec":0,"mu":false,"nb":false,
           "oss":0,"st":0,"cd":0,"prod":0,"tox":0,"slock":0}, … 127 项，按 (q,r) 升序],
 "cells":[{"id":0,"pid":0,"fac":0,"kind":"ImmuneBasic","p":[6,0],"e":50,"alive":true,
           "hand":[],"equip":[],"mods":[{"name":"I型干扰素","uses":1,"stage":…,"layer":…,
                                        "seq":…,"value":…,"floor":…,"dur":…,"req":…}],
           "marked":false,"mark_left":0,"mark_round":-1,"eff_used":false,"diff":false,
           "atk":0,"draw":0,"tox":0,"ab":0,"mut":false,"armor":false,"meta":false,"jump":0,
           "respawn":-1,"death_round":null,"camp_r":-1,"camp_p":[0,0]}, … 按 id 升序],
 "g":{"round":1,"memory":0,"immune":0,"winner":-1,"eff_round":-1,
      "order":[0,1],"ctypes":[-1,0],"diffed":[],
      "chemo_at":[],"chemo_left":0,"chemo_by":-1,
      "phase":…,"active_seat":0,"start_step":2,
      "pending_discard":null,"pm_seat":null,"pm_cell":null,"pm_a":0,"pm_b":0,
      "tgf":0,"paused_decay":0,"cytokine_seat":-1,"cancer_disabled_until":0,"alarm_round":0}}
```

> **粗体是核查后新增的 15 项**：`g` 块 13 项（phase / active_seat / start_step / pending_discard / pm_{seat,cell,a,b} / tgf / paused_decay / cytokine_seat / cancer_disabled_until / alarm_round）、`cells.death_round`、`board.slock`。原协议那句「轨迹必须带 pid，状态可以不带」要改成「**phase 与 start_step 和 pid 一样属于必备项**」——`ask.kind` 推不出 `StartStep`，也推不出 pending 种类。

**映射规则**：

* `sp` ← `special`/`TissueType`（枚举序一致）；`ts` ← `tissue`/`TissueState`（序一致）；`sol` ← `solid`/`SolidificationCount`（都是十分位，两边注释矛盾但实际同口径，阈值 30·20·20：`cw_data.gd:383-385` ↔ `BoardRules.cs:141-144`）
* `st`/`cd` ← C# 单字段 `Charge` 按 `Type` 拆（MetabolicCore→`st`、BoneMarrow→`cd`、其余 0）
* `kind` ← GD 的 `itype`/`ctype` 两字段合成 C# 的 9 值枚举名（BASIC↔ImmuneBasic、B_CELL↔BCell、T_CELL↔TCell、MACRO↔Macrophage、DENDRITIC↔Dendritic、MELANOMA↔Melanoma、SIGNET↔SignetRing、OSTEO↔Osteosarcoma、SCLC↔SmallCellLung）
* `id`：C# 侧 −1（EntityId 0 是 Invalid）；`e`：两边十分整数，**不做浮点比较**
* `immune` = C# `ImmuneLevel − 1`；`eff_round` = C# `EffectorRound==0 ? -1 : 值`；`winner` 由 `Faction?` 反查席位
* `memory`：取免疫席位的 `AntigenMemory`，**并额外断言所有免疫席位相等**（GD 是阵营共享单值、C# 每席位一份，任何只写单席位的路径会内部撕裂，比对器用 `memory_split` 标出来）
* `alarm_round` ↔ `cancer_win_streak`：**结构性不可比**（连续达标回合数 ↔ 首次达标回合号），只能各自算派生量再比
* **`mods` 必须导九元组**（核查更正）：不能只导 `{卡名: 剩余次数}`。要么 GD 侧把每条 mod 的 `(name,uses,until,seq,data)` 映射到 `ActiveModifier(Card,Target,Stage,Layer,Sequence,Value,Floor,Uses,Duration,Requirement)`，要么把「身上带任何 mod 的细胞」整步标 `NOT_COMPARABLE`。否则移动费用/伤害这类最该对的数全是拿伪造修饰算出来的。

**排除**（照抄 `cw_state_codec.gd:62-77` 再加一条）：`phase`\*、`win_reason`、`win_kind`、`feed_log`、`feed_seq`、`board_radius`、`cells[*].play_n`，**外加 `current_pid`/`ActiveSeat`**（`cw_game.gd:52-54` 明写它「纯给界面看、不进 state_hash」，C# 的 `ActivePlayerSeat` 却是权威状态，留在比对集里必报假差异）。
\* `phase`/`active_seat` **进状态用于注入，不进比对**——这两件事必须分开，原协议混为一谈。

**引擎私货绝不进跨内核比对**：`rng`（PCG32 的 64 位内部数对 C# 无意义）、`flow`（GD 流程状态机私有游标）、`_pending`（两边形状不同）。随机性改由每步的 `rng` 带子比。

**不做跨语言状态哈希**，全部逐字段 diff——同样的代价，但差异报告直接落到字段名上。（GD 侧 `state_hash()` 照旧只用于自证轨迹可复现：同一命令跑两遍，591,259 字节 JSONL 逐字节相同，已验。）

### 2.3 `.cwx.jsonl` —— L1 轨迹

```json
{"t":"header","proto":1,"players":2,"seed":4242,
 "ruleset":{"net_version":…,"tune_sig":"…","git":"0239b48","prd_sha":"3C367B76…"},
 "policy":"lcg-sorted-key","boot_rng":[[0,5,2],…,[0,3,0]],"pre":{…canon…}}
{"t":"step","n":15,
 "ask":{"kind":"action","pid":1,"tag":"","n":8,
        "pick":"k=action|act=draw","idx":3,"opts":["k=action|act=end", …]},
 "sub":[{"k":"pick","r":2,"tag":"基因组不稳定"}],
 "rng":[[1,51,28]],
 "post":{…canon…}}
{"t":"footer","steps":40,"rounds":3,"winner":-1,"draws":92,
 "kinds":{"setup_place":2,"action":38},"state_hash":"21a4d64f…"}
```

第 n 步的 `pre` = 第 n−1 步的 `post`，整局只存一份状态。

**`ruleset` 指纹是必填且比对器要校验**——`cw_replay.gd` 文件头写的那个老病（VERSION 停在 2、五次改动没升号）不能重演：规则一改，所有旧轨迹静默失效。校验不上直接拒跑。

**「一步」的定义**（这是协议里最容易做错的一半）：

* **一步 = 一次顶层询问**，不是一次 `ask()`。`CWGame.step()` 的 match 只处理 4 种顶层 kind（`setup_place` / `action` / `revive` / `immune_revive`），其余 6 种全是卡牌结算中途经 `game.ask()` 的**子询问**，折进父步的 `sub[]`，不单独成步。实测 6p seed=4242：顶层 `{setup_place:6, action:459, revive:3, immune_revive:1}`，子询问 `{pick:3}`。
* **一步的边界 = 「作答 + 自动推进到下一个询问」**（S/E 阶段夹在里面）。被测侧必须自己走到同一边界：`ExecuteDecision` 之后循环 `AdvancePhase` 直到有选项或 Finished，**且用同一条带子**。不加这个循环，比的是两个不同时刻（第一版实测 step2 报 `CELL_E gold=50 mine=30`，其实只是 C# 还没跑 S 阶段）。实测屏障间平均只跑 **1.01** 个调度事件（max 2，120 个屏障里只有 1 次 >1），所以这个循环约 5 行。
* **`sub[]` ↔ C# pending 是错位的**：GD 的子询问在 C# 侧常是**顶层** pending（`pick`+`r` → `PendingMutation` 引出的 `ChooseMutationDecision`；`pick`+`card` → `PendingDiscard`）。驱动器提交父动作后必须排空 C# 多出来的 pending，用 `sub[]` 按语义喂进去。喂不上 = 一条 `SUBASK_SHAPE`。

### 2.4 结果行

```json
{"table":"move_quote","fixture":"macro_on_mucus","key":"cell=1 to=(5,0)",
 "status":"MISMATCH","gd":7,"cs":6,"unit":"十分能量",
 "gd_ref":"cw_actions.gd:579 _move_cost_mod","cs_ref":"RulePolicies.cs RawMoveCost",
 "prd":{"sha":"3C367B76…","line":286,"text":"…"},
 "trace":{"gd":{"base":8},"cs":{"base":7}},
 "reachable":true}
```

`table`+`fixture`+`key` 是稳定主键（跨版本可再 diff）。`reachable:false` 标不可达差异（特征化，不是 bug）。`prd` 扩成三元组是核查后的强制项——见第 7 节。

---

## 3. 差异报告示例（要能定位到规则）

### 3.1 L0 报告

```
契约表核对：39 条一致，5 条分叉，4 条 UNDEFINED
  ✗ MISMATCH   roll_domain       攻击判定骰面值域   GD=1..6              C#=0..5
  ✗ MISMATCH   roll_domain       实际可达的判词     GD=crit,fail,success C#=fail,success
        → CellRules.cs:194/205 的 NextInt(6) ↔ RulePolicies.cs:326 判 roll==6
        → PRD 3C367B76:L?? 概率 1/3·1/2·1/6，两份 PRD 一致 → 照发工单
  ✗ MISMATCH   move_cost         immune_into_mucus  GD=7  C#=6
        trace: gd={base:8} cs={base:7}  → 差在基准价不在修饰器
        → CWData.IMMUNE_MOVE_CANCEROUS=[10,8,8,8] ↔ RulePolicies { I=>10, II=>8, _=>7 }
        → III 与 X 两档差 0.1（已知四处偏离之外的第五处）
  ○ UNDEFINED  level_min_memory  n=2                GD=0,10,30,70  C#=0,10,20,50
        → 两份 PRD 命中「2人局」均为 0 条 → 不发工单，进 Kevin 待裁清单
  ○ NOTIMPL    proliferate_chance  adj2_no_solid    GD=60‰  C#=<无此查询>
        → BoardRules.cs:97 把算式内联在 rng.NextDouble() 里，需先抽纯查询
```

**红绿模式指根因**——这是 L0 相对整局对拍最大的收益，实跑样例：

```
anaerobic/block4_one_cell      MISMATCH  gd=24  cs=30     ← 块内 1 个癌细胞
anaerobic/block9_three_cells   PASS      gd=20  cs=20     ← 块内 3 个癌细胞（撞巧）
anaerobic/sclc_warburg         MISMATCH  gd=27  cs=33     ← 24:30 各 ×1.1 上取整
anaerobic/glut1_phase2         MISMATCH  gd=32  cs=38     ← 24:30 各 +8
```
四条一摆：**一个根因——人数系数 k 缺失（issue #43，`_split_share` 里的 `anaerobic_cells_k`），瓦伯格与 GLUT1 各自的算式其实是对的**。整局对拍只会说「第 47 步能量不一样」。

⚠ `block9_three_cells` 在 k 完全缺失时照样 PASS，所以：**每条规则至少三条用例，跨越它的分段边界**（k 的 1/2/3 细胞、免疫等级 I/II/III/X、分期 1/2/3）。单条用例通过永远不能当作该规则对齐的证据。

### 3.2 L1 报告

```
2p seed=4242：40 步全程无中断，199 条原始差异 → 归并 15 组

● RNG_SPAN     ×1   step15 第 1 抽：黄金 [1,51]（51 面） vs C# [0,48]（49 面）
    └ 紧随 CELL_HAND gold=["癌症转移"] mine=["GLUT1高表达"]
    → 抽卡权重池两边差 2 → issue #41 权重 3/4/6→2/3/4 与 issue #42 新增【癌症转移】，CardRules 没跟
● OPTION_EXTRA ×38  k=action|act=pass（每个 action 询问一条）
    → DecisionRouter.cs:81 的 PassDecision 我们没有对应物 —— 38 条噪声收敛成一条结论
● CELL_MODS    ×23  step8 cell0: gold=["I型干扰素:1"] mine=[]
    → 【I型干扰素】在 CardRules.cs 没有效果分支；连报 23 步 = 该修饰一直不在
● TILE_TS      ×4   M0.setup (-2,3): gold=1 mine=0
  G_CTYPES     ×1   gold=[-1,0] mine=[-1,3]
    → 初盘：15 格初始癌组织重合 11 格、差 4 格（GD rng 随机长 ↔ MatchSetup.cs:67-88 确定性 BFS）
    → 癌种分配算法不同（GD 逐次 pick_random+erase ↔ C# 一次 Shuffle 按序发）
● RNG_NO_COUNTERPART ×64  BoardRules.cs:98 NextDouble / 11 处 Shuffle
    ⚠ 此后所有状态差异降级为「不可信」，不计为新发现
```

**四条定位线，按精度排序**：

1. **`rng` 带子的区间本身**（最精确，在结算之前报警）。「带子 `[0,126,*]`，C# 要 `(0,5)`」= 化疗选格是全盘还是邻格。
2. **`nopt` + `MISS_OPTION`**：直接点名哪条规则没生成这个动作。
3. **`sub[]` 形状**：GD 子询问 ↔ C# 顶层 pending 的错位。
4. **`post` 逐字段 diff**：`TILE_<字段>` / `CELL_<字段>` / `G_<字段>`，字段名即定位。

**归并规则**：按 `(码, 规则名)` 分组，每组只留「首次步号 + 次数 + 3 个样例」。实测 2p 199→15 组、4p 207→16 组、6p 174→10 组。**报告之间可以再 diff**——「修好 3 条、新增 1 条、11 条照旧」，这才是可执行清单该有的样子。

**差异码全集**：`OPTION_MISSING / OPTION_EXTRA / OPTION_COUNT / PICK_UNAVAILABLE / RNG_SPAN / RNG_BASE / RNG_OVERRUN / RNG_UNUSED / RNG_NO_COUNTERPART / TILE_* / CELL_* / G_* / SUBASK_SHAPE / EXEC_FAIL / EXEC_THROW / PHASE_FAIL / AVAILABLE_THROW / TAINTED / NOT_COMPARABLE`。

---

## 4. 我们这边第一步要写的东西

> 所有原型已在 scratchpad 留档，拷回仓库即可重跑。两个仓库工作树当前干净。
> 留档根：`C:\Users\fanke\AppData\Local\Temp\claude\D--Projects-SpringSense-2026-2027-Cell-War\e332144a-3ed6-48fa-8784-eedcd3006dc7\scratchpad\`

### A. `game/tests/xcheck_gen.gd` —— L0 用例生成器（279 行，已跑通）

留档 `scratchpad/xcheck_gen.gd`。`extends SceneTree`，结构：

* `const CASES := [...]` —— 用例规格（id / probe / players / world 稀疏补丁 / subject）。**规格即真相**：按它搭世界、按它跑探针、把它原样写进 JSON。
* `_build(spec)`：`CWGame.new()` → `g.tune = CWTuning.new()` → `g.init(CWData.FACTION_ORDER[n], 0)` → `g.setup.build_board()` → 打 tiles/cells 补丁 → **装载末尾重算 derived（`update_marks()`）** → 跑探针 → `g.dispose()`。**不调 `run_game()`、不消耗一次 rng。**
* `_run_probe(g, probe, subject)` 分派表，现有 6 条：

| probe | 调用 |
|---|---|
| `aerobic_income` | `g.world.aerobic_income(cell)`（`cw_world.gd:427`） |
| `anaerobic_gain` | `g.world.anaerobic_gain_for(cell)`（`cw_world.gd:956`） |
| `move_cost` | `g.actions._move_cost_mod(cell, to, g.actions._move_base_cost(cell, to))`（`cw_actions.gd:579/558`） |
| `quote_path` | `g.actions.quote_path(cell, path)`（`cw_actions.gd:133`） |
| `proliferate_chance` | `g.world.proliferate_chance(c)`（`cw_world.gd:669`） |
| `pressure_at` | `g.world.pressure_at(c)`（`cw_world.gd:1049`） |

* 落盘：`JSON.stringify(case, "  ", true)`（**sort_keys=true**）+ `xcheck/tune_default.json`。

**探针纪律（code review 专盯这一条）**：探针只许调**产品代码里已有的公开纯查询**，不许在生成器/测试里重算一遍算式。做不到就老实记 `NOTIMPL`。

**要新抽的纯查询（GD 侧）**：`erosion_candidates(fresh)`（从 `_erosion` 里抽出来）、`e_steps()`（返回有序步名表 `pressure,proliferate,erosion,anaerobic,upkeep,camp_purify,solidify,ossify,rooted,tick`）。其余（`aerobic_income` / `anaerobic_gain_for` / `proliferate_chance` / `pressure_at` / `pressure_lethal` / `quote_path` / `_split_aerobic` / `_split_share`）早就为了「界面预计收入不能抄第二份算式」拆好了，直接可用。

**⭐ 自验（不依赖 C#，必须最先做）—— round-trip self-check**：
`_build` 改成：按 spec 搭世界 → **先序列化出 case JSON** → **从这份 JSON 重新装载一个世界** → 在重载世界上跑探针 → 断言两次探针结果逐位相同，不同即**拒绝落盘**。这条能一次性杀掉「只进世界、不进文件」的状态（`effector_round` 就是这么漏的）。**在这条落地之前，不要把用例集扩到 E 阶段分步和 `--harvest`**——那正是假设失效的区域。

### B. `game/tests/xcheck_export.gd` + `xcheck_bridge.gd` + `xcheck_tape.gd` —— L1 轨迹录制（284 行，已跑通）

留档 `scratchpad/gd/`。三个文件都**无 `class_name`**，不进 `global_script_class_cache.cfg`、不用 `--import`、不动热更基线。

* `xcheck_tape.gd`（50 行）：rng 鸭子替身。`randi_range(from,to)` 在 `from==to` 时直接返回不消耗；录音模式追加 `[from,to,v]`；**放音模式念带子的同时照样调一次内部 `randi_range`**（因为 `heuristic_bridge.gd:334` 会偷看 `rng.state`）。`take()` 返回自上次以来那一段。
* `xcheck_bridge.gd`（65 行，`extends CWBridge`）：**必须单独成文件**——测试脚本里内部类不能 extends 全局类（`Could not resolve super class inheritance`）。`static func key(req, data)` 是**语义键的唯一定义处**；`ask()` 把选项键排序后用一条与引擎无关的 LCG 挑一个（按排序后的键挑，所以我们自己改选项生成次序也不会整串错位）。
  **绝对不能用 `CWHeuristicBridge`（读 `rng.state`）或 `CWMonteCarloBridge`（写 `image.rng.seed`）。**
* `xcheck_export.gd`（169 行，`extends SceneTree`）：`static func canon(g)` 是**规范化状态的唯一定义处**；驱动循环 `await g.pending()` → 策略选下标 → `await g.step(idx)` → 收 `bridge.take()` 与 `tape.take()` → 落一行。**顶层不走 `game.ask()`**，所以桥只会收到子询问——顶层/子询问自动分流，不用改引擎一行。

**待补（核查后新增）**：`canon()` 的 `g` 块补 13 字段、`cells` 补 `death_round`、`board` 补 `slock`、`mods` 导九元组（见 2.2）。

**自验（不依赖 C#）**：同一条命令跑两遍，JSONL **逐字节相同**（已验：591,259 字节）。

### C. `tools/xcheck_gen.sh` / `tools/xcheck_report.py`

```bash
# xcheck_gen.sh
GODOT="${GODOT:-D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe}"
cd "$(dirname "$0")/.."
timeout -k 5 180 "$GODOT" --headless --path game --script res://tests/xcheck_gen.gd -- --out ../xcheck/cases
rsync -a --delete xcheck/cases/ "../cellwar-next/tests/CellWar.Core.Tests/xcheck/cases/"
cp xcheck/tune_default.json "../cellwar-next/tests/CellWar.Core.Tests/xcheck/"
```

`xcheck_report.py`：`results.jsonl` → `DIFF.md`（按子系统分组、五档状态、与上次对比出「新红/已修/回归」、NOTIMPL 单调闸）。

**两个已知坑**：① `--script` 模式下 `_initialize` 里抛运行时错误不会退出，SceneTree **永远空转** → 所有导出器必须 `timeout -k 5 180` 兜着跑。② 首次无头启动要导入资源（约 90 秒），之后走缓存 0.5 秒；CI 第一次别当成挂死。

### D. `game/tests/` 里的两条护栏测试（必须有）

1. ✅ **rng 可替换性**（2026-09-16 `t_xcheck`）：真装 `xcheck_tape.gd` 的替身进去掷一次骰，断言带子上多一条；改回静态类型当场 SCRIPT ERROR。
2. ✅ **语义键映射钉死**（同一条测试）：8 个样例与 C# `SemanticKeyTests` 同组；另钉桥的「去重 → 排序 → LCG、同键取第一条」。

### E. `xcheck/COVERAGE.md`

按 PRD 章节 + 68 张卡 + 9 个种类技能列全表，每格标 `已打靶 / NOTIMPL / UNDEFINED / 未写用例`。**这张表才是「C# 到底差什么」的权威答案**，不是 NOTIMPL 的条数。

### 命令（实测）

```bash
# L0 生成
cd "D:/Projects/SpringSense/2026-2027/Cell War/Cell-War"
"D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe" \
  --headless --path game --script res://tests/xcheck_gen.gd -- --out ../xcheck/cases
# → 共 23 个用例，零 SCRIPT ERROR

# L1 录制
"D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe" \
  --headless --path game --script res://tests/xcheck_export.gd -- \
  players=2 seed=4242 out=<abs>/trace_2p_4242.jsonl steps=40
# steps=0 跑到终局。注意 Godot 可执行文件在 Godot_v4.5-stable_win64.exe/ 这个目录里
```

---

## 5. 给队友的一段话（可直接转发）

> **Cell War 双内核对拍 —— C# 侧需求单（2026-09-15）**
>
> 我们把对拍做成三层：L0 是「同一条规则两边各算出什么数」的靶场（**你们生产代码零改动就能跑起前几条探针**），L1 是「同一个真实局面 + 同一个动作，两边演化成什么」的单步重放。L2 整局等价闸门放到阶段 1。我这边的两个导出器和 C# 侧的两个壳子都已经真编真跑过，代码可以直接拿走。
>
> **P0 · 三条现成 bug，不依赖任何协议对齐，建议今天就修**
>
> 1. **攻击掷骰越界，暴击永远打不出来。** `CellRules.cs:194` 与 `:205` 的 `rng.NextInt(6)` 产出 0..5，而 `RulePolicies.cs:326-327` 的 `AttackOutcome` 判 `roll == 6 ? crit : roll <= 2 ? fail`。实测 60000 次：fail 50.2% / success 49.8% / **crit 0%**（应为 33.3 / 50.0 / 16.7）。带【免疫突触成熟】那条分支同理（`roll >= 5` 只剩 5 一个面、`roll == 1` 漏了 0）。改 `NextInt(6)+1` 或把 `AttackOutcome` 整体改成 0 基。**改完请补一条骰面值域断言，别只补结果断言**——我们这边就是靠值域表才抓到它的，光比判定函数是 16/16 全绿。两份 PRD 的 1/3·1/2·1/6 完全一致，这条没有歧义。
> 2. **`WithOccupyingCell` 静默丢两个字段。** `WorldStateExtensions.cs:18` 手写了一份初始化器，漏掉 `SolidLockRound` 和 `ToxinRound`（同文件 `CopyTissue` 有这两项）。实测：一格 `Toxin=7 SolidLock=3`，放进一个细胞之后变成 `Toxin=0 SolidLock=0`。这不只是 fixture 问题——**线上任何一次细胞进出格都在清【TNF-α局部炎症】的锁和【细胞毒素】的格记录**。改成走 `CopyTissue`。
> 3. **`IDeterministicRng` 的注入在执行层无效。** `Runtime.cs:77-78` 每一步现场 `new Xoshiro256StarStar(1)` 再 `SetState`，`Runtime.cs:164` 的 `Fork()` 同样硬写；构造函数收下的那个实例只在 `Runtime.cs:37-41` 被调过一次 `GetState()`。实测注入计数实现跑到第 6 世界回合：`Draws=0 GetState=1`，96 次消耗全出自硬写死的那个。**这条对对拍不阻塞**（对拍走 `BasicRulesEngine` 的纯函数面，rng 是入参），但路线 A 的生产内核必须改成持有工厂。
>
> **P1 · 带子对齐要的两条抽法口径改造（L1 的硬前置）**
>
> 我们这边的随机数全是 Godot `randi_range` 的整数闭区间抽取，没有浮点抽取、没有 Shuffle。要让 C# 能念我们录的带子，抽法形状必须对齐：
>
> 4. `BoardRules.cs:98` 的 `rng.NextDouble() < adjacent.Length * rate` → `rng.NextIntRange(1, 1001) <= 千分数`（对齐 `cw_world.gd:618`）。**这条是「先改」不是「要改」**：E 阶段 100% 走 `NextDouble`、实测每回合 27 次，不改的话任何跨 E 阶段的对拍整段是废的——而 E 阶段正是平衡的大头。
> 5. 11 处 `rng.Shuffle(xs).Take(k)` / `Choose` → 改成逐次 `RemoveAt(NextInt(remaining))` 取 k 个（= 我们的 `CWGame.pick_random`，`cw_game.gd:837`）。命中点：`BoardRules.cs:111/166`、`CardRules.cs:78/104/287/312`、`CellRules.cs:242`、`SkillRules.cs:104/137/155`、`MatchSetup.cs:41`。Shuffle 消耗 n−1 抽、取法也不同。
> 6. **退化区间零消耗**：`NextInt(1)` / `NextIntRange(n, n+1)` 一律不消耗随机数。Godot 的 `randi_range(n,n)` 实测消耗 0（2 人局 515 次调用只推进 485 步 PCG）。不这么定义，带子从第一个单选项处就错位。
>
> **P2 · 把内联算式抽成纯查询（L0 扩表的前提，每条都是不改行为的小重构）**
>
> | 要什么 | 现在在哪 | 建议签名 |
> |---|---|---|
> | 增生千分率 | `BoardRules.cs:97` 内联 | `int ProliferateChance(WorldState, HexPosition)`，**返回整数千分率** |
> | 侵蚀候选集 | `BoardRules.cs:103-112` 内联 | `IReadOnlyList<HexPosition> ErosionCandidates(...)` + `int ErosionCount(int stage, int roll)` |
> | 微环境压迫 | `BoardRules.cs:80-84` 内联 | `int PressureLoss(WorldState, Cell)` |
> | 根深蒂固目标集 | `BoardRules.cs:145-155` 内联 | `IReadOnlyList<HexPosition> RootedTargets(...)` + `int RootedLimit(int stage)` |
>
> 另：`BoardRules.EvolveEndOfRound` 拆成具名步骤 + `IReadOnlyList<string> EStepOrder()`（行为不变，`EvolveEndOfRound` 改成按表调一遍）；`Settlement.ApplyValue` 加一个输出 `List<(string Name, int Before, int After)>` 的重载——没有它，「修饰器叠加顺序」那一族只能比最终数字。
>
> ⚠ **探针纪律**：`Run` 里只许转发到生产代码路径，不许在测试里照抄一遍算式。`proliferate_chance` 现在只能写 `=> null`（记 NOTIMPL），正是因为算式内联在 `BoardRules.cs:97`——在测试里抄那行就等于自欺，靶打在测试自己身上，永远全绿。
>
> **P3 · L1 要的两个入口**
>
> 7. **公开 `PagedMap` 的 JSON converter**，或提供 `public static WorldState FromJson(string)`。现状：外部程序集 `JsonSerializer.Deserialize<WorldState>(stateJson)` 抛 `JsonException: could not be converted to PagedMap<HexPosition,Tissue>`，因为 `MapConverterFactory` 埋在 `internal static class CheckpointCodec` 里。变通办法是把对拍工具伪装成 `CellWar.Core.Tests`（蹭 `CellWar.Core.csproj:10` 的 `InternalsVisibleTo`，能跑），但那把工具钉死在测试程序集身份上。
> 8. **加一个钳位入口**：`public static MatchSession Clamp(WorldState world, Func<RngState, IDeterministicRng> rng)` —— 灌世界后**就地重入 `RuleFlow.Continue`**（生成 C# 自己的 `Input`）而**不推进阶段**。约 10 行。没有它，L1 只能走 `BasicRulesEngine` 的纯函数面，验的是规则函数而不是运行时/调度器——而路线 A 要发给玩家的权威内核是整个 `MatchSession`。**这一条决定 L1 的结论覆不覆盖调度层。**
>
> **不需要你们做的**
>
> * **不要为了对拍去改选项顺序。** 协议按语义匹配、不认下标——正是为了让 `DecisionRouter.Available` 的枚举顺序（以及 `Tiles(s)` 走 `PagedMap` 迭代序这件事）可以自由演进。
> * **不需要改 `MatchSession.Restore` 的签名**，也不需要改 `CheckpointCodec.cs:92` 的 xoshiro 校验——对拍不走 Checkpoint 这条路（原因见我们的规格第 7 节）。
>
> **要先一起定的两件事（不定就会互相发错工单）**
>
> 9. **PRD 版本。** 两仓各持一份，已分叉：正本 `Cell_War_玩法PRD.md` sha256 `3C367B76…`（1700 行），你们 `cellwar-next/docs/` 那份 `52D0EB0B…`（1678 行，冻结在 09-12，与你们 `PRD版本记录.md` 登记的哈希逐位相同）。去空白 diff 48 行，把我们的 124 条活锚点打到你们那份上**失配 8 条**，而且分歧正好落在争议规则上：`ANAEROBIC_CELLS_K`（issue #43 的 k）、`ANAEROBIC_BLOCK_COEF(_BY_PLAYERS)`、`ANAEROBIC_BLOCK_EXP_BY_PLAYERS`、整套【I-趋化源】的 `CHEMO_COST/CHEMO_FULL_TURNS/CHEMO_COOLDOWN_ROUNDS`。**所以我们之前说的「已确认四处规则偏离」，至少三处要改判为「PRD 未同步」，我不会把它们当成 C# bug 发给你们。** 做法：约定唯一正本路径 + 哈希，两仓各留一个 `prd.sha256` 并进 CI；差异行的 `prd` 字段扩成 `{sha, line, text}`。
> 10. **`UNDEFINED` 这一档要 Kevin 裁。** 两份 PRD 都无明文的：全部 2 人局数值（两份 PRD 命中「2人局」均为 0 条）、负数半值舍入方向、骰面值域（PRD 只给概率）、11 个特殊格坐标（PRD 只给个数）。典型例：抗原记忆门槛 2 人局 —— 我们 `cw_data.gd:231/243` 走缺省档 `[0,10,30,70]`，你们 `CellRules.cs:51-52` 是 `Count == 6 ? 70/30 : 50/20` 即 2 人走 50/20。**这条我不发工单**，因为 `cw_data.gd` 自己的注释倾向于 2 人门槛该更低，你们那一侧未必是错的。
>
> 另外更正两条我们之前说错的：①「C# 只有约 37 张卡有效果分支」是旧数——实测 `CardRules.cs:19` 的 Registry 有 48 键，另 19 张被动走 `PhaseRules.cs:67 GrantTurnModifiers`，`Cards.cs:143` 自报 67/67 且 `CardTests.cs:127` 有测试钉死；而且你们能把 4/6/2 人局都跑到分出胜负不抛异常（1081 / 1133 / 17 次决策）。②「GD 的攻击是独立顶层行动」是错的——攻击在**两边都折在 move 里**（`cw_actions.gd:_do_move` 第 786 行起）。麻烦帮忙复核一遍我们的语义键映射表，同类错误可能还有。

---

## 6. 被核查推翻的假设（诚实栏）

**这些不是理论顾虑，是本轮真编真跑证伪的。忽略任一条都会让对拍产出假清单。**

### 6.1 「Mode B 可以靠 `MatchSession.Restore(投影出来的 Checkpoint)` 落地」——**不成立**

依据「手改 checkpoint JSON（`WorldRound` 1→9）再 Restore 被接受」得出的结论，被更硬的两条实测推翻：

* **决策屏障处 C# 的事件队列恒空**。`MatchSession.Start(4,4242)` 连采 60 个屏障：`Future/Immediate 非空 = 0/60`，`Input present = 60/60`。即在「该谁作答」这个点上，C# 的**全部流程位置就是 `Input.Options` 本身**，没有第二个容器可投影。而规范化状态按协议明确排除 `flow` 与 `_pending` ⇒ 投影器**天然产不出这一块**。
* 把 Input 与队列清空（这正是「规范化状态 → Checkpoint」的真实形状）后，`CheckpointCodec.Decode` **接受**，但会话永久死亡。

**替代方案**：走 `BasicRulesEngine` 纯函数面（`BasicRulesEngine.cs:8-28`，三个入口全 public、无宿主依赖）。实测 `MatchSetup.Create(4,4242)` → `GetAvailableDecisions` 直接返回 112 个选项，`ExecuteDecision(opts[0])` 成功、seat 0→1。**完全不需要 MatchSession / Checkpoint / Restore。**

**代价（必须写进结论）**：这么做验的是 C# 的**规则函数**，不是它的**运行时/调度器**。而路线 A 要发给玩家的权威内核是整个 `MatchSession`（含 Runtime、事件队列、Checkpoint/Fork/回滚）。⇒ **L1 产出的差异清单不覆盖调度层**，除非队友加上第 5 节第 8 条的 `Clamp` 入口。

另外两笔账：`ExecuteDecision` 单独调**会卡死**（纯函数走完四次 Place 后 `phase=S / seat=0`，此时 `GetAvailableDecisions` 给不出 `EndTurn`，阶段推进只由调度器的 `AdvancePhase` 做），驱动器必须自己复刻 `RuleFlow.Continue`（`RuleHandlers.cs:43-49`，约 5 行）；外部程序集反序列化不出 `WorldState`（见第 5 节第 7 条）。

### 6.2 「三个函数纯 + 黄金状态足以重建 WorldState」——**前半句成立，后半句不成立**

* **(a) 纯函数**：证伪失败，判成立。规则文件对 `SimulationState` / `Simulation.` / `.Tick` / `Outbox` / `NextSequence` / `Immediate` / `Future` 的引用数 = 0。**可以放心依赖**：harness 不用 MatchSession/Runtime/Checkpoint 这条路线本身是对的，Events 丢掉不丢语义。
* **(b) 黄金状态足以重建**：**不成立**。canon 缺 15 个字段（`g` 块 13 项 + `cells.death_round` + `board.slock`），`ask.kind` 推不出 `StartStep` 也推不出 pending 种类。且 `mods` 只导 `{卡名: 剩余次数}` 是不够的——移动费用/伤害这类最该对的数会是拿伪造修饰算出来的。**修法见 2.2。**
* **M1 自证要改写法**：原写法「`FromCanon(Canon(w))` 与 `w` 逐字段相等」若那个「逐字段」只覆盖 canon 字段，它在缺失的 15 个字段上**必然空过、给出虚假通过**。正确形式：C# 侧取一个真实推进过的 `w`，做 `w → Canon → FromCanon → w'`，比 `Save().Json` **全量**；差异字段清单就是必须补进 canon 的清单。**这道自证要在 harness 写第二行代码之前先跑。**

### 6.3 「用例直接赋值搭出来的世界，对两个内核都是合法世界」——**不成立，且失败是静默的**

四处反例，三处静默：

1. **C# loader 自己就在静默丢字段**：`WithOccupyingCell`（`WorldStateExtensions.cs:18`）漏 `SolidLockRound` / `ToxinRound`，而 `toxin_round` 就在 `TileFields` 白名单里。实测「赋值后 `Toxin=7 SolidLock=3` → 回填 OccupyingCell 后 `Toxin=0 SolidLock=0`」。**凡是格上有细胞的 tile，用例写的 toxin_round 一律被清零——而「格上有细胞」恰恰是这两个字段唯一起作用的场合。**
2. **GD 侧 `marked` 是派生值**：`cw_game.gd:1072 update_marks()` 在六处被调，是每次状态变动后重建的光环派生值。实测装载态 `marked=[false,false,false,false]`，跑一次 `update_marks()` → `[true,true,true,false]` ⇒ **含树突的用例装出来是引擎永远到不了的盘面**。
3. **席位↔细胞绑定被 loader 硬编码**：C# loader 里写死 `CancerType = CellType.Melanoma`；现有 `anaerobic/block9_three_cells` 用例今天就该被这条挡下。
4. **「只进世界、不进文件」的状态**（`effector_round`）污染的是权威侧的金标准本身。

**修法（按优先级）**：① round-trip self-check（第 4 节 A 项，**最先做**，是唯一能把这类静默失败变成可见失败的通用机制）；② C# 侧 `Load` 之后按白名单反读一遍逐字段比对，不等即 `BADFIXTURE`；③ `players_meta` 进 schema；④ derived 字段末尾重算而不是纯赋值。**在 ① 落地之前，`COVERAGE.md` 里把「含树突的用例」「含 toxin_round / solid_lock 的用例」标成暂不可写。**

### 6.4 「PRD 是双方共同的、可仲裁的权威」——**两个合取项今天都不成立**

* **「共同」不成立**：两份 PRD 分叉 48 行，8 条锚点失配，分歧正落在争议规则上（详见第 5 节第 9 条）。
* **「对每条规则有明文」不成立**：2 人局数值在两份 PRD 里命中「2人局」均为 **0 条**；骰面值域、负数舍入、特殊格坐标、派生几何均无明文。**真实锚定率是 73%（不是 89%），非常量规则事实为 0%。**
* `tools/prd_crosscheck.py` 有解析盲区：不认 `const X: Array[int] = […]`（`=` 而非 `:=`）这一形，10 条锚点是死的——补上后 `PRESSURE_MUL_BY_STAGE` 会立刻报红（PRD 那句多了个 `}`）；`static func`（`is_world_event_round` / `level_min_memory` / `anaerobic_cells_k`）也没纳入扫描。
* **「MAP 锚点可一行不改地也指向 C#」不成立**：脚本的 `DATA` 写死 `cw_data.gd` 且按 GDScript 语法解析，指向 C# 要重写解析层。
* **别新建表**：扩 `cellwar-next/docs/requirements/PRD对齐矩阵.md`（已有 77 行、五档图例、章程声明）。另起一份会立刻变成第三份分叉文本。
* ~~**`equip_seq` 那条工单要反向或删除**：PRD:157 明写「与打出的先后无关」，该改的是 GD 不是 C#。~~
  🔴 **这条撤销（2026-09-15 晚）—— 我读错了 PRD，而且方向正好读反。**
  PRD:157 那句是「**阶段**由效果的**类别**决定，与打出的先后无关」，说的是**归哪个阶段**，
  不是同阶段内部怎么排。而 PRD:182-184 紧接着写明：
  > 同一阶段内有多个效果时，先按**来源层级**（细胞自带被动 → 卡牌 → 技能 → 世界事件），
  > **同层级再按「打出/装备的先后顺序」。**
  ⇒ **`equip_seq` 是 PRD 明文要求的，GD 是对的，缺的是 C#。** 照原工单改会把唯一正确的一侧改坏。

### 6.5 其余限制（没被推翻，但必须公开）

| 限制 | 后果 | 缓解 |
|---|---|---|
| **L0 全绿 ≠ 两内核等价** | 采样论证不是证明。实例：`anaerobic/block9_three_cells` 在 k 完全缺失时照样 PASS | 每条规则至少三条用例跨分段边界 + `--harvest` 灌真实局面 |
| **L0 不验掷骰次序** | 每条算式全绿仍可能一上线就分叉 | 只能靠 L1 的带子；两件事并行但不互相替代 |
| **L0 碰不到流程编排** | `_pending` 优先级 ↔ `DecisionRouter.cs:14-21`（PendingDiscard → PendingMutation 优先于一切）、回合/阶段转换查不到 | 单列在阶段 1 待办，不假装覆盖了 |
| **L0 漏「单条都对、组合不对」** | 最典型是修饰器结算顺序：GD 有 `equip_seq` + `mods[*].seq`，C# 的 `ActiveModifier.Sequence` **永久技能没有戳** | 只能靠人工设计的多修饰夹具 |
| **覆盖率靠运气** | LCG 随机策略：2p 40 步只碰到 `setup_place` 与 `action`，`revive`/`free_move`/`pick`/`pick_cell`/`pick_tile`/`chemo_target`/`immune_revive` **七类询问一次都没走到**（占询问总数约 10%）；2p seed=4242 policy=9 只跑 19 步就结束了 | 多种子批扫 + **有向采样**（按「这一步是否用到还没对过的规则」加权）+ 覆盖率报表 |
| **宽松模式有麻醉作用** | 一条 `RNG_SHAPE` 之后的所有状态差异都不再可信 | 报告必须把 `RNG_SHAPE` 之后的差异**降级标注**，否则会被当成新发现去查 |
| **轨迹体积** | 全量状态每步 14.8 KB，6 人局跑满约 13 MB/条；3 人数 × 20 种子 ≈ 800 MB | 上 delta 编码（只记变了的 tile/cell），预计压到 5% 以内；**不进 git** |
| **双向维护成本** | 旋钮一改（`tune_default.json` 变）或我们改规则，全部用例要重生成，队友那边可能整片变红——而那多半是**我们**动了规则 | 「重生成用例」绑进我们改规则的提交（与开发日志同提交的老规矩一致）；`DIFF.md` 必须显示与上次的对比而不只是当前快照 |
| **`NOTIMPL` 会变成垃圾桶** | 缺口不红是优点，但 C# 可以靠「一直不实现」维持绿灯 | NOTIMPL 单调收敛闸 + `COVERAGE.md` 全表 + 出口条件写「NOTIMPL 清零」 |
| **仓库卫生** | 0239b48 把临时探针 `game/tests/_probe_contract_export.gd` 扫进了仓库（与 c14aa60「撤掉误提交的临时探针」同一个毛病）；仓库里还有并行产生的 `xcheck_*.gd`（`xcheck_tape.gd` 与另一份 TapeRng 几乎重复） | 落地前先合并，**别出现两套带子实现**；探针要么删要么转正成 `tools/` 下的正式工具 |
| **`var rng: Object` 的产品代价** | 19 个 `randi_range` 调用点永久失去静态类型检查 | 我们保留它（L1 需要），但必须配护栏测试（第 4 节 D-1）。若 Kevin 决定只做 L0，这条可以回滚 |

---

## 7. 分步落地

每步都可独立验证，不依赖下一步。**M-1 和 M0 不依赖队友做任何事。**

| 里程碑 | 做什么 | 产出物 | 验证方式（自验，不依赖对方） | 工期 |
|---|---|---|---|---|
| **M-1** 卫生与前置 | ① 队友修 P0 三条 bug；② 钉 PRD 正本哈希 + 两仓 `prd.sha256` 进 CI；③ 修 `prd_crosscheck.py` 的两处解析盲区；④ 合并仓库里重复的 `xcheck_*.gd`、清掉误提交探针 | `prd.sha256` × 2、`UNDEFINED` 待裁清单 v1 | `python tools/prd_crosscheck.py` 跑通且锚点数上升；`git status` 干净 | **0.5 天**（我们）+ **0.5 天**（队友） |
| **M0** L0 靶场上线 | 生成器落位 `game/tests/xcheck_gen.gd` + **round-trip self-check** + `tools/xcheck_gen.sh` + `xcheck_report.py` + `COVERAGE.md` 骨架；C# 侧测试壳落位 `tests/CellWar.Core.Tests/XCheck/XCheckTests.cs`（已写好，`scratchpad/XCheckTests.cs`） | 23 条用例 + `results.jsonl` + `DIFF.md` 第一版 | **GD 侧**：round-trip 自检全过，跑两遍输出逐字节相同。**C# 侧**：`Load` 反读自检全过、`BADFIXTURE=0`。整条流水线 **1.2 秒** | **1 天**（我们）+ **0.5 天**（队友） |
| **M1** L0 扩表 | 扩到 40~60 张表（选题照抄 `prd_crosscheck.py` 的 146 条 MAP 锚点）；每条规则三条边界用例；`--harvest` 模式（~40 行，**必须用固定脚本桥**）；队友做 P2 四处纯查询抽取 + E 阶段拆具名步 + `ApplyValue` trace 重载 | 核心数值子系统（收入/费用/压迫/增生/侵蚀/固化/攻击）完整红绿表 | `MISMATCH` 列表每条能一句话写成工单；`NOTIMPL` 单调下降；`COVERAGE.md` 核心区无「未写用例」 | **2 天**（我们）+ **1.5 天**（队友） |
| **M2** L1 自证 | **先跑 `w → Canon → FromCanon → w'` 比 `Save().Json` 全量**，拿差异字段清单去补 canon；补 15 个字段 + `mods` 九元组；队友做 P1 三条 RNG 口径改造 | 往返自证测试（红→绿）、canon v2 | 往返自证逐字节相同才算过。**这一步不过，后面全是假清单** | **1 天**（我们）+ **0.5 天**（队友） |
| **M3** L1 教师强制重放 | 录制器收口（delta 编码、`ruleset` 指纹、七类未覆盖询问、粘性 TAINTED）；C# 重放器收口（`scratchpad/xcheck/` 已有 370 行可用版）；差异聚合与覆盖率报表 | 2p/4p/6p 各一条完整轨迹 + 聚合差异清单 | 轨迹跑两遍逐字节相同；`BADFIXTURE=0`；`RNG_NO_COUNTERPART=0`（P1 做完就该归零）；归并后每组能指到一条规则 | **1.5 天**（我们）+ **0.5 天**（队友） |
| **M4** 批扫归档 | 3 人数 × 20 种子 × 有向采样；清单分级（BLOCKING / KNOWN_GAP / UNDEFINED / CONVENTION）；转成 issue 列表 | `DIFF.md` 正式版 + `COVERAGE.md` 全表 + issue 列表 | 与 M3 的报告再 diff，能读出「修好 N 条 / 新增 M 条 / 照旧 K 条」 | **1 天** |
| **阶段 1** | `Clamp` 入口 → L1 覆盖调度层；L2 终局比对闸门；选项顺序/按语义提交的线上协议 | — | — | 另算 |

**合计到「能交出完整差异清单」：我们约 6.5 人天，队友约 3.5 人天，可并行。**

**关键节奏**：M0 结束（第 1.5 天）就有一条会红会绿、1.2 秒跑完的流水线在跑——**不必等用例写全才有产出**，每加一条用例就多一行可执行清单。这是它相对整局对拍最实际的优势：整局对拍要等三个死结全解开才能看见第一个有意义的结果。

**不在这个工期里的**：C# 内核**真正对齐**规则（七项缺失状态维度、`events` 容器、修饰器先后戳），那是另一个量级，也正是这份清单要拿去排期的东西。

> 🔴 **更正（2026-09-15 晚）**：这里原来写「补上 `events` 容器是把 L1 有效覆盖率
> **从约一半提到八成**的唯一杠杆」——**那个数字站不住，而且优先级判断也错了。**
>
> 实测：**世界事件今天默认是关的**（`cw_tuning.gd:330` `world_events_on := false`，
> `cw_world_fx.gd:121` 最外层直接 return），而且 **PRD 自己写着两遍**
> 「暂时停止维护，正常平衡性测试和对局不考虑世界事件」（PRD:59、PRD:1597）。
> ⇒ 照默认旋钮录的 L1 带子里，**15 个世界事件一次都不会触发** ——
> 补上它们对 L1 覆盖率的提升是 **0**，不是「一半到八成」。
>
> **但要分清两件事，别矫枉过正**：
> * **15 个事件的内容**可以延后 —— PRD 都说不维护了。
> * **容器本身仍是硬前置**：它是 §批 5 那 430 条断言的三件前置之一（见本文批次表），
>   因为 `mods` 的 canon 形状要它才定得下来；而且容器里今天**真正会动的有三张卡**
>   （【基质稳定】【TGF-β释放】【TNF-α局部炎症】，`cw_card_fx.gd:113/119/1031`），
>   它们**不受那个开关影响**。
>
> C# 今天用三个专用标量顶着那三张卡（`TurnState.TgfStacks` / `PausedDecayRound` /
> `Tissue.SolidLockRound`），所以**现行行为是覆盖到的** —— 欠的是通用容器，不是功能。
