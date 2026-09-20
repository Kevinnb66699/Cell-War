# 口径二 · 批 2「AI 进 C#」—— 交接包（硬约定 + 设计稿，2026-09-19）

> **交接说明**：Kevin 2026-09-19 决定「AI 进 C# 让队友完成」，并已拍：只交付**普通 AI（启发式）**进 C# + 策略口，扁平 MC / MCTS 不迁；其余六条见 `docs/archive/内核替换_拍板记录.md` §十 / §十五。本包 = 规划工作流 S1 出的硬约定（JSON 原文附后）+ 设计稿 + 主会话对八个工程问题的裁决。方案稿正文见 `docs/archive/口径二_批2_AI进C#_方案.md`。三条线（A 止血两件 / B 子进程入口 / C `CellWar.Ai`）都还**没有落地**，副本 `scratchpad` 里的半成品不作数，队友从硬约定开工即可。

---

# 批 2「AI 进 C#」—— 三条线的设计、人日、风险（S1 产出）

> 只读调研。行号核于 `csharp-core` HEAD **7487567**。
> **S1 写完时 HEAD 已前进到 022bd16**（「拍板记录 §十五再续三」）—— 逐文件核过：那一次**只改 `docs/archive/内核替换_拍板记录.md`（+5 行）**，本文引用的代码行号一处没动。
> 那 5 行正是本轮的收窄口径入库：Kevin 原话「关于 AI 交付的问题，拍板 1 你只需要交付普通 AI（启发式），剩下两个不需要迁移」，同处写明「§十 拍板 1 收窄定稿……扁平 MC 与 MCTS 不迁移（留在 GD 侧直到 GD 内核退役，之后由训练模型接）。(a3) 子进程止血与 4bis / 计数器照旧」。
> 硬约定的机器可读版在 `scratchpad/ai_contract.json`；本文只写「为什么这么切」「多少人日」「哪里会塌」。
> **每条事实带出处**。没有出处的句子是判断，一律用「⇒」「建议」起头。

---

## 〇、一页结论

1. **三条线互不依赖，可并行，分三次提交，顺序 A → B → C。**
   A 与 B 都要改 `game/scripts/net/cw_net_bridge.gd` 的同一个 `_init()`（A 设预算、B 拨子进程开关）⇒ **A 必须在 B 之前落**，否则第二次补丁的 old 锚点对不上。C 不碰 `game/**`，与谁都不撞。

2. **Kevin 09-19 追加口径把线 C 收窄了一档，这一档改变了三件事**（原话「拍板 1 你只需要交付普通 AI（启发式），剩下两个不需要迁移」）：
   - `cw_eval.gd` 的 13 维特征与 13 个权重 **不搬**。理由不是「不想搬」，是**启发式根本不用它** —— `grep CWEval game/scripts/ai/heuristic_bridge.gd` 只命中三条版本号注释（`:14` / `:18` / `:28`），零调用；估值是扁平 MC 与 MCTS 的末端（`monte_carlo_bridge.gd:213`、`mcts_bridge.gd:161`）。⇒ 「特征」这一件从「13 维 + RL 稿 §3 的几十个量」缩成「启发式今天读的那些量」。
   - **不留 MC / MCTS 的接口占位**。没有 `ISearch` / `IRollout` / `ILeafValue` 这类为将来预留的空壳 —— 预留的接口没有第二个实现来证伪，改起来比重写还贵。
   - 交付物的性质从「陪练桩」变成**产品 AI**：它将来是 C# 权威侧上真正出手的那一档「普通」。⇒ 测试判据要多一条「每种 DecisionType 至少命中一次」，否则「把某个分支改成恒回 0」这种变异，只测合法性是抓不到的。

3. **线 C 的最大结构收获：它绕开了 P-1 与 P-2。**
   方案 §四把 `Runtime.Fork()` 的 rng 缺口（P-1）与 `MatchSession` 注不进 rng（P-2）列成 (b) 的第一必修。但那是「AI 住在 Runtime 里」才成立的前提。本批的 AI 直接在 `WorldState` 上滚（`BasicRulesEngine.ExecuteDecision(state, decision, rng)` 收 state、回 `RulesResult(NewState, …)`），**自己持有一只 `Xoshiro256StarStar`，永不碰权威侧的随机流** ⇒ P-1 / P-2 既不挡它、它也不修它们。两条账仍欠着，但不在本批的关键路径上。

4. **三处「简报里的事实」要更正**（都已核，见 `ai_contract.json.verified_today`）：
   - `WorldState` **不是 record**，是 `public sealed class` + init-only 属性（`WorldState.cs:8`），唯一字段清单是 `WorldStateExtensions.Copy`（`:12`），另有 `DeepClone()`。别写 `with` 表达式。
   - **`core/` 下没有 `.sln`**。简报说的「进 `core/*.sln`」不成立；仓库唯一的 dotnet 入口是 `tools/run_l0.sh:50` 的 `dotnet test core/CellWar.Core.Tests`。
   - 本地那条预算闸在 **`match.gd:900`**（方案稿写的 `:872` 已位移）；`state_hash()` 在 **`cw_room.gd:664`**（方案稿写 `:665`）。

---

## 一、线 A · GD 止血两件（1.0 人日）

### A1 · 联机专家档补 `max_sim_steps = 192`（0.5 人日）

**事实**：`cw_net_bridge.gd:16` 建的那只 `mc` 从来没设过预算，默认 `0 = 无上限`（`monte_carlo_bridge.gd:32`）；本地路上 `match.gd:900` 一直有这条闸。实测代价：381~645 ms / 决策（`拍板记录:313`、`开发日志:170`），bench 上 178~183 ms；补上 192 之后落到 48.7~52.8 ms 那一档（`docs/archive/架构审查_2026-09-02.md:68`）。

**设计**：把 `match.gd` 写死的 `192` 提成 `const AI_MC_MAX_STEPS := 192`，两侧同读。
⇒ 「联机 = 本地」从**两处字面量恰好相等**变成**结构事实**，将来任一侧改动都会被新测试抓到。
代价是多改 `match.gd` 一行（简报写的是「只改那一行」）—— 这是 S1 的判断，列进 questions 让 Kevin 一句话认。

**唯一的行为改动**：联机专家档弱一档。Kevin 4bis 已认这个代价，但**没人写过「专家档有多强」这句对外说法** ⇒ 列进 questions。

**实现细节（P-A 别踩）**：GDScript 不能在成员声明里链式设属性，要走 `func _init()`。加 `_init` 之前先核一遍 `CWNetBridge.new()` 的全仓调用点是不是都无参。

### A2 · 两个计数器（0.5 人日）

**为什么不是 fx-diag**：fx-diag 是**客户端 print**，要 Kevin 装诊断包 → 打一局 → 复现 → 回传日志；四步一步没成（`拍板记录:317` 已打、`:330` 至今 0 条、`:338` Kevin 叫停）。这两个计数器打在**服务器 / 房主侧与播放队列上**，我们自己跑的无头测试和任何一局局域网房都会写出来。

**设计**：`CWRoom.fx_stats`（push 次数 / 总微秒 / 峰值 / `state_hash()` 单独一份）、`CWPlayQueue.fx_stats`（批数 / 积压快进次数 / 触发时的最大 `batch.size()` / 手动快进另计）。前缀 `[fx-count]`，**别复用已叫停的 `[fx-diag]`**。

**一处要更正简报**：简报写「怎么在 `net_play.gd` 里读出来断言存在」。`net_play.gd` 是纯客户端（`CWNetClient`），既读不到 `CWRoom` 的计数器，也不建 `CWPlayQueue` ⇒ **断言只能落在 `headless_test.gd` 的进程内联机测试上**（`t_play_queue` 在 `:19739`、`:19815` 已有 `hurry_backlog = 3` 一批 5 条那段；`CWRoom.new()` 直测有 `:7546` / `:18247` 的先例）。`net_play.gd` / `net_live.gd` 的作用是「跑起来就会看见那两行」，不是断言点。

**零行为改动的执行机构**：`_hurry_now` 的判定式（`cw_play_queue.gd:50`）、`state_hash()` 的调用次数与位置、`push_state_to` 的报文内容与顺序，一个字不许动；`fx_stats` **绝不能进 `CWStateCodec` / `state_hash`** —— 进了 `t_ai_same_hash` 与 `t_rec_transparent` 那族当场红（那一族正是 2026-09-19 批 3 落地时被「往 `players[].cancer_type` 写值」咬过一次的地方）。

---

## 二、线 B · (a3) 两个静态线程入口 → 子进程入口（3~5 人日）

### 为什么这条能成立

今天的线程边界**已经是一条纯数据边界**：`cw_mc_thread_entry(holder, snap, options, cfg, _box)`（`monte_carlo_bridge.gd:135`）与 `cw_mcts_thread_entry`（`mcts_bridge.gd:119`）都是 `static`，入参全是可 `var_to_bytes` 的纯数据，出参只有 `{best, stats}`；`_evaluate_on` 的注释自承「只依赖 image 与 cfg，绝不碰外层 game / 场景树」（`:164-165`）。⇒ 把 `Thread.start()` 换成「起一个子进程、送 `(snap, options, cfg)`、收一个下标」，**数据契约一个字不用改**，`t_ai_same_hash` 不用重录。

### 关键设计决定（与理由）

