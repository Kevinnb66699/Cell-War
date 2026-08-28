# 重构 API 设计（目标形态）

> 本文件定义 Cell-War 完成 Elm 化重构后，逻辑层对外留下的 API 契约。
> 与 `docs/架构说明书.md`（目标架构总纲）配套，本文档只描述**接口形态**，不含实现。
> 2026-08-28 与用户逐项核对确认；原型 `game/scripts/elm/` 已验证该形态可行。

---

## 0. 形态一句话

**状态机被动、外界推动、纯函数、不可变、rng 进 state、演出不阻塞。**

- 逻辑 = `Game.update(state, msg)` 纯函数（无 await、无 rng、无桥）。
- 外壳 = 推动者 + effect 路由（唯一接触外部）。
- 状态机**不自走**：它停在某个 state（可能恰好呈现一个 ask = `pending`），由外界发 msg 推动才变。

---

## 1. GameState（不可变，单一来源）

```gdscript
## state: Dictionary = {
##   "pc": String,          # 阶段：SETUP_PLACE / TURN_ACTION / WORLD / DONE ...
##   "rng_state": int,      # 随机源进 state；掷骰 = 纯函数消耗它，不经过桥
##   "turn": int, "players": Array, "tiles": Dictionary, "cells": Array,
##   "pending": Dictionary | null,  # 当前 ask（kind+pid+options）；null=没在问
##   "logs": Array,
## }
## 不变性：update 永远返回新 state（旧 state 不动）；外壳维护事件链（chain）。
```

- 棋盘坐标**单一来源 `CWData`** 不变。
- 差分/事件链是**内部优化**（先全量拷贝跑通等价、后优化），不改变本签名。
- `state_hash()` 纳入 `rng_state`，锁步联机校验闭环。

---

## 2. Msg（外界推动状态机变动的唯一输入）

```gdscript
## { "kind": "step" }                  # 外界请求推进内部环节
## { "kind": "decision", "idx": int }  # 外界回答当前 pending（7 种 kind 之一）
## 没有别的 msg。演出回执、UI 事件都不是 msg（逻辑不等它们）。
```

- **ask 不是 msg**，也不是状态机等待的对象。ask 是 state 当前呈现的需求（`pending`）；
  `decision`（外界对它的回答）才是推动 state 变动的 msg。

---

## 3. Effect（状态机产出，不阻塞）

```gdscript
## { "kind": "ask", "req": {...} }        # 需要外界决策（req.options 给桥/UI）
## { "kind": "roll_show", "value", "sides", "at", ... }  # 掷骰演出通知，逻辑不等
## { "kind": "log", "text" }
```

---

## 4. 中央 Updater（唯一入口，纯函数）

```gdscript
## static func update(state: Dictionary, msg: Dictionary) -> Dictionary:
##     # 返回 { "state": 新state, "effects": Array }
##     # msg.kind == "step"     -> 内部推进到下一个 ask 或 DONE
##     # msg.kind == "decision" -> 应用 pending 答案 + 推进到下一个 ask/DONE
##     # 停在 ask 时不走（要靠外界再发 decision）——状态机不自走
```

---

## 5. 子 Updater（纯函数，父 update 的处理环节，不被外壳单独驱动）

```gdscript
## SetupUpdater    .advance(state, effects)          # SETUP_PLACE：产出落子 ask
##                 .apply_place(state, idx, effects) # decision 路由
## TurnUpdater     .advance(state, effects)          # TURN_ACTION：产出 action ask
## ActionsUpdater  .apply_action(state, idx, effects)        # 选动作：可能再问
##                 .apply_attack_target(state, idx, effects)
##                 .apply_differentiate(state, idx, effects)
##                 .apply_remodel_target(state, idx, effects)
##                 .apply_confirm(state, idx, effects)
## WorldUpdater    .advance(state, effects)          # 回合推进（侵蚀/增生/复活，用 rng）
##                 .apply_revive(state, idx, effects)
## 签名统一：(state, ...) -> void（改传入的副本），由父 update 编排。
```

