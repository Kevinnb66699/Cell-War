## cw_tutor_beats.gd —— `cwtut/2` 的**条目文法**：九个动词表 + 三类谓词表 + `allow` 前缀匹配
## （docs/新手引导v2_实现方案.md §2.6 / §3.3，S1，2026-09-19）
##
## **纯函数、零引擎、零节点**：这里只认「数据长什么样、判据成不成立」，一个 `CWGame` 都不碰，
## 所以 `t_tutor_beats` 起不起局都能测（毫秒级）。导演与校验器共读这一份，加一条判据 =
## 表里写一行 + `done()` 里加一支，别处不用动。
##
## **不带 class_name，调用方 preload**（方案 §1.5）：台词 / 顺序 / 谓词是天天在改的东西，
## 补丁里新增的 `class_name` 进不了热更。
##
## 两条从老 `guide_watch.gd` 原样照抄的教训（机制照抄、代码不留）：
## ① **计数类谓词只在同一个行动回合内有效** —— 引擎每个行动回合把 `attacks_used` / `draws_used`
##    清零，所以基线里记了「这是谁的第几回合」，`same_turn()` 为假时调用方要重新取基线；
## ② **默认值一律取更保守的那一边** —— `can_move` 默认 `true`（「没在问 = 谈不上走不动」）、
##    `foes` 默认 `1`（「不知道 = 还有敌人」）。反过来写，关卡会在「还没有镜像」那一瞬间
##    被自动重置掉 / 被直接翻过去。
extends RefCounted

## 没有人类席位 / 细胞还没上场（同 `CWBoard.NO_TILE` 的哨兵约定）
const NONE := Vector2i(9999, 9999)

## 九个动词（方案 §2.6）。**不允许第十个**：新需求先问「能不能写成 `play` 的一支 fx」，
## 再问「能不能进钩子」。`blocking` = 这一条没跑完导演不翻页。
## `keys` 是这一条**额外**许可的字段；通用字段 `do` / `step` / `prd` 每条都许。
const VERBS := {
	"state":  { "blocking": false, "keys": ["load", "ui", "reveal", "npc"] },
	"say":    { "blocking": true,  "keys": ["who", "lines", "beats", "auto", "at"] },
	"point":  { "blocking": false, "keys": ["ui", "hex", "mode", "tip"] },
	"unlock": { "blocking": false, "keys": ["ids"] },
	"play":   { "blocking": true,  "keys": ["fx", "at", "secs", "args", "seed", "await"] },
	"wait":   { "blocking": true,  "keys": ["secs"] },
	"player": { "blocking": true,  "keys": ["allow", "until", "hint", "hex", "ui",
		"reset_when", "advise_when", "advise"] },
	"npc":    { "blocking": false, "keys": ["seat", "plan"] },
	"hook":   { "blocking": true,  "keys": ["call", "args"] },
}
## 每条都许的通用字段
const COMMON_KEYS := ["do", "step", "prd"]

## `point.mode` 三档（方案 §5.1）。`soft` = PRD 通用规则 8 的「较慢频次反差较低的轻微闪烁」
const POINT_MODES := ["soft", "arrow", "fullscreen"]

## `say.who` 四档（PRD:23 / :407 / :397 / :447）。`seat:<n>` 与 `ui:<控件 id>` 带参数，比前缀
const WHO_PLAIN := ["player", "narrator"]
const WHO_PREFIX := ["seat:", "ui:"]

## `state.ui.camera` 的两个枚举（PRD 04:08 版给关卡模板加的「镜头变化」，PRD:9-22）：
##   `地图调中/左/右` ⇒ anchor = "map"，`玩家调中/左/右` ⇒ anchor = "player"
## 缺省是「地图调中」（PRD「默认情况下调整后竖直方向地图/角色是居中的」）。
## 和 `POINT_MODES` 一样住在这张表里：**校验器与常驻层表读的是同一份**，两处各抄一份必漂
const CAMERA_ANCHORS := ["map", "player"]
const CAMERA_ALIGNS := ["center", "left", "right"]
const CAMERA_DEFAULT := { "anchor": "map", "align": "center" }

