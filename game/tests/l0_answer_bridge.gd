## l0_answer_bridge.gd —— L0 里按**语义键**作答中途询问的脚本桥（批 5b 卡牌半边）
##
## 为什么要它：GD 的卡牌中途选择是协程里的 `await game.ask(...)`，没有任何挂起态字段 ——
## 没装桥时基类恒答 0（= 「停止 / 放弃」），一张会问的卡会一路跑到底，而 C# 那边停在 `Pending*` 上。
## 两侧要可比，就得在**同一个 op 里**把询问序列答完；作答用语义键（`CWSemKey`），与 L1 重放同一套。
##
## 单独成文件是因为测试脚本里的内部类不能 extends 全局类（xcheck_bridge.gd / fx_recorder.gd 同因）。
extends CWBridge

var answers: PackedStringArray = PackedStringArray()
var used := 0
var asked: Array = []
var errors: Array = []


func ask(req: Dictionary) -> int:
	var keys := PackedStringArray()
	for o in req["options"]:
		keys.append(CWSemKey.key(req, o["data"]))
	asked.append({ "kind": str(req.get("kind", "")), "tag": str(req.get("tag", "")), "keys": keys })
	if used >= answers.size():
		errors.append("第 %d 问没有作答（kind=%s tag=%s）；可选：%s" % [
			asked.size(), str(req.get("kind", "")), str(req.get("tag", "")), " / ".join(keys)])
		return 0
	var want := answers[used]
	used += 1
	for i in keys.size():
		if keys[i] == want:
			return i
	errors.append("第 %d 问里没有语义键「%s」；可选：%s" % [asked.size(), want, " / ".join(keys)])
	return 0
