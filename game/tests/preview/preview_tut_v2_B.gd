extends SceneTree
## preview_tut_v2_B.gd —— 新手教程 v2「方向 B · 剧场对白」界面方向稿。**给人看的工具，不是测试。**
##
## Kevin 2026-09-19：老教程的界面整套作废，基于剧本（`Cell_War_新手引导PRD_hxr.md`）从 0 重做，
## 先出两版方向稿给他挑。这一份是 B：**台词走底部对白面板**（左头像 + 右文字 + 右下「▼」），
## 控件提示是**像素箭头 + 描边高亮**，章节提示是**全屏黑底大字 + 英文副标**（接开场那一页），
## 重置 / 目录是**贴在对白面板上沿的两个文字页签**，图鉴解锁是**对白面板上方弹的横幅**，
## 操作禁用 = **棋盘罩一层 12% 黑**。整体像一段有旁白的剧：信息全压在底部，棋盘上方干净。
##
## **为什么非得出图**：这一版的全部风险都是排版风险 —— 对白面板 108px 会不会啃掉棋盘下缘、
## 右栏在时文字列还剩几个字、第七关九席的右栏与全屏引导会不会打架。平底色预览骗过三次
## （记忆：手牌抽屉 / 右边地图 / 菜单装饰细胞压字），所以这里一律用**真 Board.tscn + 真机位 +
## 真细胞贴图 + 真 CWActionBar / CWMatchPanel + CWStyle 真字体**，只有方向 B 自己新增的件是现画的。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_tut_v2_B.gd -- <输出目录>
##
## 不做：教程流程 / 关卡数据 / 内核接线。方向定了才轮到那些。

# ── 真素材 ────────────────────────────────────────────────────────────────
const BOARD_SCENE := preload("res://scenes/Board.tscn")
## 英文副标用开场那页同一支字（`tutorial_opening.gd` 的 LOGO_FONT），章节提示才接得上开场
const SILK := preload("res://assets/fonts/silkscreen_bold.ttf")
## 横排 6 帧静息呼吸表，与棋盘上的细胞同一批（`CWMatch.IMMUNE_ART` / `CANCER_ART`）
const CELL_ART := {
	"immune": preload("res://assets/art/cells/anim/immune_breath.png"),
	"tcell": preload("res://assets/art/cells/anim/tcell_breath.png"),
	"bcell": preload("res://assets/art/cells/anim/bcell_breath.png"),
	"macro": preload("res://assets/art/cells/anim/macrophage_breath.png"),
	"dendritic": preload("res://assets/art/cells/anim/dendritic_breath.png"),
	"melanoma": preload("res://assets/art/cells/anim/melanoma_breath.png"),
	"sclc": preload("res://assets/art/cells/anim/sclc_breath.png"),
}
const BREATH_FRAMES := 6
const BREATH_POSE := 2               ## 出图钉死在呼吸表的第 3 帧，别让两次出图长得不一样
const CELL_FOOT_DY := 6.0            ## 同 CWMatch：脚底落在格顶面中心再往下 6px

# ── 方向 B 的版面（全部是这一版自己的新数，改一个要重看图）────────────────
## 对白面板：贴底、左右各留 12。**上沿 360** 是被 `CWActionBar.BAR_RECT`（476）逼出来的 ——
## 面板 108 高 + 8 缝 = 468，正好停在行动栏上边。技能按钮和台词必须同框
## （剧本第七关「技能按钮弹出文字提示」、第一关「台词 + 【迁移】按钮」），所以面板不许压住行动栏。
const DLG := Rect2(12, 360, 936, 108)
## 右栏（CWMatchPanel.RECT.x = 696）在时对白面板的右缘：688，让出 8 的缝。
## 第一、二关没有右栏用全宽，第三关起窄 260 —— **文字列的字数上限也跟着变**，见方案说明。
const DLG_RIGHT_WITH_PANEL := 688.0
const PAD := 10.0
const AVATAR := 88.0                 ## 头像底板：细胞贴图最大 32×34，×2 = 64×68，四周还留得下 10
const TEXT_X := 112.0                ## 文字列相对面板左缘（PAD + AVATAR + 14）
const NAME_DY := 12.0
const LINE1_DY := 34.0
const LINE_H := 30.0                 ## 正文 20 的行距。面板 108 高 ⇒ 最多两行（34 + 30 + 20 = 84 < 98）
## 任务条：可操作态（剧本的「O-玩家」）把对白面板收成一条，把棋盘下缘还回去。
## 上沿 434 ⇒ 下沿 468，和对白面板同一条底边，收放时下边不跳。
const TASK := Rect2(12, 434, 936, 34)
## 重置 / 目录两个页签：骑在底部那条的上沿，右对齐。
## **不塞进面板内部**是算过的：两个 20 号字的按钮要 110px，右栏在时文字列只剩 430（21 个汉字），
## 剧本里最长的一句「当迁移到癌组织上时，会自动将癌组织转为健康组织」正好 23 个字，会撞。
const TAB_H := 30.0
const TAB_GAP := 8.0
const TAB_DY := 4.0                  ## 页签底边到面板上沿的缝
const BANNER_H := 34.0               ## 图鉴解锁横幅
const BANNER_GAP := 6.0
## 操作禁用：棋盘罩 12% 黑。再深就成了「暂停」，再浅在深底棋盘上看不出来。
const DIM := 0.12
## 第七关全屏级引导的压暗。0.30 试过，和寻常的 12% 禁用罩分不出层次（出过一张图）——
## 「全屏提示」得一眼看出是**另一种**状态，所以拉到 0.45
const SPOT_DARK := 0.45
const MODAL_DARK := 0.55             ## 目录面板的压暗

