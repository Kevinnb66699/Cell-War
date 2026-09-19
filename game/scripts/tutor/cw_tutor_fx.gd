## cw_tutor_fx.gd —— 新手教程 v2 的「教程演出库」（方案 §1.4 第 ② 类演出 / 拆片 S7）
##
## 这里装的六种演出**规则里一种都没有**：暗黑像素冲击波、像素错误、击退受击、
## 命中不贯穿的效应应答、地图浮现、自动重置提示。引擎一行都不知道它们存在，所以这一层有三条纪律：
##
##   ① **绝不入内核演出队列**（`CWPlayQueue`），更绝不碰内核 rng。教程那几关的骰子是**预设带子**，
##      多掷一次整条错位，而 `cw_roll_tape.gd:26-28` 的 overrun 是**静默**回落真 rng —— 错了不报。
##      本文件的随机只走自带的 `RandomNumberGenerator`，种子从 `args.seed` 来（缺省 0 = 逐帧可复现），
##      而且是在 `begin()` 里**一次摇完存进 `_plan`**，`probe(t)` 只查表。
##      源码闸在 `t_tutor_fx` 里盯着：不许出现 `game.` / `CWGame` / 裸 `randi(` / `randf(`。
##
##   ② **整段是时间的纯函数**：`probe(t)` 把这一刻的画面算成一个字典，`_apply(t)` = `probe(t)` + 落盘；
##      时间量化到 1/12 秒（`PIX_FPS`，同 `CWSkillFx` / `tutorial_opening.gd:459`）。
##      好处有三：`skip()` = 跳到末刻一步到位；无头测试自己喂时间、不用真等；同一个 t 喂两遍结果一样。
##
##   ③ **不改任何公共特效**。PRD:465「修改效应应答特效让其命中于癌细胞上而非贯穿」在这里是
##      **教程自己的变体**（kind `beam_hit`）—— `scripts/ui/beam_fx.gd` 一个字都不动，
##      那支真人对局也在用，改它回归面会溢出教程之外（方案 §4 的 463/483 行）。
##
## **没有 class_name**（方案 §1.5）：新全局类进不了热更补丁。用法是 preload：
##     const FX := preload("res://scripts/tutor/cw_tutor_fx.gd")
##     var fx = FX.new()
##     fx.attach(board)          ## 设 board 与 z 序
##     board.add_child(fx)
##     await fx.play("shockwave", {"at": Vector2i(0, 0), "radius": 3})
##
## 坐标系：本节点挂在 **Board 底下**，画的都是棋盘局部坐标（`board.tile_center` 直接用）。
## 只有重置提示的文字与边缘红光是屏幕层的，走自带的 `CanvasLayer`。
##
## **席位不认识**：`args.target` 允许写席位号，但解析要靠导演注入的 `seat_at` Callable ——
## 演出层碰不到内核，自己换不出坐标（方案 §3.7 的同一条纪律）。
extends Node2D

## 逐帧步进：同 CWSkillFx.PIX_FPS / CWChemoFx.PIX_FPS / tutorial_opening.PIX_FPS
const PIX_FPS := 12.0
const KINDS := ["shockwave", "glitch", "knockback", "beam_hit", "reveal", "reset_hint"]

## 细胞贴图：**横排 6 帧静息呼吸表**，和棋盘上的细胞同一批（同 tutorial_opening.CELL_ART 的做法，
## 按词条名建表、不去认识内核的类型枚举）。`args.tex` / `args.morph_to` 可以直接给 Texture2D，
## 也可以给这张表里的名字。
const CELL_ART := {
	"ImmuneBasic": preload("res://assets/art/cells/anim/immune_breath.png"),
	"TCell": preload("res://assets/art/cells/anim/tcell_breath.png"),
	"BCell": preload("res://assets/art/cells/anim/bcell_breath.png"),
	"Macrophage": preload("res://assets/art/cells/anim/macrophage_breath.png"),
	"Dendritic": preload("res://assets/art/cells/anim/dendritic_breath.png"),
	"Melanoma": preload("res://assets/art/cells/anim/melanoma_breath.png"),
	"SignetRing": preload("res://assets/art/cells/anim/signet_breath.png"),
	"Osteosarcoma": preload("res://assets/art/cells/anim/osteo_breath.png"),
	"SmallCellLung": preload("res://assets/art/cells/anim/sclc_breath.png"),
}
const BREATH_FRAMES := 6      ## 同 CWMatch.BREATH_FRAMES
const BREATH_FPS := 6.0       ## 同 CWMatch.BREATH_FPS
const CELL_FOOT_DY := 6.0     ## 同 CWMatch.CELL_FOOT_DY：脚底落在格顶面中心再往下 6px
const BODY_DY := 14.0         ## 胸口 ≈ 脚底上方这么多（同 CWUIBridge.show_fx 取的半高量级）
const FONT := preload("res://assets/fonts/fusion_pixel_10px.ttf")

## 冲击波（PRD:393/411）
const SHOCK_STEP := 0.10      ## 每环错峰多少秒（喂给 board.ring_delays）
const SHOCK_HIT := 0.26       ## 一格被扫到之后暗多久。**要短于「错峰 × 环数」**，否则整片同时黑、看不出「扩散」
const SHOCK_WIDTH := 0.55     ## 同时留在画面上的环有几秒厚
const SHOCK_TAIL := 0.30
const DARK_A := Color("120a16")   ## 近黑紫：格上那团暗斑
const DARK_B := Color("2b1338")   ## 环
const DARK_C := Color("6b2f7a")   ## 环缘 / 碎粒

