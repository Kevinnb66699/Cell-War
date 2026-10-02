extends CWKernel
## 测试用句柄（t_bridge_stale_ask / t_serve_ask_resend）：只答 `entry_seq()`，让询问桥的 `_await_playback` 等到测试把队列拨到这一号；
## `answer()` 只记下来（看联机那一侧「哪个答案真发出去了」）。
## 单独一个文件而不是测试里的内部类：内部类 extends 全局类在测试脚本解析时解析不到父类（kernel_slow_decider.gd 同因）。
var seq := 0
var answers: Array = []


func entry_seq() -> int:
	return seq


func answer(ask_id: int, choice: Dictionary) -> bool:
	answers.append([ask_id, choice])
	return true
