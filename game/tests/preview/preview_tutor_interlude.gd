extends SceneTree
## 新手教程 v2 · S9b **真机出图**：间章「癌变」十个分镜跑一遍，按时间连拍。
##
## 为什么不用 `tests/screenshot.gd` 走主菜单那条路：间章的 `flow[0].load` 是**显式 null**
## （承接上一关的活局面），所以它**开不了冷局** —— 把 `guide_progress.cfg` 写成 `done=5`
## 直接从主菜单进间章，`_open_tutor_level` 会去找一份并不存在的 `base`。
## 间章只有一个合法入口：**第五关打完 → `on_done` 接过来**。这份脚本就照那条路走：
## 真起 `Main.tscn` → 教程局开在第五关 → 立刻 `_tutor_next_level("interlude")` → 剧本自己往下跑。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --resolution 960x540 --windowed \
##     --script res://tests/preview/preview_tutor_interlude.gd -- <输出目录> [总秒数]
##
## 每一帧的文件名带着**时刻与此刻的游标下标**（`t12.0_row09.png`），挑图时一眼看得出
## 这一帧停在哪个分镜上。
const OPENING := preload("res://scripts/ui/tutorial_opening.gd")

const STEP := 0.25             ## 连拍间隔
const SPAN := 26.0             ## 默认总时长：十个分镜跑完还有富余

var _dir := "user://"
var _span := SPAN
var _m: CWMatch
var _scene: Node
var _t := 0.0
var _next := 0.0
var _kicked := false
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]
	if args.size() > 1:
		_span = float(args[1])
	if not _dir.ends_with("/"):
		_dir += "/"
	DirAccess.make_dir_recursive_absolute(_dir)

	## 教程局开在第五关（done_count = 4）。
	## ⚠ 这三句**会写 `user://guide_progress.cfg`**（玩家那份真进度）——
	## 出图前先备份、跑完还原，同 S5 那次真机截图的口径
	CWGuideProgress.clear()
	CWGuideProgress.set_done(3)
	OPENING.mark_seen()      ## 开场动画跳过（clear() 把 opening_seen 也清了）
	CWSettings.ai_delay_ms = 0

	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	_scene = main_scene


func _process(delta: float) -> bool:
	_t += delta
	## _ready() 要等一帧才跑完，所以起局放在第一帧而不是 _initialize 里
	if _m == null:
		_m = _scene.get_node("Match") as CWMatch
		## 走真入口（主菜单那一项发的就是它）：菜单退场 + 镜头推进 + 开局都在里头
		_scene._begin_tutorial(0)
		return false
	## 第五关关首那几句讲解是 `auto: false`（要玩家点「继续」）——
	## 不替他点的话，气泡会一直挂到间章里（真实流程里 Step2 早就读完了）
	if _t >= 2.0 and _t < 4.4 and _m._tutor_view != null:
		_m._tutor_view.advance_pressed.emit()
	## 第五关一开起来就交给间章：`on_done` 那条路（`_tutor_next_level`）走的就是这一支
	if not _kicked and _t >= 4.5 and _m.kernel != null:
		_kicked = true
		_m._tutor_next_level("interlude")
	if _t >= _next:
		_next += STEP
		_shoot()
	return _t >= _span


func _shoot() -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	var row := -1
	if _m != null and is_instance_valid(_m) and _m._director != null:
		row = int(_m._director._at)
	img.save_png("%st%05.1f_row%02d.png" % [_dir, _t, row])
	_frames += 1
	print("[间章出图] t=%.1f 游标 flow[%d] 世界 %s"
		% [_t, row, str(_m._stage.world_id) if _m._stage != null else "-"])
