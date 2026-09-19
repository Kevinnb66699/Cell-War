# xcheck/COVERAGE.md —— 「C# 到底差什么」的权威答案

> 数字段由 `python tools/xcheck_report.py --write` 刷新（口径写死在脚本里，见 `docs/对拍规格_CWX.md` §4.C）。
> 文字段人工维护。**没有「未分类」这一档** —— 每条要么 `OK` / `NOTIMPL` / `KNOWN_GAP` / `UNDEFINED` / `OUT_OF_SCOPE` 之一。
> 完工定义（测试迁移规格 §0.2）：`xcheck/COUNT` 的 `covered_sites` ≥ core 候选集的 **85%**。

## 一、计数（2026-09-19 实测，`xcheck/COUNT`）

| 量 | 值 | 口径 |
|---|---|---|
| `total_sites` | 3400 | `headless_test.gd` 全部 `check()` 站点（当次 `grep -c 'check('` 3332，差恰好 2） |
| `total_funcs` | 261 | 带断言的函数 |
| `core_sites` | **1110** | `FUNC_SUBSYSTEM` 判成 `core` 的那一档 = **分母** |
| `core_funcs` | 98 | |
| `core_addressable` | 1090 | core 里能被 `covers` 指到的不同名字（20 个站点断言名为空或同函数内重名 ⇒ 覆盖率天花板 98.2%） |
| `covered_sites` | **416** | **分子**：批 2 第二段落地 410 → 427（+17：29 条用例 17 个不重复 covers）。批 5b 卡牌半边（5c）落地 330 → 410（+80：54 条用例 80 个不重复 covers）。批 2 第一段落地 315 → 330（+15：26 条用例 15 个不重复 covers，全在 core 分母、此前无人认领）。批 5b 第一段落地 310 → 315（+5：10 条用例 5 个不重复 covers，全在 core 分母、此前无人认领）。批 5a 落地 279 → 307（+28：29 条用例 28 个不重复 covers）。批 4 落地 188 → 279（+91：66 条用例 92 个不重复 covers，91 个是新名字、全在 core 分母内）。批 3 收口 176 → 188。：`covers` ∩ 真实 check 名。批 3 落地 133 → 176（**+43**）：batch3 的 45 条用例给出 47 个不重复 `covers`，其中 4 个既有用例已指过 ⇒ 净增 43。（P2 报的 49 个里，`tick_necrosis` 那两条按评委 conflicts #5 撤掉不认领 ⇒ 47） **2026-09-19 删世界事件：427 → 416**（净删 13 个测试函数 / 15 条 L0 用例，`xcheck_report.py --write` 重算；同批 `core_sites` 1110 → 1029、`total_sites` 3433 → 3324）。 |
| `unclassified_sites` | 0 | 落不进任何一条分类规则的站点，**不许当 0 用，要回去加规则** |

子系统分布（迁移计划 §二点五 去向表的今日实测）：
`ui 1134` / `core 1110` / `net 486` / `guide 233` / `testinfra 210` / `ai 87` / `patch 72` / `persist 27`（2026-09-19 批 1 落地时实测；批 1 把 `_t_move_cost_wiring` 归 ui，core 分母 1114 → 1110）。

分类口径按 §0.6.5 第 6 条点名：`t_skill_fx` / `t_erosion_fx` / `t_prd_online_0907` 归 **core**；
`t_effector_fx` / `t_attack_fx` / `t_spread_fx` / `t_teleport_fx` / `t_dice` / `t_human_ask` / `t_card_fx_hooks` / `_t_move_cost_wiring`（批 1：4 条全是 CWUIBridge 价目表接线、零规则量）归 **ui**。

## 二、契约面逐 op（`game/tests/contract_ops.json`，48 行）

`status` 五档；`cases` 三值：`required`（两侧分派已活，启动断言强制 ≥1 用例 + 每个 `boundaries` 档 ≥1 条）/
`deferred`（已登记、该批未开工，分派表里放空壳）/ `none`（挂档，必须零用例）。
**分派集合 P 12 / S 25**（`status ∈ {OK, KNOWN_GAP, UNDEFINED}` 的行），录制代理覆写 **24** 条（S 里 `rec != "manual"`）。
「用例数」= `game/tests/l0/*.json` 今天的条数，括号里是 `stress_keys.json` 贡献的。

### P 族 · 17 条（分派 17 = 15 真 + 2 空壳 `anaerobic_pool` / `split_share`；批 1 把 `move_raw_cost` / `pass_through_cost` / `quote_path` / `move_legal` 四个空壳换成真转调）

| op | status | cases | 用例数 | 落点（GD ↔ C#） | 空档 / 备注 |
|---|---|---|---|---|---|
| `move_cost` | OK | required | 44 | `_move_cost_mod`+`_move_base_cost` ↔ `QuoteMove` | 16 档全满（批 1 加 `pass_through` / `skill_gate` / `chemo:*` 四向 —— 组织驻留前两次免费 / 第三次原价 / 巡航首移免费 / 趋化源四向正负号）。**批 5a +16**：mods / mods_gate / mods_order / mods_floor / mods_allowance 五档（修饰条目本身、闸门、语义阶段序、地板、额度） |
| `anaerobic_share` | OK | required | 7 | `anaerobic_gain_for` ↔ `AnaerobicShare` | 4 档 批 2 第二段 +3（`anaerobic/block_7` / `warburg` / `glut1`，id 用 `anaerobic/` 前缀，第一段的 E-3 禁令解除） |
| `aerobic_share` | OK | required | 18 (+2) | `aerobic_income` ↔ `AerobicShare` | 批 0 只有 `level:I`；批 2（09-19）+3 档、全部旋钮钉死（`aerobic_by_level[i]` / `aerobic_split_ref` 写 PRD 不会出现的值），不录 PRD 常数。有氧**盘面式**（`aerobic_level_base <= 0`，C# `AerobicBase` 抛 NotSupported）与 **floor / cap 夹钳**（GD `clamp_income` 在 `AerobicShare` 里未迁）两族 = 空档 aerobic-board-formula-not-migrated / aerobic-floor-cap-not-migrated，归第二段 批 2 第二段：盘面式 / 分档表两档由新 op 文件 `aerobic_board_formula.json` 收（`aerobic_level_base: 0` + `aerobic_by_level[]: 0` 走盘面式、`-1` 走分档表）；`floor_pinned` / `cap_pinned` 两档随 `aerobic_floor` / `aerobic_cap` 挪 A′ 开出（C# `AerobicShare` 补了 `clamp_income`）—— 空档 aerobic-board-formula / aerobic-floor-cap 两条**合上** |
| `pressure_at` | OK | required | 10 | `pressure_at` ↔ `PressureAt` | 7 档。批 5a +2：`stage_mult` 档（II / III 期系数） |
| `proliferate_chance` | OK | required | 1 (+1) | `proliferate_chance` ↔ `ProliferateChance` | **只一条**，分档边界空 |
| `solidify_threshold` | OK | required | 3 (+2) | `CWGame.solidify_threshold` ↔ `BoardRules.SolidifyThreshold` | 3 档 |
| `overload_loss` | OK | required | 10 | `overload_loss` ↔ `OverloadLoss` | 5 档 |
| `attack_outcome` | OK | required | 8 (+1) | `attack_outcome` ↔ `AttackOutcome` | 6 档。空档：C# `AttackOutcome` 完全不读【抗原引导】/【免疫伪装】（attack-outcome-world-events，批 5b） 批 5b S1 核：C# `AttackOutcome` ≡ GD **`base_verdict`**（契约表 `gd` 已改字），差的正是其后两句事件修正 → 第二段 A1（签名不变、加两行） **2026-09-19**：并给层的两个世界事件已删，`attack_outcome` 只剩 `return base_verdict(...)` ⇒ 两侧逐字等价，空档 attack-outcome-world-events 注销。 |
| `antibody_damage` | OK | required | 7 | `cw_actions.gd:antibody_damage(cell)` ↔ `RulePolicies.AntibodyDamage(tune, used, matured)` | 批 4 落地（E-6 **退路 B**：C# 探针从 cell 取 used / matured 再转调，`matured` 只许过 `HasSkill`；路 A = 具名重载 `AntibodyDamage(WorldState, Cell)` 待 Kevin）：7 档 —— used 0～4 递减 15/7/3/1/0、【抗体亲和力成熟】基数 20、旋钮 `antibody_halve` 关 |
| `move_raw_cost` | OK | required | 4 | `_one_step_base` ↔ `RulePolicies.RawMoveCost` | 批 1 落地：【伪足穿透】四档（门槛下 / 门槛 / 递减一格 / 递减到底），后两档老用例没有；两侧起价都不看黏液 |
| `quote_path` | OK | required | 12 | `quote_path` ↔ `RulePolicies.QuotePath` | 批 1 落地，第一个 `tree`：投影键表 `{ok,stop,total,left,gained,steps:[{to,cost,mid,afford,blocked,gain}]}`（**不收 `legal`**：GD 不看余额、C# 恒等于 afford；`blocked` 收 0/1 不收文案）。`allowance` 档（F2）与敌方占位不报价（F12）同日合上（见三） |
| `pass_through_cost` | OK | required | 4 | `pass_through_map(cell)[dest][0]` ↔ `RulePolicies.PassThroughMap` | 批 1 落地：one_hop / two_hop / two_types（中间癌组织 0.2 + 落点健康 0.7 各按自己类型算）。「不在借道表里」**不造哨兵**，两侧探针当场报清楚，否定式用 `move_legal` 表达 |
| `const` | OK | required | 40 | 两侧各一张 42 键表（`l0_runner.gd:_build_consts` ↔ `Probes.cs:ConstTable`，19 真 + 21 抛「无对应物」） | 批 0（09-19）：`batch0/const_data.json` 28 + `const_card.json` 4；三档 cw_data 28 / cw_card_data 4 / 静态函数 20 批 5b（09-19）+2 表项、来源第三档 `fx`（cw_world_fx.gd）：`CWWorldFx.EVENTS`（15 名事件表 → tree，钉两侧名表逐字相同 —— 此前没有任何东西钉它）/ `CWWorldFx.is_world_event`（bool → 1/0；名字收口）；`batch5b/const_fx.json` 3 + `const_event_rounds.json` 5（`is_world_event_round` 3/6/10/14 触发 + 1 不触发） **2026-09-19**：两侧常量表 42 → **39 键**（删 `CWData.is_world_event_round` / `CWWorldFx.EVENTS` / `CWWorldFx.is_world_event`），`cw_world_fx` 那一档 boundaries 同删。 |
| `move_legal` | OK | required | 18 | `_is_move_legal_now`（六支）↔ `CellRules.MoveLegal` | 批 1 落地：六支全覆盖（empty / attack / attack_cap / dendritic / pass_through / out_of_board）；分支②后半句两侧都是死代码，`pass_through/landing_spot_occupied` 照样钉 |
| `anaerobic_pool` | OK | required | 7 | `_anaerobic_pool` ↔ `RulePolicies.AnaerobicPool` | 批 2（09-19）转真：三档零 PRD 常数 —— `empty_block` 0 / `coef_pinned`（`anaerobic_block_coef` 钉 37，底数 1 ⇒ 与指数无关）/ `solid_pinned`（`anaerobic_solid_bonus` 钉 13）；返回 double ⇒ 千分位冻结（R4）。数值档（c / 指数 / k）归第二段；「系数 0 退回线性求和」对照档挡在 Q3（三个 C 档旋钮挪 A′） 批 2 第二段 +3 档（`cells:1` / `cells:3` / `coef_off`）：数值档按 PRD 现值冻（千分位，source 写 PRD 行号）；`coef_off/pinned_linear` 是三个无氧旋钮挪 A′ 的唯一 L0 靶子 |
| `split_share` | OK | required | 6 | `_split_share` ↔ `RulePolicies.SplitShare` | 批 2（09-19）转真：`floor_pinned` 33 / `cap_pinned` 37（旋钮钉死，`anaerobic_split: 1` 显式写出）；`count == 0` 两侧口径未核 = 空档 split-share-count-zero 批 2 第二段 +4 档（`count:1/2/3` / `no_split`），R4 成对绑定 pool 字面量 = 配对那条 `anaerobic_pool` 的冻结前精确值；`count ≤ 0` C# 改抛（GD 是 UB）—— split-share-count-zero 口径已定、仍不写用例 |
| `settle_loss` | OK | required | 4 | `CWGame.settle_loss` ↔ `Settlement.SettleLoss` | 批 0（09-19）：`batch0/settle_loss.json`，四档各一条（t_hit_order 开头 4 条） |

