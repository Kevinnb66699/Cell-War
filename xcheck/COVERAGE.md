# xcheck/COVERAGE.md —— 「C# 到底差什么」的权威答案

> 数字段由 `python tools/xcheck_report.py --write` 刷新（口径写死在脚本里，见 `docs/对拍规格_CWX.md` §4.C）。
> 文字段人工维护。**没有「未分类」这一档** —— 每条要么 `OK` / `NOTIMPL` / `KNOWN_GAP` / `UNDEFINED` / `OUT_OF_SCOPE` 之一。
> 完工定义（测试迁移规格 §0.2）：`xcheck/COUNT` 的 `covered_sites` ≥ core 候选集的 **85%**。

## 一、计数（2026-09-19 实测，`xcheck/COUNT`）

| 量 | 值 | 口径 |
|---|---|---|
| `total_sites` | 3330 | `headless_test.gd` 全部 `check()` 站点（当次 `grep -c 'check('` 3332，差恰好 2） |
| `total_funcs` | 247 | 带断言的函数 |
| `core_sites` | **1114** | `FUNC_SUBSYSTEM` 判成 `core` 的那一档 = **分母** |
| `core_funcs` | 99 | |
| `core_addressable` | 1094 | core 里能被 `covers` 指到的不同名字（20 个站点断言名为空或同函数内重名 ⇒ 覆盖率天花板 98.2%） |
| `covered_sites` | 0 | **分子**：`covers` ∩ 真实 check 名。`covers` 的**内容**是步 15 之后单独一次提交的活（§0.6.5 第 6 条），本次只建键，从 0 起算、只会往上走 |
| `unclassified_sites` | 0 | 落不进任何一条分类规则的站点，**不许当 0 用，要回去加规则** |

子系统分布（迁移计划 §二点五 去向表的今日实测）：
`ui 1130` / `core 1114` / `net 486` / `guide 233` / `testinfra 181` / `ai 87` / `patch 72` / `persist 27`。

分类口径按 §0.6.5 第 6 条点名：`t_skill_fx` / `t_erosion_fx` / `t_prd_online_0907` 归 **core**；
`t_effector_fx` / `t_attack_fx` / `t_spread_fx` / `t_teleport_fx` / `t_dice` / `t_human_ask` / `t_card_fx_hooks` 归 **ui**。

## 二、契约面逐 op（`game/tests/contract_ops.json`，44 行）

`status` 五档；`cases` 三值：`required`（两侧分派已活，启动断言强制 ≥1 用例 + 每个 `boundaries` 档 ≥1 条）/
`deferred`（已登记、该批未开工，分派表里放空壳）/ `none`（挂档，必须零用例）。
**分派集合 P 12 / S 25**（`status ∈ {OK, KNOWN_GAP, UNDEFINED}` 的行），录制代理覆写 **24** 条（S 里 `rec != "manual"`）。
「用例数」= `game/tests/l0/*.json` 今天的条数，括号里是 `stress_keys.json` 贡献的。

### P 族 · 16 条（分派 12 = 8 真 + 4 空壳）

