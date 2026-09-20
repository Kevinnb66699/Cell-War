## cw_guide_progress.gd —— 新手引导完成状态（独立于对局存档）
##
## 单独一份小配置而不是塞进 CWSave：引导进度是「这个玩家看了多少」的偏好信息，
## 跟有没有进行中的对局无关。主菜单「新手引导」项据此显示已完成标记/继续入口。
##
## **原有四个键 + 首次选择**（新手教程 v2 · S6，2026-09-19 重定，方案 §3.6）：
##   `done`         已完成的关数。**原样保留**：主菜单（`main_menu.gd:136`）与 `match.gd` 还在读它。
##   `at`           读到哪了 `{level, beat}` —— `level` 是 `index.json` 里那个**关 id**，
##                  `beat` 是关内 `flow` 下标。**续读只认「关」不认「步」**（Q-11）：
##                  `beat` 只记不读，续到步要连带定义「重进时局面怎么摆」，那是行为改动不是存档改动。
##   `unlocked`     已解锁的**图鉴解锁点** id（剧本 `flow[].unlock.ids` 写的那些）。
##                  图鉴 2026-09-19 起**去闸只留通知**（方案 §3.8）—— 这份集合今天只喂
##                  「解锁通知 + 图鉴里那一条慢闪一轮」，不再决定哪条看得见。
##   `entry_choice`  首次进入时选 new / experienced；已有进度文件的旧玩家不再弹首次选择。
##   `opening_seen` 开场动画看过没有。**别碰**：那一键归 `tutorial_opening.gd`（`SEEN_KEY`），
##                  本文件一个字都不写它 —— 目录里的「Cell War」走的是它现成的 `clear_seen()`。
##
## ⚠ **写盘一律 `ConfigFile.load` 之后 `set_value`**（方案 §3.6 的硬口径）：两边各自读改写、
## 互不覆盖。整份覆盖会把 `opening_seen` 抹掉、开场每次重播 —— `t_tutor_progress` 正面断言这一条。
##
## **旧档迁移**：2026-09-19 老教程整套推倒之后，旧档里那个 `done` 数的是**旧关**，
## 回推解锁集已经没有意义 —— `_migrate_unlocked` 恒为空，理由见那个函数的头注。
## 旧档只有 `done`（没有 `at`）照样起得来：`at_level()` 返回空串，挑关退回按 `done` 数。
class_name CWGuideProgress
extends RefCounted

const PATH := "user://guide_progress.cfg"
const SECTION := "guide"
const ENTRY_NEW := "new"
const ENTRY_EXPERIENCED := "experienced"


## 只在这台设备没有引导记录时询问一次。旧版留下的进度文件也算已进入过游戏，
## 升级客户端不能把老玩家重新带进首次选择。
static func needs_entry_choice() -> bool:
	return not FileAccess.file_exists(PATH)