## 相机：棋盘要占满「可用带」的这个比例。剩下的是呼吸。
const FIT := 0.86
const ZOOM_MIN := 1.27               ## = CWView.GAME_ZOOM，正式盘那一档，不许比它还远
const ZOOM_MAX := 3.2                ## = CWView.MENU_ZOOM。再近 16px 的小细胞肺癌会糊成一团粗块
const TILE_W := 36.0                 ## = CWBoard.distance_x
const TILE_H := 34.0                 ## 组织贴图高

## 每帧的落定时间（**真秒**，不是帧数）：棋盘高亮 `CWBoard.MARK_FADE` 是 0.22 秒的时间补间，
## 而这个循环不吃 vsync、一帧只有几毫秒 —— 数帧只会截到一张淡的（`preview_config` 头注那个坑）。
const SETTLE := 0.45
const SETTLE_FRAMES := 10            ## 容器（CWActionBar 的 HBox）要几帧才排完版

var _out := "user://tut_v2_B"
var _board: Node2D
var _cells: Node2D                   ## 我自己摆的细胞，挂在棋盘下面吃同一套画家算法
var _cam: Camera2D
var _ui: CanvasLayer
var _stage: Control                  ## 每一帧重建的全部界面件
var _bar: CWActionBar
var _panel: CWMatchPanel
var _shots: Array = []
## 要等容器排完版才能摆的件（行动栏是 HBoxContainer，`button_rect()` 当帧问到的是零矩形）。
## 每一帧建完把它们压进来，第 5 帧统一跑一遍再截图。
var _late: Array = []
var _i := 0
var _t := 0.0
var _n := 0
var _built := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = CWView.screen_size()
	root.add_child(bg)
	_board = BOARD_SCENE.instantiate()
	root.add_child(_board)
	_cells = Node2D.new()
	_board.add_child(_cells)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_cam.make_current()
	_ui = CanvasLayer.new()
	root.add_child(_ui)
	_stage = Control.new()
	_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_stage)
	_shots = [
		{ "name": "01_章节提示", "fn": "_shot_chapter" },
		{ "name": "02_第一关关首", "fn": "_shot_lv1_open" },
		{ "name": "03_第一关操作中", "fn": "_shot_lv1_act" },
		{ "name": "04_第三关右栏与图鉴", "fn": "_shot_lv3" },
		{ "name": "05_目录面板", "fn": "_shot_toc" },
		{ "name": "06_第七关结束回合", "fn": "_shot_lv7" },
		{ "name": "07_自动重置提示", "fn": "_shot_reset" },
	]


func _process(delta: float) -> bool:
	if _i >= _shots.size():
		return true
	if not _built:
		_reset()
		call(str(_shots[_i]["fn"]))
		_built = true
		_t = 0.0
		_n = 0
		return false
	_t += delta
	_n += 1
	if _n == 5 and not _late.is_empty():
		for c: Callable in _late:
			c.call()
		_late.clear()
		return false
	if _t < SETTLE or _n < SETTLE_FRAMES:
		return false
	var path: String = "%s/%s.png" % [_out, str(_shots[_i]["name"])]
	root.get_texture().get_image().save_png(path)
	print("已保存 ", path)
	_i += 1
	_built = false
	return _i >= _shots.size()


## 回到「空舞台」：127 格全刷成普通健康组织、遮罩全关、细胞与界面件清空。
## 棋盘是跨帧复用的（重铺格网那条路 2026-09-11 已经废掉，见开发日志），所以只能逐格刷回去。
func _reset() -> void:
	for c: Vector2i in CWData.all_coords():
		_board.set_tissue(c, CWData.Tissue.HEALTHY, CWData.Special.NONE)
	_board.set_marks({})
	_board.set_active_tiles([], 0.0)
	_board.modulate = Color.WHITE
	for n in _cells.get_children():
		_cells.remove_child(n)
		n.queue_free()
	for n in _stage.get_children():
		_stage.remove_child(n)
		n.queue_free()
	_late.clear()
	_bar = null
	_panel = null


# ══ 七帧 ══════════════════════════════════════════════════════════════════

## ① 第一章章节提示：接在开场动画之后，全屏半透明黑底 + 居中大字 + 一行英文副标。
## 背后是开场收尾那张全盘（净化跑完，整片健康），透 12% 出来 —— 剧本通则 1 要的是「半透明」，
## 不是一块纯黑幕布：玩家得看见自己刚才站在哪儿。
func _shot_chapter() -> void:
	var tiles := CWData.all_coords()
	_board.set_active_tiles(tiles, 0.0)
	_put_cell("immune", Vector2i(0, 0))
	_frame_board(tiles, false, 540.0)
	_chapter_card("第一章  Cell", "CHAPTER I - CELL")