| 决定 | 理由 |
|---|---|
| 子进程 = **本体自身** `OS.get_executable_path()` | 导出包里它就是游戏 exe ⇒ **导出模板与 `publish_release.sh` 零改动**。编辑器 / 源码树里要额外带 `--path`。 |
| worker 脚本放 **`game/scripts/ai/cw_ai_worker.gd`** | 导出预设 `exclude_filter="tests/*"`（`docs/archive/内核替换_迁移计划.md:294-295` 段落引的同一条），放 `game/tests/` 导出包里就没有它。 |
| 通信走**本地 TCP**（loopback + 一次性 token） | ① 编解码现成：`CWNet.encode/decode` 就是「4 字节原长 + zstd(var_to_bytes)」（`cw_net.gd:249`/`:267`），能直接吃带 `Vector2i` 键的快照；走 stdio + JSON 要新写一套 `Vector2i` 编码。② 与 sidecar 计划的 loopback + token 共用一套（`cw_kernel_sidecar.gd:3`）。③ 宿主轮询形状与今天的 `while not ready: await tree.process_frame` 逐字相同。④ **`OS.execute_with_pipe` 在无头导出包上可用与否，方案稿 §九 #6 自己说没核** —— 不拿未核的 API 当地基。 |
| **短命进程**先做（每决策一只），worker 池后议 | §九 #7：Godot 无头冷启动耗时**今天没量过**。子进程入口开头 print 一行冷启动毫秒 ⇒ 第一次跑完就有数，再让 Kevin 定要不要池。 |
| `use_subprocess` **默认 false** | 否则 `run_tests.sh` / 平衡模拟 / 教程会起成千上万个进程。只有真对局 UI（`match.gd:905` 旁）与联机桥拨开。 |

### 三级回落（硬纪律）

子进程 → 线程 → 同步。网页版 `OS.has_feature("web")` ⇒ 恒走 `_eval_sync`，与今天逐字相同（`monte_carlo_bridge.gd:110-112` 那段「单线程的必然」原样保留）。
**回落不是「拿一个别的答案」**：回落是拿同一份 `snap` 重算 —— 同一段代码、同一份数据 ⇒ `best` 逐位相同。这正是四条回落测试都能断言「与 `_eval_sync` 相同」的原因。
**硬不变量**：子进程起不来 / 超时 / 崩溃**绝不能计进 `patch_state.gd` 的 STRIKES**（批 0 底座规格 A-3.3 硬不变量②的同一条精神）。这要做成一条断言，不是一句注释。

### 三条产品路

- **本地单机 / 热座**：`match.gd:904-905` 今天已经在真对局上拨 `use_threading`，(a3) 就是在同一个开关后面多一级。教程局 `thinking` 恒 false ⇒ 天然不起进程。
- **联机**：`cw_net_bridge.gd` 那只 `mc` 拨开。`docs/开发日志.md:2186` 说的「服务器代码处处假定单线程」那一层**一行都不碰** —— 主线程仍是单线程，只是在 `await tree.process_frame` 上等（与今天 `cw_net_bridge.gd:26` → `cw_net_server.gd:80-83` 的让帧同一套）。局域网房主同进程那条路（`online_panel.gd:390`）一并治好。
- **网页版**：不治也不退化。

### 风险

- **R-B1（最大）**：导出包里 `--headless --script res://scripts/ai/cw_ai_worker.gd` 能不能跑 —— **仓库零先例**（全仓零 `OS.create_process` / `OS.execute` 实调，唯一命中是 sidecar stub 的计划注释）。P-B 必须在无头 + 一个真导出包上各实测一次。跑不通就停下来报，**不要自己改成 stdio**（那是未核的另一条路）。
- **R-B2**：冷启动耗时未量。若冷启动是 100 ms 量级，联机每决策起一只进程就不划算 —— 量出来写进回传，短命 vs 池的取舍留 Kevin。
- **R-B3**：冒烟测试真起进程，在 `SHARDS=2` 分片并行下可能抖。上墙钟上限 + 只在 `OS.has_feature("pc")` 上跑 + **失败必须红**（不许降级成警告，否则等于没测）。

---

## 三、线 C · C# `CellWar.Ai` 地基 + 完整的普通 AI（14~20 人日）

### 3.1 骨架：已经实测过一遍，不是纸上推断

在 `scratchpad/s1_ai/core/` 的副本上跑过：

1. 新建 `core/CellWar.Ai/CellWar.Ai.csproj`（`net8.0`，`ProjectReference → CellWar.Core`）+ 一个探针类，调 internal 的 `RulePolicies.PressureAt` 与 public 的 `BasicRulesEngine.GetAvailableDecisions`；
2. `core/CellWar.Core/CellWar.Core.csproj` 加一行 `<InternalsVisibleTo Include="CellWar.Ai" />`；
   ⇒ `dotnet build`：**Build succeeded, 0 Error(s)**。
3. `core/CellWar.Core.Tests/CellWar.Core.Tests.csproj` 加一行 `<ProjectReference Include="..\CellWar.Ai\CellWar.Ai.csproj" />` + `Ai/ProbeTests.cs`；
   ⇒ `dotnet test --filter AiProbeTests`：**Passed! Failed: 0, Passed: 1**。

**TFM 取 `net8.0`**（= Core），不是 Tests 的 `net10.0` —— 铁律①「AI 与 Core 永远同包同 build」。net10.0 的测试工程引 net8.0 的库没问题（上面第 3 步就是）。

### 3.2 ⚠ 要报的一件：core 那一行其实是两行

简报写「**core 只许动这一行**」。实际要两行：

| 行 | 文件 | 为什么非它不可 |
|---|---|---|
| 1 | `core/CellWar.Core/CellWar.Core.csproj` | `InternalsVisibleTo("CellWar.Ai")` —— 拍板 3 的字面实现 |
| 2 | `core/CellWar.Core.Tests/CellWar.Core.Tests.csproj` | **没有它，`CellWar.Ai` 不会被仓库里任何现有命令编译或测试。** `core/` 下没有 `.sln`，唯一的 dotnet 入口是 `tools/run_l0.sh:50` 的 `dotnet test core/CellWar.Core.Tests` |

替代方案（另开 `CellWar.Ai.Tests` 工程）**更重**：它要改 `tools/run_l0.sh`，还拿不到住在 `CellWar.Core.Tests` 里的 L1 夹具装载器（`L1View.Load` / `TapeRng` / `DeepDiff`）。
⇒ **建议认这第二行**：它在测试工程里，零产品影响，且已实测。列进 questions。

### 3.3 地基四件（收窄后的形状）

**① 可分叉世界 —— 不走 `Runtime`，直接在 `WorldState` 上滚**

`Runtime.Fork()`（`Runtime.cs:179-188`）确实是 O(1) 结构共享 + `PresentationMuted = true`，但它带 P-1 的活缺口：构造函数只在 `lease.Snapshot.Simulation.Rng == null` 时写入 rng（`:44-49`），分叉出来的快照 `Rng` 非空 ⇒ 每步 `rng.SetState(before.Rng!.Value)`（`:94-95`）用的是**真实流**，AI 会提前看到自己的骰子（`Runtime.cs:84-93` 的注释自己把这条写在第三位）。修它要动 core，本批不许。

⇒ AI 自己拿着 `WorldState` 往前滚：`ExecuteDecision(state, decision, rng)` / `AdvancePhase(state, rng)` 都收 state、回 `RulesResult(NewState, …)`，天然不改原世界。rng 是 AI 自己 `new` 的一只，派生口径照 GD 抄 `hash([根种子, 分叉序号])`（`monte_carlo_bridge.gd:236-240` 解释过为什么不用「状态 + 常数偏移」）。
**判据**：推演 200 步后原 `WorldState` 的 `L1View.Of` 逐字段不变。

**② 合法动作枚举 —— 关键是「定序」**

`BasicRulesEngine.GetAvailableDecisions(s, seat)`（`BasicRulesEngine.cs:36` → `DecisionRouter.Available`）走 `PagedMap` 的迭代序，**那个序不是契约** —— `SemanticKey.cs` 的文件头自己写着「拿下标对，第一步就错位」。
⇒ `LegalActions.Of()` 生成 `(Index, Key, Decision)` 之后**按 `Key` 的 Ordinal 序重排再编 Index**。不这么做，同一局面两次枚举可能给出不同下标，而「下标」正是 `IPolicy` 的输出。
另：要认 `SemanticKey.PassKey`（`k=action|act=pass`）—— C# 每个 action 问答固定多这一条，GD 没有。

**③ 特征 —— 只要启发式读的那些量**

绑定口径照拍板 9 / `ObservationV1Codec` 的同一条：**`CellWar.Ai` 里不许自己算规则**，规则量一律经已有函数。逐条映射见 `ai_contract.json` 的 `lineC.design.features.mapping`。要点：

- `pressure_at` → `RulePolicies.PressureAt`（`:600`）；
- `solidify_threshold` → `BoardRules.SolidifyThreshold`（`:351`，internal，靠 `InternalsVisibleTo` 读）；
- `_toxin_targets`（GD 的**私有**方法，方案 §四 P-3 专门补了一条「四条纯查询盖不住它」）→ `SkillRules.ToxinTargets`（`SkillRules.cs:121`，internal）。
  ⇒ **P-3 那条补充项靠 `InternalsVisibleTo` 一行就解决了，不用给 core 开 public 门面。**
- `antibody_damage` → 今天只有三标量重载 `RulePolicies.AntibodyDamage(RuleTuning, used, matured)`（`:834`）。具名 `(WorldState, Cell)` 重载是批 4 的「路 A」，**Kevin 已同意但排在批 5b 第二段之后**（拍板记录 §十二 / §十五）⇒ 本批走退路：自己从 cell 取 `used` / `matured`（`matured` 只许过 `HasSkill`）。

