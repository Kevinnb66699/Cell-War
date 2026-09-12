extends SceneTree
## 知识之书搜索的预览图 —— 给人看的工具，不是测试（Kevin 2026-09-06 要的搜索功能）。
## 打开书、把词填进搜索框、铺出结果页，截一帧。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_codex_search.gd -- <输出.png> [搜索词]
const WARMUP := 20

var _out := "user://codex_search.png"
var _query := "血管"
var _frames := 0
var _book: CWCodex


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_query = args[1]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	_book = CWCodex.new()
	root.add_child(_book)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_book.open()
		_book._search.text = _query
		_book._search.grab_focus()
		_book._on_query(_query)
		return false
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
