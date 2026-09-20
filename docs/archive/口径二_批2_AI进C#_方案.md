# 口径二 · 批 2「AI 进 C#」方案稿

> 日期：2026-09-19 ｜ 分支 `csharp-core` ｜ **只读调研**：本稿不改一行代码、不动仓库。
>
> **读法**：每条事实后面带出处（`文件:行` 或 `文档 §节`）。**没有出处的句子是判断，不是事实**，本稿一律用「⇒」「建议」「推荐」起头。
>
> **可独立阅读**：§1 自带事实层，不需要先读迁移计划或拍板记录。
>
> **本稿要回答的**：今天 AI 怎么跑 → 「AI 单开一个进程」有哪几条路 → 每条的硬前置与人日 → 给 Kevin 一次拍完的清单（§8）。

---

## 〇、一页结论

**1. 「AI 搬家」不是一件事，是三件，它们对进程边界的要求完全相反**（展开见 §2）：

| | 是什么 | 今天在哪 | 能不能跨进程 |
|---|---|---|---|
| **策略** | 给一个局面 + 一张候选表，挑一个 | `heuristic_bridge.gd`（798 行） | **能**，一次往返就够 |
| **推演** | 一份能分叉 / 快进 / 回滚的世界 + 陪练 | `monte_carlo_bridge.gd` / `mcts_bridge.gd`（252 + 273 行） | **不能逐 step，可整批**（每决策一份快照进、一个下标出） |
| **特征** | 把局面压成数 | `cw_eval.gd`（13 维 × 13 权重，184 行） | 跟推演走 |

算账要分清**两种边界**，这是本稿第一版算错、修订时纠过来的一条：

- **逐 step 观测穿不过。** 一次全知 envelope 的 encode + 装载中位 **8.5 ms**（`docs/观测协议_v1.md` 附录 D），真对局较强档一次决策要跑 **192 个模拟 step**（`game/scripts/ui/match.gd:872`）。若每个 step 都要一份 envelope，192 × 8.5 ms ≈ **1.6 s / 决策**，而今天同一档实测 **48.7 ~ 52.8 ms**（`docs/archive/架构审查_2026-09-02.md:68`）。⇒ **「进程里没有引擎、靠观测报文推演」（路 (c) 那种形态）差 30 倍，不成立。**
- **整批 rollout 穿得过。** 仓库里现成的副线程入口 `cw_mc_thread_entry`（`monte_carlo_bridge.gd:135`）与 `cw_mcts_thread_entry`（`mcts_bridge.gd:118`）都是 **static**，入参只有 `(holder, snap, options, cfg, _box)`，`_evaluate_on` 的注释自承「**只依赖 `image`（一份完全自洽的 CWGame）与 cfg**，绝不碰外层 game / 场景树」（`monte_carlo_bridge.gd:164-165`），回一个 `{best: 下标, stats}`（`:224`、`mcts_bridge.gd:228`）。⇒ **一次决策要跨的是一份快照 + 一个整数，不是 192 份 envelope。** 这份快照今天已经在跨机器传了：联机的 `state` 报文就是它（裁过 rng 与他人手牌），实测 **3.3 KB（zstd 后）、`shadow.restore` 0.25 ms**（`docs/archive/内核替换_拍板记录.md:313`、`docs/开发日志.md:170`）。

**2. 四条路的一句话判词**（(a3) 是修订时补的第四条，比 a1/a2 都便宜）

| 路 | 一句话 | 治不治 Kevin 的线程阻塞 | 最大代价 |
|---|---|---|---|
| **(a1/a2) AI 留 GD、子进程里放一份完整 GD 引擎 + 走网络报文 / envelope** | 形状照抄今天的 `bot` 机器人客户端 | 联机治、单机要多起一个 loopback 服务器 | 与「不留 GD 内核」拍板冲突（§六 2026-09-18）；`bot` 旁路欠账续期 |
| **(a3) 把两个静态线程入口原样改成子进程入口** | **一份 snapshot 进、一个下标出**；不动 AI 一行算法、不动报文、不动标尺 | **三条产品路都治**（本地单机也成立） | 多一套子进程生命周期；仍是 GD AI（不推进 C# 迁移） |
| **(b) AI 重写进 C#、住内核进程** | 迁移计划原案；接口面**基本齐了**，缺 5 个小口子 | **都治**（AI 天然不在渲染进程） | 硬依赖 sidecar 落地；1585 行要重写 |
| **(c) AI 当决策服务（envelope 进、语义键出）** | 协议层**今天就成立**，但**承载不了推演** | 治（策略在别的进程） | 只能跑「不搜索的策略」；模型本身还不存在；全知档**禁止过网**要先破 |

**3. 推荐（一句话）**：**(a3) 立刻止血、(b) 做地基、(c) 做策略口、(a1/a2) 不做**。
它们不是四选一 —— (a3) 是一条不改算法、不改协议、**不动平衡标尺**的纯搬运（§3.1bis）；(b) 提供「可分叉的世界 + 合法动作枚举 + 特征」；(c) 提供「策略可替换、可跨语言」的那一个口子。(b)+(c) 拼起来正好是训练模型路线要的形态（拍板记录 §九 #7：「我们在训练 AI 模型」，`docs/archive/内核替换_拍板记录.md:333/:336`）。

**4. Kevin 那一次「攻击动画不完整」，AI 已经被排除过了** —— 不是本稿的新发现：`docs/开发日志.md:161`「那局**没有 AI**，『专家档 AI 堵帧』假说作废；代码里房主与远端客户端路径逐字相同」，`docs/archive/内核替换_拍板记录.md:315` 同句。而且诊断线已经走过一轮并被叫停（fx-diag 补丁 build 202609180001 已打、至今 **0 条** `[fx-diag]`，`拍板记录:317/:330`；Kevin「复现不等了、诊断线不再是发版的顾虑」，`拍板记录:338`）。⇒ **要再量，必须换一种不依赖 Kevin 复现的量法**（计数器，§7 / 拍板 5），否则就是把已经叫停的那件事重提一遍。

---

## 一、今天 AI 怎么跑（事实层）

### 1.1 四只桥，一条继承链 + 一只并列

```
CWBridge                  game/scripts/core/cw_bridge.gd:11        引擎唯一接口
  └ CWHeuristicBridge     game/scripts/ai/heuristic_bridge.gd:11   798 行，不用随机数
      └ CWMonteCarloBridge  game/scripts/ai/monte_carlo_bridge.gd:22-23   252 行，扁平 MC
          └ CWUIBridge      game/scripts/ui/ui_bridge.gd:22-23     界面桥同时是 AI 桥

CWMCTSBridge              game/scripts/ai/mcts_bridge.gd:27-28     273 行，直接继承启发式
  └ CWMCTSValueBridge      game/scripts/ai/mcts_value_bridge.gd:14  23 行，只覆写 _leaf_tag
```

`CWMCTSBridge` **刻意不继承扁平 MC**，与它并列 —— 为的是不动平衡标尺（`game/scripts/ui/match.gd:879-880` 注释）。

桥与引擎的**唯一**接口是 `bridge.ask(req) -> int`，`req = {kind, pid, prompt, options:[{label, data}], tag?}`，10 种 `kind`（`game/scripts/core/cw_bridge.gd:1-18`）；引擎侧入口 `game.ask(pid, req)`（`game/scripts/core/cw_game.gd:403-410`）。

AI 代码量：`game/scripts/ai/` 共 **1585 行**（`wc -l`，不含 `.uid`）；迁移计划 §四 记的是 1576 行 MC/MCTS/启发式，C# 侧 **0 行**（`docs/archive/内核替换_迁移计划.md:189`）。

⚠ **这 1585 行里有自承的死码，搬迁量要先剔**：`heuristic_bridge.gd:324` 注释原文「（`kind="differentiate"` 那条 `_pick_differentiation` 是死代码 —— **引擎从不发那种询问**，留着没动。）」，函数体在 `:622`、分支在 `:72-73`。同类还有 `:70` 的 `"attack_target"` 分支 —— 引擎侧 `grep -o '"kind": "[a-z_]*"' game/scripts/core/*.gd` 的实际取值里**没有** `attack_target`，`cw_bridge.gd:5-8` 的 10 种 kind 清单里也没有（那 10 种是 `setup_place / immune_revive / revive / action / free_move / pick_cell / pick_tile / pick / chemo_target / effector_target`；同处还写明「UI 自己发起的 `confirm`（裂解净化二次确认）**不经引擎、不是 kind**」）。⇒ **至少两个分支是引擎已不再发的死码，本稿的人日表按「先剔再搬」口径估。**

**界面上只有三档**：`AI_LEVEL_NAMES := ["普通", "较强", "树搜索"]`，`AI_NORMAL=0 / AI_MC=1 / AI_MCTS=2`（`match.gd:804-807`）。**第四档 `CWMCTSValueBridge` 全仓没有任何一处实例化**（`grep -rn "CWMCTSValueBridge" game/` 只命中它自己的定义与注释）—— 它今天是一段**未接线的代码**，本方案不把它算进要搬的量，但要算进「要么接上、要么删掉」的账（§9）。

### 1.2 三只桥各读引擎哪些量

#### ① 启发式桥 —— 读得最杂，是「纯查询 RPC」的真正需求方

它**不做推演**，纯靠读引擎当场打分。行号均为 `game/scripts/ai/heuristic_bridge.gd`：

| 类别 | 调用 | 行 |
|---|---|---|
| 席位 / 细胞 | `game.player(pid)["faction"]` | 67, 101 |
| | `game.cell_of(pid)`（读 `energy` / `pos` / `hand` / `equipped`） | 93, 130, 340, 538, 652, 747 |
| | `game.cells[cid]`（按 cid 直取，读 `pos`） | 559, 615, 737 |
| | `game.living_cells(faction)` | 110, 118, 197, 257, 424, 604 |
| | `game.cells_at(pos[, faction])` | 113, 213, 235, 255, 263, 268, 276, 305, 469, 591, 694 |
| 棋盘 | `game.tile(c)["tissue"｜"solid"]` | 199, 233, 311, 407, 412, 441, 506, 562, 595, 663 |
| | **`game.tiles` 字典本体 + `.keys()` 全表扫** | 254, 262, 351-352, 689-692, 775 |
| | `game.is_cancerous(c)` | 241, 263, 467, 503, 593, 640, 712, 776 |
| | `game.count_tissue(SOLID)` | 349, 363, 447 |
| | `game.solidify_threshold()` | 444 |
| 规则计算 | `game.world.pressure_at(pos)` | 137, 293, 310 |
| | `game.actions.antibody_damage(me)` | 154 |
| | **`game.actions._toxin_targets(me)` —— 下划线私有方法，桥直接伸进去调** | 160 |
| | `game.can_pay(me, cost)` | 563 |
| 旋钮 / 全局 | `game.tune.immune_move_cancerous[game.immune_level]`、`game.tune.counter_dmg_on_fail` | 170-172, 177, 583-584 |
| | `game.memory` / `game.immune_level` | 371, 755, 757 / 170, 177, 583 |
| 随机 | **`game.rng.state`（只读、不消耗）**：分化种类按 `hash([rng.state, pid])` 选 | 322-334 |

两个对搬家最要命的点：

- **`game.tiles` 整份字典与 `game.cells` 数组是被当成裸数据结构遍历的**，不是通过查询函数。任何「只开几条纯查询 RPC」的方案都盖不住这两处。
- **`_toxin_targets` 是私有方法**（`:160`）。纯查询 RPC 清单必须把它算进去，否则启发式搬不过去。

`heuristic_bridge.gd:3-4` 文件头明写：「**策略只依赖对局状态、不使用任何随机数** → 同一种子的对局完全可复现（确定性测试依赖这一点）」。`AI_VERSION := "v11"`（`:36`），注释要求「改任何 AI 行为都要升号并重量平衡基线」（`docs/架构说明书.md:409-421`）。

#### ② 扁平 MC 桥

**只接管 `kind == "action"` 且 `options.size() > 1` 的顶层询问**（`monte_carlo_bridge.gd:69-72`），其余（落子 / 复活 / 卡牌中途选择）全部 `super.ask()` 回落启发式。

- 对**真 game** 只读两样：`game.player(pid)["faction"]`（`:77`）、`game.snapshot()`（`:79`）。
- 对**副本 image** 读写：`rng.seed/state`、`step(i)`、`pending()`、`is_over()`、`snapshot()/restore()`、`bridges`、`sim_quiet`、`order`、`cells`、`current_pid`、`tune.cancer_types`、`dispose()`（`:143-159`、`:189-224`、`:245-252`）。
- 末端估值 `CWEval.score(image, my_faction, death_cost)`（`:213`）。

#### ③ MCTS 桥

同样只接管 `action` 且选项 > 1（`mcts_bridge.gd:63-66`）。读真 game 两样（`:70-74`），副本上多读一个 `image.rng.state` 当根种子（`:144`）。叶子评分走 `CWLeafValue` 接口（`:161`、`:271-274`），默认 `CWClassicLeafValue` 包 `CWEval`。

#### ④ 估值 `cw_eval.gd` —— 两只 MC 的共同末端

`features(g)`（`:129-165`）一次要扫全盘：`g.tiles.keys()` 全表（`:134`）、`g.cells_at(c, IMMUNE)`（`:142`）、`g.cells` 全表读 `alive/faction/energy/hand/equipped/pos`（`:151-162`）、`g.memory` / `g.immune_level`（`:164`）；死亡项再读 `g.count_tissue(SOLID)`、`cell["respawn_round"]`、`g.round_no`（`:170-176`）；`_dist_to_cancerous` 又一次 `g.tiles.keys()` 全扫（`:179-184`）。`g.winner` 做终局短路（`:109`）。

**13 维特征向量 + 13 个整数权重已经拆出来**（`:73-86`），`score_with()` 允许外部注权重（`:108`）—— **训练路线在 GD 侧已有落点**。默认权重下输出必须逐位不变，`t_eval_features` 钉着（`:69-71`）。

