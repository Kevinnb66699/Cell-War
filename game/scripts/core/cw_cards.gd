## cw_cards.gd —— 抽卡
##
## **只做「抽到的是哪张卡」，不做效果。** 66 张卡的效果是另一个量级的工作
## （其中 35 张还要先有一套修饰/触发框架，见 docs/PRD差异对照.md 第五节）。
## 现在抽到的卡有真名字、真类别、真权重，会进手牌、会占满 8 张的上限、
## 会被右侧竖条的方块数出来 —— 但打不出去。
##
## 卡的身份表在 [CWCardData]，由 tools/gen_card_data.py 从 PRD 生成。
class_name CWCards
extends RefCounted

var game: CWGame


## 抽一张。source 只用于日志（"基因表达" / "骨髓" / "突变"）。
##
## PRD 定的三条规矩都在这里：
##   ① 只从**该玩家当前等级**的池里抽（免疫按抗原记忆等级，癌症按世界回合分期）
##   ② 手上已有的同名【技能】、已装备的同名【永久技能】**从候选剔除**，
##      其余卡的相对权重不变；候选空了就抽不了
##   ③ 【事件】抽取后**立即结算并弃置**，不进手牌
func draw(cell: Dictionary, source: String) -> void:
	var card := pick(cell)
	if card == "":
		game.log_msg("　%s 的卡池已无合法卡牌，抽卡落空" % game.cell_name(cell))
		return
	var kind: int = CWCardData.CARDS[card]["kind"]
	if kind == CWCardData.Kind.EVENT:
		## 事件卡不进手牌：立即结算并弃置（CWCardFx）。**别偷偷把它塞进手牌**，
		## 那会让手牌上限和界面都对不上规则。
		game.log_msg("　%s 经由「%s」抽到【事件】%s（立即结算并弃置）" % [
			game.cell_name(cell), source, card])
		if not game.card_fx.resolve_event(cell, card):
			game.log_msg("　（该事件效果未实现，按无效果弃置）")
		return
	## 上限由调用方把关（CWActions._can_draw / collect_special）；这里再兜一道
	if cell["hand"].size() >= CWData.HAND_MAX:
		return
	cell["hand"].append(card)
	game.log_msg("　%s 经由「%s」抽到【%s】%s（手牌 %d）" % [
		game.cell_name(cell), source, CWCardData.KIND_NAMES[kind], card,
		cell["hand"].size()])


## 按权重从合法候选里抽一张，抽不出返回空串。
## **必须走 game.rng**（确定性回放的前提），候选顺序由 CWCardData 固定。
func pick(cell: Dictionary) -> String:
	var legal: Array = []
	var total := 0
	for c in CWCardData.pool_of(cell["faction"], game.immune_level, game.round_no):
		if not is_legal(cell, c["name"]):
			continue
		legal.append(c)
		total += int(c["weight"])
	if total <= 0:
		return ""
	var r: int = game.rng.randi_range(1, total)
	for c in legal:
		r -= int(c["weight"])
		if r <= 0:
			return c["name"]
	return legal[legal.size() - 1]["name"]


## 这张卡此刻能不能被这个细胞抽到。
## 同名限制**只管技能**：事件卡抽完就弃，不存在「手上已经有一张」的情况。
func is_legal(cell: Dictionary, card: String) -> bool:
	if CWCardData.CARDS[card]["kind"] == CWCardData.Kind.EVENT:
		return true
	return not (card in cell["hand"]) and not (card in cell["equipped"])