## ② 第一关关首：两格横向连接的健康组织 + 未分化免疫细胞 + 台词第一句 + 【迁移】按钮。
## 台词在说 ⇒ 操作禁用 ⇒ 棋盘罩 12% 黑、【迁移】降灰（`CWActionBar` 的 disabled，位置照占）。
func _shot_lv1_open() -> void:
	var tiles := [Vector2i(0, 0), Vector2i(1, 0)]
	_board.set_active_tiles(tiles, 0.0)
	_put_cell("immune", Vector2i(0, 0))
	_frame_board(tiles, false, DLG.position.y)
	_action_bar([{ "title": "迁移", "disabled": true }])
	_dim_board(DIM, false, DLG.position.y)
	_dialogue("免疫细胞", CELL_ART["immune"], CWStyle.IMMUNE,
		["欢迎来到Cell_War！"], false, true)


## ③ 第一关操作中：台词说完 ⇒ 对白面板收成一条任务条，棋盘下缘还回来；
## 【迁移】按钮进提示态（描边高亮 + 头顶箭头），目的格进提示态（棋盘原生 MARK_MOVE + 箭头）。
## **没有压暗**：这一刻是可操作的，剧本通则 9 的禁用只覆盖「提示 / 对话进行中」。
func _shot_lv1_act() -> void:
	var tiles := [Vector2i(0, 0), Vector2i(1, 0)]
	_board.set_active_tiles(tiles, 0.0)
	_put_cell("immune", Vector2i(0, 0))
	_frame_board(tiles, false, TASK.position.y)
	_board.set_marks({ Vector2i(1, 0): _board.MARK_MOVE })
	_action_bar([{ "title": "迁移" }])
	_tile_arrow(Vector2i(1, 0), CWStyle.IMMUNE)
	_task_strip("使用【迁移】，向前行动一格", false)
	## 箭摆在按钮**左边**而不是头顶：行动栏钉在 y=476，头顶那 8px 正是任务条的下沿，
	## 箭画上去会骑在条子上（第一版出图就是这样）
	_late.append(func() -> void:
		var r: Rect2 = _bar.button_rect("迁移")
		_hilite(r, CWStyle.IMMUNE)
		_arrow(Vector2(r.position.x - 20.0, r.position.y + r.size.y / 2.0), 3, CWStyle.IMMUNE))


## ④ 第三关：地图向前方延伸、凸的癌组织连通块、右栏弹出（状态框 + 抗原记忆框），
## 台词「发现新的癌细胞，继续清理」，同框叠两条图鉴解锁横幅。
##
## 横幅这里**故意摆两条**：剧本里一关连着解锁好几条（第一关就是【健康组织】+【迁移】），
## 要看的是两条叠起来会不会顶到棋盘。第三关真实只解锁【攻击】一条。
func _shot_lv3() -> void:
	_build_lv3()
	_dim_board(DIM, true, DLG.position.y)
	_dialogue("免疫细胞", CELL_ART["immune"], CWStyle.IMMUNE,
		["发现新的癌细胞，继续清理"], true, true)
	_banners(["攻击", "净化"], DLG.position.y - TAB_DY - TAB_H)


## 第三关的棋盘 + 右栏（目录那一帧也用它当底）
func _build_lv3() -> void:
	var tiles := CWData.all_coords(3)
	_board.set_active_tiles(tiles, 0.0)
	for c: Vector2i in _LV3_CANCER:
		_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE)
	_put_cell("immune", Vector2i(-3, 1))
	_put_cell("melanoma", Vector2i(2, -1))
	_frame_board(tiles, true, DLG.position.y)
	_side_panel([CWData.Faction.IMMUNE, CWData.Faction.CANCER], false, false)


## ⑤ 目录面板：从底部那条的「目录」页签拉开，盖住棋盘带，对白面板留在底下不动
## （玩家看得见自己是从哪一关点开的）。页签本身进悬停态（CWStyle.link_hot 的白光）。
func _shot_toc() -> void:
	_build_lv3()
	_dim_board(DIM, true, DLG.position.y)
	_dialogue("免疫细胞", CELL_ART["immune"], CWStyle.IMMUNE,
		["发现新的癌细胞，继续清理"], true, true)
	var modal := ColorRect.new()
	modal.color = Color(0, 0, 0, MODAL_DARK)
	modal.size = CWView.screen_size()
	modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(modal)
	_toc_panel()