配套工具已经在：`game/tests/collect_eval_data.gd` 导出「局面特征 → 最终胜负」的自对弈 CSV 喂权重回归，文件头自称「**这是 RL 路线上最便宜的第一步**」（`:1-8`）。

### 1.3 推演靠什么复制世界

`CWMonteCarloBridge._build_image_static(snap, cfg)`（`monte_carlo_bridge.gd:143-159`）是**唯一**的造世界口子，MCTS 直接复用（`mcts_bridge.gd:92`、`:119`）：

1. 从 `snap["order"]` / `snap["players"]` 重建阵营表 → `CWGame.new()` + `copy.init(faction_list, 0)`；
2. `copy.tune.cancer_types = snap["tune"]["cancer_types"]`（`tune` 是每局独立的实例，`cw_game.gd:89`）；
3. `copy.restore(snap)`；
4. 副本所有席位挂**同一只纯启发式陪练**、`copy.sim_quiet = true`。

快照本体是 `CWStateCodec.snapshot`（`game/scripts/core/cw_state_codec.gd:9-28`）/ `restore`（`:30-59`），字典是 **25 键**：`tiles / board_radius / cells / chemo_track / feed_log / feed_seq / effector_round / players / order / differentiated / flow / pending / round_no / memory / immune_level / winner / win_reason / win_kind / cancer_win_streak / chemo / current_pid / phase / events / rng / tune`（`tiles`/`cells`/`players`/`events` 全部 `duplicate(true)` 深拷）。`docs/archive/内核替换_迁移计划.md:86` 记的同样是 25 键，并且是「`CWMirror` 不收 `flow / pending / rng`」那条的出处。`CWGame.snapshot/restore` 只是薄壳（`cw_game.gd:371-377`）。**`rng.state` 也在快照里**（`cw_state_codec.gd:25`）—— `cw_game.gd:366-367` 明写「少了它，同一步走两遍会掷出不同的骰子，整个推演就没有意义了」。

**快照是可序列化的纯数据**：`tune` 那一项是 `game.tune.rules_state()`，实现就是把 `RULE_FIELDS` 逐个 `get()` 装成字典（`game/scripts/core/cw_tuning.gd:34-38`），`rng` 是一个整数。全字典里没有对象引用，键里的 `Vector2i` 正是 `var_to_bytes` 存在的理由（`cw_net.gd:5-6`：「报文 = 4 字节原长 + `zstd(var_to_bytes(字典))`……因为棋盘键是 Vector2i」）。⇒ **这份快照今天就在跨机器传**，(a3) 不需要发明新的序列化。

**确定性靠派生随机流，不用真骰子**：`_playout_seed(real_state, r) = hash([real_state, r])`（`monte_carlo_bridge.gd:239-240`）。注释（`:231-238`）解释得很清楚：2026-09-01 之前直接沿用真状态，那等于「让 AI 先用**真骰子**把这一步玩一遍再决定 —— 一个只有 AI 才有的信息优势」。MCTS 的三重保证见 `mcts_bridge.gd:12-18`：树内每条边进入前 `image.rng.seed = hash([父路径种子, 动作号])`（`:192`），所以不存快照也能重演状态、无需转置表。

**成本**：`cw_game.gd:369` 写着「实测深拷贝一次约 0.16 ms。真要跑上万次推演的话，这个成本是主要开销，届时应该换成落子/悔子（make-unmake）而不是整份复制 —— 但那要先有回滚日志」。扁平 MC 每候选一次 `snapshot()`、每条 rollout 一次 `restore()`（`monte_carlo_bridge.gd:195`、`:214`）；MCTS 每次迭代一次 `restore(root_snap)`（`mcts_bridge.gd:166`）。

### 1.4 决策一次的耗时量级

| 口径 | 数字 | 出处 |
|---|---|---|
| 一次 `snapshot()` 深拷 | ≈ **0.16 ms** | `cw_game.gd:369` |
| 引擎单步 | 0.106 ms；4 人整局约 292 步 / 31 ms | `docs/架构说明书.md:340-372` |
| 默认 `rollouts=2 / horizon=40`、无预算 | **单决策 ≈ 135 ms**，2 人整局 3.4 s | `docs/开发日志.md:11298` |
| `bench_mc` 早/中/晚三局面，无限预算（656 step） | **178.6 / 182.7 / 179.2 ms** | `docs/archive/架构审查_2026-09-02.md:68` |
| 同上，真对局较强档预算（192 step） | **48.7 / 49.9 / 52.8 ms** | 同上 |
| 浅层整局（r=1 h=2 budget=24）2/4/6 人 | 2.95 / 2.38 / 2.88 s | 同上 |
| **联机专家档（无预算闸，Kevin 机器实测）** | **381 ～ 645 ms / 决策** | `docs/archive/内核替换_拍板记录.md:313`、`docs/开发日志.md:170` |
| 联机 AI 席历史事故 | **一整个 AI 回合把服务器堵死 8 秒**，客户端心跳超时被判掉线 | `docs/开发日志.md:8630` |
| 一次全知 envelope（`viewer = -2`） | C# 36 259 ~ 48 108 B；GD 42 961 ~ 52 764 B（gzip 约 3.4~4.1 KB） | `docs/观测协议_v1.md` 附录 D |
| 一次全知 envelope 的 GD encode + `CWMirror` 装载 | 中位 **8.5 ms**（encode 3.9 / 装载 4.6） | 同上 |
| 一步 `push_state` 给 6 席 + 2 观众各一份 | **41 ms** | 同上 |

预算旋钮：真对局较强档 `max_sim_steps = 192`（`match.gd:872`）；树搜索档 `MCTS_ITERATIONS=160 / MCTS_HORIZON=12 / MCTS_MAX_STEPS=384`（`match.gd:811-813`，注释自承「**这三个数没有对局数据支撑**」）。
⚠ **192 这个预算只存在于本地路上。** `cw_net_bridge.gd:16` 建的那只 `mc` **从来没有设过 `max_sim_steps`**，默认值是 `0 = 无上限`（`monte_carlo_bridge.gd:32`）⇒ **联机专家档恒等于上表「无限预算」那一档**（bench 178~183 ms、Kevin 机器 381~645 ms），本稿第一版写的「联机每决策 50 ms 起」在联机路上根本不存在。**这是一条今天就能拧、不用等任何一批的旋钮**（§7 建议 1）。预算按**模拟 step 计工作量、不是墙钟**（`monte_carlo_bridge.gd:30-32`），所以快慢机器上评估同一批 rollout。基准脚本 `game/tests/bench_mc.gd`，断言 `t_mc_budget` 在 `game/tests/headless_test.gd:4343-4387`。

每步之间另有观感停顿 `CWSettings.ai_delay_ms = 220`（`game/scripts/core/cw_settings.gd:14`，`heuristic_bridge.gd:59-60` 的 `await create_timer(...)`）—— 那是**让帧**，不是阻塞。

### 1.5 三条路各住在哪个进程哪个线程

#### 路 1：本地单机 / 热座 / 教程 —— 全在**客户端主线程**

`match.gd:508-511` 把 `CWUIBridge` 当 `cfg["decider"]` 交给 `CWKernelInProc.open()`；教程走 `adopt` 版（`match.gd:550-551`）。`game/scripts/kernel/cw_kernel_inproc.gd:89-90` 的 `_run()` 是 fire-and-forget 协程，跑在主线程；`:388-389` 询问时 `await deciders[pid].ask(req)` ⇒ **AI 的思考就发生在引擎协程里、在主线程上**。

唯一的逃生口是副线程：`_threaded_eval` 起 `Thread`、主线程 `while not ready: await tree.process_frame`（`monte_carlo_bridge.gd:104-127`、`mcts_bridge.gd:98-114`）。**全仓只有这两处开线程**（`monte_carlo_bridge.gd:123`、`mcts_bridge.gd:110`，无 `WorkerThreadPool`）。

**★ 这两个入口的形状是 (a3) 的全部依据，值得单列**（`monte_carlo_bridge.gd:135-141`、`mcts_bridge.gd:118-123`）：

```gdscript
static func cw_mc_thread_entry(holder, snap, options, cfg, _box) -> void:
    var copy := _build_image_static(snap, cfg)      # 由快照造一份完全自洽的 CWGame
    holder["result"] = await _evaluate_on(copy, options, cfg)   # -> {best: 下标, stats}
    copy.dispose()
```

- **static**：不捕获主桥实例，文件注释原文「Thread 只拿到数据与 holder，接触不到主 game / UI / 场景树」（`monte_carlo_bridge.gd:122`）。
- **入只有 `(snap, options, cfg)`**，全是可 `var_to_bytes` 的纯数据（§1.3）；`cfg` 里连叶子评分器都只穿一根 `StringName` 标签，「坚决不传评分器对象本身跨线程」（`mcts_bridge.gd:50-52`）。
- **出只有 `{best, stats}`**（`monte_carlo_bridge.gd:224`、`mcts_bridge.gd:228`），调用方只取 `int(res.get("best", 0))`（`:92` / `:88`）。
- `_evaluate_on` 的注释自承「**只依赖 `image` 与 cfg**，绝不碰外层 game / 场景树」（`:164-165`）。

⇒ **今天的线程边界已经是一条纯数据边界。** 把 `Thread` 换成子进程，数据契约一个字不用改 —— 这正是 (a3)（§3.1bis）。

#### 路 2：联机 —— AI 住在**服务器进程的主线程**，客户端一行 AI 都不跑

`game/scripts/net/cw_room.gd:378-389`：一个房间 = 一份 `CWGame` + 一个 `CWNetBridge`（注册给所有 pid）+ 一个收养该 game 的 `CWKernelInProc`（`consumer=false / autorun=false`）；`:399` `_run()` → `await game.run_game()`。

`game/scripts/net/cw_net_bridge.gd:14-16` 桥自带两只 AI：`heur := CWHeuristicBridge.new()`（新手档 / 超时 / 离线代打）、`mc := CWMonteCarloBridge.new()`（专家档，默认 `rollouts=2 / horizon=40`）。分流在 `:19-31`：真人在线 → `room.ask_human`；否则 `await room.server.next_frame()` 让一帧，再按 `s["tier"]` 走 mc 或 heur。

**联机只有两档**：`game/scripts/net/cw_net.gd:191` `AI_TIERS = {"heur": "AI·新手", "mc": "AI·专家"}` ⇒ **树搜索档在联机路上根本不存在**。

服务器宿主两种：无头进程（`server/run.sh` → `godot --headless --script res://server/server_main.gd`，该脚本是 `SceneTree` 子类，`_process` 里 `server.poll()`，`game/server/server_main.gd:59-61`），或**局域网开房时就在客户端自己的进程里**（`game/scripts/ui/online_panel.gd:390` `CWNetServer.new()`，`:218` 在 `_process` 里 `lan.poll()`）。

客户端侧是 `CWKernelRemote`（`match.gd:695`，`game/scripts/kernel/cw_kernel_remote.gd:1-9`），只收报文流、只发 `answer`，**不含任何 AI**。

#### 路 3：网页版 —— 被迫回到主线程

导出预设 `variant/thread_support = false`（**稳定出处 `docs/网页导出.md:48`**：开线程的 web 包要求浏览器处于跨源隔离状态；日志里的同条在 `docs/开发日志.md:13421`）。两只桥都先探一句 `if not OS.has_feature("threads"): return await _eval_sync(...)`（`monte_carlo_bridge.gd:111-112`、`mcts_bridge.gd:101-102`）。`monte_carlo_bridge.gd:110` 的注释：「**代价是强 AI 思考时标签页会卡住 —— 那是单线程的必然，不是这里能解决的**」。这条是 2026-09-14 补的（`docs/开发日志.md:13434`：无线程构建上如果 `Thread.start()` 不同步执行，那个轮询 `while` 会**永远等下去且不报错**）。

### 1.6 主线程为什么会被卡

六条，按可信度排：

1. **评估是零挂起的纯 CPU 协程**。`monte_carlo_bridge.gd:164-165`：「它本身是协程，但只在 image 的桥全为同步启发式时才会一路跑到底（**零真挂起**）」；`mcts_bridge.gd:138` 同。同步路径下它整段占住调用线程，一帧都不让。
2. **`use_threading` 默认 false**（`monte_carlo_bridge.gd:50`、`mcts_bridge.gd:47`），**只有真对局的 UI 装配拨开**：`match.gd:876-877` `thinking = level != AI_NORMAL and not tutorial`、`bridge.use_threading = level == AI_MC and thinking`；`match.gd:888` 给树搜索桥。⇒ 平衡模拟、无头测试、教程局、**以及联机服务器**全是 false。
3. **联机服务器单线程、从没开过线程化，而且没有预算闸**。`game/scripts/net/cw_net_server.gd:9-12`：「单线程的代价：AI 席决策期间本进程不轮询网络」，两条对策是让一帧（`cw_net_bridge.gd:26` → `cw_net_server.gd:80-83`）与 `STALL_FORGIVE_MS = 1000` 的超时豁免（`cw_net_server.gd:42`）。`cw_net_bridge.gd:16` 建的 `mc` 既没设 `use_threading = true`、**也没设 `max_sim_steps`**（默认 `0 = 无上限`，`monte_carlo_bridge.gd:32`）⇒ **专家档 AI 席在服务器主线程同步推演、且是无预算档：每决策 180 ms 量级起，Kevin 机器上实测到 645 ms**（`docs/archive/内核替换_拍板记录.md:313`、`docs/开发日志.md:170`），历史上堵死过 8 秒（`docs/开发日志.md:8630`）。`docs/开发日志.md:2186` 记着「服务器代码处处假定单线程（AI 席让帧靠 `SceneTree.process_frame`），搬线程等于重写那一层」。
   ⇒ **这里有两个独立的旋钮**：给联机 `mc` 补一个 `max_sim_steps`（≈ 3.5 倍提速，0.5 人日，不动架构），与把评估挪出主线程（线程 = 与 :2186 那句冲突；子进程 = (a3)）。
