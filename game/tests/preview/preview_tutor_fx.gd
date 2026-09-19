extends SceneTree
## 教程演出库 `cw_tutor_fx` 的真机对照图（拆片 S7）—— **给人看的工具，不是测试**。
##
## 为什么非得出图：这六种演出规则里都没有，无头测试只能证明「喂时间不报错、同一个 t 结果一样」，
## 证明不了**好不好看**。而本片里有两处是明着要 Kevin / hxr 挑的：
##   ① 像素错误三种表现（jitter 抖动 / blocks 色块错位 / scanlines 扫描线）—— hxr 未答口径，三种都做；
##      **Kevin 2026-09-19 定 `blocks` 为默认并加了「马赛克串台」**（错开的那几条里有一小片是别人的像素）,
##      所以 blocks 另出一段 `glitch_blocks_morph`：串台来源 = pool / morph_to，马赛克就是变身预告；
##   ② 自动重置提示三个候选（rewind 倒带 / edge 边缘红光 + 棋盘抖 / dissolve 溶解再浮现）——
##      Kevin 2026-09-19「两个都不好，重做」，这是重做的三版。
##
## 真 Board.tscn + **真机位**（`CWView.GAME_ZOOM` / `GAME_ANCHOR`，和对局一模一样）+ 真细胞贴图；
## 细胞的摆法照 `CWMatch._sync_cells`（脚底 = 格顶面中心 + CELL_FOOT_DY），
## 要代画的那一只把真节点交给 `args.node`，由演出库自己藏起来 —— 和真机同一条路径。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_tutor_fx.gd -- <输出目录>
##
## 逐帧倾倒（出动图用）：一次一段，从 0 到「收尾后再定格 DUMP_HOLD 秒」，每 1/12 秒一张：
##   godot --path game --script res://tests/preview/preview_tutor_fx.gd -- dump=reset_hint:rewind out=<目录>
## dump 认 SHOTS 里的名字，`kind:variant` 与 `kind_variant` 两种写法都行；
## 出来的是 `<名字>_000.png` 起的一串 960×540，再交给 tools/make_fx_gif.py 合成 GIF
const FX := preload("res://scripts/tutor/cw_tutor_fx.gd")
const WARMUP := 12                 ## 棋盘铺完、相机就位再开拍
const OUT_DEFAULT := "user://tutor_fx"
const DUMP_HOLD := 0.5             ## 逐帧模式：收尾之后再定格多久
const DUMP_STEP := 1.0 / FX.PIX_FPS   ## 一帧 = 演出库自己的量化格（1/12 秒）

