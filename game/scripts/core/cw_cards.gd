## cw_cards.gd —— 卡牌系统（原型桩）
##
## 卡池尚未定义（说明 #2）：所有抽卡得到「空白卡」，只计入手牌数、无任何效果。
## 卡牌内容定稿后，在这里实现 即时/能力 两类卡的抽取与结算。
class_name CWCards
extends RefCounted

var game: CWGame


func draw(cell: Dictionary, source: String) -> void:
	cell["hand"] += 1
	game.log_msg("　%s 经由「%s」抽到空白卡（卡池未定义；手牌 %d）" % [
		game.cell_name(cell), source, cell["hand"]])