## 像素错误（PRD:399/403/487）
const GLITCH_MODE := "blocks"   ## 缺省表现（Kevin 2026-09-19 拍板：三选一定「色块错位」）
const GLITCH_SECS := {"light": 1.2, "heavy": 2.0}
const GLITCH_SLICES := 5      ## blocks 模式把胞体横切几条
const GLITCH_BARS := 3        ## scanlines 模式同时几条暗带
const MORPH_AT := 0.80        ## 演到这个比例就把贴图换成 morph_to
const SHUFFLE_AT := 0.20      ## 随机切换从这个比例开始（PRD:487）
## **马赛克串台**（Kevin 2026-09-19，看完动图改的口径：**以像素为单位，不是以一块矩形为单位**）：
## blocks 模式下，错开的那几条里**逐像素**各掷一次 —— 中了的那个像素画的不是自己的，
## 而是 `pool` / `morph_to` 的贴图**同一位置**那一个像素，像被撒了一层别人的像素噪点在身上闪。
## 间章「分化→普通」「免疫→小细胞肺癌」与第七关「随机切换→定格印戒」这三处，
## 串台来源正好就是「将要变成的样子」，噪点本身就成了预告；**定格之后整个关掉**。
##
## 逐像素怎么还能算「随机全在 begin() 里摇完」：`begin()` 摇的是**每一帧一颗种子**（外加这一帧的密度），
## 每个像素中不中是拿「种子 + 像素坐标」算的一个整数哈希（`_pix_noise`）—— 纯函数、零随机流，
## 所以 `probe(t)` 依旧只查表，同一个 t 喂两遍仍然逐像素相同。
const MOSAIC_DENSITY := {"light": Vector2(0.08, 0.15), "heavy": Vector2(0.25, 0.40)}
## 同一批噪点连着几帧再重掷。**定的是 1 = 每帧重掷**：调到 3 逐帧截下来比过，看不出差别 ——
## 胞体本来就每帧在错动，冻住的噪点跟着一起动，照样是新的一片
const MOSAIC_HOLD := 1
## 没给 `pool` / `morph_to` 时的替补来源：**同阵营另一种细胞**（照 CELL_ART 的名字分阵营，
## 演出层不认识内核的类型枚举）
const MOSAIC_KIN := {
	"immune": ["ImmuneBasic", "TCell", "BCell", "Macrophage", "Dendritic"],
	"cancer": ["Melanoma", "SignetRing", "Osteosarcoma", "SmallCellLung"],
}
const INK_CYAN := Color("30d1fa")   ## 色差重影：同 CWStyle.IMMUNE
const INK_MAGENTA := Color("ff5ec4")

## 击退受击（PRD:411/469/473）
const KNOCK_SECS := 0.62
const KNOCK_WAIT := 0.10      ## 挨了这么久才被推出去（先看见受击、再看见位移）
const KNOCK_FLASH := 0.16
const KNOCK_ARC := 6.0        ## 被推出去时抛起多少像素
const INK_HIT := Color("ffb03a")    ## 同 CWStyle.CANCER

## 效应应答变体（PRD:463-465/483）：形态照 beam_fx 的双螺旋，**止于目标胸前、不贯穿**
const BEAM_CHARGE := 0.50
const BEAM_REACH := 0.40
const BEAM_HOLD := 0.90
const BEAM_LOOP := 0.60       ## loop 时命中处那一下脉冲的周期
const BEAM_START := 16.0      ## 光束从发动者身上偏出多少才起头
const BEAM_HALT := 10.0       ## **不贯穿的那 10 个像素**：光束在目标胸前这么远就停住
const BEAM_SWELL := 7.0
const BEAM_TWIST := 0.1
const BEAM_SPIN := 9.0
const INK_BEAM_A := Color("e3c071")
const INK_BEAM_B := Color("fff3c5")
const INK_BEAM_CORE := Color("faf3d4")

## 自动重置提示（PRD:47）：三个候选，`args.variant` 选一
const RESET_SECS := 1.5
const RESET_TEXT := "本关重置"
const RESET_VARIANTS := ["rewind", "edge", "dissolve"]
const RESET_VARIANT := "rewind"   ## 缺省候选（Kevin 2026-09-19 拍板：三选一定「倒带」）
const INK_RESET := Color("ff4d5a")
const INK_TEXT := Color("eaf8fc")   ## 同 CWStyle.TEXT_HI
const SCREEN_LAYER := 60

## 注入件 ────────────────────────────────────────────────────────────
var board                       ## Board.tscn 的实例。**不标类型**：board.gd 没有 class_name
var seat_at := Callable()       ## 席位 -> 格坐标；导演注入（演出层不认识席位）
var auto_play := true           ## 真机由 _process 喂时间；测试置 false 自己调 advance()
var rng_seed := 0               ## args.seed 缺省时用它

var _kind := ""
var _args := {}
var _t := 0.0
var _dur := 0.0
var _running := false
var _loop := false
var _rng := RandomNumberGenerator.new()
var _plan := {}                 ## begin() 时一次摇好的随机表 + 预算量；probe() 只查表
var _state := {}                ## 这一帧的画面（= probe(t) 的结果）。**末帧留着**，skip() 之后还能问
var _hidden: Array = []         ## 被本段代画而临时藏起来的真节点
var _imgs := {}                 ## 贴图 -> Image（串台逐像素取色用；纯缓存，不进 _plan）
var _shake_home := {}           ## 抖动节点 -> 原位（reset_hint 的 edge 候选）
var _add: Painter               ## 叠加混合层：受击闪白 / 命中高光
var _screen: CanvasLayer
var _sky: ScreenPaint                   ## 屏幕层画布（重置提示的文字与边缘红光）


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_add = Painter.new()
	_add.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_add.z_index = 1
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_add.material = mat
	_add.paint = _paint_add
	add_child(_add)
	_screen = CanvasLayer.new()
	_screen.layer = SCREEN_LAYER
	add_child(_screen)
	_sky = ScreenPaint.new()
	_sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sky.paint = _paint_screen
	_screen.add_child(_sky)
	_sky.size = _sky.get_viewport_rect().size


## 认一张棋盘。z 序照 board 自己的「压在所有格之上」那一档（同 preview_beam.gd 的做法）
func attach(b) -> void:
	board = b
	if b != null:
		z_index = b.Z_OVER_BOARD


func _process(delta: float) -> void:
	if _running and auto_play:
		advance(delta)


# ── 对外的四个动词 ──────────────────────────────────────────────────

## 播一段，**播完才返回**（协程）。导演在这期间已经把操作闸关死了（方案 §3.4）
func play(kind: String, args: Dictionary) -> void:
	begin(kind, args)
	while _running and is_inside_tree():
		await get_tree().process_frame


## 一步到位：跳到末刻、落一次盘、收尾。`loop` 的那种（beam_hit）也靠这一下停
func skip() -> void:
	if not _running:
		return
	if _kind == "reveal":
		board.set_active_tiles(_coords(_args), 0.0)
	_loop = false
	_t = _dur
	_apply(_dur)
	_finish()


