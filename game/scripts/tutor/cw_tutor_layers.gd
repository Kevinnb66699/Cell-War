## cw_tutor_layers.gd —— 教程局的「UI 层开关」（docs/新手引导v2_实现方案.md §3.2(b)，S1，2026-09-19）
##
## 剧本每一条 `flow[].ui` **增量覆写**这张表：没写的层保持上一条的值；写 `"*": false`
## 先把所有层关掉再按后面的键覆写（间章 PRD:387「所有 UI 消失」一条搞定）。
## PRD 每关都先写「界面变化：对比上一关游戏界面元素增删」（PRD:11），落到代码就是这十个开关。
##
## **为什么是静态表而不是挂在某个节点上**（老 `guide_layers.gd:7-10` 的教训原样照抄）：
## 能量数字的渲染点有三处 —— `match_panel.gd` 右栏那一行 / `tile_info.gd` 悬停详情 /
## `ui_bridge.gd` 规划路径的「走完剩」，分属三个互不认识的控件。把「此刻该怎么写能量」
## 穿成参数要改三条调用链上的每一层签名，而这件事**一局之内只有一个答案**。
## 代价是跨局会留味道 ⇒ `CWMatch.start()` 与 `teardown()` 各 `reset()` 一次。
##
## **带 class_name，代价是走不了热更，别再往里塞新逻辑**（方案 §1.5 的三个例外之一）：
## 三个互不认识的渲染点要一张静态表才最省，`scripts/tutor/` 里其余文件一律 preload。
##
## 正式对局永远不碰它：默认值就是「全开 + 能量照常写」，所以非教程局读到的和今天一模一样。
class_name CWTutorLayers
extends RefCounted

## 教程「无限能量」的标志值：数据里把能量写成这个数（方案 §3.2(c)「大能量 99990」），
## 声明了 `energy: "infinite"` 的关就把它渲染成 `ENERGY_INF_MARK`，而不是「9999.0」。
## **不是拿 `>=` 去猜**：`energy` 是 `"plain"` 时照常按十分位写数字，标志值也照写。
const INFINITE_AT := 99990

## ★ **显示串常量只有这一处**（方案 §3.2(b) / 拆片 S13）。Kevin 2026-09-19 原话
## 「补字形，如果没有相似字形，就用 INF」—— 缝合像素 10px 原本没有 U+221E，
## **S13 已经把字形手补进字库**（`tools/add_infinity_glyph.py`，合并在 35e6c91），
## 字形闸 `t_font_coverage` 有一条「∞ 在字库里」的正面断言，所以这里直接写 ∞。
## 三个渲染点跟着这一行走，将来要改也只改这一行。
const ENERGY_INF_MARK := "∞"
## PRD:431 第七关「癌细胞能量保持为 Null，内部计算为无限能量」的那个字面量。
## 四个 ASCII 字形字库里都有，不进 S13 的账
const ENERGY_NULL_MARK := "Null"

## 层名 → 默认值。**这张表就是白名单**：`apply()` 收到表外的键当场 warning
## （剧本写错一个层名，真机上的表现是「那一层没反应」，不报就查不出来）。
## 连通配符 `"*"` 一共 11 层（方案 §3.2(b) 的清单）：
##   action_bar / sidebar / round_no / end_turn / hand / skill_bar —— 控件显隐
##   switch_type —— 「切换种类」按钮（PRD:355 第五关 Step2）。**值是那一组 world 名**
##                  （`["b", "t", "macro", "dc"]`）：按一下换下一份，换法就是关内 `load`。
##                  `false` / `[]` = 不出这个按钮
##   move_path —— 迁移态的路径规划器（关掉 = 不画线、不出「规划路径」按钮，
##                走已有的那条「降级可见」的路，PRD:107/151/197）
##   cost      —— 每格耗能与按钮上的价签（PRD:107）
##   camera    —— **镜头**（PRD 04:08 版给关卡模板加的「镜头变化」，PRD:9-22）：
##                `{"anchor": "map"|"player", "align": "center"|"left"|"right"}`。
##                `map` = 让整张活跃地图落在镜头的正中 / 三分之一 / 三分之二处，
##                `player` = 让玩家那只细胞落在那儿；竖直方向一律居中。
##                **它是唯一不能「关」的层**（镜头永远存在）—— `"*": false` 也不碰它
##   energy    —— "plain"（照常写数字）/ "infinite"（标志值换成 ENERGY_INF_MARK）
##                / "null"（标志值换成 ENERGY_NULL_MARK，PRD:431）/ "hidden"（整个不写）
##
## 值的约定：`false` / `[]` / `""` = 关，`true` / 非空数组 / 非空串 = 开。
## **数组形态的「白名单」由决策闸（`allow`，方案 §3.2(a)）落实**，不在这儿过滤 ——
## 行动栏的按钮是从 `req["options"]` 建的，闸把选项滤掉按钮就根本不出现，
## 两处都过滤等于同一件事写两遍、还会对不上。这里只认「这一层开不开」。
## 镜头那两个枚举与缺省值（「地图调中」）住在条目文法表里 —— **校验器读的是同一份**
const BEATS := preload("res://scripts/kernel/cw_tutor_beats.gd")
const CAMERA_DEFAULT := BEATS.CAMERA_DEFAULT
const CAMERA_ANCHORS := BEATS.CAMERA_ANCHORS
const CAMERA_ALIGNS := BEATS.CAMERA_ALIGNS