## ⑥ 第七关：玩家控制癌细胞。右栏只剩状态 + 免疫等级 + 结束回合，**上方不显示第 X 回合**；
## 全屏级引导 = 压暗 30% 且只在【结束回合】那块挖洞 + 四向像素箭头收拢；
## 按钮旁挂一条文字提示「点击结算【微环境压迫】」。提示色跟着**当前控制方**走 ⇒ 这一关全是癌方橙。
func _shot_lv7() -> void:
	var tiles := CWData.all_coords(4)
	_board.set_active_tiles(tiles, 0.0)
	for c: Vector2i in CWData.all_coords(1):
		_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE)
	## 间章留下的固化癌组织。第 5 个参数是 0~1 的固化进度（`_solid_tex` 按它挑石化贴图族的档）
	_board.set_tissue(Vector2i(0, 0), CWData.Tissue.SOLID, CWData.Special.NONE, true, 1.0)
	for c: Vector2i in [Vector2i(3, -1), Vector2i(2, 0)]:
		_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE)
	_put_cell("sclc", Vector2i(0, 0))
	_put_cell("tcell", Vector2i(-4, 0))
	_put_cell("bcell", Vector2i(2, -3))
	_put_cell("macro", Vector2i(1, 2))
	_put_cell("dendritic", Vector2i(-2, 3))
	_put_cell("immune", Vector2i(3, -1))
	_frame_board(tiles, true, TASK.position.y)
	_side_panel([CWData.Faction.CANCER, CWData.Faction.IMMUNE, CWData.Faction.IMMUNE,
		CWData.Faction.IMMUNE, CWData.Faction.IMMUNE, CWData.Faction.IMMUNE], true, false)
	## 【结束回合】在右栏里钉底：面板 RECT(696,0) + PAD 16，块高 END_H 52
	var end_btn := Rect2(696.0 + CWMatchPanel.PAD,
		CWMatchPanel.RECT.size.y - CWMatchPanel.PAD - CWMatchPanel.END_H,
		CWMatchPanel.W, CWMatchPanel.END_H)
	_spotlight(end_btn, SPOT_DARK)
	_hilite(end_btn, CWStyle.CANCER)
	var mid := end_btn.position + end_btn.size / 2.0
	## 只留上、左两枚：按钮钉在右下角，下方和右方都没有画面可站（下沿离屏底只有 16）
	_arrow(Vector2(mid.x, end_btn.position.y - 18.0), 0, CWStyle.CANCER)
	_arrow(Vector2(end_btn.position.x - 20.0, mid.y), 3, CWStyle.CANCER)
	_tip_strip("点击结算【微环境压迫】", Vector2(end_btn.position.x - 34.0, mid.y), CWStyle.CANCER)
	_task_strip("点击【结束回合】", true)


## ⑦（选做）自动重置的动画提示：剧本通则 7。示意帧画的是动画的**中段** ——
## 棋盘整体淡到 45%，四向箭头朝中央收拢，中间一块牌写明为什么重来。
## 口径：淡出 0.35s → 摆回本关初始状态 → 淡入 0.35s，全程禁用操作，牌在中段 0.6s 内可见。
func _shot_reset() -> void:
	var tiles := CWData.all_coords(3)
	_board.set_active_tiles(tiles, 0.0)
	for c: Vector2i in _LV3_CANCER:
		_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE)
	_put_cell("immune", Vector2i(-1, 1))
	_put_cell("melanoma", Vector2i(2, -1))
	_frame_board(tiles, true, TASK.position.y)
	_side_panel([CWData.Faction.IMMUNE, CWData.Faction.CANCER], false, false)
	_board.modulate.a = 0.45
	var dark := ColorRect.new()
	dark.color = Color(0, 0, 0, 0.35)
	dark.size = CWView.screen_size()
	dark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(dark)
	var w := _w("自动重置 · 回到本关起点", CWStyle.SIZE_BODY) + 48.0
	var card := Rect2(350.0 - w / 2.0, 214.0, w, 72.0)
	_plate(card, 0.55, Color(CWStyle.PANEL, 0.96))
	_label("自动重置 · 回到本关起点", CWStyle.SIZE_BODY, CWStyle.TEXT_HI,
		Vector2(card.position.x + 24.0, card.position.y + 14.0))
	_label("能量不足以抵达癌细胞", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM,
		Vector2(card.position.x + 24.0, card.position.y + 46.0))
	var c := card.position + card.size / 2.0
	_arrow(Vector2(c.x, card.position.y - 26.0), 0, CWStyle.IMMUNE)
	_arrow(Vector2(c.x, card.position.y + card.size.y + 26.0), 2, CWStyle.IMMUNE)
	_arrow(Vector2(card.position.x - 26.0, c.y), 3, CWStyle.IMMUNE)
	_arrow(Vector2(card.position.x + card.size.x + 26.0, c.y), 1, CWStyle.IMMUNE)


## 第三关那个「凸」的癌组织连通块（剧本：距免疫细胞几格外）。半径 3 的小盘内，尖朝免疫细胞。
const _LV3_CANCER: Array[Vector2i] = [
	Vector2i(2, -1), Vector2i(2, 0), Vector2i(1, 0),
	Vector2i(3, -1), Vector2i(2, -2), Vector2i(1, -1),
]


# ══ 方向 B 的件 ════════════════════════════════════════════════════════════

