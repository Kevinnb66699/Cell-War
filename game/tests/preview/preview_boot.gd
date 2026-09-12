extends SceneTree
## 启动器那一屏的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这是玩家双击之后看见的**第一屏**，而它上面只有两样东西，
## 一行字和一个按钮。第一版的按钮只给了字，深色底上读起来就是「第二行说明」，
## 末字还被默认底框裁掉半个 —— 那只有出图才看得出来（2026-09-10 当场逮到）。
##
## **不让 Boot 进场景树**：`_ready` 一跑就要去连补丁站，出图不该依赖外网，
## 更不该跟网络快慢赛跑（本机网太好，等不到按钮露面就切场景了）。
## 所以只调 `_build_note()` 造那一层，再把它搬到预览的根上，自己摆状态。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_boot.gd -- <输出.png>
const WARMUP := 12

var _out := "user://boot.png"
var _frames := 0
var _boot: Node
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_boot = load("res://scripts/boot.gd").new()
	_boot._build_note()          ## 只造那一层，不跑 _ready（见文件头）
	var layer: CanvasLayer = _boot._note.get_parent()
	_boot.remove_child(layer)
	root.add_child(layer)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	var img := root.get_texture().get_image()
	match _shot:
		0:
			## 头两秒：只有一行字（绝大多数人只会看见这一帧闪一下）
			img.save_png(_out + "_checking.png")
			print("已保存 ", _out, "_checking.png（刚进来：只有一行字）")
			_boot._skip.visible = true
		1:
			img.save_png(_out + "_skip.png")
			print("已保存 ", _out, "_skip.png（等到 %.0f 秒：露出跳过）"
				% _boot.SKIP_AFTER)
			_boot._note.text = "有新版本需要完整更新，请到 GitHub Releases 下载新客户端"
			_boot._skip.visible = false
		2:
			img.save_png(_out + "_toold.png")
			print("已保存 ", _out, "_toold.png（基线太老：只报信、不给跳过）")
			_boot.free()
			return true
	_shot += 1
	_frames = WARMUP - 3
	return false
