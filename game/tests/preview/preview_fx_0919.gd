extends SceneTree
## 2026-09-19 三条表现 issue 的对照图 / 动图素材 —— 给人看的工具，不是测试。
##
## #48 能量增损的通用飘字、#52 固化癌组织生成的像素弥散、#53 特效 bug 八条：
## 这些全是「动起来才看得出对不对」的东西（粒子从哪儿发出、图层压在谁上面、
## 血门是躺着还是立着），一帧静态图说明不了问题，所以这支**连拍整段**，
## 外面再用 `tools/make_fx_gif.py` 拼成动图（`--from-prefix <前缀> <输出.gif> [--fps] [--crop]`）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_fx_0919.gd -- <场景> <输出前缀>
## 场景：energy（#48，带右栏）· solid（#52 / #53 ⑥）· fx53（#53 ①②③④⑤⑦⑧）
## 出图：`<输出前缀>_000.png` … 按 FPS 逐帧，直到 END。
const WARMUP := 12
const FPS := 20.0
const END := { "energy": 2.6, "solid": 2.0, "fx53": 3.9 }

var _scene := "energy"
var _out := "user://fx0919"
var _board: Node2D
var _fx: CWSkillFx
var _energy: Node2D
var _beam: CWBeamFx
var _tp: CWTeleportFx
var _panel: CWMatchPanel
var _game: CWGame
var _mirror: CWMirror
var _cells: Array = []       ## [{ sprite, pos, cid }]
var _frames := 0
var _t := 0.0
var _shot := 0
var _script: Array = []      ## [[开演时刻, Callable], …]，按时间逐条放

const ENERGY_FX := preload("res://scripts/ui/energy_fx.gd")
## 三只细胞摆哪、用哪张贴图。免疫在左、癌在右 —— 两边的飘字都要看得见
const SPOTS: Array[Vector2i] = [Vector2i(-3, 0), Vector2i(1, -2), Vector2i(-2, 4), Vector2i(2, 2)]
## 2 号起手是**通用免疫细胞**：⑤ 那一拍当场分化成 B 细胞，才看得见交叉淡入淡出
const ART := ["tcell", "melanoma", "immune", "signet"]
const ITYPE := [CWData.ImmuneType.T_CELL, -1, CWData.ImmuneType.B_CELL, -1]
const CTYPE := [-1, CWData.CancerType.MELANOMA, -1, CWData.CancerType.SIGNET]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_scene = args[0]
	if args.size() > 1:
		_out = args[1]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	## 底色必须沉到最底：格子的 z **就是它自己的贴图 y**，后排是负数 ——
	## 底色留在 z=0 的话，棋盘后半张会被它整块盖掉（第一版就是这么丢了半个棋盘）
	bg.z_index = -4096
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	## 棋盘摆在左边那块（右边 264 留给竖条，同对局机位）
	_board.position = Vector2(348, 270)
	root.add_child(_board)

	_game = CWGame.new()
	_game.init(CWData.FACTION_ORDER[4], 11)
	_game.setup.build_board()
	## 席位次序照 FACTION_ORDER[4]（免疫 / 癌 / 免疫 / 癌），细胞手摆（同 preview_skill_fx 的做法）
	for i in SPOTS.size():
		var faction: int = CWData.FACTION_ORDER[4][i]
		var made := CWSetup.make_cell(i, i, faction, SPOTS[i], ITYPE[i], CTYPE[i])
		made["energy"] = 40 + i * 7
		_game.cells.append(made)
		if faction == CWData.Faction.CANCER:
			_game.tiles[SPOTS[i]]["tissue"] = CWData.Tissue.CANCER
	_mirror = CWMirror.new()
	_resync()

	_fx = CWSkillFx.new()
	_fx.z_index = _board.Z_OVER_BOARD
	_board.add_child(_fx)
	_energy = ENERGY_FX.new()
	_energy.z_index = _board.Z_OVER_BOARD
	_board.add_child(_energy)
	_beam = CWBeamFx.new()
	_beam.z_index = _board.Z_OVER_BOARD
	_board.add_child(_beam)
	_tp = CWTeleportFx.new()
	if _scene == "energy":
		_panel = CWMatchPanel.new()
		root.add_child(_panel)
		_panel.refresh(_mirror, Callable())


func _resync() -> void:
	var err := _mirror.sync_from(_game)
	if err != "":
		push_error("preview_fx_0919：镜像装载失败 —— %s" % err)