## 一条 = 一段演出。`cells` 里每条是 [格, 贴图名]；`proxy` 指哪一只交给演出库代画；
## `tumor` 是要染成癌性组织的中心（半径 1）；`at` 是在哪几刻截图（秒）。
const SHOTS := [
	## ① 暗黑像素冲击波（PRD:393/411）：起 / 环推到中途 / 尾声
	{"name": "shockwave", "kind": "shockwave", "proxy": -1, "tumor": Vector2i(0, 0),
		"args": {"at": Vector2i(0, 0), "radius": 3},
		"cells": [[Vector2i(0, 0), "Melanoma"], [Vector2i(2, 0), "ImmuneBasic"],
			[Vector2i(-2, 1), "TCell"], [Vector2i(1, -2), "BCell"]],
		"at": [0.10, 0.35, 0.70]},

	## ② 像素错误 · 模式一：抖动（PRD:399 分化后转回普通免疫）
	## 三种模式都**把机位推近到 2.8**：对局机位下细胞只有 20 来个像素，错位两三格看不出来。
	## 取景参数其余照旧（同一台相机、同一套 CWView.apply），只是 zoom 抬上去
	{"name": "glitch_jitter", "kind": "glitch", "proxy": 0, "tumor": Vector2i(9, 9), "zoom": 2.8,
		"args": {"at": Vector2i(0, 0), "mode": "jitter", "intensity": "light",
			"morph_to": "ImmuneBasic", "seed": 20260919},
		"cells": [[Vector2i(0, 0), "Macrophage"], [Vector2i(2, 0), "ImmuneBasic"],
			[Vector2i(-2, 1), "TCell"]],
		"at": [0.20, 0.60, 1.10]},

	## ③ 像素错误 · 模式二：色块错位（同一段戏换一种表现）
	{"name": "glitch_blocks", "kind": "glitch", "proxy": 0, "tumor": Vector2i(9, 9), "zoom": 2.8,
		"args": {"at": Vector2i(0, 0), "mode": "blocks", "intensity": "light",
			"morph_to": "ImmuneBasic", "seed": 20260919},
		"cells": [[Vector2i(0, 0), "Macrophage"], [Vector2i(2, 0), "ImmuneBasic"],
			[Vector2i(-2, 1), "TCell"]],
		"at": [0.20, 0.60, 1.10]},

	## ③′ 像素错误 · **拍板的那一版**：blocks + 马赛克串台 + 随机切换 + 定格印戒细胞癌
	## （PRD:487-489）。串台块采的就是 `pool` / `morph_to` 里的贴图 —— 错开的那几条里
	## 会先闪出「将要变成的样子」，再定格成印戒细胞癌。第七关那一处用的就是这套参数
	{"name": "glitch_blocks_morph", "kind": "glitch", "proxy": 0, "tumor": Vector2i(0, 0),
		"zoom": 2.8,
		"args": {"at": Vector2i(0, 0), "mode": "blocks", "intensity": "heavy",
			"shuffle": true, "pool": ["ImmuneBasic", "TCell", "Melanoma", "Osteosarcoma"],
			"morph_to": "SignetRing", "seed": 20260919},
		"cells": [[Vector2i(0, 0), "Melanoma"], [Vector2i(2, 0), "ImmuneBasic"],
			[Vector2i(-2, 1), "TCell"]],
		"at": [0.30, 1.10, 1.85]},

	## ④ 像素错误 · 模式三：扫描线（**剧烈** + 随机切换 + 定格印戒细胞癌，PRD:487-489）
	{"name": "glitch_scanlines", "kind": "glitch", "proxy": 0, "tumor": Vector2i(0, 0), "zoom": 2.8,
		"args": {"at": Vector2i(0, 0), "mode": "scanlines", "intensity": "heavy",
			"shuffle": true, "pool": ["ImmuneBasic", "TCell", "Melanoma", "Osteosarcoma"],
			"morph_to": "SignetRing", "seed": 20260919},
		"cells": [[Vector2i(0, 0), "Melanoma"], [Vector2i(2, 0), "ImmuneBasic"],
			[Vector2i(-2, 1), "TCell"]],
		"at": [0.30, 1.10, 1.85]},

	## ⑤ 击退 + 受击（PRD:411/469/473）：挨打那一下 / 飞在半空 / 落地
	{"name": "knockback", "kind": "knockback", "proxy": 0, "tumor": Vector2i(-2, 0), "zoom": 2.0,
		"args": {"from": Vector2i(0, 0), "to": Vector2i(2, 0)},
		"cells": [[Vector2i(0, 0), "ImmuneBasic"], [Vector2i(-2, 0), "Melanoma"],
			[Vector2i(-1, -1), "TCell"]],
		"at": [0.08, 0.30, 0.58]},

	## ⑥ 效应应答变体（PRD:463-465/483）：蓄力 / 推出去 / **停在癌细胞胸前不贯穿**
	{"name": "beam_hit", "kind": "beam_hit", "proxy": -1, "tumor": Vector2i(2, 0),
		"args": {"from": Vector2i(-4, 0), "to": Vector2i(2, 0), "loop": true},
		"cells": [[Vector2i(-4, 0), "TCell"], [Vector2i(2, 0), "Melanoma"],
			[Vector2i(-4, 2), "BCell"]],
		"at": [0.30, 0.85, 1.50]},

	## ⑦ 地图浮现（PRD:45）：转调 board 的活跃集淡入，按 ring_delays 由内向外排队
	{"name": "reveal", "kind": "reveal", "proxy": -1, "tumor": Vector2i(9, 9),
		"args": {"coords": []},              ## 运行期填：半径 3 的整片
		"cells": [[Vector2i(0, 0), "ImmuneBasic"]],
		"at": [0.10, 0.30, 0.60]},

	## ⑧ 自动重置提示 · 候选 a「倒带」
	{"name": "reset_hint_rewind", "kind": "reset_hint", "proxy": -1, "tumor": Vector2i(1, 0),
		"args": {"variant": "rewind"},
		"cells": [[Vector2i(0, 0), "ImmuneBasic"], [Vector2i(1, 0), "Melanoma"],
			[Vector2i(-2, 1), "TCell"]],
		"at": [0.35, 0.95]},

	## ⑨ 自动重置提示 · 候选 b「边缘红光 + 棋盘抖一下」
	{"name": "reset_hint_edge", "kind": "reset_hint", "proxy": -1, "tumor": Vector2i(1, 0),
		"args": {"variant": "edge"},
		"cells": [[Vector2i(0, 0), "ImmuneBasic"], [Vector2i(1, 0), "Melanoma"],
			[Vector2i(-2, 1), "TCell"]],
		"at": [0.35, 0.95]},

	## ⑩ 自动重置提示 · 候选 c「细胞原地溶解再浮现」
	{"name": "reset_hint_dissolve", "kind": "reset_hint", "proxy": -1, "tumor": Vector2i(1, 0),
		"args": {"variant": "dissolve", "seed": 20260919},
		"cells": [[Vector2i(0, 0), "ImmuneBasic"], [Vector2i(1, 0), "Melanoma"],
			[Vector2i(-2, 1), "TCell"]],
		"at": [0.35, 0.95]},
]