### S 族 · E 阶段 18 条（**批 3 已落地 2026-09-19**：required 12 / deferred 6，分派里是真步）

| op | status | cases | 用例数 | 落点（GD ↔ C#） | 空档 / 备注 |
|---|---|---|---|---|---|
| `anaerobic` | OK | **required** | 4 | `cw_world.gd:_anaerobic` ↔ `BoardRules.Anaerobic` | 批 3：默认（平方根）档 + 【GLUT1高表达】。线性对照与【瓦伯格】110% 两档 = **KG-1**（C# 侧 `anaerobic_block_coef` / `anaerobic_floor` 两个旋钮没生效），k 系数四细胞档 = **B10**（细胞写在席位 2/3、对局只有 2 席，两侧都装不回去） |
| `cancer_upkeep` | OK | deferred | **0** | `_cancer_upkeep` ↔ `BoardRules.CancerUpkeep` | 批 3 **收不到（B9）**：唯一来源 `t_balance_candidates` 候选③ 把两只癌细胞放在同一席，`$.cells[<席位>]` 语义键歧义 ⇒ 差分整条作废。四档（关着不扣 / 10.0 扣 20% / 0.4 扣 20% / 免疫不受影响）全空 |
| `pressure` | OK | **required** | 9 | `_pressure` ↔ `BoardRules.Pressure` | 批 3：五档盘面（抵平 / 二癌四健康 / 四癌两健康 / 固化双倍权重 / 致死）+ 两档减免。护盾三档撞 `cells[].mods` ⇒ 批 5a。批 5a +2：`shield` 档（护盾条目吃压迫），原「护盾三条撞 mods」空档合上 |
| `proliferate` | OK | **required** | 8 | `_proliferate` ↔ `BoardRules.Proliferate` | 批 3：六档。事件两档 = **KG-2**（【增殖抑制】下 GD 不掷骰、C# 还要抽一次）/ **KG-3**（【异常增殖】翻倍 C# 没实现）；`necrosis_cleared_on_flip` = **KG-6**。⚠ `all_six_convert` / `off_round_same` 钉的是「六邻全转」，不是事件（评委 conflicts #6） |
| `erosion` | OK | **required** | 4 | `_erosion` ↔ `BoardRules.Erosion` | 批 3：四档。`args.fresh` 两侧统一成 `"q,r;q,r"` 串（批 1 机件③ = B3，本批合上）。`necrosis_cleared_on_flip` = **KG-6**；「一次侵蚀转 2 或 3 格」是 60 个种子的集合统计断言，单条用例回指不了 |
| `resolve_camping` | OK | **required** | 4 | `_resolve_camping` ↔ `BoardRules.ResolveCamping` | 批 3：三档（没蹲满 / 已固化作废 / E 阶段完成净化），靠 **B4** 才收得到。另三条断言落在 **KG-5** 的那条草稿上 |
| `solidify` | OK | **required** | 8 | `_solidify` ↔ `BoardRules.Solidify` | 批 3：六档。`osteo:same_rounds` 的 check 名以 `%d` 开头、按 xcheck 口径取到空串，`covers` 指不到；血管三档（`t_vessel_no_solid`）撞 **B9** 批 2 +1 档 `vessel`（2 条：血管不可固化 / 血管以外照常）—— C# `BoardRules.RaiseSolid` 早有 `BloodVessel` 判据，**不是**规则结果差；B9 撞的三档就此收 2 |
| `rooted` | OK | **required** | 5 | `_rooted` ↔ `BoardRules.Rooted` | 批 3：五档，**靠 B4 才收得到**（六条断言全在 `_blank_board()` 上）。目标走 `pick_random`，两侧 pop-loop 同形，5 条全绿 = 带子对得上 |
| `ossify` | OK | **required** | 3 | `_ossify` ↔ `BoardRules.Ossify` | 批 3：两档，靠 **B4**。另四条（到期回合免疫站在格上 = **KG-4**，与它同段的 16121 / 16124 / 16125 三条）整段不进仓库 |
| `decay` | OK | **required** | 3 | `_decay` ↔ `BoardRules.Decay` | 批 3：三档。事件两档（抑制 / 到期恢复）撞 **KG-7**（那只癌细胞摆在盘外 (5,5)） |
| `mark_adhesion` | OK | deferred | **0** | `_mark_adhesion` ↔ `BoardRules.MarkAdhesion` | 批 3 **收不到（B9）**：`t_effector_responses` 的 near/mid/far 三只癌细胞同属席位 1 |
| `tick_durations` | OK | **required** | 6 | `cw_world_fx.gd:tick_durations` ↔ `BoardRules.TickDurations` | 批 3：两档；GD 半边住在 `CWWorldFx` 上。修饰过期三档撞 `mods` ⇒ 批 5a，TNF 那条撞 **B6**。批 5a +2：`mods_expire` / `mods_keep` 两档（round 的清掉、"" 的留着），原「修饰过期三档撞 mods」空档合上 批 5b +2：`event:stacks_and_doubled_preserved` / `event:doubled_one_round_expires`（`t_ev_double_instant` 的盘面：【增殖抑制】被【双重触发】拉成 left 2 / stacks 1 / doubled "repeat"）；带 `data` 的 TNF 那条仍撞 B6，归第二段第 1 个提交 **2026-09-19**：四个 `event:*` 档与 `batch3`/`batch5b` 的用例随世界事件删除，本行只剩 `mods_expire` / `mods_keep` 两档。 |
| `tick_necrosis` | OK | **required** | 4 | `_tick_necrosis` ↔ `BoardRules.TickNecrosis` | 批 3：四档，**只钉倒计时本身、`covers` 留空**（评委 conflicts #5，见下表）。盘面档撞 **B5**（`aerobic_by_level = []` 表达不了） 批 2 第二段：`countdown:board` 一档的阻塞（C# `AerobicBase` 对 `aerobic_level_base <= 0` 抛）**已消**，这一档现在能开；本段没开，转下一轮工单 |
| `tick_chemo_cd` | OK | deferred | **0** | `_tick_chemo_cd` ↔ `BoardRules.TickChemoCooldown` | 批 3 **收不到（B10）**：B4 之后草稿有了，但该局细胞写在席位 2/3、对局只有 2 席 ⇒ 两侧都装不回去 |
| `tick_chemo_track` | OK | **required** | 2 | `_tick_chemo_track` ↔ `BoardRules.TickChemoTrack` | 批 3 当天 KG-8 合上后放回 2 条（ticks / expires）|
| `expire_marks` | OK | **required** | 2 | `_expire_marks` ↔ `BoardRules.ExpireMarks` | 批 3 当天 KG-8 合上后放回 2 条（first_round / second_round）；第三条 loose 与 cc 同席（B9）留 GD |
| `clear_newborn` | OK | **required** | 1 | `_clear_newborn` ↔ `BoardRules.ClearNewborn` | 批 3：一档（`t_ev_chaos` 跑完整个 e_phase 的那一次，原 check 是整相不变量） |
| `cap_energy` | OK | deferred | **0** | `_cap_energy` ↔ `BoardRules.CapEnergy` | 批 3 **零用例（B7）**：`headless_test.gd` 全文一条 cap_energy 的 check 都没有，不是收割的问题；要 required 只能手写 |