## 对白面板。左头像（当前控制的细胞贴图 ×2，整数倍放大才不磨锯齿）+ 名字 + 右侧台词，
## 右下角「▼」等玩家点一下继续，上沿右侧骑两个页签（重置 / 目录）。
func _dialogue(who: String, art: Texture2D, ink: Color, lines: Array,
		with_panel: bool, more: bool) -> void:
	var r := _dlg_rect(with_panel)
	_plate(r, 0.55, Color(CWStyle.PANEL, 0.96))
	var box := Rect2(r.position + Vector2(PAD, PAD), Vector2(AVATAR, AVATAR))
	_plate(box, 0.30, CWStyle.BTN_BG)
	var face := Sprite2D.new()
	face.texture = art
	face.hframes = BREATH_FRAMES
	face.frame = BREATH_POSE
	face.scale = Vector2(2, 2)
	face.position = box.position + box.size / 2.0 + Vector2(0, -4)
	_stage.add_child(face)
	_label(who, CWStyle.SIZE_LABEL, ink, r.position + Vector2(TEXT_X, NAME_DY))
	for i in lines.size():
		_label(str(lines[i]), CWStyle.SIZE_BODY, CWStyle.TEXT_HI,
			r.position + Vector2(TEXT_X, LINE1_DY + i * LINE_H))
	if more:
		## 「▼」不用字符：这套点阵字不保证有 U+25BC，缺字会画成豆腐块。画一枚像素三角。
		_arrow(r.position + r.size - Vector2(24, 20), 0, CWStyle.IMMUNE, 1)
	_tabs(r, "")


## 任务条：可操作态（「O-玩家」）的对白面板。只剩一行任务 + 常驻两个按钮。
func _task_strip(text: String, with_panel: bool) -> void:
	var r := TASK
	if with_panel:
		r.size.x = DLG_RIGHT_WITH_PANEL - r.position.x
	_plate(r, 0.35, Color(CWStyle.PANEL, 0.90))
	_arrow(r.position + Vector2(18, r.size.y / 2.0), 3, CWStyle.IMMUNE, 1)
	_label(text, CWStyle.SIZE_BODY, CWStyle.TEXT,
		r.position + Vector2(32, _mid(r.size.y, CWStyle.SIZE_BODY)))
	_tabs_in(r)


## 两个常驻页签，骑在对白面板上沿、右对齐。`hot` 指名哪一个画成悬停态（目录打开时）。
func _tabs(panel_rect: Rect2, hot: String) -> void:
	var y := panel_rect.position.y - TAB_DY - TAB_H
	var x := panel_rect.position.x + panel_rect.size.x
	for cap: String in ["目录", "重置"]:      ## 从右往左摆
		var w := _w(cap, CWStyle.SIZE_BODY) + 24.0
		x -= w
		_plate(Rect2(x, y, w, TAB_H), 0.40, CWStyle.BTN_BG)
		var l := _label(cap, CWStyle.SIZE_BODY, CWStyle.TEXT,
			Vector2(x + 12.0, y + _mid(TAB_H, CWStyle.SIZE_BODY)))
		if cap == hot:
			CWStyle.link_hot(l, true)
		x -= TAB_GAP


## 任务条形态：两个按钮收进条子右端（条子只有 34 高，骑上去会顶到棋盘）
func _tabs_in(r: Rect2) -> void:
	var x := r.position.x + r.size.x - 14.0
	for cap: String in ["目录", "重置"]:
		var w := _w(cap, CWStyle.SIZE_BODY)
		x -= w
		_label(cap, CWStyle.SIZE_BODY, CWStyle.TEXT_DIM,
			Vector2(x, r.position.y + _mid(r.size.y, CWStyle.SIZE_BODY)))
		x -= 16.0


## 图鉴解锁横幅：从对白面板上方弹出来，新的在下、旧的被顶上去。
## 左缘对齐台词的文字列，看起来是同一个人在说「顺便，你解锁了……」。
func _banners(names: Array, bottom_y: float) -> void:
	var y := bottom_y - BANNER_H - BANNER_GAP
	for i in names.size():          ## names[0] = 最新的一条，摆最下面；旧的被顶上去
		var head := "图鉴解锁："
		var body := "【%s】" % str(names[i])
		var w := _w(head, CWStyle.SIZE_BODY) + _w(body, CWStyle.SIZE_BODY) + 28.0
		var x := DLG.position.x + TEXT_X
		_plate(Rect2(x, y, w, BANNER_H), 0.45, CWStyle.BTN_BG)
		var ty := y + _mid(BANNER_H, CWStyle.SIZE_BODY)
		_label(head, CWStyle.SIZE_BODY, CWStyle.TEXT_DIM, Vector2(x + 14.0, ty))
		_label(body, CWStyle.SIZE_BODY, CWStyle.IMMUNE,
			Vector2(x + 14.0 + _w(head, CWStyle.SIZE_BODY), ty))
		y -= BANNER_H + BANNER_GAP