## 装配：认参数、摇随机、算时长、做一次性的转调（reveal）与代画准备，然后落第 0 帧。
## 真机走 play()；无头测试走 begin() + advance()，不用真等
func begin(kind: String, args: Dictionary) -> void:
	clear()
	if not (kind in KINDS):
		push_warning("教程演出库：不认识的 kind「%s」（认得的只有 %s）" % [kind, str(KINDS)])
		return
	_kind = kind
	_args = args.duplicate()
	_rng.seed = int(_args.get("seed", rng_seed))
	_plan = _roll()
	_dur = _duration_of()
	_loop = bool(_args.get("loop", false)) and kind == "beam_hit"
	_t = 0.0
	_running = true
	visible = true
	_prepare()
	_apply(0.0)


## 拆局 / 换代：把这一层擦干净并还原一切副作用。**每支演出都要有这个**——
## 它们靠 advance() 推进，也靠 advance() 把自己收走；没人再喂时间的话，最后那一帧会永远留在屏幕上
func clear() -> void:
	_restore()
	_running = false
	_loop = false
	_kind = ""
	_args = {}
	_plan = {}
	_state = {}
	_t = 0.0
	_dur = 0.0
	visible = false
	_redraw()


func duration() -> float:
	return _dur


func running() -> bool:
	return _running


func now() -> float:
	return _t


## 这一刻画在屏上的是哪张贴图（`morph_to` / 随机切换的验收口径）
func current_tex() -> Texture2D:
	var pool: Array = _plan.get("pool", [])
	var i := int(_state.get("tex", -1))
	if i < 0 or i >= pool.size():
		return null
	return pool[i]


## 马赛克串台这一块采的是谁的贴图（`_state.mosaic` 条目里的第 2 个数）
func mosaic_tex(i: int) -> Texture2D:
	var src: Array = _plan.get("mosaic_src", [])
	if i < 0 or i >= src.size():
		return null
	return src[i]


## 喂时间。真机由 _process 调；无头测试自己调
func advance(delta: float) -> void:
	if not _running:
		return
	_t += delta
	_apply(_t)
	if not _loop and _t >= _dur:
		_finish()


## 跳到某一刻（不收尾）。测试的幂等判据用它
func seek(to: float) -> void:
	_t = maxf(to, 0.0)
	_apply(_t)


# ── 时间的纯函数 ────────────────────────────────────────────────────

## 这一刻的画面。**只读 `_kind` / `_args` / `_plan` / `_dur`，不摇随机、不碰节点** ——
## 所以同一个 t 喂两遍结果一定相同，中间搅多少全局随机数都影响不到它
func probe(t: float) -> Dictionary:
	var q := _quant(t)
	match _kind:
		"shockwave":
			return _probe_shock(q)
		"glitch":
			return _probe_glitch(q)
		"knockback":
			return _probe_knock(q)
		"beam_hit":
			return _probe_beam(q)
		"reveal":
			return {"kind": "reveal", "q": q, "n": _coords(_args).size()}
		"reset_hint":
			return _probe_reset(q)
	return {}


func _apply(t: float) -> void:
	_state = probe(t)
	## 落盘：这一层只有一处会动真节点 —— 重置提示的「棋盘抖一下」
	var off: Vector2 = _state.get("shake", Vector2.ZERO)
	for n: Node2D in _shake_home:
		n.position = (_shake_home[n] as Vector2) + off
	_redraw()


func _finish() -> void:
	_running = false
	_loop = false
	_restore()
	_redraw()


func _redraw() -> void:
	queue_redraw()
	if _add != null:
		_add.queue_redraw()
	if _sky != null:
		_sky.queue_redraw()


# ── 装配期的三件小事 ────────────────────────────────────────────────

## 一次性摇好本段要用的随机数。**全在这儿，probe() 里一颗都不摇**
func _roll() -> Dictionary:
	var out := {}
	match _kind:
		"shockwave":
			out["delays"] = board.ring_delays(_shock_full(), SHOCK_STEP)
		"glitch":
			var pool: Array = [_tex_of(_args.get("tex", "ImmuneBasic"))]
			for name in _args.get("pool", []):
				pool.append(_tex_of(name))
			out["morph"] = -1
			if _args.has("morph_to"):
				pool.append(_tex_of(_args["morph_to"]))
				out["morph"] = pool.size() - 1
			out["pool"] = pool
			## 随机切换只在 1..hi 里挑：0 是本体、末位是 morph_to（定格那一张不许提前抽到）
			out["hi"] = (pool.size() - 2) if int(out["morph"]) >= 0 else (pool.size() - 1)
			var amp: float = 7.0 if _heavy() else 2.0
			var n := int(floorf(_duration_of() * PIX_FPS)) + 2
			var rows: Array = []
			var picks: Array = []
			for _i in n:
				var slices: Array = []
				for _j in GLITCH_SLICES:
					slices.append(_rng.randf_range(-amp * 1.6, amp * 1.6))
				var bars: Array = []
				for _j in GLITCH_BARS:
					bars.append(_rng.randf())
				rows.append({
					"dx": _rng.randf_range(-amp, amp),
					"dy": _rng.randf_range(-amp * 0.5, amp * 0.5),
					"cut": _rng.randf(),
					"slices": slices,
					"bars": bars,
				})
				## 随机切换（PRD:487）只在 pool 的 1..n-1 里挑，0 是本体、末位是 morph_to
				picks.append(_rng.randi_range(1, maxi(int(out["hi"]), 1)))
			out["rows"] = rows
			out["picks"] = picks
			## 马赛克串台**只在 blocks 摇**：另两种模式的随机流一颗都不动，表现一帧不变
			out["mosaic_src"] = []
			out["mosaic"] = []
			if str(_args.get("mode", GLITCH_MODE)) == "blocks":
				## 来源：pool / morph_to（第 0 张是本体，不算）；一张都没给就退回同阵营另一种细胞
				var src: Array = pool.slice(1)
				if src.is_empty():
					src = _kin_pool(pool[0] if not pool.is_empty() else null)
				out["mosaic_src"] = src
				var band: Vector2 = MOSAIC_DENSITY["heavy" if _heavy() else "light"]
				var mos: Array = []
				mos.resize(n)
				var f := 0
				while f < n:
					var hold := _rng.randi_range(1, MOSAIC_HOLD)
					## 一帧 = [这一帧的噪点种子, 这一帧多大比例的像素被串]（像素中不中由 _pix_noise 算）
					var here: Array = ([_rng.randi(), _rng.randf_range(band.x, band.y)]
						if not src.is_empty() else [])
					for j in range(f, mini(f + hold, n)):
						mos[j] = here
					f += hold
				out["mosaic"] = mos
		"reset_hint":
			var delay: Array = []
			for _c in _args.get("cells", []):
				delay.append(_rng.randf_range(0.0, 0.30))
			out["delay"] = delay
	return out


