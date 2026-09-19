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
	"attacked": "本行动回合攻击次数涨了（带参数 `attacked:N` = 涨满 N 次，S5b）",
	"drew": "手牌多了一张 —— 抽过一次卡",
	"played": "打出或装备过一张卡（`play_n` 涨）",
	"differentiated": "分化过",
	"leveled": "免疫等级涨了",
	"ended": "换人或换回合了 —— 结束过一次行动回合",
	"round": "世界回合前进了",
	## 下面两条是**状态谓词**（只看此刻，不看基线），同 `placed` 的那一类。S5 补，第三关要它们：
	"beside": "站到了敌方细胞的相邻格（PRD:247 第三关 Step1「迁移到癌细胞相邻格」）",
	"stuck": "能量不足以移动 —— 正问着这一席，可这一问里一个【迁移】选项都没有（PRD:251 第三关的自动重置）",
	## 带参数的那一条（S5b）：`low_energy_beside:<十分能量>`
	"low_energy_beside": "站到了敌方细胞的相邻格，可剩下的能量**少于参数**（PRD:251 第二条：所剩能量小于预期）",
}


## 把此刻的局面拍成一张小快照。**只读**：批 1 起读的是观测镜像（CWMirror），够不着引擎。
## `pid` 是屏幕前这位真人的席位；没有席位 / 细胞不在场时位置是 NONE，其余为 0。
##
## 末四个键（`beside` / `asked` / `can_move` / `energy`）服务三条**状态谓词**，它们只看此刻的这一张：
## `can_move` 的默认是 **true**（「没在问 = 谈不上走不动」），别改成 false —— `stuck` 会当场把关卡重置掉。
static func snapshot(m: CWMirror, pid: int) -> Dictionary:
	var snap := { "pos": NONE, "hand": 0, "play_n": 0, "diff": false, "attacks": 0,
		"draws": 0, "memory": 0, "level": 0, "round": 0, "actor": -1,
		"beside": false, "asked": false, "can_move": true, "energy": 0 }
	if m == null:
		return snap
	snap["memory"] = int(m.memory)
	snap["level"] = int(m.immune_level)
	snap["round"] = int(m.round_no)
	snap["actor"] = int(m.current_pid)
	var me := {}
	for c in m.cells:
		if int(c["pid"]) == pid and bool(c["alive"]):
			snap["pos"] = Vector2i(c["pos"])
			snap["hand"] = int((c["hand"] as Array).size())
			snap["play_n"] = int(c["play_n"])
			snap["diff"] = bool(c["differentiated"])
			snap["attacks"] = int(c["attacks_used"])
			snap["draws"] = int(c["draws_used"])
			snap["energy"] = int(c["energy"])
			me = c
			break
	## 相邻格上有活着的敌方细胞吗（按**阵营**比，不按席位：教程里敌方只有一只，正式局也讲得通）
	if not me.is_empty():
		var ring: Array = CWData.neighbors(Vector2i(me["pos"]))
		for c in m.cells:
			if bool(c["alive"]) and int(c["faction"]) != int(me["faction"]) and Vector2i(c["pos"]) in ring:
				snap["beside"] = true
				break
	## 「走不动了」只在**正问着这一席的顶层行动问**里谈得上：引擎的选项表已经把付不起的迁移滤掉了
	## （`cw_actions.immune_move_options` 的 `can_pay` 那一行），所以「表里一条 act=move 都没有」
	## 就是「能量不足以移动」。这里不自己算价钱 —— 算价钱要读旋钮，而 `CWMirror.tune` 只有 9 个键。
	if not m.ask.is_empty() and str(m.ask.get("kind", "")) == "action" and int(m.ask.get("seat", -1)) == pid:
		snap["asked"] = true
		snap["can_move"] = false
		for o in m.ask.get("options", []):
			if str(((o as Dictionary).get("data", {}) as Dictionary).get("act", "")) == "move":
				snap["can_move"] = true
				break
	return snap


## 两张快照是不是同一个行动回合拍的。计数类判据只在回合内可比（引擎每回合清零）
static func same_turn(base: Dictionary, now: Dictionary) -> bool:
	return int(base.get("round", -1)) == int(now.get("round", -2)) \
		and int(base.get("actor", -1)) == int(now.get("actor", -2))


## `键:参数` 里的那个整数。没写 / 写歪了退回缺省 —— 缺省一律取**更难成立**的那一边，
## 剧本漏写参数只会让这一步等不到，不会把关卡自己翻过去或掀了（S5b）
static func _arg(text: String, dflt: int) -> int:
	return int(text) if text.is_valid_int() else dflt


## 这一步做到了没有。`base` 是步骤开始那一刻的快照，`now` 是此刻的。
## 不认识的键一律 false —— 剧本写错键不该让教程「自己翻过去」，护栏会当场报出来。
##
## **带参数的判据写成 `键:参数`**（S5b）：`cw_tutorial_data._check_steps` 查表时一直只看冒号前
## 那一截，这里才是真解析参数的地方。今天两条用它：`attacked:N`（涨满 N 次，PRD:275
## 「玩家前两次攻击」）与 `low_energy_beside:<十分能量>`（PRD:251 第二条）。
static func done(key: String, base: Dictionary, now: Dictionary) -> bool:
	var cut := key.split(":", true, 1)
	var arg: String = cut[1] if cut.size() > 1 else ""
	match cut[0]:
		"placed":
			return now.get("pos", NONE) != NONE
		"moved":
			var was: Vector2i = base.get("pos", NONE)
			var at: Vector2i = now.get("pos", NONE)
			return at != NONE and was != NONE and at != was
		"purified":
			return int(now.get("memory", 0)) > int(base.get("memory", 0))
		"attacked":
			## 缺省「比基线多打一次」；`attacked:N` = 这一行动回合里**多打满 N 次**才算
			return int(now.get("attacks", 0)) - int(base.get("attacks", 0)) >= _arg(arg, 1)
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
		"beside":
			## 状态谓词：基线是什么样不管（同 placed）。第三关 Step1 就是「站过去」这一件事
			return bool(now.get("beside", false))
		"stuck":
			return bool(now.get("asked", false)) and not bool(now.get("can_move", true))
		"low_energy_beside":
			## 状态谓词 + 参数（PRD:251 第二条）：站到了敌方相邻格，可剩下的能量**不够把它打死**。
			## 参数是十分能量（纪律 3），由剧本写死 —— 这里不自己算「三次攻击要多少」：
			## 算它要读 `immune_move_cancerous` 这类分档旋钮，而 `CWMirror.tune` 只有 9 个键（同 `stuck`）
			return bool(now.get("beside", false)) and int(now.get("energy", 0)) < _arg(arg, 0)
	return false