## 棋盘的 map 要等它自己 _ready 之后才有，所以格子贴图 / 细胞都在 WARMUP 那一帧再摆
func _setup_scene() -> void:
	for i in SPOTS.size():
		var c: Vector2i = SPOTS[i]
		_board.set_tissue(c, int(_game.tiles[c]["tissue"]), int(_game.tiles[c]["special"]), false, 0.0)
		var sp := Sprite2D.new()
		## 棋盘上的细胞用**呼吸表**（anim/*_breath.png，横排 6 帧），不是右栏那份居中摆的单帧图标
		sp.texture = load("res://assets/art/cells/anim/%s_breath.png" % ART[i])
		sp.hframes = CWMatch.BREATH_FRAMES
		sp.offset = Vector2(0, -sp.texture.get_height() / 2.0)  ## hframes 只切横向，高度不变
		sp.position = _at(c, true)
		sp.z_index = _board.tile_z(c, _board.Z_CELL)
		_board.add_child(sp)
		_cells.append({ "sprite": sp, "pos": c })
	match _scene:
		"energy": _script = _script_energy()
		"solid": _script = _script_solid()
		"fx53": _script = _script_fx53()


func _at(c: Vector2i, body := false) -> Vector2:
	return _board.tile_center(c) + Vector2(0, CWMatch.CELL_FOOT_DY if body else 0.0)


## 细胞中心（脚底再往上半个贴图高）—— 演出对准的就是这一点，同 CWMatch.cell_half_height
func _body(i: int) -> Vector2:
	var sp: Sprite2D = _cells[i]["sprite"]
	return sp.position - Vector2(0, sp.texture.get_height() / 2.0)


## 头顶再往上 4px：飘字从这儿起
func _head(i: int) -> Vector2:
	var sp: Sprite2D = _cells[i]["sprite"]
	return sp.position - Vector2(0, float(sp.texture.get_height()) + 4.0)


## 改一只细胞的能量，棋盘飘字 + 右栏色闪 + 右栏数字一起走（对局里由镜像差分触发，这儿手点）
func _bump(i: int, amount: int) -> void:
	_game.cells[i]["energy"] += amount
	_resync()
	_energy.push(i, _head(i), amount)
	if _panel != null:
		_panel.bump_energy(i, amount > 0)


## 分化换图（对局里由 CWMatch._apply_immune_art 在镜像差分认出 itype 变化时调，这儿手点）：
## 旧形态淡出、新形态淡入，同 tools/art-preview/common-skills.js:59
func _differentiate_to(i: int, art: String) -> void:
	var sp: Sprite2D = _cells[i]["sprite"]
	CWMatch.cross_fade_art(sp)
	sp.texture = load("res://assets/art/cells/anim/%s_breath.png" % art)
	sp.hframes = CWMatch.BREATH_FRAMES
	sp.offset = Vector2(0, -sp.texture.get_height() / 2.0)


## 跟着血流走的那一跳（issue #53 ④）：**对时走实装的那支纯函数**，参数一个不自己编 ——
## 动图里看到的缩小 / 放大时刻和真机一致，这条 issue 要看的就是这个
func _jump(i: int, to: Vector2i) -> void:
	var sp: Sprite2D = _cells[i]["sprite"]
	var from: Vector2i = _cells[i]["pos"]
	var ghost_pos := sp.position
	var ghost_z := sp.z_index
	_cells[i]["pos"] = to
	sp.position = _at(to, true)
	sp.z_index = _board.tile_z(to, _board.Z_CELL)
	var timing: Array = CWMatch.homing_teleport_timing(_fx.homing_elapsed(_at(from), _at(to)))
	_tp.play(_board, sp, i, ghost_pos, ghost_z, CWTeleportFx.edge_for(CWData.Faction.CANCER),
		maxf(float(timing[0]), 0.0), Callable(), float(timing[1]), bool(timing[2]))


# ---- 三个场景的时间表 ----

func _script_energy() -> Array:
	return [
		[0.15, func() -> void: _bump(0, 25)],      ## 有氧收入
		[0.55, func() -> void: _bump(1, -12)],     ## 挨了一下
		[0.62, func() -> void: _bump(1, -4)],      ## 同一拍的第二笔 → 并进上一条
		[1.00, func() -> void: _bump(2, -8)],      ## 迁移费
		[1.25, func() -> void: _bump(0, -5)],      ## 同一只的第二条 → 左右错峰
		[1.70, func() -> void: _bump(2, 18)],
	]