func _duration_of() -> float:
	match _kind:
		"shockwave":
			var d: Array = (_plan.get("delays", {}) as Dictionary).values()
			var top: float = (d.max() as float) if not d.is_empty() else 0.0
			return top + SHOCK_HIT + SHOCK_TAIL
		"glitch":
			return float(_args.get("secs", GLITCH_SECS["heavy" if _heavy() else "light"]))
		"knockback":
			return float(_args.get("secs", KNOCK_SECS))
		"beam_hit":
			return BEAM_CHARGE + BEAM_REACH + BEAM_HOLD
		"reveal":
			var rd: Dictionary = board.ring_delays(_coords(_args), board.ACTIVE_RING_DELAY)
			var vals: Array = rd.values()
			var lead: float = (vals.max() as float) if not vals.is_empty() else 0.0
			return lead + float(_args.get("secs", board.ACTIVE_FADE))
		"reset_hint":
			return float(_args.get("secs", RESET_SECS))
	return 0.0


## 一次性的转调与代画准备
func _prepare() -> void:
	## 地图浮现（PRD:45）：board 已经有按 ring_delays 错峰的活跃集淡入，**转调、不重写**
	if _kind == "reveal":
		board.set_active_tiles(_coords(_args), float(_args.get("secs", board.ACTIVE_FADE)))
	## 本层要代画的那几只，真节点先藏起来（同 CWAttackFx 的做法），收尾时还回去
	_hide(_args.get("node", null))
	for n in _args.get("nodes", []):
		_hide(n)
	if _kind == "reset_hint" and str(_args.get("variant", RESET_VARIANT)) == "edge":
		var sh = _args.get("shake_node", board)
		if sh is Node2D:
			_shake_home[sh] = (sh as Node2D).position


func _hide(n) -> void:
	if n is CanvasItem and (n as CanvasItem).visible:
		(n as CanvasItem).visible = false
		_hidden.append(n)


func _restore() -> void:
	for n in _hidden:
		if is_instance_valid(n):
			(n as CanvasItem).visible = true
	_hidden.clear()
	for k: Node2D in _shake_home:
		if is_instance_valid(k):
			k.position = _shake_home[k]
	_shake_home.clear()


# ── ① 暗黑像素冲击波（PRD:393/411）────────────────────────────────────

## 以 args.at 为心、半径 args.radius（缺省 3）的**整个对称邻域**（越界的格也留着）——
## 这样 `board.ring_delays` 取到的重心正好是 at，错峰就是「由内向外一环一环」。
## 画的时候才把盘外的格滤掉
func _shock_full() -> Array:
	var at := _coord(_args.get("at", _args.get("target", Vector2i.ZERO)))
	var r: int = maxi(int(_args.get("radius", 3)), 1)
	var out: Array = []
	for dq in range(-r, r + 1):
		for dr in range(maxi(-r, -dq - r), mini(r, -dq + r) + 1):
			out.append(at + Vector2i(dq, dr))
	return out


func _probe_shock(q: float) -> Dictionary:
	var at := _coord(_args.get("at", _args.get("target", Vector2i.ZERO)))
	var delays: Dictionary = _plan.get("delays", {})
	var tiles: Array = []
	for c: Vector2i in delays:
		if not board.map.has(board.axial_to_rc(c)):
			continue
		var p := CWPix.phase(q, float(delays[c]), SHOCK_HIT)
		if p <= 0.0 or p >= 1.0:
			continue
		tiles.append([board.tile_center(c), _steps(sin(p * PI) * 0.8)])
	var rings: Array = []
	var lead := q / SHOCK_STEP
	var rmax: int = maxi(int(_args.get("radius", 3)), 1) + 1
	var k := 0
	while k <= rmax:
		var age := (lead - float(k)) * SHOCK_STEP
		if age >= 0.0 and age <= SHOCK_WIDTH:
			rings.append([float(k) * float(board.distance_x), _steps(1.0 - age / SHOCK_WIDTH)])
		k += 1
	return {
		"kind": "shockwave", "q": q, "at": board.tile_center(at),
		"rings": rings, "tiles": tiles,
		"burst": _steps(CWPix.phase(q, 0.0, float(rmax) * SHOCK_STEP)),
		"span": float(rmax) * float(board.distance_x),
	}


func _draw_shock() -> void:
	var sq := _squash()
	var at: Vector2 = _state["at"]
	for row: Array in _state.get("tiles", []):
		var ink := DARK_A
		ink.a = row[1]
		CWPix.disc(self, row[0], 11.0, ink, sq)
		var rim := DARK_C
		rim.a = _steps(float(row[1]) * 0.7)
		CWPix.ring(self, row[0], 13.0, rim, sq)
	for row: Array in _state.get("rings", []):
		var ink2 := DARK_B
		ink2.a = row[1]
		CWPix.ring(self, at, row[0], ink2, sq)
		var ink3 := DARK_C
		ink3.a = _steps(float(row[1]) * 0.5)
		CWPix.ring(self, at, maxf(float(row[0]) - 3.0, 0.0), ink3, sq)
	var p: float = _state.get("burst", 0.0)
	if p > 0.0 and p < 1.0:
		var dust := DARK_C
		dust.a = _steps(1.0 - p)
		CWPix.burst(self, at, p, dust, 26, float(_state.get("span", 60.0)))


# ── ② 像素错误（PRD:399/403/487）三种表现 ──────────────────────────────

func _heavy() -> bool:
	var s := str(_args.get("intensity", "light"))
	return s == "heavy" or s == "剧烈"


## 这一帧的噪点种子与密度（**查表，不摇随机**）
func _mosaic_at(i: int) -> Array:
	var mos: Array = _plan.get("mosaic", [])
	if i < 0 or i >= mos.size() or not (mos[i] is Array):
		return []
	return (mos[i] as Array).duplicate(true)


## 这一帧哪些像素被串了：`[[x, y, 采谁], …]`，坐标是**本体贴图一帧之内**的像素位。
## **画与断言都走这一支**，两边口径就不会分家；纯函数（只看 `_state` 里那颗种子与密度）
func mosaic_pixels() -> Array:
	var m: Array = _state.get("mosaic", [])
	var tex := current_tex()
	var srcn: int = (_plan.get("mosaic_src", []) as Array).size()
	if m.size() < 2 or tex == null or srcn <= 0:
		return []
	var s := int(m[0])
	var d := float(m[1])
	var w := int(_fw(tex))
	var h := int(_fh(tex))
	var out: Array = []
	for y in h:
		for x in w:
			if _pix_noise(s, x, y) < d:
				out.append([x, y, int(_pix_noise(s + 977, x, y) * float(srcn)) % srcn])
	return out