### S 族 · S 阶段 5 条 + 动作 3 条

| op | status | cases | 用例数 | 落点（GD ↔ C#） | 空档 / 备注 |
|---|---|---|---|---|---|
| `reset_round_flags` | OK | deferred | 0 | `_reset_round_flags` ↔ `CellRules.ResetRoundFlags` | 批 3 |
| `tissue_production` | OK | required | 4 | `_tissue_production` ↔ `BoardRules.TissueProduction` | 批 2；**不是 `Produce`**（`Produce` 头一行还有 `ResetRoundFlags`） 批 2（09-19）转真：四档 —— 核心进度 +1 / 骨髓 `cards:1` 已满（`store_progress` 恒 1.0）/ `occupied` 收用例自写在 tile 上的 store / `necrosis_skip`；期望里没有产出周期或产量常数（弱依赖「任何 period > 1」，Q2 只影响第二段的骨髓抽卡半边）；撤 vessel 档（血管格是空 delta）；【营养缺乏】档 = 空档 tissue-production-nutrient-shortage |
| `vessel_teleport` | OK | required | 4 | `_vessel_teleport` ↔ `BoardRules.Transport` | 批 2（本行原写「批 3」是笔误）转真：四档（含 `necrosis_blocks` —— GD 只查 necrosis，`solid_blocks` 改字），6 条；会改连通块的那条把 `anaerobic_floor` / `anaerobic_cap` 同钉 33 防无氧常数漏进 delta |
| `aerobic` | OK | required | 7 | `cw_world.gd:_aerobic` ↔ `PhaseRules.Aerobic` | 批 2；薄壳 `aerobic()` 不是契约步 批 2（09-19）转真：`level_I` / `level_III`（`aerobic_by_level[i]` 钉 41）/ `necrosis_cut`（`necrosis_aerobic_pct` 钉 0）/ `tgf_consumed`（一层【TGF-β释放】被有氧消耗）；细胞 `energy: 300` 显式写出，不烘默认初始能量 批 2 第二段：+`tgf/restores_next_round` 等（PRD 现值冻） |
| `overload` | OK | deferred | 0 | `cw_world.gd:_overload` ↔ `PhaseRules.Overload` | 批 2；薄壳 `overload()` 不是契约步 |
| `enter_tile` | OK | required | 10 | `cw_actions.gd:enter_tile(cell, dest, paid := -1)` ↔ `CellRules.EnterTile` | 批 1 落地：healthy / purify / special 三档 delta；`paid` 只写缺省（C# 不消费，写了当场红）；`free` 档撤（要卡牌 + 挂起态 ⇒ 批 5b）；GD runner 原读 `to` 已改 `dest` 批 2 +1 档 `purify_memory`（2 条：净化 +1 抗原记忆 —— 批 2 的主语，记忆压在 10 以下绕开门槛表分叉） 批 2 第二段 +`memory:level_up` 档：`purify/memory/level/two_players_stays_II`（2 人局 memory 20~29 停在 II —— 旧 C# 给 III；门槛表合上后的真靶子）+ 四人 20 → III + X 级清零 |
| `execute` | OK | required | 100 | `cw_actions.gd:execute(cell, data)` ↔ `GetAvailableDecisions → SemanticKey.Of → ExecuteDecision` | 批 1 进表（决策类 op）：args = `seat` + 语义键 `key`，**`rec: "manual"`**（行动总入口不许代理覆写）；批 1 只 `act=move` 落空格；**批 4 加 17 档**：攻击 15 档（判词 / 反击 / 击杀 / 补体调理重掷 / 穿孔素 pick / 攻击上限……，`rolls` 逐条按硬约定的掷骰次序）+ 抗体 + `move/purify_heal`（巨噬【局部吞噬】回能按实付 0.7/0.5/0.4/0.3/0.2/0.0 + 旋钮 0 七态 —— S1 路 ②，不动 core 的 `EnterTile` 签名）。批 5a +7：`move/spend` / `move/keep` / `move/exhaust`（修饰打出后消耗 / ON_BENEFIT 不消耗 / 额度用尽回基准价）+ `move/ras`（【RAS持续激活】首次定殖回能 / 同回合第二次不回，主会话补收） **批 5b 卡牌半边（09-19）+12 档、+54 条**：args 加 `answers`（`;` 分隔的语义键串，同一个 op 里把中途询问答完；两侧各自排干挂起态，GD 桥 `tests/l0_answer_bridge.gd` / C# `Steps.Execute` 逐条 `GetAvailableDecisions → SemanticKey.Of → ExecuteDecision`）；`ask:free_move` / `ask:pick` / `ask:pick_cell` / `ask:pick_tile` / `draw/event` / `draw/pool` / `draw/limit` / `play/equip` / `play/memory` / `effector/neutralize` / `mutate` / `discard`；`$.g.asking_pid` 由 runner 原样放回 |
| `damage_hit` | OK | **required** | 25 | `cw_game.gd:immune_hit(target, base, attacker, attack, add)` / `cancer_hit(target, base, reason, skill)` ↔ `CellRules.Damage(s, id, amount, LossSource, ability)` | 批 4 落地：args `[target, base, source, ability]`，`source` 四个字面词 immune_attack / immune_effect / cancer_skill / world，immune 两档的 `ability` 只许「攻击」「技能」（GD 硬编码，两侧探针硬断言）；不收 `attacker`（C# `Damage` 没有：吸血 / 斩杀住在 `Move` 与 GD 伤后触发队列）、`add`（GD 第一步就加进 base）、`direct`（GD 是同批第二条事件 —— 靶场造事件 = 重写攻击流程 ⇒ 走 `execute` 攻击分支）；13 档，仍 `rec: manual` 手写。盘面禁忌 F1：不许有与任一活癌细胞 ≤2 格的树突（damage-tail-update-marks） |

### 挂档 5 条（`cases: none`，不产用例，不进分派）

| op | status | 为什么 |
|---|---|---|
| `check_immune_win` | OUT_OF_SCOPE | 整局 / 状态机驱动那一档不进 L0 也不进 L1 |
| `check_cancer_win` | OUT_OF_SCOPE | 同上 |

## 三、明写的空档（本次不补，各自等哪一批）

