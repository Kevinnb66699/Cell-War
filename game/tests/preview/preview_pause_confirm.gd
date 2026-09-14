extends SceneTree
## 退出确认页的六档对照 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这里改的是**字**，而字的毛病只有看得见。
## Kevin 2026-09-10 报的正是「回放里退出写着『离开后本局由 AI 代打』」——
## 一句在本地 / 联机都对、只在回放里是假话的小字。
##
## 2026-09-13 又加一种身份：**观战**。观众没有席位，「离开后本局由 AI 代打」与
## 「当前对局不会保存」对他都是假的（Kevin 两张截图）—— 两页都换成「你是观众，×× 不影响这一局」。
##
## 顺带钉住一处排版：回放那档**一句小字都不写**，而副标题为空时
## `CWPauseMenu._rebuild` 会把整块收高 20px（head 少一行）。摆一起就看得出来。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_pause_confirm.gd -- <输出.png>
const WARMUP := 16
const PANEL_Y := 100.0
## 六档 = 六句**不一样的**小字。本地两页同句，只摆一格当参照；
## 联机有席位与观战各两页（2026-09-13 先后改的就是这四句）；回放一句都不说
const CASES := [
	{ "online": false, "replay": false, "watch": false, "page": "menu", "cap": "本地 · 返回主菜单" },
	{ "online": true, "replay": false, "watch": false, "page": "quit", "cap": "联机有席位 · 退出游戏（改）" },
	{ "online": false, "replay": true, "watch": false, "page": "menu", "cap": "回放（09-10 改的）" },
	{ "online": true, "replay": false, "watch": false, "page": "menu", "cap": "联机有席位 · 离开房间" },
	{ "online": true, "replay": false, "watch": true, "page": "menu", "cap": "观战 · 离开房间（改）" },
	{ "online": true, "replay": false, "watch": true, "page": "quit", "cap": "观战 · 退出游戏（改）" },
]

var _out := "user://pause_confirm.png"
var _frames := 0
var _menus: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	## 面板是 Control，直接挂 root 会跟着棋盘相机跑（这仓库栽过三次）——
	## 一律进 CanvasLayer
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = CWView.screen_size()
	layer.add_child(bg)

	for i in CASES.size():
		var pm := CWPauseMenu.new()
		layer.add_child(pm)
		pm.online = bool(CASES[i]["online"])
		pm.replay = bool(CASES[i]["replay"])
		pm.watching = bool(CASES[i]["watch"])
		_menus.append(pm)
		var cap := CWStyle.label(String(CASES[i]["cap"]), CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		cap.position = Vector2(_x(i), _y(i) - 20.0)
		layer.add_child(cap)


## 六档摆成 3×2（原来三档一排；观战两页 2026-09-13 加进来就排不下了）
func _x(i: int) -> float:
	return 24.0 + float(i % 3) * 312.0


func _y(i: int) -> float:
	@warning_ignore("integer_division")
	return PANEL_Y + float(i / 3) * 250.0


func _process(_d: float) -> bool:
	_frames += 1
	## 摆状态要等第一帧：`_initialize` 跑在场景树立起来之前，那时 `_ready`
	## 还没轮到，`_build_chrome()` 造的东西一个都还不在（第一版就在这儿碰空）
	if _frames == 1:
		for pm: CWPauseMenu in _menus:
			pm.visible = true
			pm.get_child(0).visible = false   ## 压暗层：三块叠起来会黑成一片
			pm._show_page(String(CASES[_menus.find(pm)]["page"]))
		return false
	## 位置每帧摆：`_rebuild` 会把面板钉回屏幕正中，而这儿要三块并排
	for i in _menus.size():
		((_menus[i] as CWPauseMenu)._panel as Control).position = Vector2(_x(i), _y(i))
	if _frames < WARMUP:
		return false
	root.get_texture().get_image().save_png(_out)
	print("已保存 ", _out, "（六档退出确认页）")
	return true