## 一个像素中不中：拿「这一帧的种子 + 像素坐标」算整数哈希取 [0,1)。
## **纯函数、零随机流** —— 逐像素掷点要是真去摇 rng，`probe(t)` 就不再是查表的了
func _pix_noise(s: int, x: int, y: int) -> float:
	var h := (s * 374761393) ^ (x * 668265263) ^ (y * 2147483647)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h ^ (h >> 16)) & 0xFFFFFF) / 16777216.0


## 串台要逐像素取色，贴图的 Image 取一次存着（纯缓存，取几次结果都一样）
func _img(tex: Texture2D) -> Image:
	if tex == null:
		return null
	if not _imgs.has(tex):
		_imgs[tex] = tex.get_image()
	return _imgs[tex]


## 没给 pool / morph_to 时的替补来源：同阵营的别的细胞（本体那张除外）
func _kin_pool(own: Texture2D) -> Array:
	var name := ""
	for k in CELL_ART:
		if CELL_ART[k] == own:
			name = str(k)
			break
	var camp := "cancer" if (MOSAIC_KIN["cancer"] as Array).has(name) else "immune"
	var out: Array = []
	for k2 in MOSAIC_KIN[camp]:
		var t: Texture2D = CELL_ART[k2]
		if t != own:
			out.append(t)
	return out


func _probe_glitch(q: float) -> Dictionary:
	var rows: Array = _plan.get("rows", [])
	if rows.is_empty():
		return {"kind": "glitch", "q": q}
	var i: int = clampi(_frame(q), 0, rows.size() - 1)
	var row: Dictionary = rows[i]
	var heavy := _heavy()
	var p := clampf(q / maxf(_dur, 0.001), 0.0, 1.0)
	## 轻：只有一部分帧真的错开（看着像偶发故障）；剧烈：帧帧都错，整只还在抖
	var on: bool = heavy or float(row["cut"]) < 0.55
	var off := Vector2(float(row["dx"]), float(row["dy"])) if on else Vector2.ZERO
	if heavy:
		off += Vector2(sin(q * 47.0) * 2.0, cos(q * 61.0))
	var pool: Array = _plan.get("pool", [])
	var morph := int(_plan.get("morph", -1))
	var tex := 0
	if morph >= 0 and p >= MORPH_AT:
		tex = morph                                  ## 末段定格：分化→普通 / 免疫→小细胞肺癌 / 印戒
	elif int(_plan.get("hi", 0)) >= 1 and p >= SHUFFLE_AT and bool(_args.get("shuffle", false)):
		tex = clampi(int((_plan["picks"] as Array)[i]), 0, int(_plan["hi"]))
	var mode := str(_args.get("mode", GLITCH_MODE))
	var out := {
		"kind": "glitch", "q": q, "mode": mode, "heavy": heavy, "p": p,
		"foot": _foot(_coord(_args.get("at", _args.get("target", Vector2i.ZERO)))),
		"off": off.round(), "tex": tex, "frame": _breath(q),
		"alpha": _steps(0.4 if (on and float(row["cut"]) < 0.12) else 1.0),
		"slices": [], "bars": [], "roll": 0.0, "mosaic": [],
	}
	if mode == "blocks":
		out["slices"] = (row["slices"] as Array).duplicate() if on else []
		## 串台只跟着**错开的**那几条走（没错位的帧整只都是自己的），定格成 morph_to 之后整个关掉
		out["mosaic"] = _mosaic_at(i) if (on and tex != morph) else []
	elif mode == "scanlines":
		out["bars"] = (row["bars"] as Array).duplicate()
		out["roll"] = _steps(fmod(q * 0.75, 1.0))
	return out


func _draw_glitch() -> void:
	var tex := current_tex()
	if tex == null:
		return
	var foot: Vector2 = _state["foot"]
	var off: Vector2 = _state["off"]
	var fr := int(_state["frame"])
	var tint := Color(1.0, 1.0, 1.0, float(_state["alpha"]))
	match str(_state["mode"]):
		"jitter":
			## 抖动 + 色差重影：本体在 off 上，冷暖两道影子往反方向各偏一点
			var ghost := Vector2(-off.x, 0.0) * 1.6
			var cyan := INK_CYAN
			cyan.a = 0.5 * tint.a
			var mag := INK_MAGENTA
			mag.a = 0.5 * tint.a
			_blit(self, tex, fr, foot, off + ghost, 0.0, 1.0, cyan)
			_blit(self, tex, fr, foot, off - ghost, 0.0, 1.0, mag)
			_blit(self, tex, fr, foot, off, 0.0, 1.0, tint)
		"blocks":
			## 色块错位：胞体横切 GLITCH_SLICES 条，每条各自横移
			var slices: Array = _state["slices"]
			var n: int = maxi(slices.size(), 1)
			for j in n:
				var dx: float = float(slices[j]) if j < slices.size() else 0.0
				_blit(self, tex, fr, foot, off + Vector2(dx, 0.0),
					float(j) / float(n), float(j + 1) / float(n), tint)
			## 马赛克串台：**逐像素**盖上去 —— 中了的那个像素画的是别人贴图同一位置的那一个像素，
			## 像撒了一层别人的像素噪点在身上闪。跟着所在的那一条一起错开，才像是「同一只细胞坏了」
			var fh := _fh(tex)
			var fw := _fw(tex)
			var top := foot + off - Vector2(fw / 2.0, fh)
			for p: Array in mosaic_pixels():
				var other := mosaic_tex(int(p[2]))
				var img := _img(other)
				if img == null:
					continue
				var sx := int(float(p[0]) * _fw(other) / fw) + int(fr * _fw(other))
				var sy := int(float(p[1]) * _fh(other) / fh)
				var c := img.get_pixel(clampi(sx, 0, img.get_width() - 1),
					clampi(sy, 0, img.get_height() - 1))
				if c.a <= 0.0:
					continue        ## 那边这一格是空的：留着自己的像素，不挖洞
				c.a *= tint.a
				var j2: int = clampi(int(float(p[1]) / fh * float(n)), 0, n - 1)
				var dx2: float = float(slices[j2]) if j2 < slices.size() else 0.0
				draw_rect(Rect2((top + Vector2(float(p[0]) + dx2, float(p[1]))).round(),
					Vector2.ONE), c, true)
		"scanlines":
			## 扫描线：本体带一道往下滑的横向撕裂，再压几条暗带
			var roll: float = float(_state["roll"])
			_blit(self, tex, fr, foot, off, 0.0, roll, tint)
			_blit(self, tex, fr, foot, off + Vector2(3.0, 0.0), roll, 1.0, tint)
			var w := _fw(tex)
			var h := _fh(tex)
			var top := foot.y - h
			for b in _state.get("bars", []):
				var y := top + fmod(float(b) + float(_state["q"]) * 0.9, 1.0) * h
				draw_rect(Rect2(Vector2(foot.x - w / 2.0 + off.x, y).round(), Vector2(w, 2)),
					Color(0.02, 0.02, 0.05, 0.6 * tint.a), true)