**④ 产品启发式 + `IPolicy`**

```csharp
public interface IPolicy { int Choose(WorldState s, int seat, IReadOnlyList<LegalAction> actions); }
public sealed class HeuristicPolicy : IPolicy { ... }
```

**不喂它 GD 的 `req`** —— C# 侧没有那 10 种 kind，只有一张决策表。RL 稿 §3.4 的输出链（合法候选 → 打分 → softmax → 下标）与这个签名逐项对得上。

**先剔的三段死码**（都已在 7487567 上核过还在）：
- `ask()` 的 `"attack_target"` 分支（`heuristic_bridge.gd:70`）—— core 实发的 kind 里没有它；
- `ask()` 的 `"differentiate"` 分支（`:72`）与 `_pick_differentiation`（`:622`）—— 文件自己在 `:324` 写「引擎从不发那种询问」；
- `"confirm"` 分支 —— `cw_bridge.gd:8` 明写「UI 自己发起的 `confirm` 不经引擎、不是 kind」⇒ C# 侧根本没有这一问。

**移植要按 `DecisionType` 覆盖，不按 kind**：Place / Move / Differentiate / Draw / Discard / Mutate / PlayCard / TypeSkill / ChainMove / StopChain / ChemotaxisStep / StopChemotaxis / CoupleDirection / CoupleTier / CancelCouple / RemodelPick / StopRemodel / PickCell / ChooseMutation / Revive / SkipRevive / EndTurn / Pass。（`Attack` / `Divide` 是 `SemanticKey.DeadCode` 点名的死代码，不管。）

### 3.4 一处必须认下来的具体差异：分化选种没有 rng

GD 的启发式按 `hash([game.rng.state, pid])` 挑分化种类（`heuristic_bridge.gd:322-334`，只读不消耗）。C# 的 `WorldState` **不带 Rng**（Rng 住 `SimulationState` / `Runtime`），AI 拿不到也不该拿。
⇒ 换成**局面本身的确定性摘要 + seat** 当选种：同一份 `WorldState` + 同一 seat 必然同一答案，且不依赖任何随机流。
这是「C# AI 不与 GD AI 逐决策一致」（Kevin 六条第 2 条）的一个**具体落点**，不是 bug。但它的具体形状要 Kevin 认一次 —— 列进 questions。

### 3.5 AI 版本号

`CellWar.Ai` 自报 `AiVersion = "cs-h1"`，**不复用 GD 的 `v11`**（`heuristic_bridge.gd:36`）—— 两边不逐决策一致，共用一个号会让「用它量出来的平衡数字」分不清是哪一版量的。
铁律③ / P-5 要的 `ObsRuleset.ai_build` **本批不加**：加字段必须升 `p`（`docs/观测协议_v1.md` §九），而本批是零协议改动。只在程序集里留常量 + 登记。

### 3.6 测试与判据

放 `core/CellWar.Core.Tests/Ai/`（不新开测试工程，理由见 3.2）。四条核心判据：

1. **四套 L1 夹具每一步都给得出合法下标**（`game/tests/l1/trace_{2p_2222,4p_4242,6p_6666,4p_chemo_4242}.jsonl`）—— **不比值**。
2. **`DecisionType` 覆盖** —— 这一条是**必须的**。只有合法性判据的话，「把某个分支改成恒回 0」这个变异抓不到（它回的 0 仍然合法）。
3. **推演 200 步不改原世界**。
4. **rng 隔离**：同一份世界 + 同一 seat 连调十次，答案逐次相同。

外加一条软闸：`CellWar.Ai` 里零 `RuleTuning` 字段的硬编码字面量、对规则函数的调用点有下界 —— 钉住「不自己算规则」。

### 3.7 人日

| 项 | 人日 |
|---|---|
| 程序集骨架 + 两行 csproj + 挂进 `dotnet test` | 0.5 |
| `LegalActions`（枚举 + 语义键 + Ordinal 定序 + Pass） | 1 |
| 特征（启发式读的那几十个量，绑到已有规则函数） | 2~3 |
| 启发式 798 行按意图移植（已剔三段死码） | 8~12 |
| 测试（四夹具 + 覆盖 + 不可变性 + 软闸） | 2~3 |
| docs 同提交 | 0.5 |
| **合计** | **14~20** |

**与方案 §3.2 的 28~47 的关系**：那张表里「启发式 8~12 + 扁平 MC 3~5 + MCTS 3~5 + CWEval 2~3 + 对齐与回归 8~15」。本批按 Kevin 追加口径只吃第一项，`CWEval` 随 MC/MCTS 一起不搬，「对齐与回归」因为**不比值**而缩成常规测试。⇒ 14~20。口径同方案：**纯编码，排除 triage、平衡重标定的对局时间；是下界，不是承诺。**

---

## 四、方案 §1.7 三处不一致：今天还在不在

| | 状态 | 依据 |
|---|---|---|
| **(1) `CWKernelInProc` 漏调 `attach_engine`** | ✅ **已修** | `cw_kernel_inproc.gd:322` `static func _attach_engine`；`open:76` / `close:112` / `set_decider:335` 三处都走它；`t_kernel_attach_engine` 在 `headless_test.gd:20507`、已注册进套件表 `:161` |
| **(2) 第四档 `CWMCTSValueBridge` 未接线** | ❌ **仍在** | `grep -rn CWMCTSValueBridge game/` 只命中 `mcts_value_bridge.gd:14` 的定义与四处注释（`cw_leaf_value.gd:11` / `cw_leaf_value_nn.gd:3` / `mcts_bridge.gd:25,50,269`），**零实例化** |
| **(3) bot 客户端的 MC 跑在被裁过的假世界上** | ❌ **仍在** | `cw_net.gd:317-330` 的 `view_for` 仍是 `rng = 0` + 他人手牌 `HIDDEN_CARD` + 他人 `pending.options` 清空；`cw_room.gd:701-706` 的 bot 旁路仍在 |

**(1) 的残留**：方案连带指出的那条注释（`ai_baseline_case.gd:7-8`「两边都成立」）今天仍在。**但实际代码是对的** —— `make_bridge` 自己在 `:29` 显式写了 `tree_ai.game = g`，所以那个夹具从来没踩到 `attach_engine` 那个洞。⇒ 纯文字瑕疵，不影响行为。

**(3) 的新连带后果 —— 这是本轮唯一新出现的账**：
批 1 规格判「`bot` 旁路与 `CWNet.view_for` / `view_for_watcher` **批 2 AI 进 C# 之后整块删**」（`docs/archive/口径二_批1_原子切规格.md:301-305` / `:804`），`cw_room.gd:704` 的注释也照这么写。
而**今天的收窄口径是「只迁启发式、MC / MCTS 留 GD」** ⇒ **这块删不掉**：bot 客户端的 MC 要跟着 GD 的扁平 MC 活到 GD 内核退役那天。
⇒ 「批 2 整块删」这条判决要顺延，并回写批 1 规格与 `cw_room.gd:704` 的注释。**列进 questions。**

---

## 五、要 Kevin 再拍的（按轻重排）

1. **线 C 的 core 改动是两行不是一行**（`CellWar.Core.csproj` 的 `InternalsVisibleTo` + `CellWar.Core.Tests.csproj` 的 `ProjectReference`）。没有第二行，`CellWar.Ai` 不会被任何现有命令编译。**建议：认**（在测试工程、零产品影响、已实测）。
2. **`bot` 旁路的处置顺延**：批 1 规格判「批 2 整块删」，而 MC / MCTS 不迁移 ⇒ 删不掉。**建议：改判「跟着 GD MC 一起活到 GD 内核退役」**，同日回写批 1 规格 `:301-305`/`:804` 与 `cw_room.gd:704` 的注释。
3. **C# 启发式的分化选种**：GD 读 `rng.state`，C# 的 `WorldState` 没有 rng ⇒ 换成局面摘要 + seat。**认不认这个具体差异的形状？**
4. **第四档 `CWMCTSValueBridge`**（23 行、零实例化）：按追加口径它连搬迁清单都进不去。**接上 / 删掉 / 就这么放着？**
5. **线 A 的 `192` 要不要提成 `CWMatch` 常量**让联机与本地同读（多改 `match.gd` 一行，换来「联机 = 本地」成为结构事实）。
6. **「专家档有多强」的对外说法**：补了 192 之后联机专家档弱一档，4bis 认了代价但没人写这句话。
7. **`CellWar.Ai` 的 `AiBuild` 自报出口推迟**：本批只在程序集里放常量、不进观测协议（进就要升 `p`）。认不认推到发版批？
8. **线 B 的子进程：短命先做、worker 池后议** —— 但 Godot 无头冷启动耗时今天没量过（§九 #7）。**要不要让 P-B 先量一次再定？**（建议：照做短命，顺手把冷启动毫秒 print 出来，下一轮再定。）

---

## 六、落地 order 与冲突面

```
提交 1 · 线 A   game/scripts/net/cw_net_bridge.gd（_init）
                game/scripts/ui/match.gd（提常量）
                game/scripts/net/cw_room.gd（fx_stats）
                game/scripts/kernel/cw_play_queue.gd（fx_stats）
                game/tests/headless_test.gd（t_net_ai_budget / t_room_push_stats / 扩 t_play_queue）
提交 2 · 线 B   game/scripts/ai/{monte_carlo_bridge,mcts_bridge}.gd（多一级开关）
                game/scripts/ai/{cw_ai_proc,cw_ai_worker}.gd（新）
                game/scripts/ui/match.gd（拨开关）
                game/scripts/net/cw_net_bridge.gd（拨开关 —— **踩线 A 改过的同一个 _init**）
                game/tests/headless_test.gd（五条）
提交 3 · 线 C   core/CellWar.Ai/**（新）
                core/CellWar.Core/CellWar.Core.csproj（1 行）
                core/CellWar.Core.Tests/CellWar.Core.Tests.csproj（1 行）
                core/CellWar.Core.Tests/Ai/**（新）
```

