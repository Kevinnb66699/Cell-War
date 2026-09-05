## cw_guide_progress.gd —— 新手引导完成状态（独立于对局存档）
##
## 单独一份小配置而不是塞进 CWSave：引导进度是「这个玩家看了多少」的偏好信息，
## 跟有没有进行中的对局无关。主菜单「新手引导」项据此显示已完成标记/继续入口。
class_name CWGuideProgress
extends RefCounted

const PATH := "user://guide_progress.cfg"
const SECTION := "guide"

## 已完成的章节数（0..CHAPTER_COUNT）。主动跳过的章节不算完成。
static func read() -> Dictionary:
	var prog := { "done": 0 }
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return prog
	prog["done"] = int(cfg.get_value(SECTION, "done", 0))
	return prog


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


static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