# ── ③ 击退 + 受击（PRD:411/469/473）─────────────────────────────────

func _probe_knock(q: float) -> Dictionary:
	var from := _coord(_args.get("from", Vector2i.ZERO))
	var to := _coord(_args.get("to", from))
	var f0 := _foot(from)
	var f1 := _foot(to)
	var mv := CWPix.phase(q, KNOCK_WAIT, maxf(_dur * 0.55, 0.001))
	var e := 1.0 - pow(1.0 - mv, 3.0)          ## ease-out：被推出去是猛地一下，落点前收住
	var foot := f0.lerp(f1, e) - Vector2(0.0, sin(mv * PI) * KNOCK_ARC)
	return {
		"kind": "knockback", "q": q, "foot": foot.round(), "from": f0, "to": f1,
		"flash": _steps(1.0 - CWPix.phase(q, 0.0, KNOCK_FLASH)),
		"mv": _steps(mv), "land": _steps(CWPix.phase(q, KNOCK_WAIT + _dur * 0.55, 0.14)),
		"frame": _breath(q),
	}


func _draw_knock() -> void:
	var f0: Vector2 = _state["from"]
	var f1: Vector2 = _state["to"]
	var foot: Vector2 = _state["foot"]
	var flash: float = _state["flash"]
	var body0 := f0 - Vector2(0.0, BODY_DY)
	var axis := (f1 - f0).normalized() if f0.distance_to(f1) > 0.01 else Vector2.RIGHT
	## 受击：胸口炸一小把 + 顺着被推的方向甩三道短线
	if flash > 0.0:
		var ink := INK_HIT
		ink.a = flash
		CWPix.burst(self, body0, 1.0 - flash, ink, 14, 26.0)
		for j in 3:
			var perp := Vector2(-axis.y, axis.x) * float(j - 1) * 5.0
			CWPix.line(self, body0 + perp - axis * 6.0, body0 + perp - axis * (10.0 + flash * 14.0),
				ink, 2)
	var tex := _tex_of(_args.get("tex", "ImmuneBasic"))
	if tex != null:
		_blit(self, tex, int(_state["frame"]), foot, Vector2.ZERO, 0.0, 1.0, Color(1, 1, 1, 1))
	## 落地那一下：脚下一圈扁扁的尘
	var land: float = _state["land"]
	if land > 0.0 and land < 1.0:
		var dust := INK_HIT
		dust.a = _steps(1.0 - land)
		CWPix.ring(self, f1, 6.0 + land * 14.0, dust, _squash())


# ── ④ 效应应答变体：命中不贯穿（PRD:463-465/483）──────────────────────

func _probe_beam(q: float) -> Dictionary:
	var a := _body(_coord(_args.get("from", Vector2i.ZERO)))
	var b := _body(_coord(_args.get("to", _args.get("from", Vector2i.ZERO))))
	var full := a.distance_to(b)
	var reach := CWPix.phase(q, BEAM_CHARGE, BEAM_REACH)
	## **不贯穿**：射程封在目标胸前 BEAM_HALT 个像素，任 q 多大都越不过去
	var halt := maxf(full - BEAM_HALT, BEAM_START + 1.0)
	var hold := maxf(q - BEAM_CHARGE - BEAM_REACH, 0.0)
	return {
		"kind": "beam_hit", "q": q, "a": a, "b": b, "full": full,
		"charge": _steps(CWPix.phase(q, 0.0, BEAM_CHARGE)),
		"reach": _steps(reach), "tip": lerpf(BEAM_START, halt, reach), "halt": halt,
		"impact": _steps(0.55 + 0.45 * sin(fmod(hold, BEAM_LOOP) / BEAM_LOOP * TAU)) if reach >= 1.0 else 0.0,
	}


func _draw_beam() -> void:
	var a: Vector2 = _state["a"]
	var full: float = _state["full"]
	if float(_state["reach"]) <= 0.0:
		## 蓄力：光点朝发动者收拢（同 beam_fx 的第一拍）
		var ink := INK_BEAM_B
		ink.a = 1.0
		CWPix.burst(self, a, 1.0 - float(_state["charge"]), ink, 16, 30.0, true)
		return
	if full <= BEAM_START:
		return
	var b: Vector2 = _state["b"]
	var axis := (b - a) / full
	var perp := Vector2(-axis.y, axis.x)
	var tip: float = _state["tip"]
	var q: float = _state["q"]
	var s := BEAM_START
	## 双螺旋：包络两头收尖 —— **尖就收在 tip 上**，所以看得出来是「停在那儿」不是「穿过去」
	while s < tip:
		var env: float = sin((s - BEAM_START) / maxf(tip - BEAM_START, 1.0) * PI) * BEAM_SWELL
		var o: float = sin(s * BEAM_TWIST - q * BEAM_SPIN) * env
		var base := a + axis * s
		draw_rect(Rect2((base + perp * o).round(), Vector2(2, 2)), INK_BEAM_A, true)
		draw_rect(Rect2((base - perp * o).round(), Vector2(2, 2)), INK_BEAM_B, true)
		s += 1.0
	CWPix.line(self, a + axis * BEAM_START, a + axis * tip, INK_BEAM_CORE, 1)
	## 命中点：两圈往外推的击中环 + 一小团火花，**全部落在 halt 上，一个像素都不往后**
	var hit: float = _state["impact"]
	if hit > 0.0:
		var at := a + axis * float(_state["halt"])
		var ink2 := INK_BEAM_B
		ink2.a = hit
		CWPix.ring(self, at, 6.0 + hit * 5.0, ink2, _squash())
		var ink3 := INK_BEAM_A
		ink3.a = _steps(hit * 0.6)
		CWPix.ring(self, at, 11.0 + hit * 7.0, ink3, _squash())
		CWPix.burst(self, at, hit, ink2, 10, 15.0)


