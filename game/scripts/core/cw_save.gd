## cw_save.gd —— 存档读档：把流程状态机的快照原样写进磁盘
##
## 存档载荷就是 `game.snapshot()`：流程位置是数据（flow/_pending）、rng 状态也在里面，
## 所以「继续对局」= 建同构对局 → restore → run_game 把那条待决的询问重新问出来，
## 连「存档那一刻你正要做的决定」都原样回来 —— 这正是流程写成状态机换来的能力
## （和蒙特卡洛推演同一个地基）。
##
## **只在 pending 边界写**（_pending 非空）：中途询问挂起时协程栈不在快照里，
## 写了也恢复不出来。暂停菜单的「保存并退出」按这个条件亮灭 ——
## 人类的顶层决策期间 _pending 一直挂着，实际上几乎总是能存。
##
## 单一存档位：写覆盖、读不删（同一局可以反复回到存档点重打）。
## 日志不入档（不在快照里）——读档后日志面板从恢复点重新记起。
class_name CWSave
extends RefCounted

const PATH := "user://save.cw"
const VERSION := 1


static func exists() -> bool:
	return FileAccess.file_exists(PATH)


## 能写才写（pending 边界 + 文件真的落了盘），返回是否成功。
static func write(game: CWGame, human: Array, smart: bool) -> bool:
	if game == null or game._pending.is_empty() or game.is_over():
		return false
	var payload := {
		"version": VERSION,
		"players": game.order.size(),
		"human": Array(human),
		"smart": smart,
		"at": Time.get_datetime_string_from_system(false, true),
		"snap": game.snapshot(),
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(var_to_str(payload))
	f.close()
	return true


## 读不出、版本不认识、人数不合法 → 返回 {}（调用方按「没有存档」处理）。
static func read() -> Dictionary:
	if not exists():
		return {}
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var payload: Variant = str_to_var(f.get_as_text())
	f.close()
	if not (payload is Dictionary) or payload.get("version", -1) != VERSION:
		return {}
	if not CWData.FACTION_ORDER.has(payload.get("players", 0)):
		return {}
	if not (payload.get("snap") is Dictionary) or payload["snap"].is_empty():
		return {}
	return payload


static func clear() -> void:
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
