extends CWHeuristicBridge
## 测试用消费者（t_play_queue 批 1 步 4）：show_fx 是要等两帧的协程、show_result 立即落地，把先后顺序记在 order 里。
## 验「顺序播：有时长的演出播完才放下一条」与「快进：退回触发即走」。
## 单独一个文件：内部类 extends 全局类在测试脚本解析时解析不到父类（kernel_probe_bridge.gd 同因）。
var order: Array = []


func show_fx(kind: String, _data: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	await tree.process_frame
	order.append("fx:" + kind)


func show_result(text: String, _at: Vector2i, _linger := false) -> void:
	order.append("result:" + text)