| 空档 | 等谁 | 出处 |
|---|---|---|
| ~~`mods` 四元组的装载~~ —— **已合上（2026-09-19）**：E-2 的 `setup_ops` 前奏落地（`L0/WorldLoader.cs` 一张 15 行路由表，只有「哪个名字走哪条生产路径」、没有任何值；表外的名字仍 `UNLOADABLE`）。压力用例 `stress/mods/inflammatory_chemotaxis_replaces_move_cost` 进仓库，新 `L0/SetupOpsTests.cs` 8 项，`RoundTripTests` 三条夹具 175 步「装不回去」清零 | —— | §0.6.1 第 4 条 / E-2 落地记录 |
| **`events.pool` / `double_next`** —— **世界事件已删（Kevin 2026-09-19），本条空档作废**：两个字段冻成恒定值（`pool` 恒 `[]` / `double_next` 恒 false），两侧「空表 = 缺省」逐字同口径；原计划给 `WorldState` 加 `EventPool` / `DoubleNext` 两个字段的事不做了 | **批 5b** 迁世界事件时解除 | §0.6.1 第 5 条 |
| ↳ 批 5b 第一段（09-19）：归第二段第 2～3 个提交 —— `WorldState` 加 `EventPool` / `DoubleNext` 两个字段（要破 E-4「不动 `WorldState`」那一条，拍板记录 §十三 第 1 条，推荐接受：默认值就是今天 codec 恒产的两个常量）、`ObservationV1Codec` 改真值、删 `WorldLoader.cs:157-160` 两句 UNLOADABLE，压力用例 `stress/events/pool_is_overwritten_not_appended` 随之进仓库 | 第二段 | 批 5b S1 设计草案 §2.1 / §2.5 **世界事件已删（Kevin 2026-09-19），本条空档作废**（`WorldState` 不加 `EventPool` / `DoubleNext`）。 |
| **§0.6.7 四条入口**：`move_legal` / `anaerobic_pool` / `split_share` / `settle_loss` —— 09-19 Kevin 接受、C# 入口已开、两侧空壳进分派（P 16）；探针面与用例随批 0 / 1 / 2 定 | 各批的 C-2 步 1 | 拍板记录 §九 |
| ~~`covers` 的内容~~ —— **已填（2026-09-19）**：53 条老用例 45 条回指真实 `check()` 名（36 个不同名字，全在 core），`covered_sites` 26 → 57（E-2 前奏落地那次 `stress/mods/inflammatory_chemotaxis_replaces_move_cost` 再 +1 ⇒ 58）。留空 8 条：`overload/curve_*` 4 条（等价断言在 `t_overload` 的 `for pair` 循环里、check 名是 `%` 拼的空名，按口径指不到）、`move_cost/immune_to_healthy/level_I`（GD 没有任何 check 钉这个数，L0 净增）、`move_cost/cancer_to_*` 与 `sclc_minimal_cytoplasm` 3 条（GD 只有 `== g.tune.xxx` 的同义比较，不算钉数值，按严口径不指） | —— | 开发日志 2026-09-19 covers 条 |
| ~~收割器碰到 stage `init` 的局~~ —— **已合上（2026-09-19 同日）**：`cw_case_loader.gd:STAGE_TO_PHASE` 把 `init` 映成 `Setup`（协议 phase 对 init / setup_place 都编成 setup，envelope 上等价）；`t_rec_*` 四条与 `harvest.gd` 首跑随之通 | —— | 开发日志 2026-09-19 步 13 条 |
| ~~`chemo-move-quote`~~ —— **已合上（2026-09-19 同日）**：根因是借道报价 C# 逐段跑修饰再相加、`cost_rows` 又从落点单格起算；改成与 GD 同：`PassThroughRoutes` 累计 RawMoveCost、修饰按落点只跑一遍（`RulePolicies.RawFor`）。`trace_4p_chemo_4242` envelope 从 248 拧到 279 整条一致；`pass_through_cost` 的 KNOWN_GAP 一并转 OK | —— | 开发日志 2026-09-19 借道条 |
| ~~F2 · C# `QuotePath` 不预演费用额度~~ —— **已合上（2026-09-19 同日）**：`RulePolicies.QuotePath` 每走通一步在丢掉的 world 上走真提交同一条 `CellRules.ConsumeModifiers`（烧闸门 / 扣限次修饰），用例 `quote_path/allowance/*` 2 条（组织驻留三步 0/0/5、真走一步后只剩一次）进仓库、`allowance` 档开档。原空档： GD 每走通一步 `burn_allowances`（issue #35），C# 一步都不烧 `fx_turn`：装【组织驻留】走三步 GD 报 0/0/5、C# 报 0/0/0。`t_plan_allowance` 9576 / 9580 / 9590 三条用例已写好（只要 `equipped` + `fx_turn`），`quote_path` 不设 `allowance` 档 | —— | 批 1 P1 / P2 各自取证；开发日志 2026-09-19 F2/F12 条 |
| ~~F12 · `quote_path` 敌方占位那一步的 `cost`~~ —— **已合上（2026-09-19 同日）**：C# 占位那一支不再报价（`occupied ? null : QuoteMove`），用例 `quote_path/blocked/enemy_occupied_is_not_quoted` 钉住。原空档： GD 在 occupied 分支根本不报价（0），C# 无条件先 `QuoteMove`（给的是攻击价）。`blocked` 档只用同阵营占位、任何 `quote_path` 路径不经过敌方占位格 | —— | 批 1 P1 / P2 |
| **F3 · `quote_path` 的 `blocked` 文案三条**（`t_plan_path` 3959 / 3974 / 4078：GD 六种 `move_block_reason` 文案、C# 恒一句）—— 投影只收 0/1 | 留 GD | 批 1 |
| **跨 op 同源断言 8 条**（「报价 == 真走一遍」「规划器与选项生成同一把尺子」）—— 一条 L0 用例只跑一个 op，结构上搬不动；**不**拆成两条单 op 用例刷分子 | 留 GD | 批 1 S1 F5 |
| **批 1 留 GD 74 条**：跨 op 同源 8 + 文案 / 日志 ~20（`move_block_reason` 整族）+ 选项生成级 ~10（`build_options` / `immune_move_options`）+ 纯查询契约 ~8（state_hash / 不烧闸门 / 不消耗 rng，P 族探针两侧天然满足）+ 其余（清单 `scratchpad/b1_inventory.json`） | 留 GD | 批 1 S1 |
| ~~批 1 清单里判去批 5a 的 28 条~~ **批 5a 重新分诊（2026-09-19）**：19 收 / 1 批 4 已收 / 3 卡【组织浸润】（infiltration-from-equipped）/ 5 留 GD（X 级要 tier C 旋钮 `immune_move_cancerous[3]`、报价纯查询两条要同 op 连跑两次、end_turn、equip_seq 前提）。「mods 装不进」这个原判据 28 条里一条都不成立了。原文：（`_t_ruling_a_rewrite` 5 / `t_card_mods` 16 / `_t_cost_required` 5 / `_t_commit_revalidates` 1 / `t_card_perms` 2）—— 判据是「要 `mods` ⇒ C# UNLOADABLE」，**而 E-2 前奏同日落地后这个前提已不成立**；另【组织浸润】在 C# 里不从 `equipped` 发修饰（打出时 `AddModifier` ⇒ mods），`equipped` 只许写【组织驻留】/【LFA-1黏附】/【组织巡航】。⚠ `_t_ruling_a_rewrite::X 级：改为 0.5 = 没变` 双重阻塞（`immune_move_*` 是 tier C 旋钮，免疫基准价只能靠 `players[].level` 拨） | **批 5a 重新分诊**（现在装得进了） | 批 1 S1 + E-2 落地记录 |
| **批 1 清单里判去别批的**：批 3 10 条（`reset_round_flags` / `resolve_camping` / `ossify`；`begin_turn` 后重新免费 2 条）、批 4 4 条（伤害 / 掷骰）、批 4/5 10 条（`enter_tile` 的 `paid` 实付回能）、批 5b 4 条（世界事件；`gain` 口径差：GD `core_gain()` 吃【代谢加速】翻倍、C# 读裸 `tile.Charge`，events 恒默认时恒绿 —— 批 5b 必须回头看） | 各批 | 批 1 S1 |
| ↳ 批 5b 第一段：那 4 条里 `gain` 的【代谢加速】口径差 = 设计草案 A2（`CollectSpecialAt` 翻倍，顺带修批 1 登记的 `quote_path` 的 `core_gain` 档），归第二段第 6 个提交；其余随 `trigger` 转 required 时收 | 第二段 | 批 5b S1 **世界事件已删（Kevin 2026-09-19），本条空档作废**：【代谢加速】已删，`core_gain` 不再翻倍，两侧逐字等价。 |
| ~~`enter_tile` 的 `free` 档~~ **撤（2026-09-19 批 5b 卡牌半边）**：`enter_tile` 自己从不扣费，免费连走是调用方的事；正确落点是 `execute` 的 `ask:free_move` 档（`execute/draw/chemo_recruit/free_move/two_steps_onto_core` 等 4 条已收） | —— | 批 1 F10 → 5c S1 |
| ↳ 5c 落地：上面那行已撤，免费连走由 `execute` 的 `answers` 文法表达（`k=free_move\|g=<卡>\|act=move\|to=q,r` / `…\|stop=1`） | 已收 | 批 5b 卡牌半边 |
| **机件三条（批 1 登记）**：~~① F13~~ **已合上（2026-09-19 同日）**：`Subset.Text` 先按键名 Ordinal 排序再印（递归进数组），`SubsetTextTests` 2 项钉住 —— 手写 `changed` 里的对象不再要照 C# 键序抄；~~② F15~~ **已合上（同日）**：两侧契约门② 加 `deferred` 分支 = 零用例（塞一条进 deferred 行两侧当场红）；③ `erosion` 的 `fresh` 参数 GD 读 JSON 数组、C# `Args.Positions` 读分号串（`L0Case.Args` 是 `Dictionary<string,string>`，数组连反序列化都过不去）—— **批 3 开工前先合**（推荐 GD 改读分号串） | 机件，随批 3 前 | 批 1 P1 / P2 |
| **`SKILL_MOVE` 费用链**（`t_homing_stream` / `t_jump_cap` / `t_ossify_cost_and_pin` 等读 `skill_move_cost`）—— 批 1 七个 op 面上没有它。批 5a 裁：**不开 `skill_move_cost` op** —— SKILL_MOVE 模板全表只有【基质阻隔】一条，C# 无事件容器，开了就是零用例空壳 | 批 5b（随事件容器） | 批 1 S1 / 批 5a S1 |
| ↳ 批 5b 第一段：仍不开。费用侧世界事件 C# **一条都没有**（`RulePolicies.MoveModifiers` 只读 `c.Modifiers` + `SkillMoveModifiers` + 趋化源 + 黏液，全 core 读 `s.Effects` 的 6 处没有一处在费用侧）；随第二段 A6（`MoveModifiers` 从 `s.Effects` 发修饰）+ A7（`SkillRules.cs:294`【转移】改走 SKILL_MOVE 管线）一起开 | 第二段第 5 个提交 | 批 5b S1 **世界事件已删（Kevin 2026-09-19），本条空档作废**：GD `cw_cost.gd:TEMPLATES` 里那 5 条世界事件模板已删，两侧费用侧从此同源。 |
| **`t_pass_through_ally:16862` 是恒真断言**（`check(not d.has(c) or true, …)`），在 core 分母里白占一格；另 4 条（16866 / 16869 / 16752 / 16769）断言名纯 `%` 拼、`covers` 指不到 | 报 Kevin（老测试，不动） | 批 1 S1 F6 |
| **`area-damage-batch`** —— GD `cw_game.gd:immune_hit_area` 批量提交（同一份批前状态、`damage.next_group()` 一次），C# 逐个 `Damage`；影响所有 `*_hit_area` 口径的卡（炎症风暴 / 免疫风暴 / 放疗 / 全身性免疫清除 / TNF-α）。2026-09-19 起两张风暴卡由死代码转为活路径，差异随之可达 | **批 4**（伤害管线） | 开发日志 2026-09-19 pick_cell 条 |
| ↳ **批 4 坐实 `area-damage-batch`（2026-09-19）**：借 `execute|act=antibody` 两目标、含当场死亡、含护盾组 ON_BENEFIT 的盘面，两侧差分逐条相同 —— **「批量 vs 逐个」的顺序本身今天不产生差异**（GD `_plan` 跨目标只读目标自己的字段 + round_no + tune）；唯一可达的差异是 GD 管线尾巴的 `game.update_marks()`（下一行）；伤后触发那条尾巴在 area 上不可达（9 处 `*_hit_area` 无一带 `Tag.ATTACK`）。设计草案甲（推荐）：新开 internal `DamageBatch`（逐个 `Damage` + 末尾一次 `UpdateMarks`），逐个那部分零行为改动；乙 = 调用点各补一句 UpdateMarks；丙 = 把 Damage 拆成五段对齐 GD 七阶段 = 动骨架。**结构性空档**，等真出现「读盘面的减伤」再做 | 批 5+ | 批 4 S1 取证 |
| ~~infiltration-from-equipped~~ **已合上（2026-09-19 同日）**：C# `SkillMoveModifiers` 加【组织浸润】一件（Subtract 3 / floor 2 / to_cancerous，不是闸门），`move_cost` 加 `skill:infiltration` 档 4 条（LFA+浸润首移 3 / 首移后只剩浸润 7 / 卡×技能换顺序 2 = 2）。原空档：【组织浸润】GD 从 `equipped` 现读模板发修饰（`cw_cost.gd:_collect`），C# `SkillMoveModifiers` 只处理【组织驻留】/【LFA-1黏附】/【组织巡航】三件、`CardRules.Registry` 那条在真打出路径上够不着（Permanent 分支在 Resolve 之前 return）：写 equipped 两侧 GD 7 / C# 10 分叉，写 mods 则 E-2 路由表没有它 ⇒ UNLOADABLE。连累批 1 那 28 条里的 3 条。设计草案：`SkillMoveModifiers` 加一件（读 `HasSkill`），与 E-2 路由表同批 | C# 侧合（规则结果差） | 批 5a S1 实测 |
| ~~card-play-feed-log~~ **已合上（2026-09-19 同日，靶场机件）**：C# L0 步在 `Stage.Scope` 里跑、`Steps.Execute` 把 `ExecuteDecision` 收进 result 的演出条目再发回作用域、`L0RunnerTests` 按 Runtime 同一条路 `SimulationState.Emit` 记 `g.feed_log` / `feed_seq`（`Subset.Encode(s, sim)` 新重载）；`execute/play/inflammatory_chemotaxis_from_hand` 两侧同绿（hand / mods 四元组 / play_n / feed 八条差分逐条同）。`t_card_mods` ①b 那类打牌序列的用例从此写得出。原空档：`execute|act=play` 两侧键形本来就同、六条差分逐条相同，但 GD 多 `feed_log` / `feed_seq`，C# 的 `ignore` 零命中是硬错 ⇒ 打出一张卡的 delta 用例今天盖不住（`t_card_mods` ①b「换出牌顺序结果相同」/ `_t_ruling_a_rewrite`「改为 X 恒在 −X 之前」因此留 GD） | 靶场：`feed_log` 的豁免口径（观测协议 §八 末行「进对拍」与 ignore 零命中硬错相撞） | 批 5a S1 实测 |
| **end-turn-not-a-step** —— `execute|act=end` GD 侧差分为空（L0 里不推回合机），C# 真推进（mods 过期 + current_pid −1 + phase e）⇒ 「结束回合」不是一条契约步 | 留 GD | 批 5a S1 实测 |
| **semkey-group-in-l0** —— `SemanticKey.cs:TypeSkill` 的三处组键（`k=action`+`chemo_target` 的【趋化源】、`k=action`+`effector_target` 的【免疫猎杀】/【Excalibur】）：GD 是两问、C# 是一条决策，用例的 key 两侧写不成同一个串；连累 `t_effector_responses` 9 条。补法：`l0_runner.gd:_execute` 见到 `k=action+<sub>\|` 就把 `act=` 留在头、其余字段拼成 `k=<sub>\|` 压进 `answers` 最前（`SemanticKey.FieldOrder` 两侧同序），约 15 行、core 不动 | 5c 第二段 | 批 5b 卡牌半边 S1 |
| **mobilization-ask-only-in-gd** —— **规则结果差**：GD `cw_card_fx.gd:_mobilization`【全身免疫动员】对每只免疫追问一次 free_move（可迁移 1 次 / 放弃），C# 只加 +1.5、一问都不问（副本实测作答那一步拿到的是普通行动表）；连累 `t_card_choices:13507 / 13509`。按口径一补充口径必须合：C# `CardRules` 那一支加追问（挂起态用现成的 `PendingChainCell` 一族） | 5c 第二段（core） | 批 5b 卡牌半边 P2 |
| **revive-not-in-l0** —— 复活挂在流程状态机上（`cw_game.gd:advance` 的 `revive_immune` / `revive_cancer` 两段 `_ask_each`），`execute` 的 `build_options` 里没有 ⇒ §0.2 ②「整局 / 状态机驱动」那一档；`t_cancer_revive_*` 27 条里 7 条是日志文案、13 条是落点集合（选项生成级）。真要收那 7 条就按 §0.6.4 开新 op（GD `CWWorld.revive_cancer/revive_immune` ↔ C# `PhaseRules.Revive` + `ReviveDecision`，两侧各有 1:1 具名入口，0.5 人日） | 5c 第二段（可选） | 批 5b 卡牌半边 S1 |
| **effector-infiltration-memory-depth** —— `t_card_choices:13446` 断的 `g.memory == mem0 + 1` 只在直调 `resolve_event`（depth 0）时成立；真正的抽卡路 `cw_cards.gd:draw` 先 `card_resolve_depth += 1`，净化就不给记忆。**两侧一致**，是老断言与产品路径的差 ⇒ 改判留 GD；仓库里 `execute/draw/effector_infiltration/free_move/into_cancer_purify` 只钉净化本身、`covers` 留空 | 留 GD | 批 5b 卡牌半边 P2 |
| **couple-tiers-stale-options** —— `t_card_choices:13633` 要「生成选项时付得起、执行时付不起」；L0 的选项与执行读同一盘面，造不出来 | 留 GD（或等前奏能改能量） | 批 5b 卡牌半边 P2 |
| **level-threshold-table-diff** —— 与上面的 **immune-level-threshold-table** 同一条（`t_effector_responses:5091` 要 `gain_memory` 跨过 X 级门槛）；Kevin 09-19 判规则结果差，批 2 第二段正在合；合上后这条与 5c 的 T4 例外一起放回 | 批 2 第二段 | 批 5b 卡牌半边 P2 ↳ 批 2 第二段已把 C# 门槛表合上（`CellRules.AddMemory` 两张常量表）⇒ 5c 的 T4 例外与 `t_effector_responses:5091` 可放回，下一轮 |
| 5c 落地时另外改判 4 条：`t_card_perms:13783 / 13797`（要走迁移进癌组织那一路，id 前缀是批 1/4 的，且 equipped 要写三个 T8 表外名字）与 `13903`（`act=antibody` 费用那半，批 4 只收了伤害半边）归 5c 第二段 / 并进批 4 的档；`t_card_perms:13986`（`is_legal` 选项生成级）与 `t_effector_responses:5209`（树突光环标记，不在 `execute` 任何一支且撞禁忌 T1）留 GD | 5c 第二段 / 留 GD | 批 5b 卡牌半边 P2 |
| **world-event-cost-modifiers** —— 费用侧世界事件（EMT + 基质阻隔）GD 4 / C# 2，`SkillRules.cs:294` 自注「C# 还没有事件容器」 | 批 5b | 批 5a S1 实测 **世界事件已删（Kevin 2026-09-19），本条空档作废** |
| ↳ 批 5b 第一段坐实差在哪：GD `cw_cost.gd:TEMPLATES` 三条（基质阻隔 MOVE MULT 2 / SKILL_MOVE MULT 2、免疫伪装 MOVE FLAT_ADD 2、迁移激活 MOVE FREE + `Store.EVENT_FREE`），cond 一律 `cancer` / `immune`；四档（`event:stroma_block_cancer` / `event:stroma_block_immune_unchanged` / `event:camouflage_plus` / `event:free_move`）**本批不开**（开了就是四条必红）。⚠【基质阻隔】翻「技能移动」是引擎比 PRD 多做的一步（`cw_cost.gd` 自注口径 #91）—— 照搬还是按 PRD 收窄要 Kevin 拍（§十三 第 5 条） | 第二段 A6 / A7 | 批 5b S1 **世界事件已删（Kevin 2026-09-19），本条空档作废** |
| **damage-tail-update-marks** —— GD 单体 `immune_hit` / `cancer_hit` 与范围都走 `submit → _submit_batch → update_marks()`，C# `CellRules.Damage` 没有这一步、抗体那条路的调用点也不补：树突在 2 格内时 GD 出 `mark_round 0→1`（标记被消耗后当场补回）、C# 出 `marked=false + mark_left=0`。用例按 F1 避开（不许有 ≤2 格的树突） | C# 侧合（随甲一起） | 批 4 S1 |
| **attack-outcome-world-events** —— C# `RulePolicies.AttackOutcome` 完全不读【抗原引导】/【免疫伪装】，写了必红 | 批 5b（世界事件） | 批 4 S1 **世界事件已删（Kevin 2026-09-19），本条空档作废** |
| ↳ 批 5b 第一段坐实：C# `RulePolicies.AttackOutcome` 等价的是 GD 的 **`base_verdict`**，不是 `attack_outcome` —— GD 那一层在 `base_verdict` 之后再套两句（fail + 【抗原引导】→ success、crit + 【免疫伪装】→ success）；两档（`event:antigen_guide` / `event:camouflage`）本批不开。按口径一补充口径合：签名不变、加两行（A1） | 第二段第 5 个提交 | 批 5b S1 **世界事件已删（Kevin 2026-09-19），本条空档作废** |
| **event-stacks-first-vs-sum** —— GD 自己就有两个读法（`CWGame.event_stacks` 取第一条 / `CWWorld._tgf_stacks` 求和），C# `WorldEffects.Stacks` 只有求和。今天不可达（世界事件同局不重复），第二段（容器 + 加倍）可能变可达；**不开 op**（开了只能出一条必红的用例） | 待 Kevin（§十三 第 6 条） | 批 5b S1 §5.1 **世界事件已删（Kevin 2026-09-19），本条空档作废**（【代谢加速】等读法已删；`CWGame.event_stacks` 只剩三张卡在用）。 |
| **opsonin-multi-reroll** —— 同一攻击者两张【补体调理】的重掷次序（F4：用例只放一张）。批 5a 没收：它是同名两条 mods，被 mods-same-name-path 挡住 ⇒ 改挂到那条名下 | 随 mods-same-name-path | 批 4 S1 / 批 5a 评委 |
| **macro-heal-paid-0.1** —— 巨噬回能封顶「实付 0.1」造不出来（迁移减免的共同地板 0.2；路 ② 造得出 0.7～0.2 与 0.0）；要盖它得走路 ①（`EnterTile` 加 `int paid = -1` 透传，动 core public 签名，报 Kevin） | 待 Kevin | 批 4 S1 / P2 |
| **damage-batch-semantics** —— `_t_damage_batching` 6 条主语全是 `simultaneous_group` / `DamageResult` 字段 / GD 自己的 state_hash，整函数留 GD | 留 GD | 批 4 S1 |
| **mods-same-name-path** —— delta 路径文法 `$.cells[i].mods[<名>]` 表达不了同名两条（`cw_case_diff.gd` 当场报歧义），判死 `_t_dmg_shield_on_benefit` 16524/16525 + `t_card_mods` 14374/14375/14376（定案 #57 同名一起扣）。批 5a 坐实：**只卡 delta、不卡 scalar**（两条同名【CXCR3趋化】的 `move_cost` 探针两侧同绿；两条同名护盾的 `damage_hit` delta GD 当场报歧义）；设计草案 = `mods[名#seq]` 第二级键 | 文法要加第二级键（§0.6.2） | 批 4 P2 |
| **批 4 结构上搬不动的两条**：`t_hit_order:449` 与 `_t_damage_required:17183/17189`（主语是「攻击者是树突 / 巨噬时不减半、不吸血」，`damage_hit` 不收攻击者、树突又被【各司其职】禁止攻击）；`t_batch_death_and_triggers::②同一目标在一批里只被宣死一次`（kills 内部记账）；【组织浸润】在 C# 是 `CardRules` 挂的 mods 条目而 E-2 路由表没有它、`SkillMoveModifiers` 也只处理三件（写 equipped 两侧分叉、写 mods UNLOADABLE）—— 批 5a 顺手补 | 留 GD / 批 5a | 批 4 S1 / P2 |
| **批 0 留 GD 的 26 个 check 名**（无 C# 对应物 21 个符号：`CWData.TOTAL_TILES` / `DIFFERENTIATE_MIN_LEVEL` / `HAND_MAX`（C# 只有 `Cell.HandMax` 的 record 字段缺省）/ `EMT_MOVE_COST` / `MUTATE_EXTRA_LOSS` / `MUTATE_MEMORY_CUT` / `CHEMO_IMMUNE_PCT` / `CHEMO_SELF_PCT` / `MARK_RANGE` / `LEVEL_MIN_MEMORY` / `EFFECTOR_NAMES` / `IMMUNE_TYPE_TEXT` / `init_cancer_tiles` / `aerobic_level_base(n)` / `level_min_memory(n)` / `skill_text` / `ring`、`CWCardData.CARDS`（两侧形状对不上）/ `effect_of`；C# 侧 private 够不着：`CWData.VESSELS`（`MatchSetup.Vessels`）/ `all_coords`（`MatchSetup.AllCoords`））—— 涉及 `t_immune_level_rules`（门槛表 5 条）/ `t_ring_and_toxin`（`ring` 4 条）/ `t_card_pool` 3 / `t_mark_range` 2 / `t_skill_info` 2 / `t_antibody_no_target_x` / `t_batch2_rules` / `t_board` / `t_card_mods` / `t_draw_purify_memory` / `t_effector_responses` / `t_guide_director` / `t_hunt_fx` / `t_mutation_faces` / `t_setup` 各 1 | 各自等对应机制迁 C#（免疫等级门槛表 = E-3 判死的 `differentiate_min_level` 家族；`ring` / `neighbors` 类几何工具随批 3；文案类永远留 GD） | 规格 B 批 0 落地记录 |
| **批 0 撤回的 5 条**：`const/data/hand_max`（C# 只有 record 字段缺省）、`anaerobic_cells_k` 与 `antibody_no_target_x` 的越界钳住各 2 条（GD `clampi` 住在静态函数里、C# 是裸表，纪律 3 不在靶场补 clamp、也不为测试在 core 开 clamp 壳） | 留 GD | 批 0 评委 |

