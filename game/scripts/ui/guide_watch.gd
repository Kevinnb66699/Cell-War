## guide_watch.gd —— 教程步骤的「完成判据」：**真实局面**满足了就自动翻页。
##
## 引导剧本每一步可以带三个字段：`flag` 高亮什么、`act` 提示做什么（「继续」有时能代做）、
## `watch` **做到了没有**。前两个早就有表可查（`CWGuideSpotlight.FLAGS` / `CWGuideBridge.STEP_HINTS`），
## 只有 `watch` 一直是写死在 `CWGuide.check_progress` 里的两支 `match`（placed / moved）——
## 于是「让玩家真做一次」这件事，出了迁移就没法要求（2026-09-13 通读剧本：
## 41 步里带动作的 7 步全挤在前 8 关，第 9 关往后一次手都不用动）。
## 这个文件把判据摊成一张表：**加一条判据 = KEYS 里写一行 + done() 里加一支**，别处不用动。
##
## **为什么单开一个文件、还不给 `class_name`**：
## ① 判据是纯逻辑（两张快照比一比），单独放才测得动 —— 不必起一整局；
## ② **补丁里新增的 `class_name` 认不出来**（全局类表在导出时烘死，见架构说明书热更那节），
##    而引导面板正是天天在改的东西。没有 class_name、调用方 `preload`，就能走热更。
##
## 用法：步骤成为当前的那一刻拍一张 `snapshot()` 当基线，之后每帧拿新快照调 `done()`。
##
## ⚠ **计数类判据只在同一个行动回合里有效**（`attacked` / `drew`：引擎每个行动回合把
## `attacks_used` / `draws_used` 清零）。所以基线里记了「这是谁的第几回合」，
## `same_turn()` 为假时调用方应当**重新取基线**，否则拿跨回合的旧数去比，
## 判据要么永远不成立、要么当场误判成立。
extends RefCounted

## 没有人类席位 / 细胞还没上场（同 `CWBoard.NO_TILE` 的哨兵约定）
const NONE := Vector2i(9999, 9999)

## 支持的判据：键 → 一句话说明（护栏拿它核剧本，说明也是给写剧本的人看的）
const KEYS := {
	"placed": "细胞已经上场（开局落子）",
	"moved": "位置变了 —— 迁移过一次",
	"purified": "抗原记忆涨了 —— **亲手**净化过一格（卡牌引发的净化不给记忆，正好只认亲手那次）",
	"attacked": "本行动回合攻击次数涨了",
	"drew": "手牌多了一张 —— 抽过一次卡",
	"played": "打出或装备过一张卡（`play_n` 涨）",
	"differentiated": "分化过",
	"leveled": "免疫等级涨了",
	"ended": "换人或换回合了 —— 结束过一次行动回合",
	"round": "世界回合前进了",
}


## 把此刻的局面拍成一张小快照。**只读**，不碰引擎任何状态。
## `pid` 是屏幕前这位真人的席位；没有席位 / 细胞不在场时位置是 NONE，其余为 0。
static func snapshot(game: CWGame, pid: int) -> Dictionary:
	var snap := { "pos": NONE, "hand": 0, "play_n": 0, "diff": false, "attacks": 0,
		"draws": 0, "memory": 0, "level": 0, "round": 0, "actor": -1 }
	if game == null:
		return snap
	snap["memory"] = int(game.memory)
	snap["level"] = int(game.immune_level)
	snap["round"] = int(game.round_no)
	snap["actor"] = int(game.current_pid)
	for c in game.cells:
		if int(c["pid"]) == pid and bool(c["alive"]):
			snap["pos"] = Vector2i(c["pos"])
			snap["hand"] = int((c["hand"] as Array).size())
			snap["play_n"] = int(c["play_n"])
			snap["diff"] = bool(c["differentiated"])
			snap["attacks"] = int(c["attacks_used"])
			snap["draws"] = int(c["draws_used"])
			break
	return snap


## 两张快照是不是同一个行动回合拍的。计数类判据只在回合内可比（引擎每回合清零）
static func same_turn(base: Dictionary, now: Dictionary) -> bool:
	return int(base.get("round", -1)) == int(now.get("round", -2)) \
		and int(base.get("actor", -1)) == int(now.get("actor", -2))


## 这一步做到了没有。`base` 是步骤开始那一刻的快照，`now` 是此刻的。
## 不认识的键一律 false —— 剧本写错键不该让教程「自己翻过去」，护栏会当场报出来。
static func done(key: String, base: Dictionary, now: Dictionary) -> bool:
	match key:
		"placed":
			return now.get("pos", NONE) != NONE
		"moved":
			var was: Vector2i = base.get("pos", NONE)
			var at: Vector2i = now.get("pos", NONE)
			return at != NONE and was != NONE and at != was
		"purified":
			return int(now.get("memory", 0)) > int(base.get("memory", 0))
		"attacked":
			return int(now.get("attacks", 0)) > int(base.get("attacks", 0))
		"drew":
			return int(now.get("hand", 0)) > int(base.get("hand", 0))
		"played":
			return int(now.get("play_n", 0)) > int(base.get("play_n", 0))
		"differentiated":
			return bool(now.get("diff", false)) and not bool(base.get("diff", false))
		"leveled":
			return int(now.get("level", 0)) > int(base.get("level", 0))
		"ended":
			## 换人或换回合都算「这一回合过去了」——「结束回合」按下之后，
			## 下一个轮到的可能是别人（换 actor），也可能直接进了下一个世界回合
			return not same_turn(base, now)
		"round":
			return int(now.get("round", 0)) > int(base.get("round", 0))
	return false
