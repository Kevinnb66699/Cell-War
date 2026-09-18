extends RefCounted
## 假联机客户端（t_play_queue 用）：只有 CWKernelRemote 用到的三样 —— stream / answer / dispose。
## 单独一个文件：测试里的内部类有时解析不到（fx_recorder.gd 同因），用 load() 现取最稳。
var stream: Array = []
var answered: Array = []      ## [ask_id, index] 逐条
var keys: Array = []          ## 随 answer 一起发的语义键（批 1 步 4）
var sent: Array = []          ## send() 发出去的报文（query RPC）
var query_results: Array = []
var disposed := false


func answer(ask_id: int, index: int, key := "") -> void:
	answered.append([ask_id, index])
	keys.append(key)


func send(m: Dictionary) -> void:
	sent.append(m)


func dispose() -> void:
	disposed = true