4. **局域网开房时服务器与客户端同进程同线程**（`online_panel.gd:390` / `:218`）⇒ 服务器侧任何同步段都直接表现为**房主客户端掉帧**。
5. **网页版必然同步**（路 3）。
6. 次要：启发式桥每次决策要做多次 `game.tiles.keys()` 全表扫 + `living_cells` 遍历（§1.2），127 格 × N 细胞，单次不贵但每个决策点都跑。

**一条可检验的因果链：阻塞 →「攻击动画不完整」**

- 演出由 `CWPlayQueue.pump()` 每圈 `kernel.pull(viewer, since, 64)` 拉一批（`game/scripts/kernel/cw_play_queue.gd:44`）；
- **`_hurry_now = hurry or batch.size() >= hurry_backlog`**（`:50`，`hurry_backlog := 24` 见 `:28`，注释原文「积压 = 对面 AI 连打，人不该等它一条条演」）；
- `_hurry_now` 为真时，`fx`（攻击 / 扑咬 / 传送溶解）与 `card_played` 从 `await consumer.show_fx(...)` 退化为**不等的** `consumer.show_fx(...)`（`:113-118`、`:52-57`）。

⇒ 主线程被堵那段时间条目积压，解堵后一批 ≥ 24 条 → 队列自动快进 → **有时长的攻击演出被吞掉一半**。症状与 Kevin 的判断吻合。**（代码推演，未跑真机验证。）**

另一条独立的截断规则：`attack_fx.gd:play` 用新一段顶掉同细胞旧一段（间隔 < 0.66 s），且「联机比本地容易撞是因为服务器 AI 没有本地那 220 ms 的每步停顿」（`docs/archive/内核替换_拍板记录.md:313`）。

### 1.7 顺手抓到的三处不一致

**(1) `CWKernelInProc` 漏调 `attach_engine` ⇒ 树搜索档真对局必崩 —— 已确认，已随本稿修掉。**

规格要求 `CWKernelInProc.open()` 里写 `if d.has_method("attach_engine"): d.attach_engine(game)`（`docs/archive/口径二_批1_原子切规格.md:374-389`，A-5.3），`ui_bridge.gd:167-173` 的文档注释也照这么写（「`CWKernelInProc.open()` 对每个 decider 试调这个鸭子方法」），且它的实现同时喂 `game` 和 `mcts.game`。**但批 1 步 6+8 把 `match.gd` 的 `bridge.game = game` 换成「只挂不喂」（`match.gd:884`）时，`CWKernelInProc` 这一侧漏了转调** —— `open` 与 `set_decider` 都是无条件的 `d.game = game`，`match.gd:884` 那句注释因此落空。

**崩点**（`CWMCTSBridge.enabled` 默认 **true**，`mcts_bridge.gd:45`，所以顶层 `action` 询问一定进 `_mcts_pick`）：`ui_bridge.gd:194` 转给 `mcts.ask(req)` → `mcts_bridge.gd:63-66` 放行 → `_mcts_pick`（`:69`）**第一句碰 game 的是 `:71` 的 `var snap := game.snapshot()`**（`:70` 只读 `req["pid"]`，不碰 game），`game` 恒 `null`，当场崩。

⇒ **已修（随本稿一并落地）**：`game/scripts/kernel/cw_kernel_inproc.gd:322` 新增 `static func _attach_engine(d, g)` —— `if d.has_method("attach_engine"): d.attach_engine(g) else: d.game = g`；`open`（`:76`）、`close`（`:112`，转交 `null`）、`set_decider`（`:335`）三处统一走它。headless 测试 `t_kernel_attach_engine`（`game/tests/headless_test.gd:20492`，已注册进套件 `:160`）钉住这三处。

⚠ **连带修正一条测试口径**：`t_ai_same_hash` 的 `mcts4` / `mcts6` 两个用例**确实跑 MCTS**（`game/tests/ai_baseline_case.gd` 的 `CASES`，level=2），所以「测试没覆盖 MCTS」是错的 —— 它覆盖的是 MCTS **桥**，没覆盖 MCTS 的**装配**：`make_bridge` 自己写 `tree_ai.game = g`（`ai_baseline_case.gd:37`）+ `b.game = g`（`:44`），整条绕开 `CWKernelInProc.open`。该文件头注 `:7-8`「批 1 把 `bridge.game = game` 换成 `attach_engine` 之后这里仍写 `b.game = g` —— attach_engine 做的就是这一件事，两边都成立」**对 mcts 那半是错的**（`b.game = g` 喂不到 `b.mcts.game`），这句注释也该改。

**(2) 第四档 `CWMCTSValueBridge` 是未接线的代码**（§1.1）。要么接上、要么删，不该以这个状态进批 2 的搬迁清单。

**(3) 今天联机机器人客户端的 MC，是在一份「被裁过的假世界」上推演的。** `CWNet.view_for`（`game/scripts/net/cw_net.gd:317-330`）**不是全量快照**：`v["rng"] = 0`、他人手牌逐张换成 `HIDDEN_CARD`、他人的 `pending.options` 清空（函数头注原文：「某个席位看到的对局：rng 去掉、他人手牌占位、他人的待决选项去掉」）。而 `bot` 客户端拿它 `shadow.restore(view)` 再 `autoplay.game = shadow`（`cw_net_client.gd:314-338`）。⇒ **既有保真度缺口**：rng 恒 0、对手手牌是占位符。对 MC 本身无害（它本来就不该用真骰子 —— `_playout_seed` 就是为此，`monte_carlo_bridge.gd:231-240`），但对启发式有害：启发式要逐张读 `cell["hand"]`（`heuristic_bridge.gd:93/130/340/…`）。这笔账今天没人记，**选 (a1) 就是把它继承下来**。

---

## 二、为什么这不是「把 AI 搬个家」一件事

把 AI 拆成三件，它们对进程边界的要求**完全相反**：

**① 策略（policy）** —— 给一个局面 + 一张候选表，挑一个。
启发式桥是它；训练出来的网络也是它（`docs/RL策略架构设计.md` §3：「合法候选上的 softmax → 返回当前询问的选项下标」）。
它只需要**一次往返**：一份观测 + 一张候选表进，一个键出。⇒ **可以跨进程、跨语言、跨机器。**

**② 推演（rollout）** —— 一份能任意分叉 / 快进 / 回滚的世界，加一个陪练策略。
MC 与 MCTS 是它。真对局较强档一次决策 **192 个模拟 step**（`match.gd:872`），无预算时 **656 step**（`docs/archive/架构审查_2026-09-02.md:68`），每一步都要枚举合法动作 + 结算。
⇒ **要分清穿哪条边界**（本稿第一版把这两条混成一条，是最重要的一处修订）：
- **逐 step 穿不过**：若进程里没有引擎、每个 step 都要一份观测报文回本体，192 × 8.5 ms/envelope ≈ **1.6 s / 决策**（附录 D 的 encode+装载中位），比今天的 48.7~52.8 ms 慢 30 倍。
- **整批穿得过**：推演本身只要「一份自洽的世界」，而那份世界今天就是由一份 25 键快照当场造出来的（`_build_image_static`，§1.3）。所以边界上真正要过的是**每次决策一份快照 + 一个下标**（`{best, stats}`），量级是 3.3 KB / 0.25 ms（`拍板记录:313`），不是 192 份 envelope。
⇒ **正确的判词是：推演必须贴着一份完整规则引擎跑 —— 但那份引擎不必在宿主进程里，它可以在子进程里由快照当场重建。**

**③ 特征（features）** —— 把局面压成数。
`CWEval.features()` 的 13 维是它（`cw_eval.gd:73-86`），RL 的观测编码也是它（`docs/RL策略架构设计.md` §3.1）。
它跟**推演**走（叶子上每次都要算）—— 除非策略是「不搜索的网络」，那它跟**策略**走，一次决策只算一次。

⇒ **「AI 单开一个进程」这句话，对 ① 无条件成立，对 ② 只有在「那个进程里有一份完整的规则引擎」时才成立。** 四条路的全部分歧都在这一句上：

- **(a1/a2)** 在子进程里放一份**长驻的 GD 引擎**、跟着权威侧同步 ⇒ ② 成立，但那是第二份内核，要同步、要保活。
- **(a3)** 在子进程里放一份 **GD 引擎，但它只活一次决策**（收一份快照 → 造世界 → 推演 → 回一个下标 → 销毁）⇒ ② 成立，且**不需要同步、不需要保活、不需要报文** —— 因为这正是今天副线程在做的事（§1.5）。
- **(b)** 在 C# 内核进程里放 AI ⇒ ② 成立，且不用第二份引擎。
- **(c)** 进程里**没有**引擎 ⇒ ② 不成立，只能跑 ①。

---

## 三、四条路

每条按同一组 8 个轴写。**(a3) 是修订时补上的第四条**（§3.1bis）—— 第一版把「子进程」默认等同于「联机 + 长驻第二份内核」，漏掉了「一份快照进、一个下标出」这种最便宜的形态。

### 3.1 路 (a1/a2)：AI 留 GDScript，子进程里放一份长驻 GD 引擎

> 修订说明：本节写的是「子进程跟着权威侧同步、长驻一份世界」那种形态。**另一种便宜得多的子进程形态见 §3.1bis (a3)。**

**进程边界**：一个无头 Godot 子进程，里面有一份完整的 `CWGame` + 现有三只桥。

**今天已经有先例**：`hello {bot: true}` 的机器人客户端。服务器给自报 `bot` 的客户端在 `sync` 里**额外**推一份老 `view` + `turn` + `logs`（`game/scripts/net/cw_room.gd:701-706`、`game/scripts/net/cw_net.gd:12-13`），客户端拿它 `shadow.restore(view)` 再把 `autoplay.game = shadow`（`game/scripts/net/cw_net_client.gd:314-338`）。

**这个先例本身就说明了 (a) 的形状**。`cw_net_client.gd:5` 原文：「服务器只给 hello 自报 `bot:true` 的客户端多发那份 view —— **AI 桥要 `game.world` / `actions` / `rng`，MC 还要 fork 整局**，镜像一样都给不了、也不该给」。

**通信协议**：两种子形态，差别很大。

- **a1 · 复用现有 `bot` 通道**（网络报文 + **按席位裁剪过的** `view`）。改动最小。⚠ 但 `CWNet.view_for` **不是全量快照**：`rng` 置 0、他人手牌换 `HIDDEN_CARD`、他人 `pending.options` 清空（`cw_net.gd:317-330`，详见 §1.7(3)）⇒ **a1 天生带一个保真度缺口**，启发式读不到对手真手牌。而且这块正是批 1 规格判了死刑的欠账：「机器人客户端旁路与 `CWNet.view_for` / `view_for_watcher` **批 2 AI 进 C# 之后整块删**」（`docs/archive/口径二_批1_原子切规格.md:301-305` 与 `:804`）。⇒ **选 a1 = 把这笔欠账续期 + 继承那个缺口，并且要写进拍板记录。**
- **a2 · 改走 envelope（观测协议 v1）**。**对启发式档成立、对 MC/MCTS 不成立**，真正的障碍是 **`CWMirror` 不是一个可 `step()` 的 `CWGame`** —— 它的清单里 `flow / pending / tune` 不进（`docs/archive/内核替换_迁移计划.md:86`），而 `_build_image_static` 要 `snap["order"] / ["players"] / ["tune"]["cancer_types"]` 再 `copy.restore(snap)` 才造得出世界（§1.3）。⇒ **造不出能推演的 `CWGame`。** 要让 a2 支持 MC，就得新开一条「给 AI 的全量状态报文」—— 那正是 a1 的老 `view` 换个名字。
  > 脚注：envelope 里没有 rng（附录 C 明写）这一点**不是**障碍。MC 本来就不该用真骰子 —— `_playout_seed` 从快照的 rng 状态派生（`monte_carlo_bridge.gd:231-240`），`view_for` 里 rng 恒 0 反而无害。本稿第一版把分界理由压在 rng 上，是错的；分界线是「能不能重建一个可 `step()` 的 `CWGame`」。

**rng 与可复现性**：子进程里的 GD 引擎自带 rng，与权威侧无关；推演用 `_playout_seed` 派生（`monte_carlo_bridge.gd:239-240`），这一条今天就是对的。
**但**：权威侧一旦换成 C#，两边 RNG 是两个算法（Godot 内建 PCG vs `Xoshiro256StarStar`），「同种子整局对拍」**结构上不可能**（`docs/archive/内核替换_迁移计划.md:262-272`，§五）。⇒ **AI 会按 GD 规则想、按 C# 规则走**。这不是 bug，但它是 (a) 的最大隐性代价，且随 GD/C# 规则差异收敛而缩小、**永远不为零**。

**对三条产品路的影响**：

- **本地单机 / 热座 / 教程 —— a1/a2 要多起一个 loopback 服务器；(a3) 不用。** 单机没有服务器（`match.gd:508-511` 直接 `CWKernelInProc.open()`，全在客户端进程），a1/a2 靠的是**网络报文**，所以在单机上得先把单机跑成联机（多一层协议 + 多一个进程）。
  ⚠ **本稿第一版在这里写成「(a) 在本地单机不成立」，那是错的**，并且是对 (a) 评价最重的一句：单机时 `CWGame` 就在客户端进程里，要喂子进程只需 `game.snapshot()` —— **和今天喂副线程的数据一模一样**（§1.5），不需要任何服务器、任何网络报文。把「子进程」默认等同于「联机」是第一版的推理错误。⇒ 这一条只对 a1/a2 成立，**对 (a3) 不成立**。
- **联机 —— 最自然。** 服务器本来就是 Godot（§六 拍板 1 已定「Godot 服务器保留 + sidecar 内核」，`docs/archive/内核替换_迁移计划.md:277`），AI 子进程与服务器同机走 loopback，当场治 §1.6 第 3 条。
- **网页版 —— 无影响。** 网页版连服务器（拍板 1，`docs/archive/内核替换_拍板记录.md:14`），网页人机局的 AI 本来就在服务器上（`docs/archive/内核替换_迁移计划.md:240-241`）。

