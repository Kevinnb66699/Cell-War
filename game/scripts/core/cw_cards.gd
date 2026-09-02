## cw_cards.gd —— 抽卡
##
## **只做「抽到的是哪张卡」，不做效果**（效果在 CWCardFx）。
## draw() 是协程：抽到的事件卡立即结算，而结算可能要玩家中途做选择
## （趋化募集的走位、风暴的选人……），所以**所有调用点都要 await**。
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
		game.announce("抽卡落空", cell["pos"])
		return
	var kind: int = CWCardData.CARDS[card]["kind"]
	if kind == CWCardData.Kind.EVENT:
		## 事件卡不进手牌：立即结算并弃置（CWCardFx）。**别偷偷把它塞进手牌**，
		## 那会让手牌上限和界面都对不上规则。
		## 界面上必须喊一嗓子——不进手牌就没有飞卡动画，不喊的话玩家只看到
		## 「花了钱、没拿到卡」（2026-08-29 试玩第二轮：Kevin 被这个无声结算迷惑）。
		## 通报由各事件的结算自己发（带效果说明，试玩第五轮 Kevin 要求）；
		## 只有还没实现的事件在这里兜底喊一声。
		game.log_msg("　%s 经由「%s」抽到【事件】%s（立即结算并弃置）" % [
			game.cell_name(cell), source, card])
		if not await game.card_fx.resolve_event(cell, card):
			game.log_msg("　（该事件效果未实现，按无效果弃置）")
			game.announce("事件【%s】效果待实现" % card, cell["pos"])
		return
	cell["hand"].append(card)
	## 牌名只有本人能看：联机时别的席位看到的是公开替身（CWGame.log_msg 的后两个参数）
	game.log_msg("　%s 经由「%s」抽到【%s】%s（手牌 %d）" % [
		game.cell_name(cell), source, CWCardData.KIND_NAMES[kind], card,
		cell["hand"].size()], cell["pid"],
		"　%s 经由「%s」抽到 1 张卡（手牌 %d）" % [game.cell_name(cell), source, cell["hand"].size()])
	await discard_to_limit(cell)


## 手牌超上限时弃到上限。**PRD 2026-09-01 改写**：原本是「手牌已满时无法发动
## 【基因表达】、骨髓的卡留在原处」，现在是「每个细胞最多持有 8 张卡牌，
## 超过 8 张时需要弃置到 8 张」—— 决策点从**抽之前**挪到了**抽之后**：
## 照样抽得到，只是抽完要自己挑一张丢掉。
##
## 放在 draw() 里而不是各调用方：进手牌的口子只有这一个，摆这儿就漏不掉。
func discard_to_limit(cell: Dictionary) -> void:
	while cell["hand"].size() > CWData.HAND_MAX:
		var opts: Array = []
		for c in cell["hand"]:
			opts.append({ "label": "弃置【%s】" % c, "data": { "card": c } })
		var idx: int = await game.ask(cell["pid"], {
			"kind": "pick", "tag": "手牌上限",
			"prompt": "手牌 %d 张，超过上限 %d，选一张弃置" % [
				cell["hand"].size(), CWData.HAND_MAX],
			"options": opts,
		})
		var gone: String = opts[idx]["data"]["card"]
		cell["hand"].erase(gone)
		game.log_msg("　%s 手牌超限，弃置【%s】（手牌 %d）" % [
			game.cell_name(cell), gone, cell["hand"].size()])


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