## 控件旁的文字提示条（剧本：结束回合按钮 / 技能按钮「弹出文字提示」）。
## 不是气泡 —— 方向 B 的语言是「牌 + 尖角」：同一套 2px 描边底板，左/右边缘长一枚指向控件的尖。
func _tip_strip(text: String, point_at: Vector2, ink: Color) -> void:
	var w := _w(text, CWStyle.SIZE_BODY) + 28.0
	var h := 38.0
	var r := Rect2(point_at.x - w - 10.0, point_at.y - h / 2.0, w, h)
	_plate(r, 0.70, Color(CWStyle.PANEL, 0.96))
	_label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI,
		r.position + Vector2(14.0, _mid(h, CWStyle.SIZE_BODY)))
	_arrow(Vector2(point_at.x - 2.0, point_at.y), 3, ink, 1)


## 章节提示：全屏 88% 黑幕 + 两道细横线夹住的大字 + 一行英文副标（开场那页的延续）。
func _chapter_card(cn: String, en: String) -> void:
	var veil := ColorRect.new()
	veil.color = Color(0.039, 0.051, 0.078, 0.88)   ## = tutorial_opening 的 SKY #0a0d14
	veil.size = CWView.screen_size()
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(veil)
	var mid := CWView.screen_size().x / 2.0
	for y in [222.0, 298.0]:
		var rule := ColorRect.new()
		rule.color = Color(CWStyle.LINE, 0.30)
		rule.position = Vector2(mid - 180.0, y)
		rule.size = Vector2(360, 1)
		rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stage.add_child(rule)
	var w := _w(cn, CWStyle.SIZE_HERO)
	_label(cn, CWStyle.SIZE_HERO, CWStyle.TEXT_HI, Vector2(mid - w / 2.0, 240.0))
	## 副标用开场那支 silkscreen + 同一档字距，才接得上「Cell_War / IMMUNE VS. CANCER」那页
	var sub := Label.new()
	var fv := FontVariation.new()
	fv.base_font = SILK
	fv.spacing_glyph = 2
	sub.text = en
	sub.add_theme_font_override("font", fv)
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", CWStyle.IMMUNE)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.size = Vector2(CWView.screen_size().x, 28)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.position = Vector2(0, 310.0)
	_stage.add_child(sub)


## 目录面板：两栏，左边第一 / 第二章，右边间章 / 第三 / 第四章。
## 状态三档：已通过（实心小菱）/ 当前（CWStyle.focus_marker，和主菜单焦点同一颗）/ 未解锁（灰字）。
const TOC_L := [
	{ "h": "第一章  Cell" },
	{ "n": "第一关  免疫", "s": 2 },
	{ "n": "第二关  癌", "s": 2 },
	{ "n": "第三关  ATP", "s": 1 },
	{ "h": "第二章  Immune" },
	{ "n": "第四关  抗原记忆", "s": 0 },
	{ "n": "第五关  分化", "s": 0 },
]
const TOC_R := [
	{ "h": "间章  癌变" },
	{ "n": "（演出）", "s": 0 },
	{ "h": "第三章  Cancer" },
	{ "n": "第七关  ……", "s": 0 },
	{ "h": "第四章  Game" },
	{ "n": "敬请期待", "s": -1 },
]