**与 C# 内核 / sidecar 的关系**：正交，**且重复**。AI 子进程不是 sidecar，它是第二个 Godot。桌面一局要跑**三个进程**（客户端 Godot + C# sidecar + AI Godot），两套握手、两套版本闸、两套崩溃语义。

**⚠ 与已有拍板冲突**：a1/a2 要求**永远保留一份长驻 GD 引擎**（AI 的推演世界，而且要跟着权威侧同步）。而 §六 拍板 2（2026-09-18）是「**不留 GD 内核，教程到时候用 C# 写**」（`docs/archive/内核替换_迁移计划.md:277`），§七 还给 GD 内核写了退役准入（`:328-336`）。⇒ **选 a1/a2 就意味着 GD 内核永远退不了役**，除非明确只是过渡、并写死期限。（(a3) 的子进程是一次性的、不跟权威侧同步，冲突程度低得多 —— 见 §3.1bis 末段。）

**与训练模型路线的兼容**：**最短**。`docs/RL策略架构设计.md` §5.1 明写「**采样端运行无头 Godot，多进程并行对局**；Python 侧负责模型、批量推理、轨迹处理和优化」，§5.2 要求「新增决策桥，在每次询问上输出观测和候选」—— 那与 (a) 的子进程是同一件事。

**硬前置**：
- a1：AI 版本自报出口（P-5）；子进程生命周期（起/停/超时/崩溃，且**崩溃绝不能计进 `patch_state.gd:82` 的 STRIKES**，同 `docs/archive/口径二_批0_底座规格.md` A-3.3 硬不变量②的精神）；联机席位表要认「外部 bot 占席」（掉线保席 / 投降投票 / 重连令牌都在 `cw_room.gd` 那 500 行里）。
- a2 另加：一条「给 AI 的全量状态报文」（新报文，升 `p`）。

**人日（纯编码，不含 triage / 平衡重标定）**：
- a1 ≈ **6~9 人日**，只治联机；要一并治本地单机 **+5~8 人日**（本地 loopback 服务器）。
- a2 的 MC 支持：**+8~12 人日**，且产物与 a1 的老 `view` 等价。
⇒ **判断：a1 / a2 都不建议做 —— (a3) 用更少的人日覆盖更多的产品路（下节）。**

---

### 3.1bis 路 (a3)：把两个静态线程入口原样改成子进程入口 ★ 修订新增

> **一句话**：今天 `Thread` 那条边界已经是一条纯数据边界（§1.5），把 `Thread.start()` 换成「起一个子进程、把 `(snap, options, cfg)` 送进去、收一个 `{best}` 回来」，**AI 算法一行不动、报文零新增、平衡标尺不动**。

**进程边界**：一个**短命**的无头 Godot 子进程（或常驻一个 worker 池，二选一，见硬前置 ③）。它不跟权威侧同步、不持有长期状态、不认识席位表 —— 它只认一份快照。

**通信协议**：**不经过联机协议，也不经过观测协议。** 传的就是 `CWStateCodec.snapshot()` 出来的那 25 键字典（§1.3）+ `options` + `cfg`，回一个 `{best, stats}`。

**rng 与可复现性 —— (a3) 在这一轴上是四条路里唯一无损的**：
- 快照里带 `rng`（`cw_state_codec.gd:25`），子进程 `restore` 后与副线程里那份 image **逐位相同**；
- 推演流照旧由 `_playout_seed(real_state, r) = hash([real_state, r])` 派生（`monte_carlo_bridge.gd:239-240`），MCTS 照旧 `image.rng.seed = hash([父路径种子, 动作号])`（`mcts_bridge.gd:192`）；
- ⇒ **同一份 snapshot 进去，出来的 `best` 与今天逐位相同**。这意味着护栏 `t_ai_same_hash`（§P-9）**继续有效、不用重录基线** —— (a1)/(a2)/(b) 三条都做不到这一点。

**对三条产品路的影响**：
- **本地单机 / 热座**：`match.gd:876-877` 今天已经在真对局上拨 `use_threading`，(a3) 就是在同一个开关后面多一级。**成立且最便宜。**
- **联机**：`cw_net_bridge.gd:16` 那只 `mc` 换成子进程即可。§1.6 第 3 条（服务器主线程同步推演）当场消失，且**不碰 `docs/开发日志.md:2186` 说的「服务器代码处处假定单线程」那一层** —— 因为主线程仍然是单线程，它只是在 `await tree.process_frame` 上等（与今天 `cw_net_bridge.gd:26` → `cw_net_server.gd:80-83` 的让帧是同一套）。局域网房主同进程的那条路（`online_panel.gd:390`）一并治好。
- **网页版**：**不治，但也不退化。** 浏览器里起不了子进程，(a3) 必须保留今天的三级回落 —— 子进程 → 线程 → 同步（今天是 `if not OS.has_feature("threads"): return await _eval_sync(...)`，`monte_carlo_bridge.gd:111-112` / `mcts_bridge.gd:101-102`）。⇒ 网页版仍是 `monte_carlo_bridge.gd:110` 那句「单线程的必然」。

**与 C# 内核 / sidecar 的关系**：**正交，且不制造第二个长驻内核。** 子进程是一次性的推演器，不是权威侧，不需要握手、不需要版本闸对齐规则（它用的就是宿主发来的快照）。⚠ 但**权威侧一旦换成 C#**，(a3) 与 (a1)/(a2) 一样要面对「AI 按 GD 规则想、按 C# 规则走」（`docs/archive/内核替换_迁移计划.md:262-272`，两边 RNG 是两个算法）。⇒ **(a3) 是止血，不是终局。**

**与训练模型路线的兼容**：**中性。** 它不推进也不阻碍 —— RL 稿 §5.1 的「无头 Godot 多进程并行采样」与 (a3) 起的是同一种进程，子进程入口这套脚手架可以复用。

**硬前置（四条，逐条核过）**：

1. **快照能不能 `var_to_bytes`？—— 能，而且今天就在这么干。** 快照全是纯数据：`tune` 项是 `RULE_FIELDS` 逐个 `get()` 装的字典（`cw_tuning.gd:34-38`），`rng` 是整数，键里的 `Vector2i` 正是 `var_to_bytes` 存在的理由（`cw_net.gd:5-6`）。`cfg` 里连叶子评分器都只穿一根 `StringName`（`mcts_bridge.gd:50-52`）。**联机的 `state` 报文实测 3.3 KB（zstd 后）、`shadow.restore` 0.25 ms**（`拍板记录:313` / `开发日志:170`）⇒ 每决策一次往返的序列化成本 **≈ 0.5 ms 量级**，对着 180~645 ms 的决策耗时可以忽略。
2. **子进程怎么起？—— 仓库里今天零先例，这是 (a3) 唯一真正的新代码。** 全仓 `OS.create_process` / `OS.execute` **一次都没用过**；唯一提到它的是 sidecar stub 的计划注释（`game/scripts/kernel/cw_kernel_sidecar.gd:3`：「真正的实现在 sidecar 那一批：`OS.create_process` 起 `CellWar.Sidecar`、loopback + token……」）。⇒ **建议与 sidecar 共用同一套进程生命周期代码**（起 / 停 / 超时 / 崩溃 / 退出码），别写两份。
3. **通信走 stdio 还是本地 TCP？⇒ 建议本地 TCP（loopback + token），理由有三条**：① 报文编解码**现成**——`CWNet.encode/decode` 就是「4 字节原长 + zstd(var_to_bytes)」（`cw_net.gd:5-6`、`:249`、`:267`），能直接吃带 `Vector2i` 键的快照，走 stdio + JSON 反而要新写一套 Vector2i 编码；② sidecar 那一批计划的就是 loopback + token（`cw_kernel_sidecar.gd:3`），共用一套；③ 宿主侧的轮询形状与今天的 `while not ready: await tree.process_frame` 完全一致。
   ⚠ **待核（引擎 API，不是仓库事实）**：Godot 4.5 的 `OS.create_process` 只回 PID、不给管道；带管道的是 `OS.execute_with_pipe`。走 stdio 前必须先确认后者在无头导出包上可用 —— **本稿不替这条下结论**。
4. **网页版怎么办？—— 不做，回落到今天的路径。** 见上「对三条产品路的影响」。⇒ (a3) 必须写成**三级回落**，不能假定子进程一定起得来（这也是 sidecar 的硬纪律：起不来绝不能计进 `patch_state.gd` 的 STRIKES，`docs/archive/口径二_批0_底座规格.md` A-3.3 硬不变量②）。

**人日（纯编码，不含 triage / 平衡重标定）**：
| 项 | 人日 |
|---|---|
| 子进程入口脚本（一个 `SceneTree` 子类，读请求 → 调现有静态入口 → 回下标） | 0.5~1 |
| 进程生命周期 + 三级回落 + 超时 / 崩溃（若与 sidecar 共用则更少） | 1.5~2.5 |
| 传输（复用 `CWNet.encode/decode` + loopback token） | 0.5~1 |
| 测试：同一 snapshot 走子进程与走线程 `best` 逐位相同 + 三级回落各一条 | 0.5~1 |
| **合计** | **3~5 人日** |

> **判断**：(a3) 比 a1 便宜一半、覆盖面更大（本地单机也治）、且是四条路里**唯一不动平衡标尺**的。它的代价是「仍然是 GD AI」—— 但它也不加深对 GD 内核的依赖（子进程不是长驻内核），所以与 §六 拍板 2「不留 GD 内核」的冲突**远小于 a1/a2**：GD AI 退役时，这套子进程脚手架照样能用来跑 C# AI 或 RL 采样端。

---

### 3.2 路 (b)：AI 重写进 C#，住 C# 内核同一进程（迁移计划原案）

**进程边界**：**不新增进程**。AI 住在已经规划好的那个内核进程里 —— 桌面是 sidecar（拍板 1：「桌面本地 sidecar，网页版连服务器」，`docs/archive/内核替换_拍板记录.md:14`），联机是服务器旁的 sidecar（§六 拍板 1 (a)）。
⇒ **对客户端渲染进程而言，AI 已经「迁出去」了。** Kevin 要的那件事由 (b) 天然满足，代价是要等 sidecar。

**通信协议**：**跨进程不新增报文**。AI 与内核在同一进程、同一份 `WorldState` 上，直接吃：
- `BasicRulesEngine.GetAvailableDecisions(WorldState, seat)` —— XML 注释原文就是「获取当前可用的决策列表（**用于AI**）」（`core/CellWar.Core/IRulesEngine.cs:28-31`）；
- `ExecuteDecision(state, decision, rng)` / `AdvancePhase(state, rng)`，三个都**收 `IDeterministicRng` 作参数**（`core/CellWar.Core/BasicRulesEngine.cs:8-36`）；
- `Runtime.Fork()` —— 走 `store.Fork(lease)`，**结构共享、O(1) 分叉**（`core/CellWar.Core/InMemoryStateStore.cs:92` 只是把同一份不可变快照再挂一个 key），并置 `PresentationMuted = true`（`core/CellWar.Core/Runtime.cs:18-19`，等价 GD 的 `sim_quiet`）。**这比 GD 的整份深拷（0.16 ms/次）便宜一个量级。**
- `MatchSession.RequestAsync(DecisionRequest, CancellationToken)` —— 在 `gate` 锁**之外** await（`core/CellWar.Core/MatchSession.cs:207-232`），带 `ControllerEpoch`（`ReplaceController` `:197`）做抢占/换手。⇒ 「AI 在别的线程想、宿主不被堵、人类可随时接管」这套挂点**今天就有**，接口在 `core/CellWar.Core/ISession.cs:5-8`。

**rng 与可复现性 —— ★ 这里有一个必修的活缺口。**

`Runtime.Fork()` 把 `rngPrototype.Fork()` 传给新 Runtime（`Runtime.cs:179-188`），**但构造函数只在 `lease.Snapshot.Simulation.Rng == null` 时才写入**（`Runtime.cs:44-49`）。分叉出来的快照里 `Rng` **非空**，于是每步 `rng.SetState(before.Rng!.Value)`（`:94-95`）用的是**真实流** ⇒ **AI 的推演会掷出与主线完全相同的骰子**。

`Runtime.cs:84-93` 的注释自己把这条写在第三位：「③ **AI 推演不能用真实 rng 状态，否则 AI 提前看到自己要掷的骰子** —— GDScript 侧 2026-09-01 修过同一个 bug（`monte_carlo_bridge` 的 `_playout_seed`）」。拍板记录 §五 #4 也写着「权威内核必须能控制随机源，**AI 一进来它就从『不阻塞』变成阻塞**」（`docs/archive/内核替换_拍板记录.md:211`）。

⇒ **P-1 必修，且今天零成本**（加一个 `Fork(RngState derived)` 或 `WithRng(...)`）。

第二个 rng 缺口：**`MatchSession` 根本没法注入 rng** —— 两个 public 构造与 `Restore` 都写死 `new Xoshiro256StarStar(...)`（`core/CellWar.Core/MatchSession.cs:122-136`、`:291-298`），`CheckpointCodec.cs:104` 还用 `new Xoshiro256StarStar(1).SetState(rng)` 校验形状。⇒ 走 `MatchSession` 的消费者（sidecar / 服务器 / AI）拿不到随机源控制权。**P-2。**

**对三条产品路的影响**：
- **本地单机 / 热座 / 教程**：AI 在 sidecar 进程 ⇒ 客户端主线程完全不背 AI。**最干净的一条。**
- **联机**：服务器是 Godot，AI 在 C# 里 ⇒ 每次决策穿一次 sidecar 边界。但**推演在 sidecar 内部**，边界只穿「问 / 答」两句话 ⇒ 便宜。AI 算力从 Godot 服务器主线程搬到 sidecar 进程，§1.6 第 3 条当场消失。
- **网页版**：连服务器，同联机；`monte_carlo_bridge.gd:110` 那句「标签页会卡住」随之作废。

