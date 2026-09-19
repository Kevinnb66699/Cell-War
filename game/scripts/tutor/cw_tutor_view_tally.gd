## cw_tutor_view_tally.gd —— 皮 T：**计数皮**（只记账不画）
## （docs/新手引导v2_实现方案.md §5.2，S1，2026-09-19）
##
## 九类意图按调用序记进一张流水账，无头跑完整关之后与关卡数据逐条比。
## **这是全案唯一让「第一关端到端验收」与方向稿解耦的机件**：方向稿还在第二轮
## （Kevin 2026-09-19「两个都不好，重做」），而主线不能停。
##
## 纪律（方案 §5.3 第 2 条）：**所有协程方法在这里立即返回**，并往流水账记一条 `{kind, args}` ——
## 测试靠它断言顺序。`busy()` 恒 false ⇒ 导演一帧就翻过一条 `say`。
class_name CWTutorViewTally
extends CWTutorView

## 流水账：`[{kind, args}, …]`，`kind` 是九类意图之一的名字
var log: Array = []


func _rec(kind: String, args: Dictionary = {}) -> void:
	log.append({ "kind": kind, "args": args })


## 只留这一类意图的账（测试写断言时省一层过滤）
func kinds() -> PackedStringArray:
	var out := PackedStringArray()
	for e in log:
		out.append(str((e as Dictionary)["kind"]))
	return out


func clear_log() -> void:
	log.clear()


func say(who: String, lines: PackedStringArray, opts: Dictionary) -> void:
	_rec("say", { "who": who, "lines": lines, "opts": opts })


func busy() -> bool:
	return false


func point(targets: Array, mode := "soft", tip := "") -> void:
	_rec("point", { "targets": targets, "mode": mode, "tip": tip })


func clear_point() -> void:
	_rec("clear_point")


func chapter(no: int, title: String) -> void:
	_rec("chapter", { "no": no, "title": title })


func codex_unlocked(ids: PackedStringArray) -> void:
	_rec("codex_unlocked", { "ids": ids })


func block(on: bool) -> void:
	_rec("block", { "on": on })


func reset_anim() -> void:
	_rec("reset_anim")


func reveal(coords: Array) -> void:
	_rec("reveal", { "coords": coords })
	if reveal_tiles.is_valid():
		reveal_tiles.call(coords)


func hint(text: String) -> void:
	_rec("hint", { "text": text })


func urge_reset(on: bool) -> void:
	_rec("urge_reset", { "on": on })


func shell(state: Dictionary) -> void:
	_rec("shell", { "state": state })


func teardown() -> void:
	_rec("teardown")
