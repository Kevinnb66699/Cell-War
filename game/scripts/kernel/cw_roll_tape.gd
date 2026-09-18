## cw_roll_tape.gd —— 带子替身（测试迁移规格 A-7 / A-1 的 `rolls`：`[[from, to, value], …]`）。
## 此前是 tests/l0_runner.gd 的内部类 RollTape；新手引导（方案 §1.7 / S0）要在产品代码里给关卡挂预设骰子，2026-09-19 上提到 scripts/kernel/。
## 不带 class_name（同 cw_world_loader.gd 的理由），用 preload 取。
##**不用 tests/xcheck_tape.gd**：那只在带子放完时直接下标越界，
## 而 GD 运行时错误不中断执行 —— 崩在带子上会印出一片假 ok。这里少掷一次、多掷一次都当场记账。
extends RefCounted

var inner := RandomNumberGenerator.new()
var tape: Array = []
var at := 0
var overrun := 0
var bad_range := 0

var seed: int:
	set(v): inner.seed = v
	get: return inner.seed

var state: int:
	set(v): inner.state = v
	get: return inner.state

## 退化区间在 Godot 里消耗 0 个随机数（xcheck_tape.gd 头注的实测），带子上也不留痕 —— 两侧必须同口径
func randi_range(from: int, to: int) -> int:
	if from == to:
		return from
	if at >= tape.size():
		overrun += 1
		return inner.randi_range(from, to)
	var e: Array = tape[at]
	at += 1
	if int(e[0]) != from or int(e[1]) != to:
		bad_range += 1
	inner.randi_range(from, to)   ## 照样推进内部状态：有人会偷看 rng.state
	return int(e[2])

func randi() -> int:
	return inner.randi()