const DEFAULTS := {
	"action_bar": true,
	"sidebar": true,
	"round_no": true,
	"end_turn": true,
	"hand": true,
	"skill_bar": true,
	"switch_type": false,
	"move_path": true,
	"cost": true,
	"energy": "plain",
	"camera": CAMERA_DEFAULT,
}

## 通配键：`{"*": false}` = 先把所有具名层按「关」的那一侧铺一遍，再按同一条里其余键覆写。
## **它不是层**，不进 `current()`，`on("*")` 也没有意义
const WILDCARD := "*"

static var _cur: Dictionary = DEFAULTS.duplicate(true)


## 回到默认（= 正式对局的样子）。开一关、拆局、重置各调一次
static func reset() -> void:
	_cur = DEFAULTS.duplicate(true)


## 「关」的那一侧长什么样：布尔层给 false，数组层给空表，`energy` 给 "hidden"。
## 通配只铺这一份，**不碰** `energy` 之外的字符串层（今天只有 energy 一个）。
## **字典层（camera）没有「关」这一档** —— 镜头永远在某个位置上，通配把它铺回缺省而不是关掉
static func off_value(key: String) -> Variant:
	var d: Variant = DEFAULTS.get(key, false)
	if d is String:
		return "hidden"
	if d is Array:
		return []
	if d is Dictionary:
		return (d as Dictionary).duplicate(true)   ## `camera`：镜头关不掉，通配也只是回到缺省
	return false


## 增量覆写：只动 `patch` 里写到的层；`"*"` 先把所有层铺成「关」再往下覆写。
## **`"*"` 必须先办**（Dictionary 的遍历次序是插入序，剧本可能把 `"*"` 写在中间）
static func apply(patch: Dictionary) -> void:
	if patch.has(WILDCARD) and not bool(patch[WILDCARD]):
		for k in DEFAULTS:
			_cur[str(k)] = off_value(str(k))
	for k in patch:
		if str(k) == WILDCARD:
			continue
		if DEFAULTS.has(k):
			_cur[str(k)] = patch[k]
		else:
			push_warning("flow[].ui 里有不认识的层「%s」（白名单：%s）"
				% [str(k), ", ".join(PackedStringArray(DEFAULTS.keys()))])


static func current() -> Dictionary:
	return _cur.duplicate(true)


## 这一层此刻开着吗
static func on(key: String) -> bool:
	var v: Variant = _cur.get(key, true)
	if v is bool:
		return v
	if v is Array:
		return not (v as Array).is_empty()
	if v is String:
		return not (v as String).is_empty() and str(v) != "hidden"
	return true


## 这一刻的镜头（PRD:9-22）。**表外的值当缺省**：剧本写错一个字不该把镜头摔到某个
## 算不出来的地方，但要说出来 —— 校验器（`cw_tutor_script.validate` 第 14 条）装载期就拦
static func camera() -> Dictionary:
	var v: Variant = _cur.get("camera", CAMERA_DEFAULT)
	var d: Dictionary = v as Dictionary if v is Dictionary else {}
	var anchor := str(d.get("anchor", "map"))
	var align := str(d.get("align", "center"))
	return {
		"anchor": anchor if anchor in CAMERA_ANCHORS else "map",
		"align": align if align in CAMERA_ALIGNS else "center",
	}


static func energy_mode() -> String:
	return str(_cur.get("energy", "plain"))


## 「切换种类」按一下要换成哪几份 world（按次序轮转）。没开这一层就是空表
static func switch_types() -> Array:
	var v: Variant = _cur.get("switch_type", false)
	return (v as Array).duplicate() if v is Array else []


## 能量数字该怎么写。**三个渲染点一律走这里**（见文件头）：
## `match_panel.gd` 右栏那一行 / `tile_info.gd` 悬停详情 / `ui_bridge.gd` 的「走完剩」。
## `mode` 留空 = 按此刻这一局的层走；显式给一档是留给测试正面核那个显示串的
## （它是**代码常量**，字形闸扫 JSON 扫不到它，判据见方案 §6.2 的 S13 那条）
static func energy_text(v: int, mode := "") -> String:
	var m := energy_mode() if mode == "" else mode
	match m:
		"infinite":
			return ENERGY_INF_MARK if v >= INFINITE_AT else CWData.fmt(v)
		"null":
			return ENERGY_NULL_MARK if v >= INFINITE_AT else CWData.fmt(v)
		"hidden":
			return ""
		_:
			return CWData.fmt(v)