## 选择先落盘再切界面：新手中途退出后，下次启动直接到主菜单，可从菜单继续引导。
static func choose_entry(choice: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value(SECTION, "entry_choice", choice)
	if choice == ENTRY_EXPERIENCED:
		cfg.set_value(SECTION, "done", level_count())
		cfg.set_value(SECTION, "at", {})
	cfg.save(PATH)

## 已完成的关数（0..level_count()）。主动跳过的关不算完成。
static func read() -> Dictionary:
	var prog := { "done": 0, "unlocked": PackedStringArray(), "at": {} }
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return prog
	prog["done"] = int(cfg.get_value(SECTION, "done", 0))
	prog["at"] = cfg.get_value(SECTION, "at", {}) as Dictionary
	if cfg.has_section_key(SECTION, "unlocked"):
		prog["unlocked"] = PackedStringArray(cfg.get_value(SECTION, "unlocked", PackedStringArray()))
	else:
		prog["unlocked"] = _migrate_unlocked(int(prog["done"]))
	return prog


## 旧档（只有 `done`）的解锁集。
##
## **2026-09-19 起恒为空**：老教程整套推倒（Kevin：「把之前教程的 UI 等设计全部删掉，
## 基于脚本从 0 构建」），`cwtut/1` 的剧本连同 `guide_data.gd` 一起删了 —— 旧档里那个 `done`
## 数的是**旧关**，拿新剧本按它回推解锁集只会给出一份对不上的清单，比给空的更难查。
## 代价可控：**图鉴 S6 已经去闸**（方案 §3.8，`codex_gated()` 随之退役），没解锁只是少一条
## 「解锁通知 + 慢闪」，旧档玩家重走一遍新教程就会逐点补回来 —— 一个条目都不会看不见。
static func _migrate_unlocked(_done: int) -> PackedStringArray:
	return PackedStringArray()


## 教程一共几关 = `index.json` 里关表的条数（老 `CWGuideData.CHAPTER_COUNT` 的口径原样搬过来，
## 那个文件随老教程一起删了）。**每次现读**：关表是数据，加一关不该要改代码。
## 读不出来（重做期间关表还空着）按 1 算 —— 别让 `all_done()` 在零关时恒为真
static func level_count() -> int:
	var raw: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/tutorial/index.json"))
	if not (raw is Dictionary):
		return 1
	return maxi(((raw as Dictionary).get("levels", []) as Array).size(), 1)


## 已解锁的解锁点 id（含旧档迁移）
static func unlocked() -> PackedStringArray:
	return PackedStringArray(read()["unlocked"])


## 记下若干个解锁点，返回**这次真正新增的**那几个（一个没新增就不落盘）。
## 集合语义：重复调用是空操作，所以剧本每次翻到同一步都调它也不会写盘写个没完
static func unlock(ids) -> PackedStringArray:
	var have := {}
	for id in read()["unlocked"]:
		have[str(id)] = true
	var added := PackedStringArray()
	for id in ids:
		if not have.has(str(id)):
			have[str(id)] = true
			added.append(str(id))
	if added.is_empty():
		return added
	var all := PackedStringArray(have.keys())
	all.sort()   ## 存盘次序稳定，diff 才看得懂
	var cfg := ConfigFile.new()
	cfg.load(PATH)   ## 旧文件存在就把其它字段带回来
	cfg.set_value(SECTION, "unlocked", all)
	cfg.save(PATH)
	return added


## 读到哪了：`level` = `index.json` 里那个**关 id**，`beat` = 关内 `flow` 下标。
## 老签名 `(chapter, level, step)` 三个整数 S6 作废 —— 关下标会随关表增删漂移，关 id 不会。
static func set_at(level_id: String, beat: int) -> void:
	## 同一步渲染多次（重排 / 重算提示）不重复写盘。**逐字段比**：
	## Dictionary 的 `==` 在 Godot 4 里比的是引用，拿它判「没变」永远为假
	var cur: Dictionary = read()["at"]
	if str(cur.get("level", "")) == level_id and int(cur.get("beat", -1)) == beat:
		return
	var cfg := ConfigFile.new()
	cfg.load(PATH)   ## 旧文件存在就把其它字段带回来（含 opening_seen，见头注那条硬口径）
	cfg.set_value(SECTION, "at", { "level": level_id, "beat": beat })
	cfg.save(PATH)


## 断点续读的落点：上次读到**哪一关**（关 id）。旧档（只有 `done`）返回空串，
## 调用方退回按 `done` 数挑关 —— 见 `match.gd` 的 `_tutor_pick_level`
static func at_level() -> String:
	return str((read()["at"] as Dictionary).get("level", ""))


static func done_count() -> int:
	return int(read()["done"])


static func has_done(chapter: int) -> bool:
	return chapter < done_count()


## 标记某章完成；把已完成数推到 max(当前, chapter+1)。
static func set_done(chapter: int) -> void:
	var cur := done_count()
	if chapter + 1 <= cur:
		return
	var cfg := ConfigFile.new()
	cfg.load(PATH)   ## 旧文件存在就把其它字段带回来
	cfg.set_value(SECTION, "done", chapter + 1)
	cfg.save(PATH)


static func set_all_done() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value(SECTION, "done", level_count())
	cfg.save(PATH)


static func all_done() -> bool:
	return done_count() >= level_count()


## ⚠ **`set_skipped()` / `codex_gated()` / `skipped` 键 2026-09-19 一并退役**（方案 §3.8：
## 图鉴去闸只留通知）。全书从此常驻可读，没有任何一处再问「要不要闸」——
## 连带着「跳过引导之后全解锁」也不必单独记一笔了。老调用方只有 `cw_codex.gd:119` 与
## `t_codex` 那三条，S6 当天一起改判。**别再把这三样加回来**：要重新上闸的话，
## `cw_codex.gd` 的 `_mark_locked` 与两个可选参数都还留着（方案 §3.8 明令不删），打开是一行的事。


static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