| op | status | cases | 用例数 | 落点（GD ↔ C#） | 空档 / 备注 |
|---|---|---|---|---|---|
| `move_cost` | OK | required | 11 (+1) | `_move_cost_mod`+`_move_base_cost` ↔ `QuoteMove` | 10 个边界档全满 |
| `anaerobic_share` | OK | required | 4 | `anaerobic_gain_for` ↔ `AnaerobicShare` | 4 档 |
| `aerobic_share` | OK | required | 1 (+2) | `aerobic_income` ↔ `AerobicShare` | **只覆盖 `level:I`**，其余等级档空 |
| `pressure_at` | OK | required | 7 (+1) | `pressure_at` ↔ `PressureAt` | 7 档 |
| `proliferate_chance` | OK | required | 1 (+1) | `proliferate_chance` ↔ `ProliferateChance` | **只一条**，分档边界空 |
| `solidify_threshold` | OK | required | 3 (+2) | `CWGame.solidify_threshold` ↔ `BoardRules.SolidifyThreshold` | 3 档 |
| `overload_loss` | OK | required | 10 | `overload_loss` ↔ `OverloadLoss` | 5 档 |
| `attack_outcome` | OK | required | 8 (+1) | `attack_outcome` ↔ `AttackOutcome` | 6 档 |
| `move_raw_cost` | OK | deferred | 0 | `_one_step_base` ↔ `RulePolicies.RawMoveCost` | **空壳**，批 1 |
| `quote_path` | OK | deferred | 0 | `quote_path` ↔ `RulePolicies.QuotePath` | **空壳**，批 1，第一个 `tree` |
| `pass_through_cost` | OK | deferred | 0 | `pass_through_map` ↔ `RulePolicies.PassThroughMap` | **空壳**，批 1（09-19 两端边界已合上：借道累计 raw、修饰只在落点跑一遍） |
| `const` | OK | required | 32 | 两侧各一张 40 键表（`l0_runner.gd:_build_consts` ↔ `Probes.cs:ConstTable`，19 真 + 21 抛「无对应物」） | 批 0（09-19）：`batch0/const_data.json` 28 + `const_card.json` 4；三档 cw_data 28 / cw_card_data 4 / 静态函数 20 |
| `move_legal` | OK | deferred | 0 | `_is_move_legal_now` ↔ `CellRules.MoveLegal` | **空壳**，探针面随批 1 定（09-19 Kevin 接受 §0.6.7，入口已开） |
| `anaerobic_pool` | OK | deferred | 0 | `_anaerobic_pool` ↔ `RulePolicies.AnaerobicPool` | **空壳**，批 2（入口已从 AnaerobicShare 拆出，返回 double） |
| `split_share` | OK | deferred | 0 | `_split_share` ↔ `RulePolicies.SplitShare` | **空壳**，批 2 |
| `settle_loss` | OK | required | 4 | `CWGame.settle_loss` ↔ `Settlement.SettleLoss` | 批 0（09-19）：`batch0/settle_loss.json`，四档各一条（t_hit_order 开头 4 条） |

### S 族 · E 阶段 18 条（全部 OK · deferred，分派里是真步）

| op | status | cases | 用例数 | 落点（GD ↔ C#） | 空档 / 备注 |
|---|---|---|---|---|---|
| `anaerobic` | OK | deferred | 0 | `cw_world.gd:_anaerobic` ↔ `BoardRules.Anaerobic` | 批 3 |
| `cancer_upkeep` | OK | deferred | 0 | `_cancer_upkeep` ↔ `BoardRules.CancerUpkeep` | 批 3 |
| `pressure` | OK | deferred | 0 | `_pressure` ↔ `BoardRules.Pressure` | 批 3 |
| `proliferate` | OK | deferred | 0 | `_proliferate` ↔ `BoardRules.Proliferate` | 批 3 |
| `erosion` | OK | deferred | 0 | `_erosion` ↔ `BoardRules.Erosion` | 批 3 |
| `resolve_camping` | OK | deferred | 0 | `_resolve_camping` ↔ `BoardRules.ResolveCamping` | 批 3 |
| `solidify` | OK | deferred | 0 | `_solidify` ↔ `BoardRules.Solidify` | 批 3 |
| `rooted` | OK | deferred | 0 | `_rooted` ↔ `BoardRules.Rooted` | 批 3 |
| `ossify` | OK | deferred | 0 | `_ossify` ↔ `BoardRules.Ossify` | 批 3 |
| `decay` | OK | deferred | 0 | `_decay` ↔ `BoardRules.Decay` | 批 3 |
| `mark_adhesion` | OK | deferred | 0 | `_mark_adhesion` ↔ `BoardRules.MarkAdhesion` | 批 3 |
| `tick_durations` | OK | deferred | 0 | `cw_world_fx.gd:tick_durations` ↔ `BoardRules.TickDurations` | 批 3；GD 半边住在 `CWWorldFx` 上 |
| `tick_necrosis` | OK | deferred | 0 | `_tick_necrosis` ↔ `BoardRules.TickNecrosis` | 批 3 |
| `tick_chemo_cd` | OK | deferred | 0 | `_tick_chemo_cd` ↔ `BoardRules.TickChemoCooldown` | 批 3 |
| `tick_chemo_track` | OK | deferred | 0 | `_tick_chemo_track` ↔ `BoardRules.TickChemoTrack` | 批 3 |
| `expire_marks` | OK | deferred | 0 | `_expire_marks` ↔ `BoardRules.ExpireMarks` | 批 3 |
| `clear_newborn` | OK | deferred | 0 | `_clear_newborn` ↔ `BoardRules.ClearNewborn` | 批 3 |
| `cap_energy` | OK | deferred | 0 | `_cap_energy` ↔ `BoardRules.CapEnergy` | 批 3 |

### S 族 · S 阶段 5 条 + 动作 2 条