**与 C# 内核 / sidecar 的关系**：**硬依赖**。`CWKernelSidecar` 今天是 **stub**：`open()` 恒失败 → `UNAVAILABLE` + `SPAWN_FAILED`，批 0 只交付一份线协议附录、不写实现（`docs/archive/口径二_批0_底座规格.md` A-3.5）。本仓 `find . -name "*.csproj"` 只有 `core/CellWar.Core` 与 `core/CellWar.Core.Tests`，**`CellWar.Sidecar` / `CellWar.Ai` 目前只在文档里**（`docs/archive/路线A_内核热更方案.md:115` / `:275`）。⇒ **(b) 的落地时间 = sidecar 落地时间 + AI 本体。**

**与训练模型路线的兼容**：**中等，且要改一版设计稿**。(b) 给训练的是「合法动作枚举 + 观测特征 + O(1) 可分叉世界」—— 正是 RL 采样端要的东西，而且比 GD 的深拷快。但 `docs/RL策略架构设计.md` §5.1 写的是「无头 Godot 采样端」，换成 C# 采样端要重写那一节（⇒ 判断：不难，吞吐反而更好，但**得有人认领改稿**）。
(b) 本身**不产出**神经网络，它产出的是网络能插进去的那些口子。

**硬前置**：P-1（Fork 派生 rng）、P-2（MatchSession 注入 rng）、P-3（纯查询 RPC）、P-4（可见性）、P-5（`ai_build`）、P-8（同包同 build 三铁律）、**以及 sidecar 本体**。详见 §4。

**人日（纯编码，不含 sidecar 本体、不含 triage、不含平衡重标定的对局时间）**：

| 项 | 人日 |
|---|---|
| P-1 + P-2（两个 rng 口子） | 1~2 |
| P-3 纯查询：`ErosionCandidates` / `RootedTargets` 抽出 + `PressureLoss` 换签名 | 2~3 |
| P-4 可见性 + P-5 `ai_build`（含升 `p`、两侧测试） | 1~2 |
| 启发式 798 行 → C# | 8~12 |
| 扁平 MC 252 行 → C#（含派生随机流、预算口径） | 3~5 |
| MCTS 273 行 → C#（含确定性三重保证） | 3~5 |
| `CWEval` 184 行 + 13 维特征 + 权重注入口 | 2~3 |
| 对齐与回归：三档跑通 + `t_ai_same_hash` 的 C# 等价物 + 重标定跑批 | 8~15 |
| **合计** | **28~47 人日** |

> **这个数怎么用 —— ⚠ 它与迁移计划 §八 的 33~70 打架，必须取舍，不能两个都留着。**
> 迁移计划 `:407-411` 说的是「唯一给了实施量级的一路按自己的表硬算是 **33~70 人天纯编码**，但它**已经把另外三路的内容包进去了**，所以那不是四路之和，是一个**下界**」⇒ **33~70 是含 AI 在内的全工程下界**。而本表单给 AI 一项就 28~47，几乎吃掉整个全工程下界。二者不能同时成立。
> **本稿的取舍：以本表为准，迁移计划 §八 的 33~70 作为「全工程下界」即告作废。** 理由：33~70 是在 AI 一行都没细拆时估的（`:189` 记的 C# 侧 AI 是 0 行），本表是逐文件、逐行数拆出来的第一份 AI 口径。⇒ **下一次改迁移计划 §八 时要把这句话回写进去**（本稿只读，没改）。口径不变：**纯编码，排除 triage、对拍用例、平衡重标定的对局时间；是下界，不是承诺。**

---

### 3.3 路 (c)：AI 只作为「决策服务」（envelope 进、语义键出）

**进程边界**：AI 是一个**不持有世界**的服务。它收一份观测 + 一张候选表，回一个语义键。实现语言随意（GD / C# / Python）。单机时本地子进程，联机时服务器旁进程，训练时就是训练脚本本身。

**通信协议 —— 今天已经画好了，缺的只是一个 op**：
- 观测：`ObserveV1(viewer)`；`viewer == -2` 是**全知**档，`SeatFilter.Crop` 原样返回（含全部 `options` 与明文手牌），是 AI 唯一能一次拿到「全局状态 + 全部合法选项」的 public 出口（`core/CellWar.Core/Observation/SeatFilter.cs:18-27`；档位定义 `docs/观测协议_v1.md` §七，注明「**禁止过网**」）。
- 作答：`MatchSession.SubmitByKey(seat, askId, key, index)`，口径「**语义键为准、下标兜底**」（`core/CellWar.Core/MatchSession.cs:246-266`，E-2 拍板）。
- 文法：`SemanticKey`（public static，`core/CellWar.Core/SemanticKey.cs:1-31`），两侧同一套，GD 那份在 `game/scripts/kernel/cw_semkey.gd`，「不许出现第四份」。
- 传输：sidecar 线协议是 JSON Lines over stdio，`op` 与 `CWKernel` 方法一一对应，**清单里已经包含 `fork_for_rollout`**（`docs/观测协议_v1.md` 附录 C）。
- 观测里已备好的 AI 特征（tier A）：`ObsTileD{Pressure, SolidFraction, StoreFraction, ProliferateChance}`、`ObsCellD{Income, AntibodyDamage, OverloadLoss, …}`、`ObsPlayerD{Income}`（`core/CellWar.Core/Observation/ObservationV1.cs:28/45/60`）。

**⚠ 致命限制：这条通道承载不了推演。** 一次全量 envelope C# 36~48 KB、GD 侧 encode + 装载中位 **8.5 ms**（附录 D），较强档一次决策 192 个模拟 step ⇒ **192 × 8.5 ms ≈ 1.6 s / 决策**。附录 D 自己给的结论是「按『每次问人之前一份』**绰绰有余**；按『每帧一份』**不行**」。
⇒ **(c) 只能跑「不搜索的策略」**：启发式（它只读当前局面，`heuristic_bridge.gd:3-4`），以及**训练出来的神经网络策略**（一次前向、不搜索）。要搜索，推演必须留在内核侧，外部只回一个键。

**rng 与可复现性**：决策服务**不需要 rng，也不该有** —— 它是纯函数 `(观测, 候选) → 键`。可复现性完全落在内核侧，这与 §五「L2 同种子整局对拍不可能」的结论一致（`docs/archive/内核替换_迁移计划.md:262-272`）：**外部策略不该依赖复现引擎的随机流**。
⚠ **一条要拍的细节**：如果网络按 softmax 采样出招，采样本身就是随机。要么温度 0 贪心（完全确定），要么**把采样种子当报文字段由内核下发**（可复现，但要升 `p`）。今天没有任何一份文档写过这条。

**对三条产品路的影响**：
- **本地单机**：桌面要跑一个本地推理服务（pytorch / ONNX Runtime）⇒ 分发变重。**权重不进 pck 是已拍的铁律②**（`docs/archive/内核替换_迁移计划.md:316-320`，按 `game/scripts/ai/cw_leaf_value_nn.gd:12-14` 的设计走本地常驻服务；「要下发权重另立项，且必须先回答『权重版本怎么和规则版本绑』」）。⇒ 桌面要么接受多一个重进程，要么单机档只用不带网络的 AI。
- **联机**：服务器旁一个推理进程，**多局共享一次 batch** ⇒ 算力最省。也顺带缓解 §三 那条「每个网页人机局在服务器上占一份 AI 算力」（`docs/archive/内核替换_迁移计划.md:240-241`）。
- **网页版**：连服务器 ⇒ 天然可用。**而且这是网页版唯一能用上强 AI 又不卡标签页的路**（`monte_carlo_bridge.gd:110` 那句「单线程的必然」对不搜索的策略不成立）。

**与 C# 内核 / sidecar 的关系**：**正交且互补**。sidecar 提供世界与枚举，(c) 提供策略。(c) 不阻塞 sidecar，sidecar 也不阻塞 (c)。

**与训练模型路线的兼容**：**这就是训练路线的部署形态**。`docs/RL策略架构设计.md` §3 的输出链是「当前询问的合法候选 → 动作特征编码 → 候选打分头 → 合法候选上的 softmax → 返回当前询问的选项下标 → Godot 规则引擎执行」，与 (c) 的 `decide` 报文逐项对应。
⚠ 但 §5.2 提醒：一次外层 `step()` 可能包含多个席位的选择，**必须覆盖开局 / 复活 / 行动 / 卡牌 / 技能的追加选择，并用 `req.pid` 路由**；不能只包装顶层 `pending()/step()`。⇒ `decide` 报文必须带 `pid` 与 `kind`，不能只带候选表。

**⚠ 第二条硬前置：全知档今天「禁止过网」，(c) 连协议都不合规。** `docs/观测协议_v1.md` §七（`:297`）的三档裁剪表里，`viewer = -2` 全知档「过网？」一栏写的是 **✘ 禁止**（`:303`；`:37` 的字段注释同样写「-2 全知（禁止过网）」）。而 (c) 在**联机形态**（服务器旁推理进程）与**训练形态**（Python 采样端）下，正是要把全知 envelope 送出进程 / 送上网。⇒ **这一条不解决，(c) 一行都不能写**，见 P-10。

**硬前置**：P-5（`ai_build`）、**P-10（全知档过网政策）**、新增 `decide` op（升 `p`）、权重版本 ↔ 规则版本绑定（铁律②明写要先回答）、**以及一个能跑的模型 —— 今天不存在**：`CWNNLeafValue` 是**占位**、`score()` 直接回落经典 `CWEval`（`game/scripts/ai/cw_leaf_value_nn.gd:11-18`、`:24-27`），`docs/RL策略架构设计.md` 状态栏写的是「**研究提案，尚未实现**」。

**人日**：协议 + 服务骨架 **3~5 人日**。**模型本身不在本方案范围**（见 RL 稿 §7 的五关与 §7.1 的三个早期问题）。

---

### 3.4 四条路对照

| 轴 | (a1/a2) 长驻 GD 子进程 | **(a3) 快照式子进程** | (b) 重写进 C# | (c) 决策服务 |
|---|---|---|---|---|
| 新增进程 | +1 长驻 Godot（桌面共 3 个） | +1 **短命** Godot（每决策一次，或一个 worker 池） | 0（复用 sidecar） | +1 推理进程（桌面）/ 服务器旁 1 个 |
| 新增报文 | a1: 0（复用 `bot` 旁路）；a2: 1 条全量状态报文 | **0**（不经联机 / 观测协议，传的就是快照本体） | 0 | 1 条 `decide`（升 `p`） |
| 能不能跑推演 | 能（子进程里有长驻 GD 引擎） | **能**（每决策由快照当场重建一份） | 能（`Runtime.Fork()` O(1)） | **不能** |
| rng 正确性 | 今天就对（`_playout_seed`）；a1 的 view 里 rng=0，无害 | **今天就对，且逐位不变** | **要先修 P-1 / P-2** | 不需要 rng（采样种子要拍） |
| 平衡标尺 | 要重新测（换了世界的保真度） | **不动**，`t_ai_same_hash` 继续有效 | 要重新测（跨语言，§五） | 不适用（策略换了就是换了） |
| 本地单机 | 要多起一个 loopback 服务器（+5~8 人日） | **成立，最便宜**（`game.snapshot()` 就在手边） | 最干净 | 要本地推理服务 |
| 联机 | 最自然，当场治阻塞 | **当场治**，且不动「服务器单线程」那一层 | 治，等 sidecar | 治，最省算力 |
| 网页版 | 无影响（本来走服务器） | **不治也不退化**（三级回落到同步） | 同联机 | **唯一能给网页强 AI 的路** |
| 与 sidecar | 正交且重复（两套握手） | 正交，**建议共用进程生命周期代码** | **硬依赖** | 正交且互补 |
| 与训练路线 | 最短（RL §5.1 就是无头 Godot） | 中性（脚手架可复用） | 中（要改 RL §5.1 那一版） | **就是它的部署形态** |
| 与已有拍板 | ⚠ 冲突（§六 拍板 2「不留 GD 内核」） | 冲突程度低（子进程不是长驻内核） | = 拍板 7 原案 | 与拍板 7 不冲突；⚠ 撞观测协议 §七「全知禁止过网」 |
| 新增欠账 | ⚠ `bot` 旁路续期（批 1 规格 `:301-305` 要求批 2 删）+ 继承 view 保真度缺口 | 一套子进程生命周期 | 无 | 权重版本绑定（铁律②已点名） |
| 纯编码人日 | 6~9（只治联机）/ +5~8（单机）/ +8~12（a2 MC） | **3~5（三条产品路一起）** | 28~47（+ sidecar 本体） | 3~5（+ 模型，另计） |

---

## 四、硬前置清单

> 标记：**[b]** 只有 (b) 需要；**[全]** 四条路都需要；**[c]** 只有 (c) 需要；**[a3]** 只有 (a3) 需要。
> **(a3) 的硬前置不在本节，在 §3.1bis**（四条：快照可序列化 ✅ 已成立 / 子进程怎么起 ⚠ 零先例 / stdio 还是本地 TCP ⚠ 待核引擎 API / 网页版回落 ✅ 照今天）。它**不依赖本节任何一条 P** —— 这正是它能立刻开工的原因。

**P-1 [b] `Runtime.Fork()` 要能派生 rng —— ★ 第一必修，今天零成本**
分叉出来的推演用的是真实 rng 流（`core/CellWar.Core/Runtime.cs:44-49` + `:94-95` + `:179-188`），AI 会提前看到自己的骰子。GD 侧 2026-09-01 修过同一个 bug（`monte_carlo_bridge.gd:231-240`），`Runtime.cs:84-93` 的注释自己写着这条。迁移计划把它排在热更载荷之前：「AI 的真正前置不是热更载荷，是 `Runtime.cs` 的 rng 注入」（`docs/archive/内核替换_迁移计划.md:322-324`）。
**建议实现口径**：照 GD 抄 —— `derived = hash([snapshot.Rng, playoutIndex])`，不要沿用真状态、也不要算术偏移（`monte_carlo_bridge.gd:236-238` 解释过为什么用 `hash`：LCG 的「状态+常数」两条流在头几个数上有结构性相关）。