# ── ⑥ 自动重置提示（PRD:47）：三个候选 ────────────────────────────────

func _probe_reset(q: float) -> Dictionary:
	var v := str(_args.get("variant", RESET_VARIANT))
	var p := clampf(q / maxf(_dur, 0.001), 0.0, 1.0)
	## 两头各淡一下，中间满亮
	var fade := minf(CWPix.phase(q, 0.0, 0.18), 1.0 - CWPix.phase(q, _dur - 0.25, 0.25))
	var out := {"kind": "reset_hint", "q": q, "variant": v, "p": _steps(p), "fade": _steps(fade),
		"shake": Vector2.ZERO, "cells": []}
	match v:
		"rewind":
			## 候选 a「倒带」：整盘被一条条横向撕裂带往左回卷，配左向双三角与一行字
			out["sweep"] = _steps(fmod(q * 2.6, 1.0))
		"edge":
			## 候选 b「边缘红光 + 棋盘抖一下」：红光绕屏一圈，抖动随时间衰减
			out["head"] = _steps(fmod(q / maxf(_dur, 0.001), 1.0))
			out["shake"] = (Vector2(sin(q * 72.0) * 3.0, cos(q * 95.0) * 2.0) * (1.0 - p)).round()
		"dissolve":
			## 候选 c「细胞原地溶解再浮现」
			var delay: Array = _plan.get("delay", [])
			var cells: Array = []
			var i := 0
			for cell in _args.get("cells", []):
				var d: float = float(delay[i]) if i < delay.size() else 0.0
				cells.append([
					_foot(_coord((cell as Dictionary).get("at", Vector2i.ZERO))),
					_steps(CWPix.phase(q, d, 0.40)),
					_steps(CWPix.phase(q, d + 0.55, 0.45)),
					i,
				])
				i += 1
			out["cells"] = cells
	return out


func _draw_reset() -> void:
	if str(_state["variant"]) == "rewind":
		_draw_rewind()
		return
	if str(_state["variant"]) != "dissolve":
		return
	var fade: float = _state["fade"]
	var i := 0
	for row: Array in _state.get("cells", []):
		var foot: Vector2 = row[0]
		var gone: float = row[1]
		var back: float = row[2]
		var cell: Dictionary = (_args["cells"] as Array)[int(row[3])]
		var tex := _tex_of(cell.get("tex", "ImmuneBasic"))
		if tex == null:
			continue
		var body := foot - Vector2(0.0, BODY_DY)
		if back > 0.0:
			## 浮现：自下而上长回来
			_blit(self, tex, _breath(_state["q"]), foot, Vector2.ZERO, 1.0 - back, 1.0,
				Color(1, 1, 1, fade))
			if back < 1.0:
				var ink := INK_CYAN
				ink.a = _steps((1.0 - back) * fade)
				CWPix.burst(self, body, back, ink, 14, 22.0, true)
		elif gone < 1.0:
			## 溶解：自上而下化掉，碎粒往外散
			_blit(self, tex, _breath(_state["q"]), foot, Vector2.ZERO, gone, 1.0,
				Color(1, 1, 1, fade))
			if gone > 0.0:
				var ink2 := INK_RESET
				ink2.a = _steps(gone * fade)
				CWPix.burst(self, body, gone, ink2, 14, 22.0)
		i += 1


## 候选 a 的棋盘那一半：几条横向撕裂带从右往左刷过整盘，左缘带一道亮边 ——
## **不动棋盘本身**（那是 match.gd 每帧覆写的地盘），只在它上面盖一层「被回卷」的样子
func _draw_rewind() -> void:
	var c: Vector2 = board.tile_center(Vector2i.ZERO)
	var w: float = float(int(board.radius) * 2 - 1) * float(board.distance_x)
	var h: float = float(int(board.radius) * 2 - 1) * float(board.distance_y)
	var band: float = w * 0.42
	var sweep: float = _state["sweep"]
	var fade: float = _state["fade"]
	for j in 7:
		var y: float = c.y - h / 2.0 + (float(j) + 0.5) * (h / 7.0)
		var x: float = c.x + w / 2.0 - fmod(sweep + float(j) * 0.13, 1.0) * (w + band)
		draw_rect(Rect2(Vector2(x, y - 6.0).round(), Vector2(band, 12)),
			Color(0.03, 0.04, 0.07, 0.34 * fade), true)
		var lead := INK_TEXT
		lead.a = _steps(0.5 * fade)
		CWPix.line(self, Vector2(x, y - 6.0), Vector2(x, y + 6.0), lead, 2)


# ── 画：棋盘层 / 叠加层 / 屏幕层 ─────────────────────────────────────

func _draw() -> void:
	if not _running or _state.is_empty():
		return
	match str(_state.get("kind", "")):
		"shockwave":
			_draw_shock()
		"glitch":
			_draw_glitch()
		"knockback":
			_draw_knock()
		"beam_hit":
			_draw_beam()
		"reset_hint":
			_draw_reset()


## 叠加混合（BLEND_MODE_ADD）：受击闪白与像素错误那一下过曝只能靠加色，调 modulate 提不亮
func _paint_add(ci: CanvasItem) -> void:
	if not _running or _state.is_empty():
		return
	var kind := str(_state.get("kind", ""))
	if kind == "knockback":
		var f: float = _state["flash"]
		if f <= 0.0:
			return
		var tex := _tex_of(_args.get("tex", "ImmuneBasic"))
		if tex != null:
			_blit(ci, tex, int(_state["frame"]), _state["foot"], Vector2.ZERO, 0.0, 1.0,
				Color(f, f, f, 1.0))
	elif kind == "glitch" and bool(_state.get("heavy", false)):
		var tex2 := current_tex()
		if tex2 != null and _frame(float(_state["q"])) % 3 == 0:
			_blit(ci, tex2, int(_state["frame"]), _state["foot"], _state["off"], 0.0, 1.0,
				Color(0.35, 0.35, 0.45, 1.0))


