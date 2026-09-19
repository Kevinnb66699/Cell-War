## cw_guide_progress.gd —— 新手引导完成状态（独立于对局存档）
##
## 单独一份小配置而不是塞进 CWSave：引导进度是「这个玩家看了多少」的偏好信息，
## 跟有没有进行中的对局无关。主菜单「新手引导」项据此显示已完成标记/继续入口。
##
## **四个键**（新手引导 S6 / S6b，2026-09-19 扩，方案 §1.11）：
##   `done`     已完成的关数。**原样保留**：主菜单与 `match.gd` 还在读它，口径一个字没变。
##   `unlocked` 已解锁的**图鉴解锁点** id（剧本 `steps[].unlock` 写的那些），知识之书据此灰显条目。
##   `at`       读到哪了 `{chapter, level, step}` —— chapter 是 PRD 的章号，level 是关下标。
##              今天只写不读（断点续读要不要做是另一回事，别顺手改 `_read_progress` 的行为）。
##   `skipped`  按过「跳过引导」。**不动 `done`** —— 跳过不等于看完，主菜单的完成标记口径没变；
##              它唯一的用处是 `codex_gated()`（S6b，Kevin 2026-09-19：跳过之后图鉴全解锁）。
##
## **旧档迁移**：2026-09-19 之前的存档只有 `done`。`read()` 见到「有 done、没 unlocked」时
## 按 `done` 现推一份解锁集（前 done 关剧本里写到的 unlock 全给），**不写回盘** ——
## 下一次真解锁时 `unlock()` 会把合并后的完整集合落盘，迁移就此固化。
class_name CWGuideProgress
extends RefCounted

const PATH := "user://guide_progress.cfg"
const SECTION := "guide"

## 已完成的章节数（0..CHAPTER_COUNT）。主动跳过的章节不算完成。
static func read() -> Dictionary:
	var prog := { "done": 0, "unlocked": PackedStringArray(), "at": {}, "skipped": false }
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return prog
	prog["done"] = int(cfg.get_value(SECTION, "done", 0))
	prog["at"] = cfg.get_value(SECTION, "at", {}) as Dictionary
	prog["skipped"] = bool(cfg.get_value(SECTION, "skipped", false))
	if cfg.has_section_key(SECTION, "unlocked"):
		prog["unlocked"] = PackedStringArray(cfg.get_value(SECTION, "unlocked", PackedStringArray()))
	else:
		prog["unlocked"] = _migrate_unlocked(int(prog["done"]))
	return prog


## 旧档（只有 `done`）的解锁集：前 `done` 关剧本里写到的 unlock 点全算解锁。
## 旧版 16 关的 `done` 可能比今天的关数大 —— 钳住就行，多出来的关本来就不存在了
static func _migrate_unlocked(done: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in clampi(done, 0, CWGuideData.CHAPTER_COUNT):
		for step in CWGuideData.steps(i):
			for id in (step as Dictionary).get("unlock", []):
				if not out.has(str(id)):
					out.append(str(id))
	return out


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


## 读到哪了。`chapter` = PRD 的章号，`level` = 关下标，`step` = 关内步号
static func set_at(chapter: int, level: int, step: int) -> void:
	## 同一步渲染多次（重排 / 重算提示）不重复写盘。**逐字段比**：
	## Dictionary 的 `==` 在 Godot 4 里比的是引用，拿它判「没变」永远为假
	var cur: Dictionary = read()["at"]
	if int(cur.get("chapter", -1)) == chapter and int(cur.get("level", -1)) == level \
			and int(cur.get("step", -1)) == step:
		return
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value(SECTION, "at", { "chapter": chapter, "level": level, "step": step })
	cfg.save(PATH)


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
	cfg.set_value(SECTION, "done", CWGuideData.CHAPTER_COUNT)
	cfg.save(PATH)


static func all_done() -> bool:
	return done_count() >= CWGuideData.CHAPTER_COUNT


## 按过「跳过引导」（`CWGuide.skip()`）。**只记这一笔，不动 `done`**：
## 跳过不是看完，主菜单的完成标记不该因此变绿
static func set_skipped() -> void:
	if bool(read()["skipped"]):
		return
	var cfg := ConfigFile.new()
	cfg.load(PATH)   ## 旧文件存在就把其它字段带回来
	cfg.set_value(SECTION, "skipped", true)
	cfg.save(PATH)


## 知识之书现在要不要按解锁集闸？（Kevin 2026-09-19 拍板，方案 §1.11 口径③）
##
## **闸只在「教程进行中」这一个状态下生效**，三态各一句：
##   · 从没进过教程（没有这份 cfg，或者一点进度都没有）→ **不闸**，整本书随便看；
##   · 教程开着、还没跳过也没通关                       → **闸**，没解锁的条目灰显（S6b 起不再隐藏）；
##   · 按过「跳过引导」／ 全部通关（`set_all_done`）      → **不闸**，全解锁。
##
## 写成这一个只读谓词而不是把判断散进面板：`cw_codex.gd` 只问它一句，
## 将来口径再改也只有这一处（S6 那会儿面板自己读 `unlocked` 就完事，改起来是两处）。
##
## 「进过教程」按**进度**算，不按 `opening_seen`（S7 写在同一份 cfg 里的另一个键）算 ——
## 看了开场就退出去的玩家一课都没上，图鉴不该因此对他关门。
## 跳过之后再回来接着看，`skipped` 不会自己清掉 ⇒ 也不再闸（「跳过之后全解锁」的字面口径）
static func codex_gated() -> bool:
	var prog := read()
	if bool(prog["skipped"]):
		return false
	if int(prog["done"]) >= CWGuideData.CHAPTER_COUNT:
		return false
	return _started(prog)


## 这个玩家进过教程吗：`read()` 出来的三样进度里有任何一样就算
static func _started(prog: Dictionary) -> bool:
	return int(prog["done"]) > 0 \
		or not (prog["unlocked"] as PackedStringArray).is_empty() \
		or not (prog["at"] as Dictionary).is_empty()


static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
