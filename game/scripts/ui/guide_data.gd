## guide_data.gd —— 新手引导剧本的**数据门面**（docs/新手引导_实现方案.md §1.1 / S3，2026-09-19）
##
## 从前这里是 16 关剧本的正本：16 个硬编码的 `_stage_*()`，台词与局面各写一份、互相对不上就只能靠测试盯。
## S3 起它退成门面：**公开面签名一条不改**（下表），实现换成读 `game/data/tutorial/*.json`
## —— `guide.gd` 那 16 处调用一行不用动，剧本改字不再是改代码。
##
## | 今天 | 数据来源 |
## |---|---|
## | `CHAPTER_COUNT` | `index.json` 的**关**数（PRD 的「章」落在关卡的 `chapter` 字段上，不是这里） |
## | `CODEX_PAGE` / `UI_STAGE` | 每关的 `codex_page` / `ui_stage` |
## | `chapter_titles()` / `chapter_subtitles()` | 每关的 `title` / `chapter_title` |
## | `steps()` / `chapter_step_count()` / `total_steps()` | 每关的 `steps[]` |
## | `act_of()` / `watch_of()` | `steps[].act` / `steps[].watch` |
## | `graduation_assist()` | **返回 `{}`** —— 新 PRD 没有毕业战 |
##
## 三条纪律：
## ① **数字不写死在文案里**（方案 §1.2 纪律 6）：正文写 `{{tune.旋钮名}}`，`steps()` 渲染时现取（`fill()`）。
## ② **只读**：门面一个字节都不写回数据，`steps()` 交出去的是深拷贝。
## ③ 关卡 JSON 一局之内不变 ⇒ 读一次缓存在静态量里（`_render()` 每次翻页都要调 `steps()`，
##    每次重读 JSON 就是每翻一页读两个文件）。
class_name CWGuideData
extends RefCounted

## 关卡读取与校验（S2）。它没有 class_name，走 preload
const DATA := preload("res://scripts/kernel/cw_tutorial_data.gd")

## 逐关的完整 JSON，按 `index.json` 的次序。**声明在下面三个静态量之前**：它们的初始化要用它
static var _cache: Array = []

## 一「章」= 一关 = 一份关卡 JSON = 一次换局（方案 §1.1 的映射表）。
## 方案正文写的 6 是全 PRD 落完的关数；这里按 `index.json` 的实数走，数据加一关它自己就涨
static var CHAPTER_COUNT: int = levels().size()

## 每关对应的 CWCodex 章节下标
static var CODEX_PAGE: Array = _column("codex_page")

## 渐进 UI 阶段：0 = 只看棋盘；1 = 目标高亮；2 = 规则/资源提示；3 = 预测与解释。
## 语义不变（`match.gd` 的提亮还在读 `ui_stage() >= 1`），只是值从数据来
static var UI_STAGE: Array = _column("ui_stage")

## `{{tune.旋钮名}}` 的占位文法（纪律 6）。`t_tutorial_data` 校验名字、这里负责现取
static var _tune_re: RegEx = RegEx.create_from_string("\\{\\{tune\\.([^}]*)\\}\\}")


## 逐关的完整 JSON（按关表次序）。第一次调用时读盘，之后走缓存
static func levels() -> Array:
	if _cache.is_empty():
		var d = DATA.new()
		for row in d.load_index().get("levels", []):
			var lv: Dictionary = d.load_level(str((row as Dictionary).get("id", "")))
			if not lv.is_empty():
				_cache.append(lv)
	return _cache


## 第 chapter 关的完整 JSON（越界返回 `{}`）。舞台要拿它开局
static func level(chapter: int) -> Dictionary:
	var all := levels()
	if chapter < 0 or chapter >= all.size():
		return {}
	return all[chapter]


static func chapter_titles() -> Array[String]:
	var out: Array[String] = []
	for lv in levels():
		out.append(str((lv as Dictionary).get("title", "")))
	return out


## 一关的一句概括（常驻壳的目录里那行小字）。S4 起数据有 `subtitle` 字段了；
## 没写的关回落到章名 —— 老调用方拿到的仍是一句非空的话，不会变成空白行
static func chapter_subtitles() -> Array[String]:
	var out: Array[String] = []
	for lv in levels():
		var d: Dictionary = lv
		var sub := str(d.get("subtitle", ""))
		out.append(sub if sub != "" else str(d.get("chapter_title", "")))
	return out