func _paint_screen(ci: CanvasItem) -> void:
	if not _running or str(_state.get("kind", "")) != "reset_hint":
		return
	var vp: Vector2 = (ci as Control).get_viewport_rect().size
	var fade: float = _state["fade"]
	var v := str(_state["variant"])
	if v == "rewind":
		## 候选 a：全屏横向撕裂带往上扫（VHS 倒带）+ 左向双三角 + 一行字
		var sweep: float = _state["sweep"]
		for j in 9:
			var y := fmod(float(j) / 9.0 + sweep, 1.0) * vp.y
			var h: float = 3.0 + float(j % 3) * 2.0
			ci.draw_rect(Rect2(Vector2(0.0, y).round(), Vector2(vp.x, h)),
				Color(INK_TEXT.r, INK_TEXT.g, INK_TEXT.b, (0.10 + 0.06 * float(j % 3)) * fade), true)
		var cx := vp.x / 2.0
		var cy := vp.y * 0.18
		## 左向双三角摆在字的**左边**，别压到字上
		for j in 2:
			var x := cx - 88.0 + float(j) * 13.0
			ci.draw_colored_polygon(
				PackedVector2Array([Vector2(x, cy), Vector2(x + 10.0, cy - 7.0),
					Vector2(x + 10.0, cy + 7.0)]),
				Color(INK_TEXT.r, INK_TEXT.g, INK_TEXT.b, fade))
		_caption(ci, vp, cy + 6.0, fade)
	elif v == "edge":
		## 候选 b：红光绕屏一圈扫过（棋盘的抖动在 _apply 里落到 shake_node 上）
		var head: float = _state["head"]
		var band := 26.0
		for e in 4:
			var d := absf(fmod(head - float(e) * 0.25 + 1.5, 1.0) - 0.5)
			var b := clampf(1.0 - d * 3.2, 0.0, 1.0) * 0.75 + 0.2
			for k in 8:
				var a := INK_RESET
				a.a = (1.0 - float(k) / 8.0) * 0.30 * b * fade
				var t := float(k) / 8.0 * band
				match e:
					0:
						ci.draw_rect(Rect2(0.0, t, vp.x, band / 8.0), a, true)
					1:
						ci.draw_rect(Rect2(vp.x - t - band / 8.0, 0.0, band / 8.0, vp.y), a, true)
					2:
						ci.draw_rect(Rect2(0.0, vp.y - t - band / 8.0, vp.x, band / 8.0), a, true)
					_:
						ci.draw_rect(Rect2(t, 0.0, band / 8.0, vp.y), a, true)
		_caption(ci, vp, vp.y * 0.16, fade)
	else:
		_caption(ci, vp, vp.y * 0.16, fade)


## 三个候选共用的那一行字：字号 / 位置一样，差别只在动画，方便 Kevin 对拍着挑
func _caption(ci: CanvasItem, vp: Vector2, y: float, fade: float) -> void:
	var ink := INK_TEXT
	ink.a = fade
	var shadow := Color(0.04, 0.05, 0.08, fade)
	ci.draw_string(FONT, Vector2(0.0, y + 1.0).round(), RESET_TEXT,
		HORIZONTAL_ALIGNMENT_CENTER, vp.x, 20, shadow)
	ci.draw_string(FONT, Vector2(0.0, y).round(), RESET_TEXT,
		HORIZONTAL_ALIGNMENT_CENTER, vp.x, 20, ink)


# ── 小工具 ─────────────────────────────────────────────────────────

## 时间量化到 1/12 秒（像素纪律②，同 tutorial_opening.gd:459）
func _quant(t: float) -> float:
	return floorf(maxf(t, 0.0) * PIX_FPS) / PIX_FPS


func _frame(t: float) -> int:
	return int(floorf(maxf(t, 0.0) * PIX_FPS))


## alpha 也量化：像素画不要 256 级渐变（同 tutorial_opening 的 _steps）
func _steps(a: float) -> float:
	return roundf(clampf(a, 0.0, 1.0) * 6.0) / 6.0


func _breath(q: float) -> int:
	return int(q * BREATH_FPS) % BREATH_FRAMES


func _foot(c: Vector2i) -> Vector2:
	return board.tile_center(c) + Vector2(0.0, CELL_FOOT_DY)


func _body(c: Vector2i) -> Vector2:
	return board.tile_center(c) + Vector2(0.0, CELL_FOOT_DY - BODY_DY)


## 棋盘是压扁的六边形网格，所以「圆」要画成同样压扁的椭圆（同 tutorial_opening._squash）
func _squash() -> float:
	return float(board.distance_y) / (float(board.distance_x) * sqrt(3.0) / 2.0)


## 格坐标：直接给 Vector2i，或给席位号 + 导演注入的 seat_at
func _coord(v) -> Vector2i:
	if v is Vector2i:
		return v
	if v is Vector2:
		return Vector2i(v)
	if typeof(v) == TYPE_INT and seat_at.is_valid():
		return seat_at.call(int(v))
	return Vector2i.ZERO


func _coords(a: Dictionary) -> Array:
	var out: Array = []
	for c in a.get("coords", []):
		out.append(_coord(c))
	return out


func _tex_of(v) -> Texture2D:
	if v is Texture2D:
		return v
	if typeof(v) == TYPE_STRING and CELL_ART.has(v):
		return CELL_ART[v]
	return null


func _fw(tex: Texture2D) -> float:
	return tex.get_width() / float(BREATH_FRAMES)


func _fh(tex: Texture2D) -> float:
	return float(tex.get_height())


## 画胞体的一条横带（r0~r1 是高度上的比例，0 = 头顶、1 = 脚底）。
## 摆法照 CWMatch._sync_cells：脚底落在格顶面中心再往下 CELL_FOOT_DY
func _blit(ci: CanvasItem, tex: Texture2D, frame: int, foot: Vector2, off: Vector2,
		r0: float, r1: float, tint: Color) -> void:
	var w := _fw(tex)
	var h := _fh(tex)
	var y0 := h * clampf(r0, 0.0, 1.0)
	var y1 := h * clampf(r1, 0.0, 1.0)
	if y1 - y0 <= 0.5:
		return
	var f := clampi(frame, 0, BREATH_FRAMES - 1)
	var src := Rect2(Vector2(float(f) * w, y0), Vector2(w, y1 - y0))
	var dst := Rect2((foot + off - Vector2(w / 2.0, h - y0)).round(), Vector2(w, y1 - y0))
	ci.draw_texture_rect_region(tex, dst, src, tint)


## 只为了有个 `_draw` 的小节点（同 board.gd 的内部类 TurnArrow / tutorial_opening 的 Painter）
class Painter extends Node2D:
	var paint := Callable()

	func _draw() -> void:
		if paint.is_valid():
			paint.call(self)


class ScreenPaint extends Control:
	var paint := Callable()

	func _draw() -> void:
		if paint.is_valid():
			paint.call(self)