**P-2 [b] `MatchSession` 要能注入 rng**
两个 public 构造与 `Restore` 都写死 `new Xoshiro256StarStar(...)`（`core/CellWar.Core/MatchSession.cs:122-136`、`:291-298`），`CheckpointCodec.cs:104` 还用它校验 checkpoint 的 rng 形状。⇒ 「注入随机源」只在 `Runtime` 构造那一层有效，走 `MatchSession` 的消费者（sidecar / 服务器 / AI）拿不到。拍板记录 §五 #4 只修到一半。

**P-3 [b] 纯查询 RPC = 对拍 L0 的 P2 四条（已完成一半）**
迁移计划 §二「两笔省」第 2 条：「**AI 要的纯查询 RPC ≈ 对拍 L0 的 P2 四条**（`ProliferateChance` / `ErosionCandidates` / `PressureLoss` / `RootedTargets`），同一批函数」（`docs/archive/内核替换_迁移计划.md:114-115`）。现状：

| 函数 | C# 状态 |
|---|---|
| `ProliferateChance` | ✅ 已抽（`core/CellWar.Core/RulePolicies.cs:590`，另有不带闸的 `ProliferateChanceRaw` `:599`） |
| `PressureAt` | ✅ 已抽（`RulePolicies.cs:562`；文档注释点名「将来的 **AI 评估**」），**但签名是按格 `(WorldState, HexPosition)`**，不是规格建议的 `PressureLoss(WorldState, Cell)` |
| `ErosionCandidates` | ❌ 仍内联在 `BoardRules.Erosion` 的收集循环里（`core/CellWar.Core/BoardRules.cs:259-294`） |
| `RootedTargets` / `RootedLimit` | ❌ 仍内联在 `BoardRules.Rooted`（`:369-383`，`limit = stage == 2 ? 1 : 3` 写在函数体里） |

**⚠ 补一条四条之外的**：启发式还要 `_toxin_targets`（`heuristic_bridge.gd:160`，**下划线私有方法**）。P2 那四条盖不住它，清单要加。

**P-4 [b] 可见性：一个必须拍的决定**
**门面是 public 的**：`IRulesEngine`（`IRulesEngine.cs:7`，含 `GetAvailableDecisions` `:31`）、`BasicRulesEngine`（含 `SolidFraction:11` / `StoreFraction:14` / `QuoteMove:21` / `GetAvailableDecisions:36`）、`GameRulesEngine` / `WorldState` / `MatchSession` / `MatchSetup` / `SemanticKey` / `Settlement` / `WorldEffects` / `CardCatalog` / `SeatFilter` 全是 public 类。
**读不到的是规则域里的那几条**：`RulePolicies:16` / `BoardRules:11` / `CellRules:24` / `CardRules:16` / `SkillRules:12` / `PhaseRules:11` / `PlacementRules:10` / `OutcomeRules:9` / `Stage:14` / `DecisionRouter:10` **全部 `internal static class`**；`core/CellWar.Core/CellWar.Core.csproj:10` 只对 `CellWar.Core.Tests` 开 `InternalsVisibleTo`。⚠ 注意 `PressureAt`（`RulePolicies.cs:562`）与 `ProliferateChance`（`:590`）**方法本身是 public，但类是 internal**，外部照样读不到。
⇒ **准确的判词**：门面（`BasicRulesEngine` 的四个方法 + `QuoteMove` / `SolidFraction` / `StoreFraction`）外部可读；**P-3 要的那四条纯查询，以及 09-19 四个具名入口里的三个（`RulePolicies.AnaerobicPool:496` / `SplitShare:515` / `CellRules.MoveLegal:365`），住在 internal 类里，一个独立的 `CellWar.Ai` 程序集一条都读不到**（只有 `Settlement.SettleLoss:145` 在 public 类里）。
三选一不变：AI 进同一程序集 / 加 `InternalsVisibleTo("CellWar.Ai")` / 做一层 public 查询门面。**这是铁律①「AI 与 Core 永远同包同 build」在代码层的具体含义**（`docs/archive/内核替换_迁移计划.md:316-320`），要一起拍（§8 第 3 条）。

**P-5 [全] AI 版本自报出口 `ai_build`**
铁律③：「宿主要有一个自报 AI 版本的出口，否则探针没有判据（探针多读一个 `AiBuild`）」（`docs/archive/内核替换_迁移计划.md:316-320`）。今天不存在：`MatchSession.Version()` 只给 `{host_abi, rules_build, digest}` 三项（`core/CellWar.Core/MatchSession.cs:283`；`ObsRuleset` 在 `Observation/ObservationV1.cs:15`，常量 `HostAbi = 1` / `RulesBuild = "core-slice-1+b0"` 在 `Observation/ObservationV1Codec.cs:18-19`）。GD 侧只有 `CWHeuristicBridge.AI_VERSION = "v11"`（`heuristic_bridge.gd:36`）与 `balance_scan` 的 `version_tag()`。
⚠ 加字段**必须升 `p`**：「字段增删改名 / 类型或单位变化一律升 `p`，消费者 `p` 不等即拒收（硬错，不静默兼容）；改协议要同一提交改 `cw_obs_proto.gd` + `ObservationV1.cs` + 两侧测试」（`docs/观测协议_v1.md` §九）。
并附一句已写进迁移计划的话：「**AI 版本号一改，所有用它量出来的平衡数字随之作废**」（`:322-324`）。

**P-6 [b][c] `fork_for_rollout` 的句柄政策**
GD 句柄侧今天是**空槽**：`game/scripts/kernel/cw_kernel.gd:188-190` 返回 `null`，三个实现的 `caps().rollout` **全是 false**（`cw_kernel.gd:76` / `cw_kernel_inproc.gd:131` / `cw_kernel_remote.gd:62` / `cw_kernel_sidecar.gd:22`）。批 0 底座规格 A-3.3 依据表原文：「**两份草案都漏**；批 0 只占槽 + caps 位，**政策归 AI 批**」。⇒ **就是本批要填的那一格**：谁能 fork、fork 出来的句柄能不能再 fork、`caps.rollout` 在三个实现上各是什么。

**P-7 [b] 推演吞吐的真成本不是 AI 的算力，是每步重算一次全量选项表**
`RuleFlow.Continue` **无条件**调 `rules.GetAvailableDecisions(state, ActivePlayerSeat)`（`core/CellWar.Core/RuleHandlers.cs:55-61`），而 `DecisionRouter.Available` 是 cells × tiles 的穷举 + 逐条 `Validate`（移动、分化、13 类带目标卡、六种种类技能各自摊开，`core/CellWar.Core/DecisionRouter.cs:182-373`）。迁移计划 §〇 记着「**每决策分配 298.6 KB**」的结构性证据（`docs/archive/内核替换_迁移计划.md:45-48`）。
⇒ **建议在 (b) 动手前先量一次**：C# 侧 **78 个测试文件**里**没有一个 Stopwatch / Benchmark**（`find core/CellWar.Core.Tests -name "*.cs" -not -path '*/bin/*' -not -path '*/obj/*'` = 78；源码侧 `core/CellWar.Core` 同口径 48 个。零 Stopwatch 是同口径 grep 的结果，`bin/` 下的 DLL 命中不算），而迁移计划 §〇 判定两路性能实测互相矛盾（C# 慢 34% vs 快 2~3 倍）「**两条都不能用**」。⇒ **今天本仓没有任何证据支持「C# AI 会快多少」。** 先补一个 `bench` 对照 `game/tests/bench_mc.gd` 的三个局面，否则 (b) 的工期与档位旋钮都是拍脑袋。

**P-8 [全] 同包同 build 三条铁律（已拍板，`docs/archive/内核替换_迁移计划.md:316-320`）**
① **AI 与 Core 永远同包同 build**，并配**正向自测**（造一个只含 `ai.dll` 的假清单跑闸、断言退出码 ——「不配正向自测的新闸就是白写」）；
② **神经网络权重不进 pck**，走本地常驻服务；要下发权重另立项，且必须先回答「权重版本怎么和规则版本绑」；
③ 宿主要有自报 AI 版本的出口（= P-5）。

**P-9 [全] 平衡标尺的处置 —— 这一条最容易被漏**
今天的护栏是 `t_ai_same_hash`：同种子 4 人 / 6 人全 AI 局、三档 AI 各一遍（`heur4 / heur6 / mc4 / mc6 / mcts4 / mcts6`，`game/tests/ai_baseline_case.gd` 的 `CASES`），`winner` / `round_no` / 整局 `state_hash` 与改动前**逐位相同**；基线在提交 `15ff402` 上录、400 步封顶（`MAX_STEPS`），存 `game/tests/baseline/ai_same_hash.json`（`docs/archive/口径二_批1_原子切规格.md:559` 与 `:680`）。**这是「AI 动了但标尺没动」的唯一硬证据。**
⚠ **限定一条**：它钉的是 AI **桥**的行为，**不含装配路径** —— `make_bridge` 自己写 `tree_ai.game = g` / `b.game = g`（`ai_baseline_case.gd:37`、`:44`），绕开 `CWKernelInProc.open`，所以 §1.7(1) 那个装配 bug 它一次都没抓到（现由新测试 `t_kernel_attach_engine` 补上）。
⚠ **而且它跨不了语言**：§五已经判定「同种子整局对拍结构上不可能」，两边 RNG 是两个算法（`docs/archive/内核替换_迁移计划.md:262-272`）。⇒ **AI 一旦进 C#，`t_ai_same_hash` 就失去参照物，平衡标尺只能靠重新测量**。这要在拍板时讲明（§8 第 2 条）。**唯独 (a3) 不触发这条** —— 它跑的是同一段 GD 代码、同一份快照，`best` 逐位不变（§3.1bis）。
同时要认一笔账：**平衡测量工具全在 GD 侧、且全部直接 `new` AI 桥 + `CWGame`**。同口径 grep（`grep -rln "CWHeuristicBridge|CWMonteCarloBridge|CWMCTSBridge|CWEval" game/`）**42 条命中里，去掉 13 条 `game/android/build/assets/` 副本、2 条 `.godot` 缓存，剩 27 个源码文件，其中 15 个在 `game/tests/`**：`ai_baseline_case.gd`、`balance_scan.gd`、`bench_mc.gd`、`collect_eval_data.gd`、`dump_game.gd`、`fx_recorder.gd`、`headless_test.gd`、`kernel_probe_bridge.gd`、`net_live.gd`、`net_play.gd`、`play.gd`、`slow_fx_bridge.gd`、`archive/balance_sim.gd`、`archive/balance_variants.gd`、`archive/demo_revive_block.gd`。
`game/tests/` 之外的 12 个是：`game/scripts/ai/` 八个（`cw_eval` / `cw_leaf_value` / `cw_leaf_value_classic` / `cw_leaf_value_nn` / `heuristic_bridge` / `monte_carlo_bridge` / `mcts_bridge` / `mcts_value_bridge`）+ `scripts/core/cw_data.gd` + `scripts/net/cw_net_bridge.gd` + `scripts/ui/match.gd` + `scripts/ui/ui_bridge.gd`。
⇒ **AI 进 C# = 这 15 个工具要么改、要么留在 GD 侧对着一个已经不用的 AI 跑。** 这是「AI 进 C# 的隐藏账单」，数字按上面的口径数，别再数出别的数。

**P-10 [c] 全知档的过网政策 —— 不拍这条，(c) 连协议都不合规**
`docs/观测协议_v1.md` §七（`:297`）三档裁剪表里，`viewer = -2` 全知档的「过网？」一栏是 **✘ 禁止**（`:303`），字段注释同样写「-2 全知（禁止过网）」（`:37`）。而 (c) 的联机形态（服务器旁推理进程）与训练形态（Python 采样端）都要把全知 envelope 送出进程 / 送上网。
⇒ **二选一**：① 新开一档「AI 档」裁剪（明文手牌 + 全部候选，但走**独立档位与独立闸**，与 `-2` 分开）；② 在 §七 明写「`-2` 仅限**宿主↔内核的可信管道**，跨机一律不许」并同步改表 —— 那等于承认 (c) 的联机 / 训练形态必须走 ①。**本稿推荐 ①**，理由：`-2` 今天是 InProc 镜像的默认档（`:309`「InProc 默认镜像 `viewer = -2` —— 与今天完全一样，不是新增泄漏」），给它松绑会把一条本地不变量变成跨机不变量。

---

## 五、需要新加的协议报文

| 报文 / 字段 | 属于哪条路 | 影响 |
|---|---|---|
| `ObsRuleset` 加 `ai_build` | **[全]**（铁律③ / P-5） | **升 `p`**；同一提交改 `cw_obs_proto.gd` + `ObservationV1.cs` + 两侧测试（`docs/观测协议_v1.md` §九） |
| sidecar op `fork_for_rollout` 的**语义**（op 名已在清单里） | (b)(c) | 附录 C 的 op 表已含此名，只是没有政策；本批定义「谁能 fork / 能不能再 fork / `caps.rollout` 三实现各是什么」 |
| `decide` op：入 `{pid, kind, envelope, options:[semkey]}`，出 `{key}` | **(c)** | 新 op ⇒ 升 `p`。**必须带 `pid` 与 `kind`**（RL 稿 §5.2：一次外层 `step()` 可能含多个席位的选择，不能只包装顶层 `pending()/step()`） |
| `decide` 的采样种子字段（若策略按 softmax 采样） | (c) | 未有任何文档写过；要么温度 0 贪心不加字段，要么加字段并升 `p`（§8 第 4 条） |
| **全知档 `-2` 的过网政策**（新开「AI 档」裁剪，或改 §七 的表） | **(c)**（P-10） | §七 `:303` 今天写的是 ✘ **禁止过网**。新开一档 ⇒ 改 `docs/观测协议_v1.md` §七 + 两侧 `SeatFilter` / `cw_obs_proto.gd` + 升 `p` |
| 「给 AI 的全量状态报文」（含 `rng`） | **(a2)** | `CWMirror` 不收 `flow/pending/tune`（`迁移计划:86`）⇒ 造不出可 `step()` 的 `CWGame`，要么新开一条，要么就是 a1 的老 `view`（rng 那条不是障碍，见 §3.1 脚注） |
| **（无）** | **(a3)** | **(a3) 零新增报文、零升 `p`** —— 传的是 `CWStateCodec.snapshot()` 本体，走 `CWNet.encode/decode` 那套现成编码（`cw_net.gd:249`/`:267`），不进联机协议、不进观测协议 |
| `CWNet` 的 `bot` 旁路（`view` / `turn` / `logs`） | **(a1)** | **不是新增，是不删**。批 1 规格要求「批 2 AI 进 C# 之后整块删」（`docs/archive/口径二_批1_原子切规格.md:301-305` / `:804`）⇒ 选 a1 要显式把它改成「保留」，并写进拍板记录 |

