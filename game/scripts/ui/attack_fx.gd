## 普通攻击临时代画双方原贴图。只消费结算结果，不改动细胞位置或生命状态。
##
## **没有 class_name**（2026-09-13 合入时改的）：新 class_name 热更装不上 ——
## 全局类表在导出那一刻烘死，补丁里的新类名认不出来（`tools/build_patch.sh` 当场拦）。
## 用法同 `scripts/net/cw_lan.gd`：`const CWAttackFx := preload(...)` 再 `.new()`。
extends Node2D

const TOTAL := 0.66
const CONTACT := 0.22
const RELEASE := 0.29
const FPS := 30.0
var _plays: Array[Dictionary] = []


func play(data: Dictionary, from: Vector2, to: Vector2,
		attacker: Texture2D, defender: Texture2D) -> void:
	# 快速连续操作以最新结果接管同一细胞，避免两段演出同时代画它。
	var ids: Array = [data["cid"], data["target_id"]]
	for i in range(_plays.size() - 1, -1, -1):
		if _plays[i]["cid"] in ids or _plays[i]["target_id"] in ids:
			_plays.remove_at(i)
	var entry := data.duplicate()
	entry.merge({"t": 0.0, "from_px": from, "to_px": to,
		"attacker": attacker, "defender": defender})
	_plays.append(entry)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	queue_redraw()


func owns(cid: int) -> bool:
	for entry in _plays:
		if int(entry["cid"]) == cid or int(entry["target_id"]) == cid:
			return true
	return false


func clear() -> void:
	_plays.clear()
	queue_redraw()


func sync(delta: float) -> void:
	for i in range(_plays.size() - 1, -1, -1):
		_plays[i]["t"] = float(_plays[i]["t"]) + delta
		if float(_plays[i]["t"]) >= TOTAL:
			_plays.remove_at(i)
	queue_redraw()


func _draw() -> void:
	for entry in _plays:
		_draw_attack(entry)


func _body(tex: Texture2D, foot: Vector2, t: float, alpha: float = 1.0) -> void:
	var size := Vector2(tex.get_width() / 6.0, tex.get_height())
	var frame := int(t * 6.0) % 6
	var source := Rect2(Vector2(frame * size.x, 0), size)
	var dest := Rect2((foot - Vector2(size.x / 2.0, size.y)).round(), size)
	draw_texture_rect_region(tex, dest, source, Color(1, 1, 1, alpha))


func _draw_attack(e: Dictionary) -> void:
	var t := floorf(float(e["t"]) * FPS) / FPS
	var from: Vector2 = e["from_px"]
	var to: Vector2 = e["to_px"]
	var direction := (to - from).normalized()
	var attacker: Texture2D = e["attacker"]
	var defender: Texture2D = e["defender"]
	var gap := minf(14.0, (attacker.get_width() + defender.get_width()) / 24.0)
	var contact := to - direction * gap
	var a := from
	var b := to
	var after := clampf((t - RELEASE) / (TOTAL - RELEASE), 0.0, 1.0)
	var victim_alpha := 1.0
	if t < 0.07:
		a = from - direction * (3.0 * t / 0.07)
	elif t < CONTACT:
		var dash := clampf((t - 0.07) / (CONTACT - 0.07), 0.0, 1.0)
		a = (from - direction * 3.0).lerp(contact, dash * dash)
	elif t < RELEASE:
		a = contact
		b = to + direction * 3.0
	else:
		var settle := 1.0 - pow(1.0 - after, 3.0)
		if bool(e["entered"]):
			a = contact.lerp(to, settle)
		else:
			a = contact.lerp(from, settle) - Vector2(0, sin(after * PI) * 5.0)
		if bool(e["target_alive"]):
			b = to + direction * (cos(after * PI * 3.0) * 3.0 * (1.0 - after))
		else:
			b = to + direction * (after * 40.0) - Vector2(0, sin(after * PI * 0.8) * 17.0)
			victim_alpha = 1.0 - after
	var attacker_alpha := 1.0 if bool(e["attacker_alive"]) else 1.0 - after
	# 与棋盘一致按脚底高度排序，碰撞中也保留原贴图像素，不旋转或非整数缩放。
	if a.y <= b.y:
		_body(attacker, a, t, attacker_alpha)
		_body(defender, b, t, victim_alpha)
	else:
		_body(defender, b, t, victim_alpha)
		_body(attacker, a, t, attacker_alpha)
	var center := a - Vector2(0, attacker.get_height() / 2.0)
	if t >= 0.1 and t < CONTACT:
		var side := Vector2(-direction.y, direction.x)
		for i in 3:
			var tip := center - direction * 9.0 + side * float((i - 1) * 4)
			CWPix.line(self, tip - direction * 7.0, tip, Color("83dce2"))
	if t >= CONTACT and t < 0.48:
		var impact := to - Vector2(0, defender.get_height() / 2.0) - direction * gap * 0.5
		var burst := clampf((t - CONTACT) / 0.26, 0.0, 1.0)
		var ink := Color("ffb03a") if bool(e["hit"]) else Color("8aa9b8")
		ink.a = 1.0 - burst
		CWPix.burst(self, impact, burst, ink, 9 if bool(e["hit"]) else 5, 14.0)
		if t < RELEASE:
			CWPix.line(self, impact - Vector2(0, 4), impact + Vector2(0, 4), Color("eaf8fc"), 2)