| ~~KG-1~~ **已合上（2026-09-19 同日，d0dd3ca：旋钮 -1 按人数 / >0 覆盖 / 0 线性对照档，`anaerobic` 加 formula:linear_ref / warburg:sclc 两档）** · `anaerobic` 两个旋钮 C# 没生效** —— `world.tuning` 写了 `anaerobic_block_coef=0` / `anaerobic_floor=0`（A′/A 档），C# 算出来的是默认档的数（期望 11 得 24、期望 13 得 27）；【瓦伯格】110% 跟着量不到 | C# 侧修；修完 `t_anaerobic_round` 001 / 002 原样放回 | 批 3 P2 实测 |
| ~~KG-2~~ **已合上（2026-09-19 同日，d0dd3ca：【增殖抑制】整步不掷，`proliferate` 加 event:proliferate_suppressed）** · `proliferate` 在【增殖抑制】下两侧掷骰次数不同** —— GD 一次都不掷（`rolls: []`），C# 还要抽 `[1,1000]`，`TapeException RNG_OVERRUN` | C# 侧修（rng 次序类，批 4 的 Tape 化也会撞） | 批 3 P2 实测 |
| ~~KG-3~~ **已合上（2026-09-19 同日，d0dd3ca：千分率 ×2^层数，加 event:abnormal_double）** · 【异常增殖】的翻倍 C# 侧没实现** —— `d.proliferate_chance` 全是 GD 的一半（500 vs 1000、1500 vs 3000），六邻一格没转 | C# 侧修 | 批 3 P2 实测 |
| ~~KG-4~~ **已合上（2026-09-19 同日，d0dd3ca：免疫占格不转、标记留着，`ossify` 加 immune_standing_keeps_mark）** · E-硬化「到期回合免疫站在格上不转固化」C# 侧缺** —— GD 不转、标记留着（changed 空），C# 照转不误（多出 `tiles@0,0.tissue=2` + `ossify_at=0`）。云端 PRD 2026-09-10 加的条件。连累 `t_batch2_rules` 16121 / 16124 / 16125 三条（第 4 回合还没到期 / 第 5 回合转固化 / 转化后标记清掉）整段不进仓库 | C# 侧补条件 | 批 3 P2 实测 |
| ~~KG-5~~ **已合上（2026-09-19 同日，d0dd3ca：C# loader 缺省 camp_pos (0,0)、dump/minify 省掉 "0,0"，`resolve_camping` 加 camp:full_round）** · `camp_pos` 的 `{q,r}` 形状两侧对不上** —— C# 报「`changed` 里的 `$.cells[0].camp_pos.q` 在 pre / post 上一个字段都命不中」（GD 侧同一条绿）。envelope 形状差，不是规则差。连累 `resolve_camping` 的「蹲满一回合净化完成 / +1 抗原记忆 / 标记随净化取消」三条 | §0.6.1 补一条字面口径 | 批 3 P2 实测 |
| **KG-6 · 骨髓 / 核心格的 `store` / `cards` 落点** —— GD 的整盘 dump 在骨髓格上写了 `store`，C# `WorldLoader` 抛「`store` 是代谢核心那类的存量、`cards` 只有骨髓格有」。连累 `erosion` / `proliferate` 的 `necrosis_cleared_on_flip` 两档 | §0.6.1 补一条字面口径 | 批 3 P2 实测 |
| **KG-7 · 盘外细胞 (5,5) 的口径** —— `t_card_mods` ⑩段把癌细胞摆在半径 6 的棋盘外，GD 容得下、C# `WorldLoader` 不收。连累 `decay` 的 `event:suppressed` / `event:expired_resumes` 两档 | 要么原测试挪进盘内，要么两侧统一口径 | 批 3 P2 实测 |
| ~~KG-8~~ **已合上（2026-09-19 同日，d0dd3ca：C# 编码器 g.differentiated 按旗标现算（与 GD loader 同口径），`expire_marks` / `tick_chemo_track` 转 required）** · `differentiated` 由哪一侧现算（闸二 2b 红，按 C-3 最要紧）** —— GD `cw_case_loader.gd:_differentiated_of` 要 `cell["differentiated"] == true`，C# 按细胞 `type` 现算；一只 `differentiated=false` 的树突细胞 GD 算 0 种、C# 算 1 种（`$[state][g][differentiated]` 条数 0 → 1）。既有 156 条用例里没有这种细胞，以前没露出来 | **等 Kevin / 主会话裁**；裁完 `expire_marks` + `tick_chemo_track` 当场从 deferred 转 required（+4 条用例、+2 行） | 批 3 P2 实测 |
| ~~`pressure` 的护盾三条~~ **已收（批 5a，`shield` 档）**：原文（首次闸门已烧 / 盾完全吸收 / 压迫吃掉这面盾）—— 三条都要 `cells[].mods` | **批 5a**（setup_ops 的 `mods` 路由已开，重新分诊） | 批 3 评委 missing |
| **`proliferate` 的固化块计数四条**（两个相邻块各一格固化 5305 / 固化在块深处 5309 / 同一块只算一次 5323 / 守护半径恰为 3 13873）—— 前三条的主语是 `proliferate_chance(t)` 的**数值**、第四条是 `_watched(pos)` 的布尔，都不是 `_proliferate` 这一步的 delta | 归 `proliferate_chance` scalar 探针那一档（批 2 补） | 批 3 评委 missing |
| **`tick_necrosis` 认领的两条 check**（`t_necrosis::坏死一过，两种格子照常攒` / `坏死一过，血管照常把人送到另一端`）—— 这两句断的是两次 `_tick_necrosis` **之后**由 `_tissue_production()` / `_vessel_teleport()` 产生的结果；批 3 的 4 条用例只钉倒计时本身（necrosis 2→1 / 1→0），按「covers 指不到就不认领」`covers` 留空。全文七处 `_tick_necrosis` 调用点逐条查过，没有任何一条 check 单独断言坏死计数器 | 随 `tissue_production` / `vessel_teleport` 那批迁 | 批 3 评委 conflicts #5 |
| ~~机件 ③ `erosion.fresh` 文法~~ —— **已合上（批 3 落地）**：`cw_rec_world.gd` 录 `";".join(...)`、`l0_runner.gd:_positions` 改收 String 再 `split(";")`（空串 = 空表），与 C# `Steps.Args.Positions` 逐字相同 | —— | 批 1 登记的机件三条，至此全清 |
| ~~B1 · 收割器没看 loader 的 `errors`~~ —— **已合上（批 3 落地）**：`cw_case_loader.gd:dump_world` 末尾 `errors` 非空就整份作废返回 `{}`（B1a）；`cw_recorder.gd` 每次 dump 之前 `_fill_cancer_types()` 现算癌席癌种、**取完 envelope 原样放回**（它进 `state_hash`，留在世界里 `t_rec_transparent` 当场红） | —— | 批 3 S1 B1 / 落地时实测 |
| ~~B4 · 代理只挂在 `make_game()` 上~~ —— **已合上（批 3 落地）**：`headless_test.gd:bare_game()` 末尾也过一次 `on_game_made`（不设 Callable 时一行都不执行）。全仓 103 处在用，落地前跑过全量 GD 套件 3895 项 | —— | 批 3 S1 B4 |
| ~~B9 · 同席多细胞 ⇒ 收割器静默产出 `changed` 空的假绿草稿~~ —— **已合上（批 3 落地）**：`cw_recorder.gd:finish()` 差分完查一次 `Diff.errors`，非空按规矩 5 记 UNLOADABLE、不产用例（288 → 275 条草稿，落掉的 13 条全是这一类） | —— | 批 3 P2 new_blockers |
| **B5 · `_dump_tuning` 表达不了分档表被清空 / 缩短** —— `t_necrosis` 把 `g.tune.aerobic_by_level` 设成 `[]`，dump 里一个键都不出现；连累 `tick_necrosis` 的 `countdown:board` 一档 | **批 2**（收有氧时一定撞）之前定「清空」的写法 | 批 3 S1 B5 （`countdown:board` 那一档另一个阻塞 —— C# 盘面式抛 —— 批 2 第二段也消了） |
| ↳ **已合上（2026-09-19 批 2）**：表长语法 `name[]: <长度>`（只许缩短，加长 UNLOADABLE），两侧 loader 两趟、dump 长度不同先写 `name[]`、minify 按缺省长度削 + 等于缺省的普通旋钮也削（C# `MinifyTuning` 补对称）；压力用例 `stress/tuning/aerobic_by_level_truncated_roundtrips`（`probe: proliferate_chance` + `aerobic_by_level[]: 0` + 期望 30，一个有氧数字都不碰）闸二 2a 钉住；变异：dump 不写 `name[]` → 2a 红、load 不认 `name[]` → 越界红 | —— | 批 2 P1 / 评委 |
| **B6 · `events.active[].data` / `doubled` 的编码不合 §0.6.1 第 5 条** —— `data` 被 dump 成 GDScript `Vector2i` 的 `str()`（`"(0, 1)"`，不是协议 `"q,r"`）、值还是 bool，而 C# `L0Effect.Data` 是 `Dictionary<string,int>` ⇒ 整文件 `JsonException`；连累 `tick_durations` 的 TNF 那一档 | **批 5b**（世界事件） | 批 3 S1 B6 **2026-09-19**：`doubled` 随世界事件冻成恒空串；`data` 那一半（TNF-α局部炎症，**卡牌**）照旧挂着。 |
| ↳ 批 5b 第一段：**整条归第二段第 1 个提交**（要同时改 GD `cw_world_loader.gd` 的 `_load_events` / `_dump_events` 与 C# `L0Effect`，P1 / P2 在两台副本上并行时不能各改一半 —— 批 3 的 NO-GO 就是这么来的）；本批用例的 `data` 一律 `{}`。紊乱的坐标值装不进 `<string,int>`：替代案 `"<id>.q"` / `"<id>.r"` 两个 int 键（§十三 第 3 条） | 第二段第 1 个提交 | 批 5b S1 §2.4 **2026-09-19**：世界事件半边作废，只剩卡牌侧的 `data` 编码。 |
| **B7 · `cap_energy` 在 `headless_test.gd` 里零 check** —— `cap_energy` / `energy_cap` / 能量上限 / 溢出 四个词全空 | 手写一条（不属「一律收割」口径） | 批 3 S1 B7 |
| **B8 · `t_ossify_cost_and_pin` 在收割器下跑不出结果** —— 同批 21 个函数里只有它没打出 HARVEST 行（该函数以 UI / 价签断言为主，批 3 不依赖） | 收割器碰 UI 函数会挂，记一笔 | 批 3 S1 B8 |
| **B10 · 规矩 5 只验 dump、不验 load** —— 装不回去的世界照样出草稿（细胞写在不存在的席位 / 盘外格）；连累 `tick_chemo_cd` 整条与 `anaerobic` 的 k 系数档 | `finish()` 里再 `load_world(pre)` 一次（本批未做，登记） | 批 3 P2 new_blockers |
| ↳ 批 2 复核：仍未做、仍登记；只连累收割批（`harvest.gd` 出草稿那一路），**不**连累 `anaerobic` 的 k 系数档（那档挡在 Q3 的旋钮 tier） | 收割批 | 批 2 S1 |
| ~~aerobic-board-formula-not-migrated~~ **已合上（2026-09-19 批 2 第二段）**：C# `RulePolicies.AerobicBase` 两条 `throw` 换成按人数分档（`{2:2.0,4:2.0,6:1.8}`，缺省 2.0）+ 盘面式（`(健康 − 坏死) × 3.0 ÷ 127`）；用例 `aerobic_board_formula.json`（`board_formula/full_board` / `necrosis_20_tiles` / `by_players/six_players_1_8`）；growth 项未迁另记 aerobic-mult-growth-not-migrated | —— | 批 2 P1 |
| ~~aerobic-floor-cap-not-migrated~~ **已合上（2026-09-19 批 2 第二段）**：C# `AerobicShare` 补 GD `clamp_income` 两行（夹在基准上、排在均分之前），`RuleTuning.AerobicFloor / AerobicCap` + `WithKnob` + dump / minify 行表各两行（评委抓的：行表漏了 ⇒ 闸二 2a 对它们空过）；`aerobic_floor` / `aerobic_cap` 挪 A′（「挪进去吧」（09-19，两行随三个无氧旋钮一起挪 A′））；用例 `aerobic_share/floor_pinned` / `cap_pinned`；变异「夹钳排到均分后 / 封顶排到低保前 / 整条失效」各只红该红的 | —— | 批 2 P1 / P2 |
| **split-share-count-zero** —— 口径已定（批 2 第二段）：GD `_split_share(pool, 0)` 是 `scaled / float(0)` = inf → `int(round(inf))` = INT64_MIN 再被地板兜成 2.0，**UB 不是规则**，不复刻；C# 改成抛 NotSupportedException，`AnaerobicShare` 调用处 `maxi(count, 1)` 守着（变异「守卫失效」2 红 / 「调用处 maxi 拿掉」1 红）。用例仍禁 `count ≤ 0`（T12） | 已定、不写用例 | 批 2 P1 |
| ~~immune-level-threshold-table~~ **已合上（2026-09-19 批 2 第二段，Kevin §十五 Q1 判规则结果差）**：C# `CellRules.AddMemory` 行内 `Count==6 ? 70/30 : 50/20` 换成 GD 的两张常量表（缺省 `[0,10,30,70]`、4 人 `[0,10,20,50]`；真分叉只在 2 人与 5/7 人的 III/X）；用例 `enter_tile/purify/memory/level/two_players_stays_II`（2 人局 20~29 停 II）+ `four_players_reaches_III` + X 级清零；变异「缺省档退回旧值」9 红 / 「四人档失效」7 红（含 `4p_chemo` L1 夹具）。**教程口径**（§十五 Q-18）：教程关卡不按席位数回落，一律钉 6 人档 | —— | 批 2 P1 / P2 |
| **aerobic-mult-growth-not-migrated** —— GD `cw_tuning.gd:aerobic_mult_at(round_no)` 的 growth 项（系数随世界回合线性增长）C# 盘面式只复刻了 `maxi(aerobic_mult, 0)`；`aerobic_mult_growth` 是 E-3 判死的 B 档、两侧拧了都硬错 ⇒ growth = 0 是唯一装得进的取值；口径从「显式抛」降成「注释里写着」，今天 C# 内核没有任何路径能把 growth 设成非 0 | 随 E-3 判死档一起处置 | 批 2 评委 #5 |
| **antigen-exposure-memory-bonus** —— GD `cw_game.gd:gain_memory` 开头【抗原暴露】的 `event_stacks` 加成（每**次**获得 +stacks），C# `AddMemory` 整条没有。事件**内容**，Kevin 选的 5b 第二段 (b) 不含它 | 批 5b 内容档（未排） | 批 2 P1 Q3 **世界事件已删（Kevin 2026-09-19），本条空档作废**：GD `gain_memory` 开头那段已删，两侧逐字等价。 |
| **tissue-production-nutrient-shortage** —— 【营养缺乏】下的产出档 C# 不读 `s.Effects`（随批 5b 第二段 A3） | 批 5b 第二段 | 批 2 S1 **世界事件已删（Kevin 2026-09-19），本条空档作废**：GD `_tissue_production` 的【营养缺乏】早退已删，两侧逐字等价。 |
| **r4-tree-float-gate-missing** —— R4 浮点硬闸只装在 scalar 与 delta 两处；tree 一侧 GD `l0_runner.gd:_to_json` 遇 float 静默 `int(round(v))`、C# `L1View.Plain` 拿到 double —— tree 探针今后**不许返回 float**，返回了两侧静默分叉（今天没有返回 tree 的浮点探针，炸不了）；要补是两侧各一句 | 下一个返回 tree 的浮点探针出现时 | 批 2 评委 #11 |