---

## 六、人日与不阻塞性

### 6.1 汇总（纯编码；**排除** triage、对拍用例、平衡重标定的对局时间）

| 路 | 人日 | 备注 |
|---|---|---|
| **(a3) 两个静态线程入口 → 子进程入口** | **3~5** | **本地单机 / 热座 / 联机一起治**；网页版回落同步（不退化）；**平衡标尺不动** |
| (a1) 联机 AI 进子进程，复用 `bot` 通道 | **6~9** | 只治联机；继承 `view_for` 的保真度缺口 |
| (a1) + 本地 loopback 服务器 | **+5~8** | 才能治本地单机 ⇒ **合计 11~17，被 (a3) 全面压过，不建议** |
| (a2) 让子进程改吃 envelope 并支持 MC | **+8~12** | 产物与 a1 的老 `view` 等价 ⇒ **不建议做** |
| (b) AI 重写进 C# | **28~47** | **不含 sidecar 本体**（`CellWar.Sidecar` 今天不存在；路线 A 估 250~400 行） |
| (c) 决策服务协议 + 骨架 | **3~5** | **不含模型本身**（RL 稿 §7 五关，无估）；**不含 P-10 的协议改动** |
| 附：给联机 `mc` 补一个 `max_sim_steps` | **0.5** | 不改架构的纯旋钮，≈ 3.5 倍提速（§1.4 / §1.6 第 3 条） |

> ⚠ **与迁移计划 §八 的 33~70 冲突，见 §3.2 末的取舍段** —— `:407-411` 的 33~70 是**含 AI 在内的全工程下界**，与本表的 (b) 28~47 不能同时成立。**本稿以本表为准，33~70 作为全工程下界作废，下次改迁移计划 §八 时回写。** 口径不变：纯编码、排除 triage / 对拍用例 / 平衡重标定，**是下界**。

### 6.2 哪一条最不阻塞其它批次

**最不阻塞：(a3) 与 (c)。**
- **(a3)** 不动规则域、不动协议、不动 C#、不动 sidecar、不动平衡基线，只加一层进程调度。它是四条里**唯一今天就能开工、且改错了随时能退回线程**的一条。
- **(c)** 不动 GD、不动规则域、不动 sidecar，只加一个 op 与一次升 `p`。而且它**先做也不浪费** —— 无论最后 AI 住哪，策略口都要有。⚠ 但它**被 P-10 卡住**：全知档今天禁止过网，协议不改就写不了联机 / 训练形态。

**(b) 阻塞多，但阻塞的都是本来就要做的。** P-1/P-2 是拍板记录 §五 #4 的欠账，P-3 是对拍 L0 的 P2 四条（迁移计划 §二已经算过「做一次算两笔」的账，`:114-115`），P-5 是铁律③。⇒ **(b) 的前置不是额外开销，是把已欠的账还了。** 真正的阻塞是 **sidecar 本体**（今天 stub）。

**(a1/a2) 会新增一笔欠账。** `bot` 旁路与 `CWNet.view_for` / `view_for_watcher` 本来判了批 2 整块删（`docs/archive/口径二_批1_原子切规格.md:301-305` / `:804`），选 a1 等于续期；同时它要求永远留一份长驻 GD 引擎，与 §六 拍板 2（「不留 GD 内核」）冲突。**(a3) 两笔都不欠** —— 它不碰 `bot` 旁路，子进程也不是长驻内核。

---

## 七、止血：Kevin 那一次「攻击动画不完整」

> **入库的原话**（`docs/archive/内核替换_拍板记录.md:338` = `docs/开发日志.md:86`）：「没有攻击动画不完整的问题，**大概率是线程阻塞，到时候把 AI 迁出去就好了**」。
> **未入库**：「我开的是局域网房，但是没有放 AI，把 AI 思考单开一个进程吧」—— 这句是**口头转述（09-19，未入库）**。本稿第一版给它挂了 `拍板记录:338` + `开发日志:78` 两个出处，**两个都不成立**（`grep -rn '局域网房' --include=*.md .` 只命中 `拍板记录:313/:315` 与 `开发日志:110/:161/:170`，没有一条是这句）。按本稿自己定的规矩「没有出处的句子是判断，不是事实」，这里改标口头。

**先认三件已经入库的事，不要当成新发现**：

1. **那一局没有 AI 席 ⇒ 「AI 堵帧」假说 09-19 早前一轮就作废了。** `docs/开发日志.md:161`：「局域网房主看不到攻击动画：**那局没有 AI**，『专家档 AI 堵帧』假说作废；**代码里房主与远端客户端路径逐字相同**」；`docs/archive/内核替换_拍板记录.md:315` 同句。⇒ 「把 AI 迁出去」会消掉**最大的一个**积压源（历史上堵死过 8 秒，`docs/开发日志.md:8630`），但**治不了他当天看到的那一次**。
2. **诊断补丁已经打过，而且没跑出数据。** `拍板记录:317`：fx-diag 补丁 build 202609180001 已上线（从 `a2fa59a` 另起分支 `diag-fx-0919`，只加 `[fx-diag]` print）；`:330`：「现在 **0 条 `[fx-diag]`**：带诊断的客户端还没跑过」。
3. **Kevin 已经叫停过一次。** `拍板记录:338`：「fx-diag 复现**不等了**、诊断线**不再是发版的顾虑**」。

⇒ **所以「再花半天量一次」这句话不能照原样提** —— 必须说清**换的是哪种量法，以及为什么这次拿得到上次拿不到的数**（见下）。

局域网房主进程里，每次问人之前都会发生的同步段，按量级排：

| 嫌疑 | 量级 | 出处 |
|---|---|---|
| `push_state` 逐人编 envelope（6 席 + 2 观众各一份） | **41 ms / 次** | `docs/观测协议_v1.md` 附录 D；实现 `game/scripts/net/cw_room.gd:662-705` |
| 观众 envelope 已按日志游标分档共用（正常一局只有一档） | 已优化 | `cw_room.gd:665-681` |
| `game.state_hash()` 每次 push 一次 | 未量 | `cw_room.gd:664` |
| 演出队列积压快进阈值 | `hurry_backlog := 24` | `game/scripts/kernel/cw_play_queue.gd:28`、`:50`、`:113-118` |
| `attack_fx.gd:play` 同细胞新段顶掉旧段（间隔 < 0.66 s） | 独立截断规则 | `docs/archive/内核替换_拍板记录.md:313` |

**建议（按性价比排，都不需要等批 2）**：

1. **★ 最便宜的一条：给联机 `mc` 补一个 `max_sim_steps`（约 0.5 人日）。** `cw_net_bridge.gd:16` 那只 `mc` 今天是无预算档（§1.4 / §1.6 第 3 条），补上本地那条 `192` 就是 **645 ms → 180 ms 量级**的直降。它不改架构、不动协议、不动播放形态，**与 AI 住哪完全无关**。⚠ 唯一代价：AI 变弱一档，联机与本地的专家档强度要对齐一次说法。
2. **换一种量法（约 0.5 人日）—— 不是 fx-diag，是计数器。** 在 `cw_room.push_state`（`game/scripts/net/cw_room.gd:662`）记「本次 push 的毫秒数」与「`game.state_hash()` 单独的毫秒数」（`:665`），在 `CWPlayQueue.pump`（`game/scripts/kernel/cw_play_queue.gd:38`）记「触发快进那一刻的 `batch.size()`」（`:50`）。
   **为什么这次拿得到上次拿不到的数**：fx-diag 是**客户端**的 print，要 Kevin 装上带诊断的包、打一局、复现、把日志发回来 —— 这三步一步都没发生（`拍板记录:330`，0 条）。而这两个计数器打在**服务器 / 房主侧**，**我们自己跑的无头联机测试**（`game/tests/net_play.gd` / `net_live.gd`）与任何一局局域网房都会写出来，**不依赖 Kevin 复现，也不需要再发一版诊断补丁**。
   ⇒ 一局下来就能分清是 envelope（41 ms/次）、是 `state_hash`、还是别的。**没有这个数，改什么都是猜。**
3. **把 `hurry_backlog` 从「条数」改成「条数 + 已积压时长」二选一**，或者对 `fx` 单独豁免快进。**这一条直接对着症状**，与 AI 住哪无关。⚠ 但它会改变拍板 2 定下的播放形态（「有时长的演出播完再放下一条」，`docs/archive/内核替换_拍板记录.md:315`）⇒ 要 Kevin 点头。
4. **联机专家档 AI 席挪出主线程。** 两种做法：
   - **开 `use_threading`（约 1 人日 + 验证）**：技术上可行 —— `_threaded_eval` 只要求 `Engine.get_main_loop() as SceneTree`（`monte_carlo_bridge.gd:117-120`），而无头服务器正是 `SceneTree` 子类、`_process` 里 `server.poll()`（`game/server/server_main.gd:59-61`），局域网房主也有 SceneTree。⚠ **但撞 `docs/开发日志.md:2186`**「服务器代码处处假定单线程（AI 席让帧靠 `SceneTree.process_frame`），搬线程等于重写那一层」。
   - **换成子进程 = (a3)（3~5 人日）**：主线程仍然单线程，只是在 `await tree.process_frame` 上等，**不碰 :2186 说的那一层**。⇒ **推荐这条**，理由见 §3.1bis。

---

## 八、给 Kevin 的拍板清单

### 拍板 1 · 批 2 交付整只 AI，还是先只交付「地基」？

- **(A)** 照原案交付整只：启发式 + 扁平 MC + MCTS 全部重写进 C#。
- **(B)** 先只交付**地基**（可分叉世界 + 合法动作枚举 + 特征 + 陪练用的启发式），**策略留一个可替换的口子**；MCTS 与「更强的档」等模型。

**推荐 (B)，但要认清它的性质：(B) = 收窄拍板 7 的交付范围，需要 Kevin 明确重拍。**
⚠ **不能把 (B) 说成「与已拍的一致」。** 拍板 7 白纸黑字是「**重写成 C#**，后续接神经网络模型」（`docs/archive/内核替换_拍板记录.md:21`）；而 §九 #7 的「启发式 v4 去留不重要，AI 走训练模型路线」（`:333`、原话 `:336`）说的是**启发式的下一版升级**不重要，**不等于现有启发式不用搬**。
支持 (B) 的理由：训练路线最终要的是那个策略口（RL 稿 §3），不是一份 C# 启发式；先搬地基能让 (b) 与 (c) 两条同时往前走；而且 1585 行里已有自承死码要先剔（§1.1）。
另：这一条在批 0 里有登记在案的版本 —— `docs/archive/口径二_批0_底座规格.md:691` 第 7 条「**本地 AI 归 GDScript 还是进 sidecar**……**它决定 GD 内核能不能退役**」，与本条和拍板 4 是同一件事的两个面，建议一起答。

### 拍板 2 · C# 的 AI 要不要保证与 GD 的 AI 逐决策一致？

- **(A)** 要：C# 启发式与 GD 启发式同局面同答案，平衡标尺不用重标定。
- **(B)** 不要：接受**重新测量**，AI 版本号一并升。

**推荐 (B)。** 理由：§五 已经判定「同种子整局对拍结构上不可能」（两边 RNG 是两个算法，`docs/archive/内核替换_迁移计划.md:262-272`），`t_ai_same_hash` 跨不了语言；硬要逐决策一致，等于把 798 行里每一个 tie-break 都写成规格条款。**代价要认**：所有用今天 AI 量出来的平衡数字随之作废（`:322-324` 已写明），4 人 / 6 人的基线要重跑。

### 拍板 3 · `CellWar.Ai` 怎么读 Core 的 internal？

- **(A)** AI 进 `CellWar.Core` 同一程序集。⚠ **与 09-18 已拍的第 6 条冲突，除非同时推翻它 —— 不建议。**
- **(B)** 独立 `CellWar.Ai` + `InternalsVisibleTo("CellWar.Ai")`。
- **(C)** 给 AI 做一层 public 查询门面。

**推荐 (B)。**
⚠ **先说 (A) 的问题**：`docs/archive/内核替换_迁移计划.md:294-295` 第 6 条「**`CellWar.Ai` 进不进热更载荷？—— 已拍板：进**」，`:278` 的 09-18 拍板表第 6 条「进（已拍过）」，`docs/开发日志.md:435` 同。**载荷里独立发一份 `CellWar.Ai.dll`，就意味着它是独立程序集** ⇒ 把 (A) 当开放选项摆上来，等于让 Kevin 在不知情的情况下推翻自己。本稿把它降级为「不建议」。
**(B) 的理由**：铁律①「AI 与 Core 永远同包同 build」（`docs/archive/内核替换_迁移计划.md:316-320`）说的是**同一次发版载荷**、不是同一个程序集，**(B) 才是这条铁律的字面实现**；internal 边界本来也不构成隔离；而 (C) 是第二份 API 表面，规则一改要改两处 —— 何况启发式还要 `_toxin_targets` 这种私有方法（`heuristic_bridge.gd:160`），门面会越开越大。

### 拍板 4 · 「AI 单开一个进程」落在哪个进程？

- **(A)** 终局就是 sidecar 进程（AI 是 sidecar 的一部分）。
- **(B)** 第三个独立进程（AI 自己一个）。
- **(C)** 过渡期先用**长驻** GD 子进程（路 a1/a2），有明确期限。
- **(D) ★ 新增**：**现在就做 (a3)（3~5 人日）当止血，终局仍走 (A)。**

