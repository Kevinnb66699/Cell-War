## elm_cards.gd —— CardUpdater（迁移 cw_cards）：纯函数，父 update 的处理环节。
##
## 卡池尚未定义（说明 #2）：所有抽卡得到「空白卡」，只计入手牌数、无任何效果。
## 卡牌内容定稿后，在这里实现 即时/能力 两类卡的抽取与结算。
class_name ElmCards
extends RefCounted


static func draw(s: Dictionary, cell: Dictionary, source: String, effects: Array) -> void:
	cell["hand"] += 1
	ElmGame.add_log(s, effects, "　%s 经由「%s」抽到空白卡（卡池未定义；手牌 %d）" % [
		ElmGame.cell_name(s, cell), source, cell["hand"]])