var _out := OUT_DEFAULT
var _board: Node2D
var _cam: Camera2D
var _fx
var _sprites: Array[Sprite2D] = []
var _frames := 0
var _i := -1
var _k := 0
var _t := 0.0
var _save := ""
var _n := 0
var _dump := ""                 ## 非空 = 逐帧倾倒这一段（空 = 照旧出 30 张静帧）
var _dump_n := 0
var _dump_total := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		var s := str(a)
		if s.begins_with("dump="):
			_dump = s.substr(5).replace(":", "_")
		elif s.begins_with("out="):
			_out = s.substr(4).rstrip("/").rstrip("\\")
		else:
			_out = s.rstrip("/").rstrip("\\")
	DirAccess.make_dir_recursive_absolute(_out)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_fx = FX.new()
	_fx.auto_play = false          ## 时间由本脚本喂，截图时刻才精确
	_fx.attach(_board)
	_board.add_child(_fx)
	print("[教程演出库 S7] 出图到 %s" % _out)


func _process(d: float) -> bool:
	_frames += 1
	if _frames == 1:
		## **相机要等进了树才认**（`_initialize` 里 make_current 会被 `!is_inside_tree()` 拒掉）
		_cam.make_current()
		CWView.apply(_cam, _board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
	if _frames < WARMUP:
		return false
	if _dump != "":
		return _dump_step()
	## 存的是**上一帧**渲染出来的画面，所以「推进」与「存盘」各占一帧
	if _save != "":
		root.get_texture().get_image().save_png(_save)
		print("  %s" % _save)
		_save = ""
		_k += 1
		return false
	if _i < 0 or _k >= (SHOTS[_i]["at"] as Array).size():
		_i += 1
		_k = 0
		if _i >= SHOTS.size():
			print("[教程演出库 S7] 共 %d 张" % _n)
			return true
		_setup(SHOTS[_i])
		_t = 0.0
		return false
	_fx.advance(d)
	_t += d
	if _t >= float((SHOTS[_i]["at"] as Array)[_k]):
		_save = "%s/%s_%d.png" % [_out, str(SHOTS[_i]["name"]), _k]
		_n += 1
	return false


## 逐帧倾倒一段演出。时间用 `seek()` 给（不收尾），超过时长那一帧才 `skip()`
## 收尾（代画的真节点还回去），剩下的帧就是「演完之后的盘面」定格。
## 和静帧一样，「喂时间」与「存盘」各占一帧 —— 存的是上一帧渲染出来的画面
func _dump_step() -> bool:
	if _save != "":
		root.get_texture().get_image().save_png(_save)
		_save = ""
		_dump_n += 1
		return false
	if _i < 0:
		_i = _find(_dump)
		if _i < 0:
			push_error("教程演出库：没这一段「%s」" % _dump)
			return true
		_setup(SHOTS[_i])
		_dump_total = int(ceilf((_fx.duration() + DUMP_HOLD) * FX.PIX_FPS))
		print("  逐帧倾倒 %d 帧 @%d fps" % [_dump_total, int(FX.PIX_FPS)])
		return false
	if _dump_n >= _dump_total:
		print("[教程演出库 S7] %s 共 %d 帧" % [_dump, _dump_total])
		return true
	var t := float(_dump_n) * DUMP_STEP
	if t < _fx.duration() - 0.0005:
		_fx.seek(t + 0.001)        ## 微推一下：别让浮点误差把量化掉到上一格
	elif _fx.running():
		_fx.skip()
	_save = "%s/%s_%03d.png" % [_out, str(SHOTS[_i]["name"]), _dump_n]
	return false


func _find(name: String) -> int:
	for j in SHOTS.size():
		if str(SHOTS[j]["name"]) == name:
			return j
	return -1


## 一段戏的台面：擦干净上一段 → 铺组织 → 摆细胞 → 交参数开演
func _setup(shot: Dictionary) -> void:
	_fx.clear()
	for s in _sprites:
		s.queue_free()
	_sprites.clear()
	_board.set_active_tiles(CWData.all_coords(), 0.0)
	for c in CWData.all_coords():
		_board.set_tissue(c, CWData.Tissue.HEALTHY, CWData.Special.NONE, false, 0.0)
	var tumor: Vector2i = shot["tumor"]
	for c in _around(tumor, 1):
		if _board.map.has(_board.axial_to_rc(c)):
			_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)

	var args: Dictionary = (shot["args"] as Dictionary).duplicate(true)
	var proxy := int(shot["proxy"])
	var made: Array[Sprite2D] = []
	var i := 0
	for cell in shot["cells"]:
		var sp := _cell(str((cell as Array)[1]), (cell as Array)[0])
		made.append(sp)
		if i == proxy:
			## 真机上那一格是有细胞节点的：交给演出库，由它藏起来自己代画
			args["node"] = sp
			args["tex"] = str((cell as Array)[1])
		i += 1
	_sprites = made

	match str(shot["kind"]):
		"reveal":
			## 先收到只剩中央一格，才有「新进集合」的格可浮现
			_board.set_active_tiles([Vector2i.ZERO], 0.0)
			args["coords"] = _around(Vector2i.ZERO, 3)
		"reset_hint":
			if str(args.get("variant", "")) == "dissolve":
				var list: Array = []
				var nodes: Array = []
				for j in shot["cells"].size():
					list.append({"at": (shot["cells"][j] as Array)[0],
						"tex": str((shot["cells"][j] as Array)[1])})
					nodes.append(made[j])
				args["cells"] = list
				args["nodes"] = nodes
	CWView.apply(_cam, _board, float(shot.get("zoom", CWView.GAME_ZOOM)),
		shot.get("look", CWView.GAME_LOOK_AT), CWView.GAME_ANCHOR)
	_fx.begin(str(shot["kind"]), args)
	print("· %s（%s，时长 %.2fs）" % [str(shot["name"]), str(shot["kind"]), _fx.duration()])


func _cell(art: String, at: Vector2i) -> Sprite2D:
	var sp := Sprite2D.new()
	var tex: Texture2D = FX.CELL_ART[art]
	sp.texture = tex
	sp.hframes = CWMatch.BREATH_FRAMES
	sp.offset = Vector2(0, -tex.get_height() / 2.0)
	sp.position = _board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY)
	sp.z_index = _board.tile_z(at, _board.Z_CELL)
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_board.add_child(sp)
	return sp


func _around(at: Vector2i, r: int) -> Array:
	var out: Array = []
	for dq in range(-r, r + 1):
		for dr in range(maxi(-r, -dq - r), mini(r, -dq + r) + 1):
			var c := at + Vector2i(dq, dr)
			if _board.map.has(_board.axial_to_rc(c)):
				out.append(c)
	return out
