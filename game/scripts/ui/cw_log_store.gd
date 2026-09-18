## cw_log_store.gd —— 对局日志的 UI 侧存储（口径二 · 批 1 步 5，规格 A-7）
##
## 三条并行数组与 CWGame 同名（logs / log_secret / log_public），所以 CWLogPanel / CWLogHint 的
## refresh / _rebuild_rows / line_text 函数体一个字不改，只换形参类型。
##
## 两条喂料路（互斥）：
##   · 本地 / 热座 / 教程 / 回放（InProc）：播放队列的 log{index, text, secret_pid, public_text} 条目 → apply()。
##     index 与上一条相同 = 就地改写末条（装得下 CWGame.log_run 的语义）。
##   · 联机（Remote）：sync 条目里 envelope["logs"] = {from, lines} → reset_from()。服务器已按席位裁好，
##     secret 一律 -1、public = text，line_text 自动落回原文 —— 与今天把 m["logs"] 灌进 shadow.logs 逐字等价。
## 换局边界（game_no 变了）→ clear()。
##
## 顺带修好一个今天的 bug：log_run 就地改写末条时，联机路的 _log_cursor 已越过那一行 ⇒ 改写永久丢失；
## 按 index 覆写后本地与联机一致。
class_name CWLogStore
extends RefCounted

var logs: PackedStringArray = []
var log_secret: PackedInt32Array = []
var log_public: PackedStringArray = []


## log 条目落地：index 越界就补齐再写（中间缺的行补空串，别让并行数组错位）
func apply(e: Dictionary) -> void:
	var index := int(e.get("index", logs.size()))
	if index < 0:
		return
	while logs.size() <= index:
		logs.append("")
		log_secret.append(-1)
		log_public.append("")
	var text := String(e.get("text", ""))
	var secret := int(e.get("secret_pid", -1))
	logs[index] = text
	log_secret[index] = secret
	log_public[index] = String(e.get("public_text", text)) if secret >= 0 else text


## 重连 / 换局：从 from 起整段重灌（服务器裁好的行，没有秘密档）
func reset_from(from: int, lines: Array) -> void:
	for i in lines.size():
		apply({ "index": from + i, "text": String(lines[i]), "secret_pid": -1, "public_text": String(lines[i]) })


func clear() -> void:
	logs = PackedStringArray()
	log_secret = PackedInt32Array()
	log_public = PackedStringArray()


## 只给测试与步 5 的过渡适配器用：把一个活 CWGame 的三条数组抄一份（步 8 之后走条目流，不再有它）
static func of(game: CWGame) -> CWLogStore:
	var s := CWLogStore.new()
	if game != null:
		s.logs = game.logs.duplicate()
		s.log_secret = game.log_secret.duplicate()
		s.log_public = game.log_public.duplicate()
	return s