## 四、旋钮四档（`game/tests/contract_tune.json`，65 行 = `CWTuning` 属性全集）

| 档 | 条数 | 处置 |
|---|---|---|
| **A · 已接** | 36 | `WorldLoader.WithKnob` 已有；不动（批 2 第二段实测校准：原表 22/3/18/22 是 09-19 早间的旧数） |
| **A′ · 有属性没接 → 已接** | 7 | `anaerobic_block_coef` / `proliferate_per_adjacent[i]` / `proliferate_per_solid[i]` + 批 2 第二段挪进来的 `anaerobic_block_exp` / `anaerobic_per_cancer` / `anaerobic_per_solid` / `aerobic_floor` / `aerobic_cap`（两侧 loader 都接了线） |
| **B · C# 根本没有** | 6 | 拧了**两边都当场红**并报「这个旋钮 C# 没有对应物（E-3）」。E-3 已拍：补 6 / 判死 5 / 待定 7 |
| **C · 没人在 GD 测试里拧过（L0 用例可以拧）** | 16 | 登记在案、不进白名单、拧了报「不在白名单」；要用先挪 A′ 并两侧接线 |

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
| 2 | 收入 | 141（S1 按单条 check 主语逐条筛得 156：留 GD 79 / 已收 26 / 等数值口径 25 / 本批可落 26） | 32（第一段 15 + 第二段 17） |
| 5b | 需中途询问的卡 + 事件 | ~150 + `t_ev_*` 53（卡牌半边 S1 逐条筛得 294：可落 81 / 留 GD 87 / KNOWN_GAP 29 / 已收 93） | 85（世界事件第一段 5 + 卡牌半边 80） **2026-09-19**：世界事件半边（第一段 5 条）整批作废、用例删除，本行只剩卡牌半边（5c，80 条）。 |

## 六、明确不搬的

| 类 | 实测 | 处置 |
|---|---|---|
| 日志文案 | 20 条 / 17 个函数（core 的约 1.8%） | 逐条留 GD。⚠ 划分要落到单条 `check`，不能按函数整块划 |
| 整局 / 状态机驱动 | 计划自报 125 条 | 随 GDScript 内核退役（L2 延后到阶段 1，不是被证伪）。例外：`settle_loss` 4 条进批 0 |
| ui / net / guide / persist / ai / patch | 2035 站点（61.1%） | 不在本规格范围 |
| 测试设施与宿主自测 | 181 站点 | 验的是对拍机件本身，留 GD |