func _script_solid() -> Array:
	## 左边那格**生成**（粒子聚拢成六边形纹理），右边那格**解除**（纹理散成粒子）
	var form := Vector2i(-1, 1)
	var gone := Vector2i(3, -1)
	return [
		[0.10, func() -> void:
			_board.set_tissue(form, CWData.Tissue.SOLID, CWData.Special.NONE, false, 1.0)
			_fx.play("solid_form", { "at": _board.tile_center(form),
				"z": _board.tile_z(form, _board.Z_MARK) })],
		[0.10, func() -> void:
			_board.set_tissue(gone, CWData.Tissue.SOLID, CWData.Special.NONE, false, 1.0)],
		[1.00, func() -> void:
			_board.set_tissue(gone, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
			_fx.play("solid_break", { "at": _board.tile_center(gone),
				"z": _board.tile_z(gone, _board.Z_MARK) })],
	]


func _script_fx53() -> Array:
	## 细胞毒素铺在 3 号（癌）细胞脚下那一圈：看得出颗粒压在细胞**之下**（③）
	var ring: Array = [SPOTS[3]]
	for d in CWData.DIRS:
		ring.append(SPOTS[3] + d)
	var tiles: Array = []
	var zs: Array = []
	for c: Vector2i in ring:
		tiles.append(_board.tile_center(c))
		zs.append(_board.tile_z(c, _board.Z_MARK))
	return [
		## ① 抗体：中心 → 中心，命中后受击者横抖
		[0.10, func() -> void: _fx.play("antibody",
			{ "from_body": _body(0), "from": _at(SPOTS[0], true),
			  "targets": [_at(SPOTS[1], true)], "targets_body": [_body(1)] })],
		## ③ 细胞毒素：地面贴花，各拿自己那格的 z
		[0.35, func() -> void: _fx.play("toxin",
			{ "from": _body(0), "tiles": tiles, "tiles_z": zs })],
		## ④ 血门：躺在地上的伪 3D 圆圈
		[1.20, func() -> void: _fx.play("homing",
			{ "from": _at(SPOTS[1]), "to": _at(Vector2i(4, 2)), "spread": [_at(Vector2i(5, 1))] })],
		## ⑤ 分化：通用免疫细胞淡出、B 细胞淡入（原型第 59 行），粒子中心 = 胞体中心
		[1.40, func() -> void:
			_differentiate_to(2, "bcell")
			_fx.play("differentiate", { "at_body": _body(2) })],
		## ④ 癌细胞跟着血流走：血流入队 → 桥阻塞 BLOCK_FX_MS["homing"] 0.5 s → 才轮到镜像差分
		## 认出这一跳，所以这儿也等 0.5 s 再跳（时刻照实装算，见 _jump）
		[1.70, func() -> void: _jump(1, Vector2i(4, 2))],
		## ⑦ 突变：对准胞体中心（原来整束落在下半身）
		[1.70, func() -> void: _fx.play("mutate", { "at_body": _body(3) })],
		## ⑧ Excalibur：从细胞表面发出（起点胞体中心、起手偏移 = 胞体半径）
		[2.00, func() -> void:
			var sp: Sprite2D = _cells[0]["sprite"]
			var none: Array[Vector2] = []
			## 起手偏移 = **胞体半径**，同实装那条路（CWUIBridge.show_beam → CWMatch.cell_half_height）
			_beam.play(_body(0), _at(Vector2i(4, 0)), none, sp.texture.get_height() / 2.0)],
	]


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_setup_scene()
	var before := _t
	_t += d
	for e in _script:
		var at: float = float(e[0])
		if before <= at and _t > at:
			(e[1] as Callable).call()
	_fx.sync(d)
	_energy.sync(d)
	_beam.sync(d)
	## 受击震动由演出层代管（对局里是 CWMatch._sync_cells 每帧问一次），这儿照做
	for i in _cells.size():
		var sp: Sprite2D = _cells[i]["sprite"]
		sp.position = _at(_cells[i]["pos"], true) + _fx.shake_offset(_at(_cells[i]["pos"], true))
	if _panel != null:
		_panel.refresh(_mirror, Callable())
	if _t < float(_shot) / FPS:
		return false
	root.get_texture().get_image().save_png("%s_%03d.png" % [_out, _shot])
	_shot += 1
	return _t >= float(END.get(_scene, 2.0))
