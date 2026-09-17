extends RefCounted
## 假联机客户端（t_play_queue 用）：只有 CWKernelRemote 用到的三样 —— stream / answer / dispose。
## 单独一个文件：测试里的内部类有时解析不到（fx_recorder.gd 同因），用 load() 现取最稳。
var stream: Array = []
var answered: Array = []      ## [ask_id, index] 逐条
var disposed := false


func answer(ask_id: int, index: int) -> void:
	answered.append([ask_id, index])


func dispose() -> void:
	disposed = true