static func chapter_step_count(chapter: int) -> int:
	return steps(chapter).size()


static func ui_stage(chapter: int) -> int:
	if UI_STAGE.is_empty():
		return 0
	return int(UI_STAGE[clampi(chapter, 0, UI_STAGE.size() - 1)])


## 第 chapter 关的步表（**渲染过占位的深拷贝**）。
## 字段：`t` 标题；`b` 正文；`flag` 高亮目标；`act` 动作提示；`watch` 真实状态完成键；
## 另有数据侧自己的 `step_of` / `load` / `ui_layers` / `allow` / `hex` / `reveal` / `unlock`（S4 起用）。
static func steps(chapter: int) -> Array:
	var out: Array = []
	for raw in level(chapter).get("steps", []):
		var s: Dictionary = (raw as Dictionary).duplicate(true)
		s["t"] = fill(str(s.get("t", "")))
		var body: Array = []
		for line in s.get("b", []):
			body.append(fill(str(line)))
		s["b"] = body                     ## 没写正文的步也要有这个键：`guide.gd:_render` 直接 `s["b"].duplicate()`
		out.append(s)
	return out


static func total_steps() -> int:
	var total := 0
	for i in CHAPTER_COUNT:
		total += steps(i).size()
	return total


static func act_of(chapter: int, step: int) -> String:
	var chapter_steps: Array = steps(chapter)
	if step < 0 or step >= chapter_steps.size():
		return ""
	return str(chapter_steps[step].get("act", ""))


## placed / moved 只观察真实局面；空串表示讲解型步骤。取值域是 `CWGuideWatch.KEYS`
static func watch_of(chapter: int, step: int) -> String:
	var chapter_steps: Array = steps(chapter)
	if step < 0 or step >= chapter_steps.size():
		return ""
	return str(chapter_steps[step].get("watch", ""))


## 席位数与人类席（方案 §1.2 纪律 8：席位数是设计量，不是副产品）。
## `match.gd` 的 `player_count` / `human_players` 从这两条来
static func seats(chapter: int) -> int:
	return int(level(chapter).get("seats", 2))


static func human_seat(chapter: int) -> int:
	return int(level(chapter).get("human_seat", 0))


## 这一关的活跃格（棋盘遮罩的唯一口径，方案 §1.3：半径恒 6，小棋盘靠集合不靠半径）
static func active_tiles(chapter: int) -> Array:
	var out: Array = []
	for s in level(chapter).get("active_tiles", []):
		out.append(DATA.parse_at(str(s)))
	return out


## 文案里的 `{{tune.旋钮名}}` 现取（纪律 6）。没有占位就原样返回
static func fill(text: String) -> String:
	if not text.contains("{{"):
		return text
	var tune := CWTuning.new()
	var out := text
	for m in _tune_re.search_all(text):
		out = out.replace(m.get_string(0), _fmt(tune.get(m.get_string(1))))
	return out


## 旋钮值 → 文案里的写法。分档表（`[I, II, III]`）取 I 级那一档、按十分位显示；标量原样
static func _fmt(v: Variant) -> String:
	if v == null:
		return "?"
	if v is Array:
		var a: Array = v
		return CWData.fmt(int(a[0])) if not a.is_empty() else "?"
	return str(v)


## 毕业战只读辅助文案。**新 PRD 没有毕业战**（方案 §1.1）——
## `guide.gd:367-369` 已经用 `_chapter != CHAPTER_COUNT - 1` 挡住，行为退化成「不给辅助」。
## 签名保留：`guide.gd` 两处还在调它，删签名就得动那个文件（本片承诺 `guide.gd` 一行不改）
static func graduation_assist(_m: CWMirror) -> Dictionary:
	return {}


## 关表里每关的某个数值字段，按关次序排成一张平行表
static func _column(field: String) -> Array:
	var out: Array = []
	for lv in levels():
		out.append(int((lv as Dictionary).get(field, 0)))
	return out