| op | status | cases | 用例数 | 落点（GD ↔ C#） | 空档 / 备注 |
|---|---|---|---|---|---|
| `reset_round_flags` | OK | deferred | 0 | `_reset_round_flags` ↔ `CellRules.ResetRoundFlags` | 批 3 |
| `tissue_production` | OK | deferred | 0 | `_tissue_production` ↔ `BoardRules.TissueProduction` | 批 2；**不是 `Produce`**（`Produce` 头一行还有 `ResetRoundFlags`） |
| `vessel_teleport` | OK | deferred | 0 | `_vessel_teleport` ↔ `BoardRules.Transport` | 批 3 |
| `aerobic` | OK | deferred | 0 | `cw_world.gd:_aerobic` ↔ `PhaseRules.Aerobic` | 批 2；薄壳 `aerobic()` 不是契约步 |
| `overload` | OK | deferred | 0 | `cw_world.gd:_overload` ↔ `PhaseRules.Overload` | 批 2；薄壳 `overload()` 不是契约步 |
| `enter_tile` | OK | deferred | 0 | `cw_actions.gd:enter_tile` ↔ `CellRules.EnterTile` | 批 1 |
| `damage_hit` | **KNOWN_GAP** | deferred | 0 | `immune_hit` / `cancer_hit` ↔ `CellRules.Damage` | **空壳 + `rec: "manual"`**（住在 `CWGame` 上，四个代理够不着；批 4 手写用例）。两端签名未核，批 4 的 C-2 步 1 再核 |

### 挂档 3 条（`cases: none`，不产用例，不进分派）

| op | status | 为什么 |
|---|---|---|
| `chaos_return` | NOTIMPL | C# 未实现（`EvolveEndOfRoundB` 的 EV-1 注释） |
| `check_immune_win` | OUT_OF_SCOPE | 整局 / 状态机驱动那一档不进 L0 也不进 L1 |
| `check_cancer_win` | OUT_OF_SCOPE | 同上 |

## 三、明写的空档（本次不补，各自等哪一批）

| 空档 | 等谁 | 出处 |
|---|---|---|
| **`mods` 四元组的装载** —— C# 侧非空 `mods` ⇒ `UNLOADABLE`，压力用例 `stress/mods/…` 这次不进仓库 | **批 5a** 的 `setup_ops` 前奏（C-2 步 2「补 loader 缺的键」） | §0.6.1 第 4 条 |
| **`events.pool` / `double_next`** —— C# 侧 `pool` ≠ 全表或 `double_next` = true ⇒ `UNLOADABLE`，压力用例 `stress/events/pool_is_overwritten_not_appended` 这次不进仓库 | **批 5b** 迁世界事件时解除 | §0.6.1 第 5 条 |
| **§0.6.7 四条入口**：`move_legal` / `anaerobic_pool` / `split_share` / `settle_loss` —— 09-19 Kevin 接受、C# 入口已开、两侧空壳进分派（P 16）；探针面与用例随批 0 / 1 / 2 定 | 各批的 C-2 步 1 | 拍板记录 §九 |
| **`covers` 的内容** —— 45 条迁移用例逐条回指 `headless_test.gd` 的 `check()` 名，今天分子恒 0 | 步 15 之后**单独一次提交** | §0.6.5 第 6 条 |
| ~~收割器碰到 stage `init` 的局~~ —— **已合上（2026-09-19 同日）**：`cw_case_loader.gd:STAGE_TO_PHASE` 把 `init` 映成 `Setup`（协议 phase 对 init / setup_place 都编成 setup，envelope 上等价）；`t_rec_*` 四条与 `harvest.gd` 首跑随之通 | —— | 开发日志 2026-09-19 步 13 条 |
| ~~`chemo-move-quote`~~ —— **已合上（2026-09-19 同日）**：根因是借道报价 C# 逐段跑修饰再相加、`cost_rows` 又从落点单格起算；改成与 GD 同：`PassThroughRoutes` 累计 RawMoveCost、修饰按落点只跑一遍（`RulePolicies.RawFor`）。`trace_4p_chemo_4242` envelope 从 248 拧到 279 整条一致；`pass_through_cost` 的 KNOWN_GAP 一并转 OK | —— | 开发日志 2026-09-19 借道条 |
| **`area-damage-batch`** —— GD `cw_game.gd:immune_hit_area` 批量提交（同一份批前状态、`damage.next_group()` 一次），C# 逐个 `Damage`；影响所有 `*_hit_area` 口径的卡（炎症风暴 / 免疫风暴 / 放疗 / 全身性免疫清除 / TNF-α）。2026-09-19 起两张风暴卡由死代码转为活路径，差异随之可达 | **批 4**（伤害管线） | 开发日志 2026-09-19 pick_cell 条 |
| **批 0 留 GD 的 26 个 check 名**（无 C# 对应物 21 个符号：`CWData.TOTAL_TILES` / `DIFFERENTIATE_MIN_LEVEL` / `HAND_MAX`（C# 只有 `Cell.HandMax` 的 record 字段缺省）/ `EMT_MOVE_COST` / `MUTATE_EXTRA_LOSS` / `MUTATE_MEMORY_CUT` / `CHEMO_IMMUNE_PCT` / `CHEMO_SELF_PCT` / `MARK_RANGE` / `LEVEL_MIN_MEMORY` / `EFFECTOR_NAMES` / `IMMUNE_TYPE_TEXT` / `init_cancer_tiles` / `aerobic_level_base(n)` / `level_min_memory(n)` / `skill_text` / `ring`、`CWCardData.CARDS`（两侧形状对不上）/ `effect_of`；C# 侧 private 够不着：`CWData.VESSELS`（`MatchSetup.Vessels`）/ `all_coords`（`MatchSetup.AllCoords`））—— 涉及 `t_immune_level_rules`（门槛表 5 条）/ `t_ring_and_toxin`（`ring` 4 条）/ `t_card_pool` 3 / `t_mark_range` 2 / `t_skill_info` 2 / `t_antibody_no_target_x` / `t_batch2_rules` / `t_board` / `t_card_mods` / `t_draw_purify_memory` / `t_effector_responses` / `t_guide_director` / `t_hunt_fx` / `t_mutation_faces` / `t_setup` 各 1 | 各自等对应机制迁 C#（免疫等级门槛表 = E-3 判死的 `differentiate_min_level` 家族；`ring` / `neighbors` 类几何工具随批 3；文案类永远留 GD） | 规格 B 批 0 落地记录 |
| **批 0 撤回的 5 条**：`const/data/hand_max`（C# 只有 record 字段缺省）、`anaerobic_cells_k` 与 `antibody_no_target_x` 的越界钳住各 2 条（GD `clampi` 住在静态函数里、C# 是裸表，纪律 3 不在靶场补 clamp、也不为测试在 core 开 clamp 壳） | 留 GD | 批 0 评委 |