**推荐 (D) + (A)：先做 (a3)，终局是 sidecar；(B) 与 (C) 都不建议。**
理由：
- **(a3) 是四条里唯一「立刻能做、不动平衡标尺、三条产品路一起治」的**（§3.1bis）—— 它把今天已经是纯数据边界的 `Thread` 换成子进程，AI 算法一行不动、零新增报文、`t_ai_same_hash` 不用重录。**它不等 sidecar、不等批 2。**
- **终局仍是 (A)**：桌面已经要起 sidecar（拍板 1），再多一个长驻进程就要多一套握手 / 版本闸 / 崩溃语义；而**推演必须贴着一份规则引擎跑，跨出去逐 step 取观测就穿不动**（192 step × 8.5 ms ≈ 1.6 s/决策，附录 D）。
- **(C) 不建议**：a1/a2 要 6~9（+5~8 才治单机）人日，比 (a3) 贵一倍，还要把 `bot` 旁路欠账续期（`docs/archive/口径二_批1_原子切规格.md:301-305` / `:804` 判了批 2 整块删）并继承 `view_for` 的保真度缺口（§1.7(3)）。
⚠ 若仍选 (C)，**必须同时写明**：① 期限；② `bot` 旁路从「批 2 删」改成「过渡期保留」；③ 它在本地单机上要额外起一个 loopback 服务器。
⚠ 若选 (D)，**要接受一条**：(a3) 是止血不是终局 —— 权威侧换成 C# 之后，GD AI 仍然「按 GD 规则想、按 C# 规则走」（`docs/archive/内核替换_迁移计划.md:262-272`）。

### 拍板 4bis · 联机专家档要不要立刻补一个 `max_sim_steps`？（0.5 人日，独立于上面所有条）

- **(A)** 补 `192`（= 本地那条），联机专家档从 381~645 ms 降到 180 ms 量级。
- **(B)** 不补，维持无预算档。

**推荐 (A)。** 理由：`cw_net_bridge.gd:16` 那只 `mc` 从来没设过 `max_sim_steps`，默认 `0 = 无上限`（`monte_carlo_bridge.gd:32`）—— **这不是设计，是漏设**：本地路上 `match.gd:872` 一直有这条闸。它不改架构、不动协议、不动播放形态，是全稿里最便宜的一条。⚠ 代价：联机专家档会变弱一档，要对齐一次「专家档有多强」的说法。

### 拍板 5 · Kevin 那一次「攻击动画不完整」要不要单独止血？

> **前史（必须先摆出来，否则这条会被当场驳回）**：① 「那局没有 AI ⇒ AI 堵帧假说作废」**不是新发现**，`docs/开发日志.md:161` 与 `docs/archive/内核替换_拍板记录.md:315` 早写下了，同处还记着「代码里房主与远端客户端路径逐字相同」；② **诊断已经打过一轮并被叫停** —— fx-diag 补丁 build 202609180001 已上线（`拍板记录:317`）、至今 **0 条 `[fx-diag]`**（`:330`）、Kevin「复现不等了、诊断线不再是发版的顾虑」（`:338`）。

- **(A)** 不单独做，等批 2/3 一起（= 09-19 §八 ② 的现状）。
- **(B)** **换一种量法**：**不是** fx-diag（已打、没跑出数据、Kevin 已叫停），而是在 `cw_room.push_state`（`cw_room.gd:662`，含 `state_hash()` `:665` 单独计时）与 `CWPlayQueue.pump`（`cw_play_queue.gd:38`，记触发快进时的 `batch.size()`，`:50`）各埋一个计数器，约 0.5 人日。

**推荐 (B)。**
**为什么这次拿得到上次拿不到的数**：fx-diag 是**客户端 print**，要 Kevin 装诊断包 → 打一局 → 复现 → 回传日志，四步一步没成。这两个计数器打在**服务器 / 房主侧**，**我们自己的无头联机测试**（`game/tests/net_play.gd` / `net_live.gd`）和任何一局局域网房都会写出来 —— **不依赖 Kevin 复现，也不用再发一版诊断补丁**。
**量什么**：最大嫌疑是每次 ask 的 `push_state` 逐人全量 envelope（6 席+2 观众 **41 ms**，附录 D）与 `hurry_backlog := 24` 的自动快进（`cw_play_queue.gd:28/50`）。半天的计数能省掉一次可能改错地方的返工。
⚠ **另注**：拍板 4bis 那条旋钮（联机 `mc` 补 `max_sim_steps`）**不用等这次测量** —— 它治的是「AI 席堵帧」那一路，与这一局（没有 AI）无关，但对其它有 AI 的联机局是实打实的。

---

## 九、本稿没有回答的

1. **第四档 `CWMCTSValueBridge` 怎么处置？** 它今天是未接线的 23 行（§1.1）。接上 / 删掉 / 随批 2 一起搬，要有人认领。
2. **C# 侧的 AI 性能没有任何本仓证据。** 78 个测试文件里零 Stopwatch；迁移计划 §〇 判定两路实测互相矛盾、「两条都不能用」。**(b) 动手前建议先补一个对照 `bench_mc.gd` 三局面的基准**（P-7）。
3. **权重版本怎么和规则版本绑？** 铁律②明写「要下发权重另立项，且**必须先回答**」这个问题（`docs/archive/内核替换_迁移计划.md:316-320`）。本稿没有答案。
4. **策略若按 softmax 采样，采样的可复现性归谁？** 今天没有任何一份文档写过（§5 表末行）。
5. **GD 侧那 15 个用 AI 桥的平衡 / 测试工具怎么办？**（P-9）搬、改、还是留在 GD 侧对着一个停用的 AI 跑 —— 这笔账本稿只记，没有排。
6. **(a3) 的子进程通信走 stdio 还是本地 TCP，取决于一条本稿没核的引擎 API**：Godot 4.5 的 `OS.create_process` 只回 PID、不给管道，带管道的是 `OS.execute_with_pipe` —— **它在无头导出包上可不可用，要实测**（§3.1bis 硬前置 ③）。本稿倾向本地 TCP（编解码现成、与 sidecar 共用），但没有替这条下结论。
7. **(a3) 起一个短命子进程还是常驻一个 worker 池？** 短命 = 每决策一次进程启动开销（Godot 无头启动量级未量）；常驻 = 要管保活与崩溃重启。**这一条要先量一次 Godot 无头冷启动耗时再定。**

> 已从本节移除的一条：「第三档在真对局里跑不跑得起来」—— 已确认是真 bug（`CWKernelInProc` 漏调 `attach_engine`，崩在 `mcts_bridge.gd:71`），**已随本稿修掉并加了 headless 测试**，详见 §1.7(1)。

---

## 附录 · 出处索引（按文件）

**GD 侧**
`game/scripts/core/cw_bridge.gd:1-18`（10 种 kind；`:5-8` 是清单本体，含「confirm 不是 kind」） · `cw_game.gd:89`（tune 实例）`:366-369`（rng 在快照里 / 0.16 ms）`:371-377`（snapshot 薄壳）`:403-410`（ask 入口） · `cw_state_codec.gd:9-28`（snapshot，**25 键**）`:30-59`（restore）`:25`（rng） · `cw_tuning.gd:34-38`（rules_state） · `cw_settings.gd:14`（ai_delay_ms）
`game/scripts/ai/heuristic_bridge.gd:3-4`（不用随机数）`:36`（AI_VERSION v11）`:59-60`（延迟让帧）`:160`（`_toxin_targets`）`:322-334`（读 rng 状态不消耗）+ §1.2 表内全部行号 · `monte_carlo_bridge.gd:22-23/30-32/50/69-72/77/79/104-127/135-139/143-159/164-165/189-224/231-240/245-252` · `mcts_bridge.gd:12-18/27-28/47/63-66/70-74/92/98-114/119/138/144/161/166/192/271-274` · `mcts_value_bridge.gd:14` · `cw_eval.gd:69-71/73-86/108-109/129-184` · `cw_leaf_value_nn.gd:11-18/24-27`
`game/scripts/ui/match.gd:508-511/550-551/695/804-813/870-891` · `ui_bridge.gd:22-23/167-173/194`
`game/scripts/kernel/cw_kernel.gd:76/189-190` · `cw_kernel_inproc.gd:43/76/89-90/112/131/321-328/330-335/388-389`（`_attach_engine` 在 `:322`） · `cw_kernel_remote.gd:1-9/62` · `cw_kernel_sidecar.gd:3/22` · `cw_play_queue.gd:12/28/38/50/52-57/113-118`
`game/scripts/net/cw_net.gd:5-6/12-13/191/249/267/301/317-330` · `cw_net_bridge.gd:14-16/19-31` · `cw_net_client.gd:5/43/94-96/314-338` · `cw_net_server.gd:9-12/42/71-72/80-83` · `cw_room.gd:378-399/662-705`
`game/scripts/ui/online_panel.gd:218/390` · `game/server/server_main.gd:59-61` · `server/run.sh`
`game/tests/bench_mc.gd` · `balance_scan.gd:1-30` · `collect_eval_data.gd:1-24` · `ai_baseline_case.gd:7-8/13-21/28-45` · `headless_test.gd:160/4343-4387/4600/4604/4621/6545/8198/15731/20492-20508` · `game/tests/baseline/ai_same_hash.json`

**C# 侧**
`core/CellWar.Core/Runtime.cs:18-19/44-49/84-95/179-188` · `MatchSession.cs:22-27/122-136/143-297` · `ISession.cs:5-22` · `IRulesEngine.cs:28-31` · `BasicRulesEngine.cs:8-36` · `IRuntime.cs:62-68` · `InMemoryStateStore.cs:92` · `RulePolicies.cs:16/496/515/556-575/585-612` · `BoardRules.cs:11/259-294/369-383` · `CellRules.cs:365` · `DecisionRouter.cs:10/182-373` · `RuleHandlers.cs:55-61` · `SemanticKey.cs:1-31` · `CheckpointCodec.cs:104` · `Observation/ObservationV1.cs:15/28/45/60` · `Observation/ObservationV1Codec.cs:18-19` · `Observation/SeatFilter.cs:18-27` · `CellWar.Core.csproj:10`

**文档**
`docs/archive/内核替换_拍板记录.md:14`（十条拍板表）`:21`（决策 7「重写成 C#，后续接神经网络模型」）`:167-169`（浮点收窄的第 3 条理由）`:189/:194`（§四 体量）`:211`（§五 #4 rng）`:295`（§八 标题 = 2026-09-19）`:313`（专家档 381~645 ms / state 3.3 KB / restore 0.25 ms）`:315`（播放形态 2 + **那一局没有 AI**）`:317`（fx-diag 补丁 202609180001 已打）`:328/:330`（发版挂起 / **0 条 [fx-diag]**）`:333/:336`（§九 启发式 v4 不重要）`:338`（**Kevin 叫停 fx-diag**）
`docs/archive/内核替换_迁移计划.md:45-48`（§〇 性能两路矛盾）`:86`（**CWMirror 25 键 / 不收 flow·pending·tune**）`:95/:100`（§二 批次图）`:114-115`（两笔省）`:132`（ai 84 站点）`:189`（C# 侧 AI 0 行）`:198-199`（可以先不动的两条）`:240-241`（网页 AI 在服务器）`:262-272`（§五 L2 不可能）`:277/:278`（§六 09-18 全部拍完 + 第 6 条「进（已拍过）」）`:294-295`（第 6 条 `CellWar.Ai` 进热更载荷 **已拍板：进**）`:316-324`（三条铁律 + 顺序）`:328-336`（§七 退役准入）`:404-413`（§八 工期口径，**33~70 = 全工程下界**，与本稿 §3.2 冲突）
`docs/archive/口径二_批0_底座规格.md` A-3.3（`fork_for_rollout` 占槽 / 硬不变量②）、A-3.5 + `:452`（sidecar stub / 硬纪律）、`:691`（**待拍第 7 条：本地 AI 归 GDScript 还是进 sidecar；它决定 GD 内核能不能退役**）
`docs/archive/口径二_批1_原子切规格.md:46`（ai 零改动）`:301-305`/`:804`（bot 旁路批 2 删）`:374-389`（A-5.3 attach_engine）`:559`/`:680`（t_ai_same_hash）`:706`（结构闸白名单）`:756-766`（E-2 拍板 a）
`docs/观测协议_v1.md:37`（viewer 字段注释「-2 全知（禁止过网）」）、§5.3（四条查询式）、**§七 `:297-309`（三档裁剪；`:303` 全知档「过网？」= ✘ 禁止；`:309` InProc 默认 -2）**、§九（版本纪律）、附录 C（sidecar 线协议 / op 清单 / 没有 rng）、附录 D（体积与耗时实测）
`docs/网页导出.md:48`（**`thread_support=false` 的稳定出处**）`:73`
`docs/架构说明书.md:143-165/241/340-372/409-421` · `docs/RL策略架构设计.md:1-40`（§1~§2）、§3、§5.1-5.3、§7、§7.1-7.2 · `docs/archive/架构审查_2026-09-02.md:68`
`docs/开发日志.md:86`（Kevin「大概率是线程阻塞」）`:161`（**那局没有 AI，堵帧假说作废**）`:170`（专家档 381~645 ms）`:435`（09-18 拍板六条，第 6 条 `CellWar.Ai` 进热更载荷）`:2186`（服务器处处假定单线程）`:8630`（AI 堵死服务器 8 秒）`:11298`（单决策 135 ms / 2 人整局 3.4 s）`:13421`（`thread_support=false`）`:13434`（无线程构建上会永远等下去）

---

> **行号口径**：`docs/开发日志.md` 随新条目**前置追加**，已有内容会整体下移 —— **引用前先 grep 关键词，不要照抄任何一份旧稿的行号**（本稿第一版对该文件的六处引用全部偏移 +8，无一命中；`thread_support` 这类更稳的出处优先引 `docs/网页导出.md`）。**本稿行号核于 2026-09-19，HEAD `bfe41d4`。**