**唯一的真冲突面**：`cw_net_bridge.gd` 的 `_init()`（A 与 B 都要写）与 `match.gd`（A 提常量、B 拨开关，不同行但同文件）。⇒ **A 必须先落**，P-B 的 old 锚点按「A 落完之后」的树写；若 P-B 在 A 之前的树上做，评委合的时候要重锚。
线 C 与另外两条零交集（不碰 `game/**`），可以任意顺序落，排第三只是因为它最大。

---

## 七、S1 做的验证（都在 scratchpad 副本上）

- `scratchpad/s1_ai/core/` —— 从 7487567 拷的 core 副本，加了探针 `CellWar.Ai` 工程与两行 csproj：
  - `dotnet build core/CellWar.Ai` → Build succeeded, 0 Error(s)（内含对 internal 类 `RulePolicies` 的调用）
  - `dotnet test core/CellWar.Core.Tests --filter AiProbeTests` → Passed! Failed: 0, Passed: 1
- 仓库本体**一个字没改、没跑 git 写操作**。
- 未跑：`tools/run_tests.sh` 全量与 `dotnet test` 全量（S1 不产补丁，基线由 P-A/P-B/P-C 各自在自己的副本上跑）。


## 主会话裁决（2026-09-19，对 S1 questions 八条；评委按此核）
1. core 改动认两行（Core.csproj InternalsVisibleTo + Tests.csproj ProjectReference）；不建 sln。
2. bot 旁路改判「跟着 GD MC 活到 GD 内核退役」：P-A 改 cw_room.gd:701-706 注释；批 1 规格回写由主会话落地时做。
3. 分化选种换成局面确定性摘要 + seat（已知差异，不逐决策一致）。
4. CWMCTSValueBridge 死码不动。
5. 192 提成 CWMatch 常量，联机与本地同读（P-A）。
6. 「专家档弱一档」对外说法只记文档，等 Kevin 定文案。
7. AiBuild 只放常量、不进观测协议。
8. 线 B 先做短命子进程 + print 冷启动 / 决策毫秒；R-B1 跑不通就停下来报，不改形状。
落地序 A → B → C；B 的锚点按 A 落后的树。


---

## 附：硬约定 JSON 原文（`ai_contract.json`）