## 四、旋钮四档（`game/tests/contract_tune.json`，65 行 = `CWTuning` 属性全集）

| 档 | 条数 | 处置 |
|---|---|---|
| **A · 已接** | 22 | `WorldLoader.WithKnob` 已有；不动 |
| **A′ · 有属性没接** | 3 | `anaerobic_block_coef` / `proliferate_per_adjacent[i]` / `proliferate_per_solid[i]`，加一行就能了 |
| **B · C# 根本没有** | 18 | 拧了**两边都当场红**并报「这个旋钮 C# 没有对应物（E-3）」。E-3 已拍：补 6 / 判死 5 / 待定 7 |
| **C · 没人拧过** | 22 | 登记在案、不进白名单、拧了报「不在白名单」 |

另有 3 个 C# 侧旋钮在 GD 没有对应字段，不进这张表、也不许出现在用例的 `tuning` 块里：
`AnaerobicBlockCoefByPlayers` / `AnaerobicBlockExpByPlayers` / `AnaerobicCellsK`。

## 五、按批次（测试迁移规格 §B，`check` 站点实测数，只用来排序与估工）

| 批 | 内容 | 条数 | covers 已挂 |
|---|---|---|---|
| 0 | 常量表 / 纯静态 | ~105 + `settle_loss` 4 | 0 |
| 1 | 移动费用 / 路径报价 | ~145 | 0 |
| 3 | E 阶段分步 | 128 | 0 |
| 4 | 攻击 / 伤害管线 | ~106 | 0 |
| 5a | 费用 / 伤害侧修饰 | ~200 | 0 |
| 2 | 收入 | 141 | 0 |
| 5b | 需中途询问的卡 + 事件 | ~150 + `t_ev_*` 53 | 0 |

## 六、明确不搬的

| 类 | 实测 | 处置 |
|---|---|---|
| 日志文案 | 20 条 / 17 个函数（core 的约 1.8%） | 逐条留 GD。⚠ 划分要落到单条 `check`，不能按函数整块划 |
| 整局 / 状态机驱动 | 计划自报 125 条 | 随 GDScript 内核退役（L2 延后到阶段 1，不是被证伪）。例外：`settle_loss` 4 条进批 0 |
| ui / net / guide / persist / ai / patch | 2035 站点（61.1%） | 不在本规格范围 |
| 测试设施与宿主自测 | 181 站点 | 验的是对拍机件本身，留 GD |
