## rig_rng.gd —— 无头测试钉骰子用的 rng 替身（测试迁移规格 A-7「Tape 化」，C-1 步 R）
##
## 以前 `_rig_roll(g, sides, want)` 是**暴力试探**：存 `g.rng.state`，反复 `randi_range` 直到掷出想要的序列再把 state 拨回去 ——
## 不可移植（对拍规格 §1 死结二：两侧 rng 算法不同）。现在改成**带子**：把想要的点数排进队列，接下来的几次 `randi_range` 按队列吐，
## 吐完回落到原来的 rng 继续。用例里写成 `rolls: [[1,6,3]]`，C# 侧 `TapeRng` 同一套语义。
##
## 装法（`_rig_next` 会自动裹一层）：`var r := Rig.new(); r.inner = g.rng; g.rng = r`。
## 靠的是 cw_game.gd 那行 `var rng: Object`（有护栏 t_rng_injectable 盯着）。`seed` / `state` 都转发给里面那只，
## 启发式桥「偷看 rng.state」的路照走；强吐一次也照样推进里面那只（与 xcheck_tape.gd 放音时的做法相同）。
## 不带 class_name（同 xcheck_* 的规矩），用 preload 取。
extends RefCounted

var inner: Object = RandomNumberGenerator.new()
var queue: Array = []   ## 待吐的点数，先进先出
var forced := 0         ## 一共强吐了几次（对账用）

var seed: int:
	set(v):
		inner.seed = v
	get:
		return inner.seed

var state: int:
	set(v):
		inner.state = v
	get:
		return inner.state


func randi_range(from: int, to: int) -> int:
	if from == to:
		return from
	if not queue.is_empty():
		var v := int(queue.pop_front())
		if v < from or v > to:
			push_error("rig_rng：排进队列的点数 %d 不在 [%d, %d] 里" % [v, from, to])
		inner.randi_range(from, to)   ## 照样推进内部状态
		forced += 1
		return v
	return inner.randi_range(from, to)


func randi() -> int:
	return inner.randi()
