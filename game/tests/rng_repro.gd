## rng_repro.gd -- 验证「rng 进 state」能否精确复刻真实游戏的随机序列
##
## 真实方式（cw_game.gd）：持久 RNG，seed 一次，连续 randi_range。
## 迁移方式（elm 化）：seed 派生出初始 state 存进 state 字典；
##   之后每次掷骰 new RNG + r.state=保存的state + randi_range + 读回新 state。
##
## 两者序列必须逐位一致（同种子可复现、锁步联机的前提）。
extends SceneTree


func _init():
	# ---- 真实方式 ----
	var a := RandomNumberGenerator.new()
	a.seed = 12345
	var seq_a: Array = []
	for i in 10:
		seq_a.append(a.randi_range(0, 5))

	# ---- 迁移方式 ----
	var b := RandomNumberGenerator.new()
	b.seed = 12345
	var st: int = b.state
	var seq_b: Array = []
	for i in 10:
		var r := RandomNumberGenerator.new()
		r.state = st
		var v: int = r.randi_range(0, 5)
		st = r.state
		seq_b.append(v)

	print("真实方式 seq: ", seq_a)
	print("迁移方式 seq: ", seq_b)
	print("序列一致: ", seq_a == seq_b)

	# 再验证 pick_random(1) 这种「先取模 randi_range(0,n-1)」形态
	var c := RandomNumberGenerator.new()
	c.seed = 999
	var stc: int = c.state
	var pool := [10, 20, 30, 40, 50]
	var out_c: Array = []
	for i in 5:
		out_c.append(pool.pop_at(c.randi_range(0, pool.size() - 1)))
	var pool2 := [10, 20, 30, 40, 50]
	var out_e: Array = []
	for i in 5:
		var rr := RandomNumberGenerator.new()
		rr.state = stc
		var vv: int = rr.randi_range(0, pool2.size() - 1)
		stc = rr.state
		out_e.append(pool2.pop_at(vv))
	print("pick_random 真实: ", out_c)
	print("pick_random 迁移: ", out_e)
	print("pick_random 一致: ", out_c == out_e)
	quit()
