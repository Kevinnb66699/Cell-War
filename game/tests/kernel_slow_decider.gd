extends CWBridge
## 测试用 decider（t_kernel_inproc 批 1 步 3 那几条）：每一问先记下来、一直等到 release() 或 abort() 才答（答 0）。
## 用来验「decider 路上 observe() 带得出正在问的那一问」与「kernel.abort() 唤得醒卡在 decider 里的一问」。
## 单独一个文件而不是测试里的内部类：内部类 extends 全局类在测试脚本解析时解析不到父类（kernel_probe_bridge.gd 同因）。
var waiting := {}
var asked := 0
var aborted := false
var _release := false


func ask(req: Dictionary) -> int:
	asked += 1
	waiting = req
	var tree := Engine.get_main_loop() as SceneTree
	while not _release and not aborted:
		await tree.process_frame
	_release = false
	waiting = {}
	return 0


func release() -> void:
	_release = true


func abort() -> void:
	aborted = true