## ---- 三类谓词（方案 §3.3）----
## ① 差分：条目入口拍一张 `snap()`，每帧与现在比。`count` 可选（缺省 1）
const DELTA := {
	"moved": "位置变了 —— 迁移过一次",
	"purified": "抗原记忆涨了 —— **亲手**净化过一格（卡牌引发的净化不给记忆，正好只认亲手那次）",
	"attacked": "本行动回合攻击次数涨了（`count` 给几次）",
	"drew": "手牌多了一张 —— 抽过一次卡",
	"played": "打出或装备过一张卡",
	"differentiated": "分化过",
	"leveled": "免疫等级涨了",
	"ended": "换人或换回合了 —— 结束过一次行动回合",
	"round": "世界回合前进了",
}
## ② 状态：只看此刻，不看基线（重置过也算数）。`arg` 可选
const STATE = {
	"beside": "站到了敌方细胞的相邻格",
	"all_dead": "敌方细胞一只不剩",
	"stuck": "能量不足以移动 —— 正问着这一席，可这一问里一个【迁移】选项都没有",
	"level_at_least": "免疫等级到了 `arg` 那一档（写罗马字，如 \"III\"）",
	"low_energy_beside": "站到了相邻格，可剩下的能量**少于** `arg`（十分位整数）",
	"tile_healthy": "`arg` 那一格是健康组织（arg 写 \"q,r\"）",
	"cell_at": "`arg` = [席位, \"q,r\"]：那一席的活细胞站在那一格",
}
## ③ 条目流：导演在 `queue.on_step` / `on_log` 旁路上认（只留给状态量表达不出来的事）
const ENTRY_PLAIN := ["e_done"]
const ENTRY_PREFIX := ["roll:", "fx:", "skill:"]


# =====================================================================
# 文法
# =====================================================================

static func is_verb(v: String) -> bool:
	return VERBS.has(v)


## 这一条跑完之前导演不翻页吗
static func is_blocking(row: Dictionary) -> bool:
	var v := str(row.get("do", ""))
	return bool((VERBS.get(v, {}) as Dictionary).get("blocking", false))


## 这一条许哪些键（通用四个 + 动词自己的）
static func keys_of(verb: String) -> Array:
	var out: Array = COMMON_KEYS.duplicate()
	out.append_array((VERBS.get(verb, {}) as Dictionary).get("keys", []))
	return out


## 条目里有没有表外的键。返回不认识的那几个（空 = 干净）
static func bad_keys(row: Dictionary) -> Array:
	var ok := keys_of(str(row.get("do", "")))
	var out: Array = []
	for k in row.keys():
		if not (str(k) in ok):
			out.append(str(k))
	return out


## `allow` 的匹配：语义键 `k=<kind>[|g=<tag>]|<field>=<v>|…` 的**前缀**匹配。
## 文法与 C# 的 `SemanticKey.cs` 逐字相同；选项在观测协议里已经带好键（`cw_obs_codec.gd`）
static func hits(key: String, allow: Array) -> bool:
	for a in allow:
		if key.begins_with(str(a)):
			return true
	return false


## 谓词是哪一类：`"delta"` / `"state"` / `"entry"` / `""`（写歪了）
static func pred_kind(pred: Dictionary) -> String:
	if pred.has("delta") and DELTA.has(str(pred["delta"])):
		return "delta"
	if pred.has("state") and STATE.has(str(pred["state"])):
		return "state"
	if pred.has("entry") and _entry_ok(str(pred["entry"])):
		return "entry"
	return ""


static func _entry_ok(e: String) -> bool:
	if e in ENTRY_PLAIN:
		return true
	for p in ENTRY_PREFIX:
		if e.begins_with(p):
			return true
	return false


static func who_ok(who: String) -> bool:
	if who in WHO_PLAIN:
		return true
	for p in WHO_PREFIX:
		if who.begins_with(p) and who.length() > p.length():
			return true
	return false


# =====================================================================
# 判据
# =====================================================================

## 把此刻的局面拍成一张小快照。**只读**：读的是观测镜像（CWMirror），够不着引擎。
## `pid` 是屏幕前这位真人的席位；没有席位 / 细胞不在场时位置是 NONE，其余为 0
static func snap(m: CWMirror, pid: int) -> Dictionary:
	var s := { "pos": NONE, "hand": 0, "play_n": 0, "diff": false, "attacks": 0,
		"draws": 0, "memory": 0, "level": 0, "round": 0, "actor": -1,
		"beside": false, "asked": false, "can_move": true, "energy": 0, "foes": 1 }
	if m == null:
		return s
	s["memory"] = int(m.memory)
	s["level"] = int(m.immune_level)
	s["round"] = int(m.round_no)
	s["actor"] = int(m.current_pid)
	var me := {}
	for c in m.cells:
		if int(c["pid"]) == pid and bool(c["alive"]):
			s["pos"] = Vector2i(c["pos"])
			s["hand"] = int((c["hand"] as Array).size())
			s["play_n"] = int(c["play_n"])
			s["diff"] = bool(c["differentiated"])
			s["attacks"] = int(c["attacks_used"])
			s["draws"] = int(c["draws_used"])
			s["energy"] = int(c["energy"])
			me = c
			break
	## 相邻格上有活着的敌方细胞吗（按**阵营**比，不按席位）。同一趟顺手数一下场上还活着几只敌方
	if not me.is_empty():
		var ring: Array = CWData.neighbors(Vector2i(me["pos"]))
		var foes := 0
		for c in m.cells:
			if not bool(c["alive"]) or int(c["faction"]) == int(me["faction"]):
				continue
			foes += 1
			if Vector2i(c["pos"]) in ring:
				s["beside"] = true
		s["foes"] = foes
	## 「走不动了」只在**正问着这一席的顶层行动问**里谈得上：引擎的选项表已经把付不起的迁移滤掉了
	## （`cw_actions.immune_move_options` 的 `can_pay` 那一行）。这里不自己算价钱 ——
	## 算价钱要读旋钮，而 `CWMirror.tune` 只有九个键
	if not m.ask.is_empty() and str(m.ask.get("kind", "")) == "action" and int(m.ask.get("seat", -1)) == pid:
		s["asked"] = true
		s["can_move"] = false
		for o in m.ask.get("options", []):
			if str(((o as Dictionary).get("data", {}) as Dictionary).get("act", "")) == "move":
				s["can_move"] = true
				break
	return s