---

## 6. 决策点（8 个决策点 / 7 种 ask kind）

当前代码里 `game.ask()` 调用点共 8 处，其中 `confirm` 是**单一 kind**、靠 `tag` 区分两个决策点。**保持现状（确认定案）**：

| # | 决策点 | kind | tag | 决策点（现文件位置） | decision 响应 |
|---|---|---|---|---|---|
| 1 | setup_place | `setup_place` | — | cw_setup:136 | 落子 |
| 2 | action | `action` | — | cw_turn:32 | 选动作 |
| 3 | attack_target | `attack_target` | — | cw_actions:138 | 选攻击目标 |
| 4 | differentiate | `differentiate` | — | cw_actions:227 | 选分化方向 |
| 5 | confirm(净化) | `confirm` | `lyse_purge` | cw_actions:301 | 确认裂解/清除 |
| 6 | confirm(再突变) | `confirm` | `remutate` | cw_actions:322 | 确认再突变 |
| 7 | remodel_target | `remodel_target` | — | cw_actions:402 | 选改造目标 |
| 8 | revive | `revive` | — | cw_world:118 | 免疫复活落点 |

```gdscript
## pending = { "kind": String, "tag": String | null, "pid": int, "options": Array }
## decision(idx) 按 kind 路由到子 Updater；kind=="confirm" 时再按 tag 细分。
```

---

## 7. 外壳 Shell（唯一接触外部：推动者 + effect 路由）

```gdscript
## class GameShell:
##     func run(seed, players) -> { "state", "chain": [state...], "effects" }
##         loop:
##             if state.pending != null:   # 停在 ask
##                 idx = bridge.ask(state.pending 的 req)   # 桥要带决策上下文
##                 msg = { kind:"decision", idx }
##             else:                        # 内部环节
##                 msg = { kind:"step" }
##             r = Game.update(state, msg); state = r.state; chain.append(state)
##             路由 r.effects: roll_show -> bridge.show_roll(...)（不等）/ UI 队列
##                            log -> 日志
```

---

## 8. 桥（原 CWBridge，接口保留、调用点上移、不再 await）

```gdscript
## class CWGameBridge extends RefCounted:    # 形态保留（可插拔/可缺失）
##     func ask(req: Dictionary) -> int      # 从 req.options 选下标
##     func show_roll(value: int, sides: int, at) -> void   # 演出通知，不等
## 差异：show_roll 从「await 播完才继续」变成「通知即返」（推翻约定 #11）。
## AI 桥不再穿透读 game.xxx；req 携带决策所需上下文（options + 必要棋盘/细胞信息）。
```

---

## 9. 现 core → 目标形态映射

```
## cw_game.gd   -> Game（中央 update/_advance/_apply_decision）+ GameState
##                  rng 属性移入 state；bridges 移给 shell；所有 await 消失
## cw_setup.gd  -> SetupUpdater（setup_place）
## cw_turn.gd   -> TurnUpdater（action + 回合流转）
## cw_actions.gd-> ActionsUpdater（攻击/分化/改造/确认）
## cw_world.gd  -> WorldUpdater（回合推进 + 复活；rng 纯函数）
## cw_bridge.gd -> 桥接口保留（ask/show_roll），调用点从 core 上移到 shell
## 棋盘坐标单一来源 CWData 不变；CWGame 保留实例壳（初始化、暴露 state 快照给 AI），
## 但内部不再是可变状态拥有者。state_hash() 纳入 rng_state（锁步联机校验闭环）。
```

---

## 10. 验证状态

- 原型 `game/scripts/elm/`（elm_core / elm_shell / elm_proto）已跑通：
  不可变 + 纯函数 update、rng 进 state 确定性、状态链/分叉隔离、
  msg 驱动（验证7：停在 ask 发 step 不变）、演出不阻塞。
- 已定案：msg = `{step, decision(idx)}`；ask 不是 msg；confirm 保持单 kind + tag。
- 未决：差分粒度——铺开时**先全量拷贝跑通行为等价、后优化成差分/事件链**。
