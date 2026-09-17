## xcheck_tape.gd —— 对拍用的「随机数带子」：录 / 放 两用的 rng 替身
##
## 鸭子类型，**没有 class_name**（不进 global_script_class_cache，不用 --import，不动热更基线）。
## `CWGame` 只用到 `seed` / `state` / `randi_range` 三样，这里就只实现这三样
## （`randi()` 只有 headless_test 用，顺手带上）。装法：`g.rng = tape` ——
## 这一步靠 `cw_game.gd` 那行 `var rng: Object` 的弱类型，有一条护栏测试盯着它别被改回静态类型。
##
## ⚠ `randi_range(n, n)` 在 Godot 里**消耗 0 个随机数**（实测：2 人局 515 次调用只前进 485 步），
## 所以带子上不留痕 —— C# 那边的 `NextIntRange` 必须同样把退化区间定义成零消耗，
## 否则从第一个单选项处就错位（对拍规格 §L1 带子·规矩 1）。
extends RefCounted

var inner := RandomNumberGenerator.new()
var tape: Array = []        ## [[from, to, value], ...]，全闭区间
var at := 0                 ## 放音游标
var playing := false
var mark := 0               ## 上一次 take() 的位置

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
	if playing:
		var e: Array = tape[at]
		at += 1
		inner.randi_range(from, to)   ## 照样推进内部状态：有人（启发式桥）会偷看 rng.state
		return int(e[2])
	var v: int = inner.randi_range(from, to)
	tape.append([from, to, v])
	return v


func randi() -> int:
	return inner.randi()


## 自上次 take() 以来录到的那一段
func take() -> Array:
	var out: Array = tape.slice(mark)
	mark = tape.size()
	return out
