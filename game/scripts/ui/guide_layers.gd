## guide_layers.gd —— 教程局的「UI 层开关」（docs/新手引导_实现方案.md §1.6 / §1.12 的 UI 层清单，S4，2026-09-19）
##
## 剧本每一步可以带一段 `ui_layers`，**增量覆写**这张表：没写的层保持上一步的值，
## 关首那一步（step0）给全量。PRD 每一关都先写「界面变化：对比上一关游戏界面元素增删」（PRD:11），
## 落到代码就是这十来个开关 —— 第一关只剩棋盘与一个「迁移」按钮，第七关才全开。
##
## **为什么是静态表而不是挂在某个节点上**：能量数字的渲染点有三处
## （`match_panel.gd` 右栏那一行 / `tile_info.gd` 悬停详情 / `ui_bridge.gd` 规划路径的「走完剩」），
## 分属三个互不认识的控件。把「此刻该怎么写能量」穿成参数要改三条调用链上的每一层签名，
## 而这件事**一局之内只有一个答案**。代价是跨局会留味道 ⇒ `CWMatch.start()` 与 `teardown()` 各 `reset()` 一次。
##
## 正式对局永远不碰它：默认值就是「全开 + 能量照常写」，所以非教程局读到的和今天一模一样。
class_name CWGuideLayers
extends RefCounted

## 教程「无限能量」的标志值：数据里把能量写成这个数（方案 §1.6「大能量 99990」），
## 声明了 `energy_display: "infinite"` 的关就把它渲染成 `INFINITE_MARK`，而不是「9999.0」。
## **不是拿 `>=` 去猜**：`energy_display` 没声明时照常按十分位写数字，标志值也照写。
const INFINITE_AT := 99990
## **写「无限」而不是 ∞**：缝合像素 10px 的 25070 个字形里**没有 U+221E**（实测，`♾ ≡ ∝ √` 也都没有），
## 上屏会渲成一个方块 —— 字形覆盖闸 `t_font_coverage` 当场把它拦下来了（它只认这份字库自己有的字，
## 不吃系统字体回退，理由见那个测试的头注）。PRD:301/369 原话是「显示 ∞」，改字形要么换字库、要么补字形，
## 两件都不该由这一片顺手做 —— 先用在库里的两个字，等 Kevin / hxr 拍（回传里记着）。
const INFINITE_MARK := "无限"

## 层名 → 默认值。**这张表就是白名单**：`apply()` 收到表外的键当场 warning
## （剧本写错一个层名，真机上的表现是「那一层没反应」，不报就查不出来）。
##   action_bar / sidebar / hand / end_turn / round_no —— 控件显隐
##   move_path —— 迁移态的路径规划器（关掉 = 不画线、不出「规划路径」按钮，走已有的「降级可见」那条路）
##   cost      —— 每格耗能与按钮上的价签
##   energy_display —— "plain"（照常写数字）/ "infinite"（标志值换成 INFINITE_MARK）
##   switch_type —— 「切换种类」按钮（PRD:355 第五关 Step2）。**值是那一组 world 名**
##                  （`["b", "t", "macro", "dc"]`）：按一下换下一份，换法就是关内 `load`
##                  （方案 §1.4，`CWTutorialStage.reload_world`）。`false` / `[]` = 不出这个按钮
##
## 值的约定：`false` / `[]` = 关，`true` / 非空数组 = 开。
## **数组形态的「白名单」由决策闸（`allow`，§1.5）落实**，不在这儿过滤 ——
## 行动栏的按钮是从 `req["options"]` 建的，闸把选项滤掉按钮就根本不出现，
## 两处都过滤等于同一件事写两遍、还会对不上。这里只认「这一层开不开」。
const DEFAULTS := {
	"action_bar": true,
	"sidebar": true,
	"hand": true,
	"end_turn": true,
	"round_no": true,
	"move_path": true,
	"cost": true,
	"energy_display": "plain",
	"switch_type": false,
}

static var _cur: Dictionary = DEFAULTS.duplicate(true)


## 回到默认（= 正式对局的样子）。开一关、拆局、重置各调一次
static func reset() -> void:
	_cur = DEFAULTS.duplicate(true)


## 增量覆写：只动 `patch` 里写到的层
static func apply(patch: Dictionary) -> void:
	for k in patch:
		if DEFAULTS.has(k):
			_cur[str(k)] = patch[k]
		else:
			push_warning("ui_layers 里有不认识的层「%s」（白名单：%s）" % [str(k), ", ".join(PackedStringArray(DEFAULTS.keys()))])


static func current() -> Dictionary:
	return _cur.duplicate(true)


## 这一层此刻开着吗
static func on(key: String) -> bool:
	var v: Variant = _cur.get(key, true)
	if v is bool:
		return v
	if v is Array:
		return not (v as Array).is_empty()
	return true


static func energy_mode() -> String:
	return str(_cur.get("energy_display", "plain"))


## 「切换种类」按一下要换成哪几份 world（按次序轮转）。没开这一层就是空表（S8）
static func switch_types() -> Array:
	var v: Variant = _cur.get("switch_type", false)
	return (v as Array).duplicate() if v is Array else []


## 能量数字该怎么写。**三个渲染点一律走这里**（见文件头）
static func energy_text(v: int) -> String:
	if energy_mode() == "infinite" and v >= INFINITE_AT:
		return INFINITE_MARK
	return CWData.fmt(v)