```json
{
  "meta": {
    "batch": "内核替换 · 批 2「AI 进 C#」—— 地基 + 三条止血",
    "author": "S1 · 硬约定 + 切提交",
    "date": "2026-09-19",
    "repo": "D:/Projects/SpringSense/2026-2027/Cell War/Cell-War",
    "branch": "csharp-core",
    "head_at_read": "7487567c83343107c040c25f8b841421ec1bb863",
    "head_short": "7487567",
    "dirty_at_read": [
      "core/CellWar.Core/RulePolicies.cs (M) —— S1 写完时已被提交进 022bd16 之前的树，工作树现已干净"
    ],
    "head_after_s1": "022bd16",
    "head_moved_note": "S1 写完时 HEAD 已前进到 022bd16（『拍板记录 §十五再续三』）。逐文件核过：该提交**只改 docs/archive/内核替换_拍板记录.md（+5 行）**，本契约引用的任何代码行号一处都没动。P-A/P-B/P-C 仍按自己拷副本那一刻的 HEAD 写 old 锚点。",
    "kevin_scope_override": "Kevin 09-19 追加，比简报第 1 条更窄、以此为准。**已入库**：docs/archive/内核替换_拍板记录.md「同日再续三」（022bd16），原文『关于 AI 交付的问题，拍板 1 你只需要交付普通 AI（启发式），剩下两个不需要迁移』，该条同时写明「§十 拍板 1 收窄定稿：批 2 只交付普通 AI = 启发式（移植进 CellWar.Ai，不求逐决策一致，策略口保留给训练模型）；扁平 MC 与 MCTS 不迁移（留在 GD 侧直到 GD 内核退役，之后由训练模型接）。(a3) 子进程止血与 4bis / 计数器照旧」。⇒ 线 C = 完整的普通 AI（产品 AI，不是陪练桩）+ IPolicy；不留 MC/MCTS 接口占位。线 A / 线 B 不变。",
    "commit_order": [
      "A",
      "B",
      "C"
    ],
    "commit_rule": "三条互不依赖，分三次提交；每次提交自带 docs（开发日志 + 方案稿落地进度 + 架构说明书对应小节）。"
  },
  "global_forbidden": {
    "files": [
      "game/scripts/core/** —— GD 规则代码一字不动（三条线都是）",
      "game/tests/baseline/ai_same_hash.json —— 不重录",
      "game/tests/ai_baseline_case.gd —— 不动（含它写死的 192；它是基线夹具）",
      "docs/观测协议_v1.md 与 core/CellWar.Core/Observation/** 与 game/scripts/kernel/cw_obs_proto.gd —— 本批零协议改动、不升 p",
      "game/scripts/net/cw_net.gd 的 NET_VERSION —— 零报文、不升号",
      "core/CellWar.Core/Runtime.cs / MatchSession.cs —— P-1 / P-2 两个 rng 缺口本批不修（线 C 结构上绕开它们，见 lineC.design.fork）",
      "core/CellWar.Core/SemanticKey.cs —— 只读不改",
      "tools/build_patch.sh / tools/publish_release.sh —— 只登记不改，发版等 Kevin"
    ],
    "rules": [
      "只读仓库；一切验证在 scratchpad 带 _ai 的副本上做。",
      "补丁按目标文件本来的行尾 / BOM 还回去（仓库里 .csproj 是 UTF-8 BOM；docs/*.md 与部分 .gd 是 CRLF —— 一律走 python load/save，别用 sed -i，别用 heredoc 写含反斜杠的内容）。",
      "要动骨架先报。core/ 的允许改动见 lineC.core_allowance，一行都不许多。",
      "平衡口径：本批只登记「AI 版本号要升、用它量出来的平衡数字作废」，不做重量。"
    ]
  },
  "verified_today": {
    "note": "S1 在 7487567 上逐条核过的事实，三组不要再重复核，但改到相邻代码时要自己复核行号。",
    "facts": [
      {
        "id": "F1",
        "claim": "cw_net_bridge.gd:16 那只 mc 仍未设 max_sim_steps（默认 0 = 无上限）",
        "evidence": "game/scripts/net/cw_net_bridge.gd:16 `var mc := CWMonteCarloBridge.new()`；全仓 max_sim_steps 赋值点 grep 里没有它"
      },
      {
        "id": "F2",
        "claim": "本地那条闸在 match.gd:900（不是方案稿写的 :872，文件已位移）",
        "evidence": "game/scripts/ui/match.gd:900 `bridge.max_sim_steps = 192 if level == AI_MC else 0`；:904-905 thinking / use_threading；:915 tree_ai.max_sim_steps"
      },
      {
        "id": "F3",
        "claim": "两个静态线程入口形状与方案 §3.1bis 一致",
        "evidence": "monte_carlo_bridge.gd:135 cw_mc_thread_entry(holder, snap, options, cfg, _box)；mcts_bridge.gd:119 cw_mcts_thread_entry(同形)；两处 _threaded_eval 都先探 OS.has_feature(\"threads\")"
      },
      {
        "id": "F4",
        "claim": "全仓零 OS.create_process / OS.execute 实调",
        "evidence": "唯一命中是 cw_kernel_sidecar.gd:3 的计划注释。⇒ 线 B 的进程生命周期是仓库第一份。"
      },
      {
        "id": "F5",
        "claim": "push_state 在 cw_room.gd:662，state_hash() 在 :664（方案稿写 :665，位移 1 行）",
        "evidence": "game/scripts/net/cw_room.gd:662 func push_state；:664 `var h := game.state_hash()`"
      },
      {
        "id": "F6",
        "claim": "CWPlayQueue.pump 在 :38，_hurry_now 判定在 :50，hurry_backlog := 24 在 :28",
        "evidence": "game/scripts/kernel/cw_play_queue.gd 逐行核过"
      },
      {
        "id": "F7",
        "claim": "§1.7(1) attach_engine 已修",
        "evidence": "cw_kernel_inproc.gd:322 static func _attach_engine；open :76 / close :112 / set_decider :335 三处都走它；t_kernel_attach_engine 在 headless_test.gd:20507、已注册进套件表 :161"
      },
      {
        "id": "F8",
        "claim": "§1.7(2) CWMCTSValueBridge 仍是未接线的代码",
        "evidence": "grep -rn CWMCTSValueBridge game/ 只命中 mcts_value_bridge.gd:14 的定义与四处注释（cw_leaf_value.gd:11 / cw_leaf_value_nn.gd:3 / mcts_bridge.gd:25,50,269），零实例化"
      },
      {
        "id": "F9",
        "claim": "§1.7(3) view_for 的保真度缺口仍在，bot 旁路仍在",
        "evidence": "cw_net.gd:317-330 `v[\"rng\"] = 0` + 他人手牌 HIDDEN_CARD + 他人 pending.options 清空；cw_room.gd:701-706 `if server.is_bot(cid)` 仍发 view/turn/logs，:704 注释仍写「批 2 AI 进 C# 之后整块删」"
      },
      {
        "id": "F10",
        "claim": "启发式桥的两条死分支今天仍在",
        "evidence": "heuristic_bridge.gd:70 `\"attack_target\"` / :72 `\"differentiate\"`；core 实发的 kind grep 里两者都没有；文件自己在 :324 写「_pick_differentiation 是死代码 —— 引擎从不发那种询问」"
      },
      {
        "id": "F11",
        "claim": "启发式桥全文零 CWEval 调用 —— 估值是 MC/MCTS 的末端，不是启发式的",
        "evidence": "grep CWEval game/scripts/ai/heuristic_bridge.gd 只命中 3 条版本号注释（:14/:18/:28），零调用。⇒ 按 Kevin 追加口径，cw_eval.gd 的 13 维特征与 WEIGHTS 本批**不搬**。"
      },
      {
        "id": "F12",
        "claim": "WorldState 是 public sealed class + init-only 属性，**不是 record**（简报那句要更正）",
        "evidence": "core/CellWar.Core/WorldState.cs:8 `public sealed class WorldState`；唯一字段清单是 WorldStateExtensions.Copy(:12)，另有 DeepClone()。没有 `with` 表达式。"
      },
      {
        "id": "F13",
        "claim": "core/ 下没有 .sln（简报说「进 core/*.sln」不成立）；唯一的 dotnet 入口是 tools/run_l0.sh:50 的 `dotnet test core/CellWar.Core.Tests`",
        "evidence": "ls core/*.sln 无此文件；grep 'dotnet test' tools/ 只有 run_l0.sh 一处"
      },
      {
        "id": "F14",
        "claim": "新程序集 + InternalsVisibleTo + 测试挂接这条路**已在副本上实测通过**",
        "evidence": "scratchpad/s1_ai/core/：新建 CellWar.Ai（net8.0，ProjectReference→Core）+ CellWar.Core.csproj 加一行 InternalsVisibleTo(\"CellWar.Ai\") ⇒ `dotnet build` Build succeeded 0 error；再给 CellWar.Core.Tests.csproj 加一行 ProjectReference→CellWar.Ai + Ai/ProbeTests.cs ⇒ `dotnet test --filter AiProbeTests` Passed 1。探针里调了 internal 类 RulePolicies.PressureAt 与 public BasicRulesEngine.GetAvailableDecisions，都编得过。"
      },
      {
        "id": "F15",
        "claim": "启发式要的私有方法 _toxin_targets 在 C# 侧已有对应，且靠 InternalsVisibleTo 就够，不用改 core",
        "evidence": "core/CellWar.Core/SkillRules.cs:121 `ToxinTargets(s, cell)`（internal static class SkillRules）"
      }
    ]
  },
  "lines": [
    {
      "id": "A",
      "name": "线 A · GD 止血两件（Kevin 六条的第 5 / 6 条）",
      "owner": "P-A",
      "man_days": "1.0（0.5 + 0.5）",
      "depends_on": [],
      "touches": [
        "game/scripts/net/cw_net_bridge.gd",
        "game/scripts/ui/match.gd",
        "game/scripts/net/cw_room.gd",
        "game/scripts/kernel/cw_play_queue.gd",
        "game/tests/headless_test.gd",
        "docs/开发日志.md",
        "docs/archive/口径二_批2_AI进C#_方案.md"
      ],
      "items": [
        {
          "id": "A1",
          "title": "联机专家档补 max_sim_steps = 192",
          "entry": "game/scripts/net/cw_net_bridge.gd:16 那只 `mc`",
          "how": "① match.gd 把写死的 192 提成 `const AI_MC_MAX_STEPS := 192`（放在 MCTS_* 三个常量旁边，注释写明「联机侧 cw_net_bridge 读同一个数」），:900 改读它；② cw_net_bridge.gd 加 `func _init() -> void: mc.max_sim_steps = CWMatch.AI_MC_MAX_STEPS`。**不要**在成员声明里链式设（GDScript 不支持）。",
          "must_check_before": "CWNetBridge.new() 全仓调用点是否都是无参（加 _init 之前核一遍）；CWMatch 能不能在 net 层 preload/引用（match.gd 有 class_name CWMatch，ai_baseline_case.gd:38 已经在这么用，所以成立）。",
          "behavior_change": "**有意的**：联机专家档从无预算降到 192 step（实测 381~645 ms → 180 ms 量级），AI 弱一档。这是线 A 唯一一处行为改动，Kevin 4bis 已认代价。",
          "tests": [
            {
              "name": "t_net_ai_budget",
              "where": "game/tests/headless_test.gd（新函数 + 注册进套件表 :161 那一行）",
              "assert": "`CWNetBridge.new().mc.max_sim_steps == CWMatch.AI_MC_MAX_STEPS` 且 `> 0`；另断言 `CWMonteCarloBridge.new().max_sim_steps == 0`（默认无上限这条口径没被顺手改掉）"
            }
          ],
          "mutants": [
            "把 cw_net_bridge 的 _init 整只删掉 ⇒ t_net_ai_budget 必红",
            "把 AI_MC_MAX_STEPS 改成 0 ⇒ t_net_ai_budget 必红",
            "把 match.gd:900 改回字面量 192 ⇒ 不红（可接受：那一步只是结构化，不是行为）"
          ]
        },
        {
          "id": "A2",
          "title": "两个计数器（换掉已叫停的 fx-diag 量法）",
          "entries": [
            "game/scripts/net/cw_room.gd:662 push_state（含 :664 的 state_hash() 单独计时）",
            "game/scripts/kernel/cw_play_queue.gd:38 pump（记触发快进时的 batch.size()）"
          ],
          "shape": {
            "cw_room": "`var fx_stats := { \"push_n\": 0, \"push_us\": 0, \"push_max_us\": 0, \"hash_us\": 0, \"hash_max_us\": 0 }`；push_state 进出各一次 Time.get_ticks_usec()，state_hash() 那一句单独夹一次。",
            "cw_play_queue": "`var fx_stats := { \"batches\": 0, \"hurry_backlog_n\": 0, \"hurry_max_batch\": 0, \"hurry_manual_n\": 0 }`；在 :50 `_hurry_now = hurry or batch.size() >= hurry_backlog` **之后**累计，**手动快进（hurry=true）与积压快进分开计**（否则回放倍速 / 观战会污染这个数）。",
            "print": "各加 `func stats_line() -> String`。前缀一律 `[fx-count]`（**不要复用已叫停的 [fx-diag]**）。CWRoom 在本局结束的广播处打一行；CWPlayQueue 在 pump 退出（running 转 false）时打一行。"
          },
          "where_it_gets_written": "服务器侧那只（cw_room）由服务器进程打印：无头 `server/server_main.gd`、局域网房主的 `online_panel` 同进程路都会走到。客户端侧那只（cw_play_queue）由 match.gd 的队列打印。**更正简报的措辞**：`game/tests/net_play.gd` 是纯客户端（CWNetClient），读不到 room 的计数器、也不建 CWPlayQueue ⇒ 断言只能落在 headless_test.gd 的进程内联机测试上，net_play.gd / net_live.gd 只是「跑起来就会看见那两行」。",
          "tests": [
            {
              "name": "t_play_queue（扩已有，headless_test.gd:19739）",
              "assert": "已有的 `q1.hurry_backlog = 3` + 一批 5 条那段（:19815）后面加：`fx_stats[\"hurry_backlog_n\"] == 1` 且 `fx_stats[\"hurry_max_batch\"] == 5`；另一条不积压的队列 `hurry_backlog_n == 0`"
            },
            {
              "name": "t_room_push_stats（新）",
              "where": "headless_test.gd（照 :18247 / :7546 直接 CWRoom.new() 的先例）",
              "assert": "推过几次之后 `fx_stats[\"push_n\"] > 0`、`hash_us <= push_us`、`push_max_us >= 0`；**不断言具体毫秒**（机器快慢不同）"
            }
          ],
          "must_not_change": [
            ":50 `_hurry_now` 的判定式（>= 不许改成 >）",
            "state_hash() 的调用次数与位置（今天每次 push 一次；计时不许把它挪走或缓存）",
            "push_state_to 的报文内容与顺序（step_end → sync）",
            "fx_stats 绝不能进 CWStateCodec / state_hash（它是 room / queue 的字段，不是对局状态）—— t_rec_transparent 那族会当场抓"
          ],
          "mutants": [
            "把 hurry_max_batch 的累计删掉 ⇒ t_play_queue 红",
            "把 :50 的 >= 改成 > ⇒ t_play_queue 红（证明计数器钉的是同一条判定）",
            "把 fx_stats 塞进 snapshot ⇒ t_ai_same_hash / t_rec_transparent 红"
          ]
        }
      ],
      "forbidden": [
        "game/scripts/ai/** 一行不动（线 A 不碰 AI 算法）",
        "game/scripts/core/** 一字不动",
        "game/tests/ai_baseline_case.gd（含它写死的 192）与 game/tests/baseline/ai_same_hash.json",
        "NET_VERSION / 任何报文字段",
        "docs/观测协议_v1.md"
      ],
      "acceptance": [
        "bash tools/run_tests.sh 全量绿（含末尾 run_l0.sh）",
        "t_ai_same_hash 未重录仍绿",
        "联机夹具 / 联机无头测试 t_net_* 全绿（A1 会让用 mc 档的联机测试变快，不该变红；若有断言依赖无预算档的行为，报出来别改夹具）",
        "git diff 里没有 game/scripts/core/** 与 game/tests/baseline/**"
      ],
      "docs": [
        "docs/开发日志.md 顶部加一条（联机专家档补预算 + 两个计数器；写明「专家档弱一档」这条对外说法要统一）",
        "docs/archive/口径二_批2_AI进C#_方案.md §七 / §八 拍板 4bis 与拍板 5 下面各补一行落地记录（改稿、不重写）"
      ]
    },
    {
      "id": "B",
      "name": "线 B · (a3) 两个静态线程入口 → 子进程入口",
      "owner": "P-B",
      "man_days": "3~5（方案 §3.1bis 表）",
      "depends_on": [],
      "touches": [
        "game/scripts/ai/monte_carlo_bridge.gd",
        "game/scripts/ai/mcts_bridge.gd",
        "game/scripts/ai/cw_ai_proc.gd（新）",
        "game/scripts/ai/cw_ai_worker.gd（新）",
        "game/scripts/ui/match.gd",
        "game/scripts/net/cw_net_bridge.gd",
        "game/tests/headless_test.gd",
        "docs/开发日志.md",
        "docs/架构说明书.md §416 AI 小节",
        "docs/archive/口径二_批2_AI进C#_方案.md §3.1bis"
      ],
      "entries_to_wrap": [
        "CWMonteCarloBridge.cw_mc_thread_entry —— game/scripts/ai/monte_carlo_bridge.gd:135",
        "CWMCTSBridge.cw_mcts_thread_entry —— game/scripts/ai/mcts_bridge.gd:119"
      ],
      "data_contract_frozen": {
        "in": "(snap: Dictionary 25 键 CWStateCodec.snapshot, options: Array, cfg: Dictionary)",
        "out": "{ best: int, stats: Dictionary }",
        "rule": "这三进一出的形状**一个字不许改**。子进程路与线程路吃同一份数据、调同一个静态入口 —— 这正是 t_ai_same_hash 不用重录的全部依据。"
      },
      "design": {
        "spawn": "`OS.create_process(OS.get_executable_path(), args)`。导出包里 get_executable_path 就是游戏本体 ⇒ **不需要第二个可执行体，导出模板 / publish_release.sh 零改动**。编辑器 / 源码树里跑时要额外带 `--path <项目目录>`（用 `OS.has_feature(\"editor\")` 分支）。",
        "worker_script_location": "**必须放 game/scripts/ai/cw_ai_worker.gd，不能放 game/tests/** —— 导出预设 exclude_filter=\"tests/*\"，放 tests 下导出包里就没有它。",
        "worker_shape": "extends SceneTree；_initialize() 读 OS.get_cmdline_user_args() 的 port= / token=，连 127.0.0.1:port，发 hello{token}，收 job{kind:\"mc\"|\"mcts\", snap, options, cfg}，调对应的 cw_*_thread_entry（同一段代码），回 done{best, stats}，quit(0)。",
        "transport": "本地 TCP（loopback + 一次性 token），报文用现成的 `CWNet.encode/decode`（cw_net.gd:249/:267 「4 字节原长 + zstd(var_to_bytes)」，能直接吃带 Vector2i 键的快照）。**不走 stdio** —— OS.execute_with_pipe 在无头导出包上可用与否方案稿没核（§九 #6），别拿它当地基。",
        "security": "TCPServer.listen(端口=0) 绑 127.0.0.1；只接受第一个连接；token 一次性、对不上就断。快照不是机密，但写明这三条。",
        "host_polling": "宿主侧形状与今天 _threaded_eval 逐字相同：`while not ready: await tree.process_frame`。联机服务器的单线程假设因此**一行都不用碰**（开发日志 :2186 说的那一层不动）。",
        "lifecycle": "短命进程（每决策一次起一只）先做。子进程入口开头 print 一行冷启动毫秒 —— 方案 §九 #7 说的「Godot 无头冷启动耗时未量」，第一次跑完就有数，worker 池留到有数之后再议。",
        "timeout": "`timeout_ms`（建议默认 8000，可由 cfg 覆盖）。超时 → OS.kill(pid) → 回落。**回落不是「拿一个别的答案」**：回落是拿同一份 snap 重算，同一段代码同一份数据 ⇒ best 逐位相同。",
        "three_level_fallback": [
          "① 子进程（use_subprocess 且 OS.has_feature(\"pc\") 且不是 web）",
          "② 线程（今天的 _threaded_eval，OS.has_feature(\"threads\")）",
          "③ 同步（_eval_sync，网页版的必然）"
        ],
        "switch": "两只桥各加 `var use_subprocess := false`。**默认 false 是硬约定** —— 否则无头套件 / 平衡模拟 / 教程会起成千上万个进程。",
        "three_product_paths": {
          "local": "game/scripts/ui/match.gd:905 那一行旁边拨：`bridge.use_subprocess = thinking and OS.has_feature(\"pc\")`；树搜索桥同理（:916 旁）。教程局 thinking 恒 false ⇒ 天然不起进程。",
          "online": "game/scripts/net/cw_net_bridge.gd 的 `mc` 在 _init 里拨 `use_subprocess = OS.has_feature(\"pc\")`（无头服务器与局域网房主都在 PC 上）。§1.6 第 3 条当场消失。⚠ 与线 A 的 A1 改同一个 _init —— **落地顺序 A 在 B 之前**，B 在 A 的基础上改。",
          "web": "`OS.has_feature(\"web\")` ⇒ use_subprocess 恒 false，走今天的 _eval_sync。**网页版路径与今天逐字相同**，这是一条判据。"
        },
        "hard_invariant": "子进程起不来 / 超时 / 崩溃 **绝不能计进 patch_state.gd 的 STRIKES**（批 0 底座规格 A-3.3 硬不变量② 的同一条精神）。这是一条断言，不是一句注释。"
      },
      "tests": [
        {
          "name": "t_ai_subproc_same_index",
          "type": "冒烟（真起一只子进程）",
          "assert": "同一份 snap + options + cfg，`_eval_sync` 与子进程路回的 `best` 逐位相同；带墙钟上限；只在 `OS.has_feature(\"pc\")` 上跑，web/无 pc 直接跳过并打印 skip"
        },
        {
          "name": "t_ai_subproc_fallback_web",
          "type": "注入",
          "assert": "把「能不能起子进程」做成**可注入的 Callable**（别真改 feature）；注成 false ⇒ 走 _eval_sync，且 best 与直接 _eval_sync 相同"
        },
        {
          "name": "t_ai_subproc_fallback_spawn_fail",
          "type": "注入",
          "assert": "spawn 恒失败 ⇒ 回落且 best 相同；push_warning 打出一条"
        },
        {
          "name": "t_ai_subproc_timeout",
          "type": "注入",
          "assert": "timeout_ms 设成 0/极小 ⇒ 回落且 best 相同；子进程被 kill、没有孤儿进程（记录 pid 后 OS.is_process_running 为 false）"
        },
        {
          "name": "t_ai_subproc_no_strikes",
          "type": "断言硬不变量",
          "assert": "上面三条失败路径跑完，patch_state 的 STRIKES 计数不变"
        },
        {
          "name": "t_ai_same_hash",
          "type": "既有护栏",
          "assert": "**不重录**、仍绿（ai_baseline_case.gd 里 use_threading=false、use_subprocess 默认 false ⇒ 它走的还是 _eval_sync 那条，一行都不该变）"
        }
      ],
      "must_not_change": [
        "_evaluate_on / _tree_search / _build_image_static —— 一行不动（「AI 算法一行不动」的执行机构）",
        "cw_mc_thread_entry / cw_mcts_thread_entry 的签名与函数体",
        "cfg / snap / options / {best, stats} 的形状",
        "game/scripts/core/** 与任何报文 / NET_VERSION",
        "game/tests/ai_baseline_case.gd 与 baseline/ai_same_hash.json",
        "导出预设 export_presets.cfg 的 exclude_filter（worker 放对地方就不用改它 —— 若发现必须改，停下来报）"
      ],
      "mutants": [
        "子进程回的 best 加 1 ⇒ t_ai_subproc_same_index 红",
        "去掉三级回落的第一级（web 上也去起进程）⇒ t_ai_subproc_fallback_web 红",
        "回落路改成「返回 0」而不是重算 ⇒ 四条回落断言全红",
        "把 use_subprocess 默认改成 true ⇒ run_tests.sh 墙钟爆掉（这条不做断言，写进风险）"
      ],
      "acceptance": [
        "bash tools/run_tests.sh 全量绿",
        "t_ai_same_hash 未重录仍绿",
        "三条产品路各有一条断言（本地 / 联机 / 网页）",
        "git diff 不含 game/scripts/core/**、不含 baseline/**、不含导出预设"
      ],
      "docs": [
        "docs/开发日志.md 一条（子进程入口落地 + 冷启动实测毫秒）",
        "docs/架构说明书.md §416「AI game/scripts/ai/」补两个新文件与三级回落",
        "docs/archive/口径二_批2_AI进C#_方案.md §3.1bis 补落地记录 + 把 §九 #6（stdio 还是 TCP）与 #7（短命还是池）各销一条账"
      ],
      "open_risks": [
        "R-B1 导出包里 `--headless --script res://scripts/ai/cw_ai_worker.gd` 能不能跑 —— 仓库零先例，P-B 必须实测（至少在无头 + 一个真导出包上各跑一次）。跑不通就停下来报，不要自己改成 stdio。",
        "R-B2 Godot 无头冷启动耗时未量（§九 #7）。短命进程的单决策开销 = 冷启动 + 序列化 + 推演；若冷启动 > 100 ms 量级，联机每决策一次就不划算 ⇒ 量出来写进回传，worker 池的取舍留 Kevin。",
        "R-B3 冒烟测试真起进程，在分片并行（SHARDS=2）下可能抖。上墙钟上限 + 只在 pc 上跑 + 失败必须红（不许降级成警告）。"
      ]
    },
    {
      "id": "C",
      "name": "线 C · C# CellWar.Ai 地基 + 完整的普通 AI（启发式）",
      "owner": "P-C",
      "man_days": "14~20（拆见 design.man_days_breakdown）",
      "depends_on": [],
      "scope_note": "**按 Kevin 09-19 追加口径收窄**：交付完整的普通 AI（产品 AI，不是陪练桩）+ 策略口 IPolicy。扁平 MC 与 MCTS **不迁移、不留接口占位**（留 GD 侧直到 GD 内核退役，之后由训练模型接）。cw_eval.gd 的 13 维特征与 WEIGHTS **不搬**（F11：启发式全文零 CWEval 调用，估值是 MC/MCTS 的末端）。",
      "core_allowance": {
        "line_1": "core/CellWar.Core/CellWar.Core.csproj —— 在既有 ItemGroup 里加 `<InternalsVisibleTo Include=\"CellWar.Ai\" />`（UTF-8 BOM，保持原行尾）",
        "line_2": "core/CellWar.Core.Tests/CellWar.Core.Tests.csproj —— 加 `<ProjectReference Include=\"..\\CellWar.Ai\\CellWar.Ai.csproj\" />`",
        "why_line_2": "**这一行超出简报「core 只许动这一行」，S1 在此明报**：core/ 下没有 .sln（F13），仓库唯一的 dotnet 入口是 tools/run_l0.sh:50 的 `dotnet test core/CellWar.Core.Tests`。不加这一行，CellWar.Ai **不会被任何现有命令编译或测试**。替代方案（另开 CellWar.Ai.Tests）反而要改 tools/run_l0.sh —— 比这一行更重。已在副本实测两行都加之后 build + test 都过（F14）。**P-C 照此做，并在回传的 questions 里复述这一条给 Kevin。**",
        "forbidden": "core/CellWar.Core/**.cs 一个字不许改（含 Runtime.cs / MatchSession.cs / SemanticKey.cs / Observation/**）。"
      },
      "new_assembly": {
        "path": "core/CellWar.Ai/CellWar.Ai.csproj",
        "tfm": "net8.0（= CellWar.Core 的 TFM；铁律①「AI 与 Core 永远同包同 build」）",
        "refs": [
          "ProjectReference → ../CellWar.Core/CellWar.Core.csproj"
        ],
        "verified": "F14 —— 已在 scratchpad/s1_ai 上实测 build + test 通过"
      },
      "design": {
        "fork": {
          "decision": "**不走 Runtime / MatchSession**，直接在 WorldState 上滚。",
          "why": "① Runtime.Fork() 带 P-1 的 rng 缺口（Runtime.cs:44-49 只在 Snapshot.Simulation.Rng == null 时写入，分叉出来的快照 Rng 非空 ⇒ :94-95 的 SetState 用的是真实流，AI 会提前看到自己的骰子）；修它要动 core，本批不许。② MatchSession 写死 new Xoshiro256StarStar（P-2），同样要动 core。③ WorldState 本体就够：BasicRulesEngine.ExecuteDecision(state, decision, rng) / AdvancePhase(state, rng) 都是 (旧 state) → RulesResult(NewState, …)，天然不改原世界。",
          "shape": "`Rollout.Advance(WorldState s, IDecision d, IDeterministicRng rng) -> WorldState`；AI **自己持有 rng**（new Xoshiro256StarStar(derivedSeed)），永不碰权威侧的随机流。派生口径照 GD：`derived = hash([根种子, 分叉序号])`，不要用「真状态 + 常数偏移」（monte_carlo_bridge.gd:236-238 解释过为什么）。",
          "note_for_simulation_state": "WorldState 不带 Rng（Rng 住 SimulationState / Runtime）。这既是 fork 简单的原因，也是下面 rng_gap 那条差异的根。",
          "correction": "F12：WorldState 是 public sealed class + init-only，**不是 record**；唯一字段清单是 WorldStateExtensions.Copy(:12)，另有 DeepClone()。别写 `with` 表达式。"
        },
        "legal_actions": {
          "shape": "`readonly record struct LegalAction(int Index, string Key, IDecision Decision)`；`LegalActions.Of(WorldState s, int seat) -> IReadOnlyList<LegalAction>`",
          "body": "BasicRulesEngine.GetAvailableDecisions(s, seat) + SemanticKey.Of(s, decision) 生成 Key。",
          "hard_rule_ordering": "**按 Key 的 Ordinal 序重排后再编 Index**。DecisionRouter.Available 走 PagedMap 的迭代序，那个序不是契约（SemanticKey.cs 的文件头自己写着「拿下标对，第一步就错位」）⇒ AI 的下标必须由 AI 自己定序，否则同一局面两次枚举可能给出不同下标。",
          "pass": "认 SemanticKey.PassKey（`k=action|act=pass`）—— C# 每个 action 问答固定多这一条，GD 没有。启发式要不要选它由策略决定，但它必须在表里。"
        },
        "features": {
          "scope": "**只做启发式今天读的那些量**（Kevin 追加口径）。不是 RL 训练特征全集，也不是 cw_eval 的 13 维。",
          "hard_rule": "**CellWar.Ai 里不许自己算规则**（照拍板 9 / ObservationV1Codec 的同一条口径）：任何规则量必须经 RulePolicies / BoardRules / SkillRules / Settlement / WorldEffects 已有函数。纯数据聚合（数格子、筛细胞、算距离）可以自己写。",
          "mapping": [
            {
              "gd": "game.player(pid)[\"faction\"] / game.cell_of(pid) / game.cells[cid]",
              "cs": "s.Players[seat] / s.Cells（纯数据）"
            },
            {
              "gd": "game.living_cells(faction) / game.cells_at(pos[, faction])",
              "cs": "自己写聚合（纯数据，非规则）"
            },
            {
              "gd": "game.tile(c)[\"tissue\"|\"solid\"]",
              "cs": "s.Board.Tissues[...]（纯数据）"
            },
            {
              "gd": "game.is_cancerous(c)",
              "cs": "按 Tissue 类型判（纯数据）；若 C# 已有具名判据优先用它"
            },
            {
              "gd": "game.count_tissue(SOLID)",
              "cs": "纯数据聚合；总格数用 RulePolicies.TotalTiles（:677，常量 127）"
            },
            {
              "gd": "game.solidify_threshold()",
              "cs": "BoardRules.SolidifyThreshold(s)（:351，internal ⇒ 靠 InternalsVisibleTo）"
            },
            {
              "gd": "game.world.pressure_at(pos)",
              "cs": "RulePolicies.PressureAt(s, at)（:600）"
            },
            {
              "gd": "game.actions.antibody_damage(me)",
              "cs": "RulePolicies.AntibodyDamage(RuleTuning, used, matured)（:834，三标量重载）。⚠ 具名 (WorldState, Cell) 重载是批 4 路 A，**待 Kevin、本批不开** ⇒ P-C 自己从 cell 取 used / matured 转调，matured 只许过 HasSkill。"
            },
            {
              "gd": "game.actions._toxin_targets(me)（私有）",
              "cs": "SkillRules.ToxinTargets(s, cell)（:121，internal ⇒ 靠 InternalsVisibleTo；F15）。⇒ P-3 清单里那条「启发式还要私有方法」靠 InternalsVisibleTo 一行就够，不用给 core 开门面。"
            },
            {
              "gd": "game.can_pay(me, cost)",
              "cs": "Settlement.CanPay(energy, cost, selfDestructive)（:174）"
            },
            {
              "gd": "game.tune.immune_move_cancerous[level] / counter_dmg_on_fail",
              "cs": "s.Tuning（RuleTuning，跟着世界走）"
            },
            {
              "gd": "game.memory / game.immune_level",
              "cs": "Player.AntigenMemory / Player.ImmuneLevel（WorldState.cs:265-266，阵营级读法见迁移 E-5「已加在 C#」）"
            },
            {
              "gd": "game.rng.state（只读不消耗，用来挑分化种类）",
              "cs": "**没有对应**，见 rng_gap"
            }
          ],
          "rng_gap": {
            "fact": "heuristic_bridge.gd:322-334 按 `hash([game.rng.state, pid])` 挑分化种类；C# 的 WorldState 不带 Rng（住 SimulationState / Runtime），AI 拿不到也不该拿。",
            "decision": "换成**局面本身的确定性摘要 + seat** 当选种（例：HashCode.Combine(s.Turn.WorldRound, seat, 活细胞数, 某个稳定的盘面计数)）。要求：同一份 WorldState + 同一 seat 必然同一答案（可复现），且**不依赖任何随机流**。",
            "status": "这是「C# AI 不与 GD AI 逐决策一致」（Kevin 六条第 2 条）的一个具体落点，不是 bug。写进 questions 让 Kevin 认一次具体形状。"
          }
        },
        "policy": {
          "interface": "`public interface IPolicy { int Choose(WorldState s, int seat, IReadOnlyList<LegalAction> actions); }`",
          "note": "**不要喂它 GD 的 req** —— C# 侧没有那 10 种 kind，只有一张决策表。RL 稿 §3.4 的输出链（合法候选 → 打分 → softmax → 下标）与这个签名对得上。",
          "no_placeholders": "**不留 MC / MCTS 的接口占位**（Kevin 追加口径）。没有 ISearch / IRollout / ILeafValue 这类为将来预留的空壳。训练模型将来就是 IPolicy 的第二个实现。"
        },
        "heuristic": {
          "source": "game/scripts/ai/heuristic_bridge.gd（798 行），**按意图移植，不求逐决策一致**。",
          "class": "`public sealed class HeuristicPolicy : IPolicy`",
          "dead_code_to_drop": [
            "ask() 的 `\"attack_target\"` 分支（:70）—— core 从不发这种 kind（F10）",
            "ask() 的 `\"differentiate\"` 分支（:72）与 `_pick_differentiation`（:622）—— 文件自己在 :324 写着是死代码（F10）",
            "`\"confirm\"` 分支 —— cw_bridge.gd:8 明写「UI 自己发起的 confirm 不经引擎、不是 kind」⇒ C# 侧根本没有这一问"
          ],
          "kinds_to_cover": "GD 的 kind 在 C# 侧塌成一张决策表。移植要按 **DecisionType** 覆盖，不按 kind：Place / Move / Differentiate / Draw / Discard / Mutate / PlayCard / TypeSkill / ChainMove / StopChain / ChemotaxisStep / StopChemotaxis / CoupleDirection / CoupleTier / CancelCouple / RemodelPick / StopRemodel / PickCell / ChooseMutation / Revive / SkipRevive / EndTurn / Pass。（Attack / Divide 是 SemanticKey.DeadCode 里点名的死代码，不管。）",
          "version": "`public const string AiVersion = \"cs-h1\"`（**不复用 GD 的 v11** —— 两边不逐决策一致）。铁律③ / P-5 要的 ObsRuleset.ai_build **本批不加**（加了要升 p），只在程序集里留常量 + 登记。"
        },
        "man_days_breakdown": {
          "程序集骨架 + 两行 csproj + 挂进 dotnet test": 0.5,
          "LegalActions（枚举 + 语义键 + Ordinal 定序 + Pass）": 1,
          "特征（启发式读的那几十个量 + 绑定到已有规则函数）": "2~3",
          "启发式 798 行按意图移植（已剔三段死码）": "8~12",
          "测试（四夹具合法性 + kind 覆盖 + 不可变性 + 源码闸）": "2~3",
          "docs 同提交": 0.5,
          "合计": "14~20"
        }
      },
      "tests": {
        "where": "core/CellWar.Core.Tests/Ai/（新文件夹，不新开测试工程）",
        "why_here": "L1 夹具的装载器（L1View.Load / TapeRng / DeepDiff）住在 CellWar.Core.Tests；另开 CellWar.Ai.Tests 会被 run_l0.sh 与所有现有 dotnet 入口漏掉（F13）。已实测（F14）。",
        "cases": [
          {
            "name": "启发式在四套 L1 夹具的每一步都给得出合法下标",
            "fixtures": [
              "game/tests/l1/trace_2p_2222.jsonl",
              "game/tests/l1/trace_4p_4242.jsonl",
              "game/tests/l1/trace_6p_6666.jsonl",
              "game/tests/l1/trace_4p_chemo_4242.jsonl"
            ],
            "assert": "每一步用 L1View.Load 装一份世界，LegalActions.Of 非空时 HeuristicPolicy.Choose 回的下标落在 [0, n) 内、且对应决策 ValidateDecision 为 true。**不比值**（不与 GD 的答案比 —— Kevin 六条第 2 条）。"
          },
          {
            "name": "kind 覆盖",
            "assert": "跑完四套夹具，**DecisionType 的命中集合 ≥ 一张写死的清单**（至少 Move / Draw / PlayCard / EndTurn / Pass 以及夹具里真出现过的那些）。**这一条是必须的** —— 没有它，「把某个分支改成恒回 0」这个变异合法性判据抓不到。"
          },
          {
            "name": "推演不改原世界",
            "assert": "装一份世界 s0，记下 L1View.Of(s0)；用启发式自对弈推演 200 步；再取 L1View.Of(s0) 逐字段相同。"
          },
          {
            "name": "rng 隔离",
            "assert": "同一份 WorldState + 同一 seat，连续调 Choose 十次，答案逐次相同（启发式不消耗、不依赖任何随机流）。"
          },
          {
            "name": "不自己算规则（软闸）",
            "assert": "CellWar.Ai 源码里零 RuleTuning 字段的硬编码字面量；对 RulePolicies / BoardRules / SkillRules / Settlement / WorldEffects 的调用点 ≥ 一个下界。形状由 P-C 定，但要能红。"
          }
        ],
        "suite": [
          "dotnet test core/CellWar.Core.Tests 全量绿（基线 1013 项，见 docs/archive/口径二_测试迁移规格.md 批 5a 落地记录）",
          "bash tools/run_l0.sh 全绿（Ai 不参与 L0，但 csproj 一动就要重跑）"
        ]
      },
      "mutants": [
        "把 LegalActions 的 Ordinal 定序去掉 ⇒ 6 人夹具上下标不稳，合法性测试应能抓到（抓不到就说明测试太松，补一条「同一世界两次枚举下标逐位相同」）",
        "把 HeuristicPolicy 的某个 DecisionType 分支改成恒回 0 ⇒ **kind 覆盖那条**红（合法性那条不会红，这就是为什么覆盖条是必须的）",
        "在推演里用反射改 WorldState.Cells ⇒ 不可变性那条红",
        "把 AI 的 rng 换成从 s 里摸来的真实流 ⇒ rng 隔离那条红（也是 P-1 那个 bug 的 AI 侧对照）"
      ],
      "forbidden": [
        "core/CellWar.Core/**.cs（含 Runtime.cs / MatchSession.cs / SemanticKey.cs / Observation/**）",
        "game/**（线 C 一个 GD 文件都不碰）",
        "协议：ObservationV1.cs / ObservationV1Codec.cs / cw_obs_proto.gd / docs/观测协议_v1.md —— 本批零改动、不升 p",
        "tools/build_patch.sh / tools/publish_release.sh —— **只登记不改**（CellWar.Ai.dll 进热更载荷是已拍的，但发版等 Kevin）",
        "MC / MCTS 的任何 C# 实现或接口占位"
      ],
      "acceptance": [
        "dotnet test 全量绿",
        "bash tools/run_l0.sh 全绿",
        "git diff 在 core/ 下只有两处 csproj 各一行 + 新增的 core/CellWar.Ai/** 与 core/CellWar.Core.Tests/Ai/**",
        "git diff 不含 game/**"
      ],
      "docs": [
        "docs/开发日志.md 一条（新程序集 + 启发式移植 + 两行 csproj 的理由）",
        "docs/架构说明书.md §236「C# 内核（core/）」加 CellWar.Ai 一节（职责、TFM、InternalsVisibleTo、测试在 Core.Tests/Ai/）",
        "docs/archive/口径二_批2_AI进C#_方案.md §3.2 / §八 拍板 1·2·3 下补落地记录，并**改一句**：Kevin 09-19 追加口径把交付范围从「地基 + 陪练启发式」收窄成「完整的普通 AI + IPolicy，MC/MCTS 不迁移」",
        "登记（只写不改）：CellWar.Ai.dll 进热更载荷的清单位置（docs/archive/路线A_内核热更方案.md:136-137 的 build 表）与 ObsRuleset.ai_build 要升 p 这条"
      ]
    }
  ],
  "section_1_7_status": {
    "checked_at": "7487567",
    "items": [
      {
        "id": "§1.7(1)",
        "title": "CWKernelInProc 漏调 attach_engine",
        "status": "已修（不再是不一致）",
        "evidence": "cw_kernel_inproc.gd:322 _attach_engine；open:76 / close:112 / set_decider:335 三处；t_kernel_attach_engine 在 headless_test.gd:20507、已注册 :161",
        "residue": "方案 §1.7(1) 连带说的那条注释（ai_baseline_case.gd:7-8）今天仍写着「两边都成立」。实际上 make_bridge 自己在 :29 显式写了 tree_ai.game = g，所以**夹具是对的**，只是那句话说得不准。⇒ 纯文字瑕疵，不影响行为；改不改列进 questions。"
      },
      {
        "id": "§1.7(2)",
        "title": "第四档 CWMCTSValueBridge 未接线",
        "status": "仍在",
        "evidence": "F8 —— 全仓零实例化",
        "impact": "按 Kevin 追加口径（MC/MCTS 不迁移），它连搬迁清单都进不去 ⇒ 「接上 / 删掉」这个账没人还。列进 questions。"
      },
      {
        "id": "§1.7(3)",
        "title": "bot 客户端的 MC 跑在被裁过的假世界上",
        "status": "仍在",
        "evidence": "F9 —— cw_net.gd:317-330 的 view_for 仍是 rng=0 + 他人手牌 HIDDEN_CARD + 他人 pending.options 清空；cw_room.gd:701-706 的 bot 旁路仍在",
        "impact": "⚠ **新出现的连带后果**：批 1 规格（:301-305 / :804）判「批 2 AI 进 C# 之后整块删」；而今天的收窄口径是「只迁启发式、MC/MCTS 留 GD」⇒ **这块删不掉，要跟着 GD MC 活到 GD 内核退役**。cw_room.gd:704 那句注释因此过期。要 Kevin 认一次顺延，并回写批 1 规格。列进 questions。"
      }
    ]
  }
}
```