func _toc_panel() -> void:
	var r := Rect2(56, 46, 576, 292)
	_plate(r, 0.60, Color(CWStyle.PANEL, 0.98))
	_label("目录", CWStyle.SIZE_BODY, CWStyle.TEXT_HI, r.position + Vector2(20, 14))
	_label("已通过的关可以重看 · 再点「目录」收起", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM,
		r.position + Vector2(66, 22))
	var rule := ColorRect.new()
	rule.color = Color(CWStyle.LINE, 0.25)
	rule.position = r.position + Vector2(20, 48)
	rule.size = Vector2(r.size.x - 40.0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(rule)
	_toc_column(TOC_L, r.position + Vector2(20, 60))
	_toc_column(TOC_R, r.position + Vector2(300, 60))
	## 目录开着 ⇒ 底下那个页签进悬停态
	_tabs(_dlg_rect(true), "目录")


func _toc_column(rows: Array, at: Vector2) -> void:
	var y := at.y
	for row: Dictionary in rows:
		if row.has("h"):
			_label(str(row["h"]), CWStyle.SIZE_BODY, CWStyle.IMMUNE, Vector2(at.x, y))
			y += 30.0
			continue
		var st: int = int(row["s"])
		var ink: Color = CWStyle.TEXT_HI
		if st == 0:
			ink = CWStyle.TEXT_OFF
		elif st == -1:
			ink = CWStyle.TEXT_OFF_DIM
		_label(str(row["n"]), CWStyle.SIZE_BODY, ink, Vector2(at.x + 26.0, y))
		if st == 1:
			var mk := CWStyle.focus_marker()
			mk.position = Vector2(at.x + 10.0, y + 12.0)
			_stage.add_child(mk)
		elif st == 2:
			var dot := ColorRect.new()
			dot.color = Color(CWStyle.IMMUNE, 0.55)
			dot.size = Vector2(7, 7)
			dot.position = Vector2(at.x + 6.0, y + 9.0)
			dot.rotation = PI / 4
			dot.pivot_offset = Vector2(3.5, 3.5)
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_stage.add_child(dot)
		y += 26.0


## 控件的描边高亮：2px 实描边 + 外一圈 1px 弱描边当辉光。
## 通则 8「较慢频次、反差较低的轻微闪烁」的口径：**只闪描边 alpha**，0.45 ↔ 0.85，0.8 Hz
## （1.25 秒一个来回）。出图取亮端。底色一点不动 —— 动底色会把按钮上的字一起带得忽明忽暗。
func _hilite(r: Rect2, ink: Color) -> void:
	if r.size.x <= 0.0:
		return
	_stroke(r.grow(3.0), Color(ink, 0.22), 1)
	_stroke(r.grow(1.0), Color(ink, 0.85), 2)


## 全屏级引导（剧本第七关「全屏提示点击结束回合按钮」）：整屏压暗，只给目标控件留一个洞。
## 用四块矩形拼，不做遮罩 shader —— 洞永远是矩形，四块足够，而且是纯 Control、不碰渲染管线。
func _spotlight(hole: Rect2, dark: float) -> void:
	var s := CWView.screen_size()
	for r in [Rect2(0, 0, s.x, hole.position.y),
			Rect2(0, hole.position.y + hole.size.y, s.x, s.y - hole.position.y - hole.size.y),
			Rect2(0, hole.position.y, hole.position.x, hole.size.y),
			Rect2(hole.position.x + hole.size.x, hole.position.y,
				s.x - hole.position.x - hole.size.x, hole.size.y)]:
		var q := ColorRect.new()
		q.color = Color(0, 0, 0, dark)
		q.position = (r as Rect2).position
		q.size = (r as Rect2).size
		q.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stage.add_child(q)


## 操作禁用（通则 9）：棋盘那一块罩 12% 黑。**只罩棋盘**，不罩底部那条 ——
## 正在说话的面板必须是全画面最亮的东西，罩上去就成了「整个游戏被暂停」。
func _dim_board(a: float, with_panel: bool, bottom: float) -> void:
	var q := ColorRect.new()
	q.color = Color(0, 0, 0, a)
	q.position = Vector2.ZERO
	q.size = Vector2(DLG_RIGHT_WITH_PANEL if with_panel else CWView.screen_size().x, bottom)
	q.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(q)


## 目的格上方那枚箭。**抬高要跟着 zoom 走** —— 教程小棋盘会推到 3.2 倍，
## 按固定像素抬只会把箭压在格子顶面上（第一版出图就是这样）。13 = 顶面高的一半。
func _tile_arrow(c: Vector2i, ink: Color) -> void:
	var p: Vector2 = CWView.board_to_screen(_cam, _board.tile_center(c))
	_arrow(p - Vector2(0, 13.0 * _cam.zoom.y + 20.0), 0, ink)


# ══ 底座 ══════════════════════════════════════════════════════════════════

func _dlg_rect(with_panel: bool) -> Rect2:
	var r := DLG
	if with_panel:
		r.size.x = DLG_RIGHT_WITH_PANEL - r.position.x
	return r


## 真行动栏（`CWActionBar`），不是画一个像按钮的方块 —— 字号、内边距、灰态全是真的。
## 第一、二关按剧本只给【迁移】，且**不带费用行**（「迁移功能内部不显示路径规划/能量消耗」）。
func _action_bar(entries: Array) -> void:
	_bar = CWActionBar.new()
	_stage.add_child(_bar)
	_bar.show_bar("", "", entries)


## 真右侧竖条（`CWMatchPanel`）。现编一局最小状态喂给它 —— 面板吃的是 `CWMirror`，
## 所以先 `CWGame.init` + `build_board` + 逐席落子，再 `sync_from`。
## `guide_layers(end_turn, round_no)` 是引擎里**已经有的**教程开关：
## 剧本第七关「上方不显示第 X 回合」走的就是 round_no=false。
func _side_panel(factions: Array, end_turn: bool, round_no: bool) -> void:
	var g := CWGame.new()
	g.init(factions, 1)
	g.setup.build_board()
	g.immune_level = 2
	g.memory = 14
	var spots := [Vector2i(-3, 1), Vector2i(2, -1), Vector2i(-4, 0), Vector2i(2, -3),
		Vector2i(1, 2), Vector2i(-2, 3)]
	for i in g.players.size():
		if int(g.players[i]["faction"]) == CWData.Faction.CANCER:
			g.players[i]["cancer_type"] = CWData.CancerType.SCLC
		g.setup.place(i, spots[i % spots.size()])
	var m := CWMirror.new()
	var err := m.sync_from(g)
	if err != "":
		push_error("preview_tut_v2_B：镜像装载失败 —— %s" % err)
	_panel = CWMatchPanel.new()
	_stage.add_child(_panel)
	## **顺序是有讲究的**：`guide_layers` 只在面板已经建过（`_built > 0`）时才重搭版面，
	## 而版面是第一次 `refresh` 才建的 —— 先喂开关的话回合那两行会留在原地，
	## 和顶上去的胜负进度块叠成一团乱码（第一版出图就是这样）。所以：先刷一次建版面，
	## 再喂开关（它自己重搭），最后再刷一次把内容填回去。真机是每帧全量刷，天然没有这个先后问题。
	_panel.refresh(m, Callable())
	_panel.guide_layers(end_turn, round_no)
	_panel.refresh(m, Callable())
	_panel.show_end_turn(end_turn)


## 把一只细胞摆到格子上。贴图不缩放（像素纪律），锚点挪到脚底中心，z 跟着格子走 ——
## 前排的组织块会正确盖住后排细胞的下半截（画家算法，见 CWBoard.tile_z）。
func _put_cell(kind: String, c: Vector2i) -> void:
	var tex: Texture2D = CELL_ART[kind]
	var s := Sprite2D.new()
	s.texture = tex
	s.hframes = BREATH_FRAMES
	s.frame = BREATH_POSE
	s.offset = Vector2(0, -tex.get_height() / 2.0)
	s.position = _board.tile_center(c) + Vector2(0, CELL_FOOT_DY)
	s.z_index = _board.tile_z(c, _board.Z_CELL)
	_cells.add_child(s)


## 机位：把这一批活跃格摆进「可用带」的正中。
##
## 正式盘的 `CWView.GAME_ZOOM` 1.27 是按 127 格配的 —— 教程第一关只有**两格**，
## 1.27 下那是屏幕正中一小撮豆子。开发日志 2026-09-11 留给 Kevin 的那条「小棋盘要不要推近」
## 这一版**推**：按活跃格的包围盒算 zoom，上限钉在菜单机位 3.2（再近 16px 的小细胞会糊成粗块）。
##
## 可用带随右栏在不在而变：没有右栏用整屏宽（第一、二关），有右栏让出 264 + 8。
## 纵向让出底部那条 —— 传进来的 `bottom` 就是对白面板 / 任务条的上沿。
func _frame_board(tiles: Array, with_panel: bool, bottom: float) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c: Vector2i in tiles:
		var p: Vector2 = _board.tile_center(c)
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var bbox := Vector2(hi.x - lo.x + TILE_W, hi.y - lo.y + TILE_H)
	var left := 12.0
	var right := DLG_RIGHT_WITH_PANEL if with_panel else CWView.screen_size().x - 12.0
	var band := Vector2(right - left, bottom - 16.0 - 16.0)
	var zoom := clampf(minf(band.x * FIT / bbox.x, band.y * FIT / bbox.y), ZOOM_MIN, ZOOM_MAX)
	var focus := (lo + hi) / 2.0
	var anchor := Vector2((left + right) / 2.0, 16.0 + band.y / 2.0)
	_cam.zoom = Vector2(zoom, zoom)
	_cam.position = CWView.camera_pos_for(focus, anchor, zoom, CWView.screen_size())


## 一块 2px 描边底板（设计稿里所有面板 / 按钮都是这一种，见 CWStyle.box）
func _plate(r: Rect2, border_a: float, bg: Color) -> void:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", CWStyle.box(border_a, bg))
	p.position = r.position
	p.size = r.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(p)


## 只有描边、没有底色的一圈（控件高亮用）
func _stroke(r: Rect2, ink: Color, width: int) -> void:
	var b := StyleBoxFlat.new()
	b.bg_color = Color(0, 0, 0, 0)
	b.border_color = ink
	b.set_border_width_all(width)
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", b)
	p.position = r.position
	p.size = r.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(p)


func _label(text: String, size: int, ink: Color, at: Vector2) -> Label:
	var l := CWStyle.label(text, size, ink)
	l.position = at
	_stage.add_child(l)
	return l


func _w(text: String, size: int) -> float:
	return CWStyle.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## 把一条字形带（满高 = 字号）对中到高 h 的框里。
## 这套点阵字的行框虚高（ascent 比字号大），交给行框居中一定偏 —— 同 CWStyle.keycap 的算法。
func _mid(h: float, size: int) -> float:
	return (h - size) / 2.0 - (CWStyle.FONT.get_ascent(size) - size)


## 像素箭头：3px 杆 + 11px 底边的实心三角，**只按 90° 整数倍旋转**（最近邻下逐像素不变形）。
## dir：0 下 / 1 左 / 2 上 / 3 右。`k` 是整数倍放大，同样只取整数。
func _arrow(at: Vector2, dir: int, ink: Color, k: int = 2) -> void:
	var s := Sprite2D.new()
	s.texture = _arrow_tex()
	s.modulate = ink
	s.scale = Vector2(k, k)
	s.rotation = dir * PI / 2.0
	s.position = at
	_stage.add_child(s)


var _arrow_cache: ImageTexture


func _arrow_tex() -> ImageTexture:
	if _arrow_cache != null:
		return _arrow_cache
	var img := Image.create(11, 12, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 6:                                   ## 杆
		for x in range(4, 7):
			img.set_pixel(x, y, Color.WHITE)
	for i in 6:                                   ## 三角，每行收一格
		var y := 6 + i
		for x in range(i, 11 - i):
			img.set_pixel(x, y, Color.WHITE)
	_arrow_cache = ImageTexture.create_from_image(img)
	return _arrow_cache
