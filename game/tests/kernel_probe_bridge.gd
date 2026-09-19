extends CWHeuristicBridge
## 数引擎报了几条演出（t_kernel_inproc 用）：ask 照启发式桥答，只多记十个 show_* 各被调了几次。
## 单独一个文件而不是测试里的内部类：内部类 extends 全局类在测试脚本解析时解析不到父类（fx_recorder.gd 同因）。
var counts := {}


func _count(kind: String) -> void:
	counts[kind] = int(counts.get(kind, 0)) + 1


func show_roll(_reason: String, _value: int, _sides: int, _pid: int, _at: Vector2i) -> void:
	_count("roll")


func show_result(_text: String, _at: Vector2i, _linger := false) -> void:
	_count("result")


func show_card_played(_pid: int, _text: String, _info := {}) -> void:
	_count("card_played")


func show_event_drawn(_pid: int, _info := {}) -> void:
	_count("event_drawn")



func show_card_drawn(_pid: int, _info := {}) -> void:
	_count("card_drawn")


func show_notice(_text: String) -> void:
	_count("notice")


func show_beam(_from: Vector2i, _to: Vector2i, _splash: Array) -> void:
	_count("beam")


func show_erosion(_at: Vector2i, _dir: int) -> void:
	_count("erosion")


func show_fx(_kind: String, _data: Dictionary) -> void:
	_count("fx")