## 两张快照是不是同一个行动回合拍的。计数类判据只在回合内可比（引擎每回合清零）
static func same_turn(base: Dictionary, now: Dictionary) -> bool:
	return int(base.get("round", -1)) == int(now.get("round", -2)) \
		and int(base.get("actor", -1)) == int(now.get("actor", -2))


## 判据成立了吗。`base` 是条目入口那张快照，`now` 是此刻这张；`m` 只给状态谓词查盘面用。
## **写歪的谓词一律返回 false**（缺省取更难成立的那一边：剧本漏写参数只会让这一步等不到，
## 不会把关卡自己翻过去或掀了）
static func done(pred: Dictionary, base: Dictionary, now: Dictionary, m: CWMirror = null) -> bool:
	match pred_kind(pred):
		"delta":
			return _delta_done(str(pred["delta"]), int(pred.get("count", 1)), base, now)
		"state":
			return _state_done(str(pred["state"]), pred.get("arg", null), now, m)
		_:
			return false


static func _delta_done(k: String, count: int, base: Dictionary, now: Dictionary) -> bool:
	match k:
		"moved":
			return Vector2i(now["pos"]) != NONE and Vector2i(now["pos"]) != Vector2i(base["pos"])
		"purified":
			return int(now["memory"]) - int(base["memory"]) >= maxi(count, 1)
		"attacked":
			## 计数类：跨回合基线作废（引擎每个行动回合清零），调用方该重新取基线
			return same_turn(base, now) and int(now["attacks"]) - int(base["attacks"]) >= maxi(count, 1)
		"drew":
			return same_turn(base, now) and int(now["draws"]) - int(base["draws"]) >= maxi(count, 1)
		"played":
			return int(now["play_n"]) - int(base["play_n"]) >= maxi(count, 1)
		"differentiated":
			return bool(now["diff"]) and not bool(base["diff"])
		"leveled":
			return int(now["level"]) > int(base["level"])
		"ended":
			return int(now["actor"]) != int(base["actor"]) or int(now["round"]) != int(base["round"])
		"round":
			return int(now["round"]) - int(base["round"]) >= maxi(count, 1)
	return false


static func _state_done(k: String, arg: Variant, now: Dictionary, m: CWMirror) -> bool:
	match k:
		"beside":
			return bool(now["beside"])
		"all_dead":
			return int(now["foes"]) == 0
		"stuck":
			## **必须正问着这一席**才谈得上走不动（`can_move` 默认 true，见文件头②）
			return bool(now["asked"]) and not bool(now["can_move"])
		"level_at_least":
			var want := _level_arg(arg)
			return want >= 0 and int(now["level"]) >= want
		"low_energy_beside":
			return bool(now["beside"]) and int(now["energy"]) < int(arg if arg != null else 0)
		"tile_healthy":
			if m == null:
				return false
			var at := _at_arg(arg)
			return at != NONE and int(m.tile(at).get("state", -1)) == CWData.Tissue.HEALTHY
		"cell_at":
			if m == null or not (arg is Array) or (arg as Array).size() != 2:
				return false
			var seat := int((arg as Array)[0])
			var at2 := _at_arg((arg as Array)[1])
			for c in m.cells:
				if int(c["pid"]) == seat and bool(c["alive"]):
					return Vector2i(c["pos"]) == at2
			return false
	return false


## `level_at_least` 的参数：**照 `players[].level` 的写法写罗马字**（`"III"`）——
## 关卡数据里等级只有那一种拼法，再要人记住「III 是下标 2」就是给自己埋雷。下标也认
static func _level_arg(arg: Variant) -> int:
	if arg is int or arg is float:
		return int(arg)
	var i: int = CWData.LEVEL_NAMES.find(str(arg))
	return i   ## 找不到给 -1 = 永不成立


## `"q,r"` → Vector2i；写歪了给哨兵
static func _at_arg(arg: Variant) -> Vector2i:
	var parts := str(arg).split(",")
	if parts.size() != 2:
		return NONE
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))
