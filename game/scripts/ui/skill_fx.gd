## skill_fx.gd —— 一次性技能演出的合集（issue #15，2026-09-11）：照 tools/art-preview R4 团队选定的那几案逐笔复刻
##
## **一只节点画全部**：每种演出是这里的一个 kind，`play(kind, data)` 登记一条、`sync()` 走时间、
## `_draw()` 把还在演的逐条画出来。不给每种演出各建一个类 —— 它们只有「一段时间 + 几笔像素」，
## 共用的是 CWPix 那几支笔和同一套时间量化，各建一类只会多出十几份一模一样的 play/sync。
## 需要**代画细胞**或**常驻**的不在这里：连锁吞噬（CWChainFx）、囊性护甲 / 刚性屏障 / 头顶标记（CWCellDeco）。
##
## 坐标是**棋盘像素**，由 CWUIBridge.show_fx 换算好再给（细胞位 = 格顶面中心 + CELL_FOOT_DY，格位 = 格顶面中心）。
## 选稿里 0.65 秒的起手静止一律去掉：游戏里演出跟在结算之后，不需要「先看清局面」那一拍。
##
## 沿用像素纪律（chemo_fx.gd 头注）：① 整数像素（CWPix 负责）② 时间按 PIX_FPS 量化 ③ 透明度只取几档。
##
## 各 kind 的数据字段（Vector2 / Array[Vector2]）：
##   antibody      from（B 细胞）targets（癌细胞们）           immune-skills.js antibody v0「单发重击」
##   toxin         from（T 细胞）tiles（1 环七格）             immune-skills.js toxin v0「同步散射」
##   lyse          from（T 细胞）to（固化格）                   revised-effects.js lyse v1「三点连爆」
##   adhesion      from / to（两只癌细胞）                     immune-skills.js adhesion v1「紫晶冠印传递」
##   homing        from / to（血管格 / 落点）spread（被感染格）  revised-effects.js homing「双端血门 · 感染扩散」
##   pseudopod     from / to（旧格 / 新格）roots（伸触手的癌性邻格）from_body / r（旧格上的胞体中心 / 半径）
##                 cid（被拉的细胞）to_tile（新格的轴坐标，定殖过场等它）revised-effects.js pseudopod v0「低弧牵引」，issue #26 改成拉细胞
##   minimal       from / to（两格）                            cancer-skills.js minimal v0「细线疾行」
##   differentiate at（免疫细胞）                               common-skills.js differentiate v2「粒子重组」
##   respire       at（免疫细胞脚底）at_body / r（胞体中心 / 半径）  common-skills.js respire v0「轻量吸收」
##   revive_immune at（复活格）                                 common-skills.js revive v0「归拢重生」
##   revive_cancer at（复活格）                                 common-skills.js revive v0「归拢重生」（铜色）
##   mutate        at（癌细胞）                                 common-skills.js mutate v0「双股消散」
##   anaerobic     at（癌细胞脚底）at_body / r sources（同连通块的癌性格）  revised-effects.js anaerobic v0「铜橙输能」
##   —— 卡牌粒子（issue #28，选稿 R5 card-effects.js；键全是**格位**，画的时候格心往上挪几像素）——
##   card_radiation    tiles（放疗区域）                          光柱逐格落下，落地碎粒
##   card_storm        at（所选免疫）tiles（2 环内全部格）         青色碎粒逐格扬起，再扬一次
##   card_inflammation at（自身）tiles（自身 + 六邻）              同上，暖橙
##   card_granule      from（攻击方）to（目标）                    橙色注入流 ×3，目标碎粒
##   card_acid         from（癌细胞）to（免疫）                    同上，紫红
##   card_cascade      from / to / tiles（转健康的邻格）            冰蓝流打中目标，再传到那两格
##   card_transfer     from（付方）to（收方）                      青流 ×3，收方回拢亮点
##   card_teleport     from（原格）to（落点）                      原格散开，落点回拢
##   card_mark         from（呈递者）to（目标）                    头顶到头顶的粉流，到了立一枚菱形头标
##   card_repair       at（自身格）                                切角徽盾由大到小收束
##   card_survive      at（自身格）                                散开再回拢（免死，人还在原格）
##   card_degrade      at（固化格）                                矿物层散去
##   card_clone        at（自身格）tiles（转癌的邻格）tiles_axial（同一批的轴坐标，定殖过场等它）
##   card_blood        drawer（抽卡者格）cells（全体癌细胞格）       各自回拢血色碎粒，抽卡者那口更大
##   （抗体依赖细胞毒作用复用 antibody（单目标）、糖酵解爆发复用 anaerobic）
##   —— 固化癌组织的生成 / 解除（issue #52 与 #53 ⑥ 成对，2026-09-19）——
##   solid_form        at（格位）z（那一格的 tile_z）  马赛克块从四周飞拢，落位就是那块六边形纹理
##   solid_break       at / z 同上                      纹理散成同样的块飞开
##   这两条**不由引擎报**：`CWMatch._sync_tiles` 看镜像里 tissue 进 / 出 SOLID 的差分开演
##   （同 `CWTeleportFx` 那条先例，`teleport_fx.gd:8-9`）—— 内核与协议一字不动。
##
## `*_body` / `r` 是 CWUIBridge.show_fx 按那一格上细胞贴图的高度另算的（issue #26：有氧 / 无氧原来对着
## 脚底收拢，看着错位；粒子堆在贴图上的一点很诡异）。没给就退回脚底的老画法（测试的裸数据、旧报文）。
class_name CWSkillFx
extends Node2D

const PIX_FPS := 12.0
const DURATION := {
	"antibody": 1.4, "toxin": 1.05, "lyse": 2.05, "adhesion": 1.2, "homing": 2.9,
	"pseudopod": 1.0, "minimal": 1.2, "differentiate": 1.65, "respire": 1.65,
	"revive_immune": 1.65, "revive_cancer": 1.65, "mutate": 1.2, "anaerobic": 2.1,
	## 卡牌粒子（issue #28）：选稿 R5 的收场时刻减去开头 0.4 s 静止（CARD_LEAD）
	"card_radiation": 1.9, "card_storm": 1.9, "card_inflammation": 1.9,
	"card_granule": 1.7, "card_acid": 1.7, "card_cascade": 2.8,
	"card_transfer": 2.0, "card_teleport": 2.1, "card_mark": 2.0, "card_repair": 1.9, "card_survive": 1.9,
	"card_degrade": 1.3, "card_clone": 2.1, "card_blood": 1.6,
	## 固化的生成 / 解除（issue #52 / #53 ⑥）：生成稍长一点 —— 聚拢要看得出「在结晶」
	"solid_form": 0.9, "solid_break": 0.75,
}
## 头顶标记离细胞位多高（同 CWCellDeco.HEAD_DY）：黏连的传递轨迹从头到头
const HEAD_DY := -33.0
## 伪足穿透的四拍（issue #26，HXR-I：细胞已经到了新格触手还在演，要的是触手把细胞拉 / 推过去）：
## 冒根 0~0.1 → 触手伸到**旧格**抓住胞体 0.1~0.25 → 拉着细胞走到新格 0.25~0.65 → 收回 0.65~0.9。
## 细胞这不到一秒画在哪由 carry_pos() 代管（CWMatch._sync_cells 每帧问），引擎那边 pos 早已是新格。
## issue #29（2026-09-12）：原来 2.4 秒（拉那段 0.9~1.8）嫌慢 —— 别的细胞是瞬移，伪足也得跟上，
## 整段压到 1.0 秒、细胞 0.65 秒到格；拉的那段和巨噬扑咬的冲刺（CWChainFx.LUNGE_FOR 0.43）一个量级。
const PSEUDOPOD_SPROUT := 0.1
const PSEUDOPOD_REACH := 0.15
const PSEUDOPOD_PULL_AT := 0.25
const PSEUDOPOD_PULL := 0.4
const PSEUDOPOD_RETRACT_AT := 0.65
const PSEUDOPOD_RETRACT := 0.25

const ICE := Color("b7ecff")
const ICE_TAIL := Color("5688a5")
const ICE_FLASH := Color("edfaff")
const ICE_RING := Color("ccefff")
const VIOLET := Color("b88aff")
const VIOLET_BURST := Color("cab0ec")
const LYSE_INK := Color("efb96e")
const LYSE_GRAIN := Color("fff0cb")
const LYSE_CORE := Color("fff1ce")
const MARK_INK := Color("c39bff")
const BLOOD := Color("dd5265")
const BLOOD_PALE := Color("ffc1d3")
const BLOOD_STREAM := Color("dc536d")
const BLOOD_SPARK := Color("ffd1db")
const BLOOD_BURST := Color("f7a0b7")
const BLOOD_SPREAD := Color("dc738b")
const ROOT := Color("704449")
const ROOT_STEM := Color("cb807d")
const ARM_DARK := Color("593941")
const ARM_LIGHT := Color("cb807d")
const ARM_TIP := Color("f3b7a3")
const STEEL := Color("8aa9b8")
const CYAN := Color("83dce2")
const COPPER := Color("d98d68")
const PINK := Color("e88a9c")
## 固化癌组织那块马赛克直接从**它自己的贴图**取色（Kevin 2026-09-13，issue #31：
## 原来那把灰白石粒看着像「白块溶解」，应该是固化癌组织碎开）。取满档那张，变体 0。
## 2026-09-19 起它不再服务「碎石重生」，而是固化的生成 / 解除（issue #52 / #53 ⑥）。
const SOLID_TEX := preload("res://assets/art/solidify/tissue_cancer_20_0.png")
## 贴图里顶面中心的像素坐标：32×34 的图，横向正中 16；顶面中心比贴图中心高 4px（CWBoard.TOP_FACE_DY）
const SOLID_TEX_CENTER := Vector2i(16, 13)
const ANAEROBIC := Color("e58b65")
const ANAEROBIC_RISE := Color("f5c79a")
## ---- 卡牌粒子（issue #28，选稿 R5 card-effects.js）----
## 选稿开头那 0.4 秒静止去掉：游戏里的 t = 选稿的 t − CARD_LEAD（画的时候加回去，公式照抄选稿）
const CARD_LEAD := 0.4
## 选稿全以**格顶面中心**为锚（position()）；细胞相关的点只是格心往上挪：碎粒中心 −4、输送线 −7、
## 头顶 −27（= 脚底 + HEAD_DY，和常驻的【标记】头标同一点）
const CARD_DUST_DY := -4.0
const CARD_FLOW_DY := -7.0
const CARD_HEAD_DY := -27.0
## 【克隆增殖】第 i 格的感染流 1.3 + 0.3i 秒（选稿钟）到，定殖过场等到那一刻才翻（arrival_in）
const CLONE_FLIP_AT := 1.3
const CLONE_STAGGER := 0.3
const CARD_CYAN := Color("30d1fa")
const CARD_ICE := Color("9cdff1")
const CARD_AMBER := Color("ffb03a")
const CARD_SAND := Color("e8d9a0")
const CARD_MAUVE := Color("c980a0")
const CARD_ROSE := Color("ff609c")
const CARD_WHITE := Color("eaf8fc")
## 细胞膜修复的盾（Kevin 2026-09-13：选稿那面描边盾「太丑了，应该做成简约像素风」）。
## 现在是**手写的像素蒙版**：25 宽 30 高、平顶直边、下半收尖 —— 一眼就是「盾」的最少笔画，
## 静止那一档正好圈住细胞（32×32 的贴图里胞体约 24px 宽）。
## 只按**整数倍**放大（3 → 2 → 1 三跳收束），像素风最忌讳的就是非整数缩放。
##
## 写成**半宽表**而不是逐行 [y, x0, x1]：短一半，而且左右天然严格对称 —— 像素盾差一列就歪。
const SHIELD_TOP := -15
const SHIELD_HALF: Array = [10,
	12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
	11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 1, 0]


## 盾的每一行 [y, x0, x1]（相对盾心）。**纯函数**，护栏直接核对称与收尖
static func shield_rows() -> Array:
	var out: Array = []
	for i in SHIELD_HALF.size():
		var h: int = SHIELD_HALF[i]
		out.append([SHIELD_TOP + i, -h, h])
	return out
const SHIELD_FILL_A := 0.14

## ---- 抗体命中的打击感（issue #53 ①「受击者应该有震动的打击感特效」）----
## 抗体飞 ANTIBODY_HIT 秒到，之后受击者横向抖 HIT_SHAKE_FOR 秒、幅度线性收敛。
## 细胞的 position 每帧被 `CWMatch._sync_cells` 覆写，所以抖动和伪足的 `carry_pos` 一样
## 由这里代管：那边每帧问 `shake_offset(细胞位)`，把返回的偏移叠上去。
const ANTIBODY_HIT := 0.8
const HIT_SHAKE_FOR := 0.28
const HIT_SHAKE_PX := 3.0
## ---- 早期血行转移的血门（issue #53 ④「圆圈应该是伪 3D 有倾斜效果」）----
## 原来 squash 0.85 几乎是个正圆，立在格子上像一枚贴纸。压到 0.42 再斜 HOMING_TILT，
## 血门就**躺在地面上**了；同一圈往下挪 HOMING_RIM 再淡画一遍 = 门圈的厚度。
const HOMING_SQUASH := 0.42
const HOMING_TILT := -0.16
const HOMING_RIM := 2.0
## 血流什么时候出发 / 落地。癌细胞的传送演出按这两拍对时（见 `homing_elapsed`）：
## 粒子流发出后细胞才缩小消失，流落地了才在目标格放大出现（issue #53 ④）。
const HOMING_LAUNCH := 0.05
const HOMING_STREAM := 1.25
const HOMING_LAND := 1.3
## ---- 固化癌组织的生成 / 解除（issue #52 / #53 ⑥）----
const SOLID_SPREAD := 22.0      ## 散开时块心离本位多远（一格宽 36，散到半格出头正好还认得出是这一格）
const SOLID_STAGGER := 0.45     ## 错峰占整段的比例：每块按自己的散列先后动身
const SOLID_SPARK := Color("e8d9a0")   ## 还在飞的块提亮到这个矿物白，落位了才退回贴图本色

var _plays: Array = []      ## [{ kind, t, data, dots }]


## 地面贴花：**一格一个节点，各拿自己那格的 z**。
## 一个节点只有一个 `z_index`，而棋盘是按排分层的（组织块的 z = 自己的贴图 y，前一排 +20）——
## 拿一层 z 铺七格，必有几格被前排盖掉。同 `CWMarkAuraFx.TileDots` / `CWBoard._marks` 的做法。
##
## 谁走这条路：**画在地上、不该盖住站在那儿的细胞**的那几种 ——
## 细胞毒素（issue #53 ③「细胞毒素图层应该在细胞之下，现在在细胞之上」）、
## 固化的生成 / 解除（那本来就是地面那块组织）。z 由 `CWUIBridge` / `CWMatch` 算好传进来
## （`tile_z(格, Z_MARK)`：比自己那格高、比细胞低），演出层不认识棋盘。
class GroundDot:
	extends Node2D
	var kind := ""
	var t := 0.0
	var from_local := Vector2.ZERO   ## 发动者相对本格的偏移（细胞毒素的颗粒从那儿飞来）

	func _draw() -> void:
		match kind:
			"toxin": CWSkillFx.draw_toxin(self, t, from_local, Vector2.ZERO)
			"solid_form": CWSkillFx.draw_solid_mosaic(self, t / CWSkillFx.duration(kind))
			"solid_break": CWSkillFx.draw_solid_mosaic(self, 1.0 - t / CWSkillFx.duration(kind))


func _init() -> void:
	visible = false


func play(kind: String, data: Dictionary) -> void:
	if not DURATION.has(kind):
		return
	var entry := { "kind": kind, "t": 0.0, "data": data, "dots": _spawn_dots(kind, data) }
	_plays.append(entry)
	visible = true
	queue_redraw()


## 这一条要不要地面贴花：数据里带了 z 才有（无头测试 / 旧报文不带 → 退回主层老画法）
func _spawn_dots(kind: String, data: Dictionary) -> Array:
	var out: Array = []
	if kind == "toxin" and data.has("tiles_z"):
		var origin := _v(data, "from")
		var tiles := _pts(data, "tiles")
		var zs: Array = data["tiles_z"]
		for i in mini(tiles.size(), zs.size()):
			out.append(_add_dot(kind, tiles[i], int(zs[i]), origin - tiles[i]))
	elif (kind == "solid_form" or kind == "solid_break") and data.has("z"):
		out.append(_add_dot(kind, _v(data, "at"), int(data["z"]), Vector2.ZERO))
	return out


func _add_dot(kind: String, at: Vector2, z: int, from_local: Vector2) -> GroundDot:
	var dot := GroundDot.new()
	dot.kind = kind
	dot.from_local = from_local
	dot.position = at
	dot.z_as_relative = false   ## 本层挂在 Z_OVER_BOARD 上，贴花要的是**格子自己那一层**
	dot.z_index = z
	add_child(dot)
	return dot


func active() -> int:
	return _plays.size()


## 拆局：把这一层擦干净（Kevin 2026-09-13：上一局的特效留在等待室的棋盘上）。
## **每个特效层都要有这个**：它们靠 `sync()` 每帧推进，也靠 `sync()` 把自己藏起来 ——
## 拆局之后没人再调 sync，最后那一帧就永远停在屏幕上。
func clear() -> void:
	for p in _plays:
		_free_dots(p)
	_plays.clear()
	visible = false
	queue_redraw()


func sync(delta: float) -> void:
	if _plays.is_empty():
		return
	var keep: Array = []
	for p in _plays:
		p["t"] = float(p["t"]) + delta
		if float(p["t"]) < duration(String(p["kind"])):
			for dot: GroundDot in p["dots"]:
				dot.t = float(p["t"])
				dot.queue_redraw()
			keep.append(p)
		else:
			_free_dots(p)
	_plays = keep
	visible = not _plays.is_empty()
	queue_redraw()


func _free_dots(p: Dictionary) -> void:
	for dot: GroundDot in p.get("dots", []):
		if is_instance_valid(dot):
			dot.queue_free()
	p["dots"] = []


static func duration(kind: String) -> float:
	return float(DURATION.get(kind, 0.0))


## 伪足拉到哪了：0 = 还按在旧格，1 = 到新格。缓入缓出，抓稳了才起步、快到了才慢下来
static func pull_phase(t: float) -> float:
	var f := CWPix.phase(t, PSEUDOPOD_PULL_AT, PSEUDOPOD_PULL)
	return f * f * (3.0 - 2.0 * f)


## 被伪足拉着走的细胞此刻该画在哪（**脚底**坐标，和 CWMatch 摆细胞用的是同一个点）；没被拉 → null。
## 时间按 PIX_FPS 量化，和触手的画面同步走格。同一只细胞连着两次被拉（AI 连走）以最新那条为准。
func carry_pos(cid: int) -> Variant:
	for k in range(_plays.size() - 1, -1, -1):
		var p: Dictionary = _plays[k]
		if String(p["kind"]) != "pseudopod" or int((p["data"] as Dictionary).get("cid", -1)) != cid:
			continue
		var t: float = floorf(float(p["t"]) * PIX_FPS) / PIX_FPS
		if t >= PSEUDOPOD_RETRACT_AT:
			return null
		var d: Dictionary = p["data"]
		var foot_from := _v(d, "from") + Vector2(0, CWMatch.CELL_FOOT_DY)
		var foot_to := _v(d, "to") + Vector2(0, CWMatch.CELL_FOOT_DY)
		return foot_from.lerp(foot_to, pull_phase(t))
	return null


## 有演出正往这一格「送东西」的话，还有几秒到；没有 → -1。定殖过场（CWUIBridge.show_erosion →
## CWErosionFx.play 的 delay）拿它等到了再翻格：伪足穿透等细胞到格（PSEUDOPOD_RETRACT_AT，issue #29：
## 原来细胞还在半路格子就红了）；【克隆增殖】第 i 格等自己那道感染流（issue #28）。
## 同一格连着两条以最新的为准，和 carry_pos 一个道理。
func arrival_in(tile: Vector2i) -> float:
	for k in range(_plays.size() - 1, -1, -1):
		var p: Dictionary = _plays[k]
		var d: Dictionary = p["data"]
		var at := -1.0
		match String(p["kind"]):
			"pseudopod":
				if d.has("to_tile") and d["to_tile"] == tile:
					at = PSEUDOPOD_RETRACT_AT
			"card_clone":
				var i: int = (d.get("tiles_axial", []) as Array).find(tile)
				if i >= 0:
					at = CLONE_FLIP_AT + float(i) * CLONE_STAGGER - CARD_LEAD
		if at < 0.0:
			continue
		return maxf(0.0, at - float(p["t"]))
	return -1.0


## 抗体打在身上抖多少（issue #53 ①）。横向高频、幅度线性收敛，**取整**（像素纪律 ①）。**纯函数**
static func hit_shake(age: float) -> Vector2:
	if age < 0.0 or age >= HIT_SHAKE_FOR:
		return Vector2.ZERO
	return Vector2(roundf(sin(age * 62.0) * HIT_SHAKE_PX * (1.0 - age / HIT_SHAKE_FOR)), 0.0)


## 站在 `at`（细胞位 = 格顶面中心 + CELL_FOOT_DY）上那只细胞这一帧要叠的抖动偏移；没被打中 → 零。
## `CWMatch._sync_cells` 每帧问一次 —— 和伪足的 `carry_pos` 同一个道理：细胞的 position
## 每帧被那边覆写，演出层想让它动就只能把偏移交出去。
func shake_offset(at: Vector2) -> Vector2:
	var out := Vector2.ZERO
	for p in _plays:
		if String(p["kind"]) != "antibody":
			continue
		var t: float = floorf(float(p["t"]) * PIX_FPS) / PIX_FPS
		for tp: Vector2 in _pts(p["data"] as Dictionary, "targets"):
			if tp.distance_to(at) <= 4.0:
				out += hit_shake(t - ANTIBODY_HIT)
	return out


## 这两格之间有没有正在演的【早期血行转移】；有 → 它已经演了几秒，没有 → -1。
## `CWMatch._play_teleports` 拿它给癌细胞的传送演出对时（issue #53 ④：
## 粒子流发出后才缩小消失、流落地了才在目标格放大出现）。同一对格以最新那条为准。
func homing_elapsed(from: Vector2, to: Vector2) -> float:
	for k in range(_plays.size() - 1, -1, -1):
		var p: Dictionary = _plays[k]
		if String(p["kind"]) != "homing":
			continue
		var d: Dictionary = p["data"]
		if _v(d, "from").distance_to(from) <= 4.0 and _v(d, "to").distance_to(to) <= 4.0:
			return float(p["t"])
	return -1.0


func _draw() -> void:
	for p in _plays:
		var t: float = floorf(float(p["t"]) * PIX_FPS) / PIX_FPS
		var d: Dictionary = p["data"]
		## 走了地面贴花的那几条这一层不再画（贴花按格子的 z 各画各的，见 GroundDot）
		if not (p["dots"] as Array).is_empty():
			continue
		match String(p["kind"]):
			"antibody": _antibody(t, d)
			"toxin": _toxin(t, d)
			"solid_form": draw_solid_mosaic(self, t / duration("solid_form"), _v(d, "at"))
			"solid_break": draw_solid_mosaic(self, 1.0 - t / duration("solid_break"), _v(d, "at"))
			"lyse": _lyse(t, d)
			"adhesion": _adhesion(t, d)
			"homing": _homing(t, d)
			"pseudopod": _pseudopod(t, d)
			"minimal": _minimal(t, d)
			"differentiate": _differentiate(t, d)
			"respire": _respire(t, d)
			"revive_immune": _revive_immune(t, d)
			"revive_cancer": _revive_cancer(t, d)
			"mutate": _mutate(t, d)
			"anaerobic": _anaerobic(t, d)
			"card_radiation", "card_storm", "card_inflammation": _card_area(t, d, String(p["kind"]))
			"card_granule", "card_acid", "card_cascade": _card_hit(t, d, String(p["kind"]))
			"card_transfer": _card_transfer(t, d)
			"card_teleport": _card_teleport(t, d)
			"card_mark": _card_mark(t, d)
			"card_repair": _shield(_v(d, "at"), t + CARD_LEAD)
			"card_survive": _card_survive(t, d)
			"card_degrade": _dust(_v(d, "at"), CWPix.phase(t + CARD_LEAD, 0.55, 1.1), CARD_SAND)
			"card_clone": _card_clone(t, d)
			"card_blood": _card_blood(t, d)


static func _pts(d: Dictionary, key: String) -> Array:
	var out: Array = []
	for v in d.get(key, []):
		out.append(Vector2(v))
	return out


static func _v(d: Dictionary, key: String) -> Vector2:
	return Vector2(d.get(key, Vector2.ZERO))


## Y 形抗体直射：0.8 秒飞到，命中后 0.52 秒碎粒 + 一圈涟漪 + 头 0.12 秒一记白闪。
## issue #53 ①：**从细胞中心射到细胞中心**（原来两头都取脚底，看着是从肚子底下发出来的）。
## `from_body` / `targets_body` 由 CWUIBridge 按那一格上贴图的高度另算，没给就退回脚底的老画法。
func _antibody(t: float, d: Dictionary) -> void:
	var origin: Vector2 = _v(d, "from_body") if d.has("from_body") else _v(d, "from")
	for tp: Vector2 in (_pts(d, "targets_body") if d.has("targets_body") else _pts(d, "targets")):
		var f := clampf(t / ANTIBODY_HIT, 0.0, 1.0)
		if f < 1.0:
			var at := origin.lerp(tp, f)
			for k in range(1, 5):
				CWPix.px(self, origin.lerp(tp, clampf(f - float(k) * 0.026, 0.0, 1.0)), ICE_TAIL, 2)
			CWPix.line(self, at + Vector2(0, 3), at, ICE, 2)
			CWPix.line(self, at, at + Vector2(-3, -3), ICE, 2)
			CWPix.line(self, at, at + Vector2(3, -3), ICE, 2)
		var age := t - ANTIBODY_HIT
		if age >= 0.0 and age < 0.52:
			var hit := clampf(age / 0.52, 0.0, 1.0)
			CWPix.burst(self, tp, hit, ICE, 24, 25.0)
			if age < 0.12:
				CWPix.disc(self, tp, 6.0, ICE_FLASH, 0.8)
			CWPix.ring(self, tp, 4.0 + hit * 19.0, ICE_RING, 0.85)


## 紫色颗粒同时射向七格：0.65 秒飞到，落地 0.35 秒小爆。
## issue #53 ③「细胞毒素图层应该在细胞之下」：整只演出改走**地面贴花**（GroundDot），
## 一格一个节点各拿自己那格的 z。这里只剩没给 z 时的退路（无头测试 / 预览）。
func _toxin(t: float, d: Dictionary) -> void:
	var origin := _v(d, "from")
	for tp: Vector2 in _pts(d, "tiles"):
		draw_toxin(self, t, origin, tp)


## 一格的细胞毒素：颗粒从 from 飞到 to，落地小爆。**静态**，贴花与退路共用同一笔
static func draw_toxin(ci: CanvasItem, t: float, from: Vector2, to: Vector2) -> void:
	var f := clampf(t / 0.65, 0.0, 1.0)
	if f < 1.0:
		for j in 4:
			var along := clampf(f - float(j) * 0.026, 0.0, 1.0)
			var spread := float(j % 3 - 1) * 3.0
			var q := from.lerp(to, along)
			CWPix.px(ci, Vector2(q.x + spread, q.y - float(j % 2) * 3.0), VIOLET, 2)
	var age := t - 0.65
	if age >= 0.0 and age < 0.35:
		CWPix.burst(ci, to, age / 0.35, VIOLET_BURST, 10, 10.0)


## 三点连爆：三粒颗粒隔 0.27 秒送入固化格，1.2 秒起三处错开炸开。
## issue #53 ②：颗粒**从细胞中心**送出（原来也是从脚底），落点仍是那一格的地面
func _lyse(t: float, d: Dictionary) -> void:
	var a: Vector2 = _v(d, "from_body") if d.has("from_body") else _v(d, "from")
	var b := _v(d, "to")
	const DETONATE := 1.2
	for i in 3:
		var p := CWPix.phase(t, float(i) * 0.27, 0.5)
		var end := b + Vector2(float(i - 1) * 9.0, -4.0)
		if p > 0.0 and p < 1.0:
			CWPix.trail(self, a, end, p, LYSE_INK, 4)
			CWPix.disc(self, a.lerp(end, p), 3.0, LYSE_GRAIN)
		elif p >= 1.0 and t < DETONATE:
			CWPix.disc(self, end, 2.0, LYSE_INK)
	if t >= DETONATE and t < DETONATE + 0.85:
		for i in 3:
			var start := DETONATE + float(i) * 0.17
			var local := CWPix.phase(t, start, 0.4)
			if t >= start and local < 1.0:
				var c := b + Vector2(-10.0 + float(i) * 10.0, -3.0)
				CWPix.burst(self, c, local, LYSE_INK, 10, 18.0)
				CWPix.disc(self, c + Vector2(0, -1), 3.0 * (1.0 - local), LYSE_CORE)


## 标记从一只癌细胞的头顶传给另一只：一串紫粒 1.2 秒飞过去（新标记由 CWCellDeco 缩入）
func _adhesion(t: float, d: Dictionary) -> void:
	var s := _v(d, "from") + Vector2(0, HEAD_DY)
	var n := _v(d, "to") + Vector2(0, HEAD_DY)
	var f := clampf(t / 1.2, 0.0, 1.0)
	var q := s.lerp(n, f)
	for j in 4:
		CWPix.px(self, Vector2(q.x - float(j) * 3.0, q.y + float(j % 2)), MARK_INK, 2 if j == 0 else 1)


## 双端血门：两格各开一圈血环，血粒 1.25 秒流过去，落点炸一下，再逐格把感染送到邻格
## 【早期血行转移】那条血流第 f（0~1）处画在哪。**纯函数**，护栏直接核。
## 两个轴都插值（Kevin 2026-09-13 issue #37：「红线永远水平，不会连到传送目标」——
## 原来只插 x、y 钉死在起点那一行，落点在哪都横着甩出去）；
## 抖动垂直于连线，斜着连过去也仍是一条抖动的血流，而不是被压扁的正弦。
static func homing_stream_pos(a: Vector2, b: Vector2, f: float) -> Vector2:
	var dir: Vector2 = (b - a).normalized()
	return a.lerp(b, f) + Vector2(0, -7.0) + Vector2(-dir.y, dir.x) * (sin(f * PI * 4.0) * 4.0)


func _homing(t: float, d: Dictionary) -> void:
	var a := _v(d, "from")
	var b := _v(d, "to")
	var p := CWPix.phase(t, HOMING_LAUNCH, HOMING_STREAM)
	for gate in [[a, false], [b, true]]:
		var at: Vector2 = gate[0]
		var open: float = CWPix.phase(t, 0.2, 0.45) if bool(gate[1]) else 1.0 - CWPix.phase(t, 1.0, 0.6)
		if open > 0.0:
			## issue #53 ④：血门**躺在地上**（伪 3D）—— 压扁 + 整体倾斜，再往下挪两像素
			## 淡画一圈当门的厚度。原来 squash 0.85 几乎是正圆，立在格子上像一枚贴纸
			var c := at + Vector2(0, -7)
			var rim := BLOOD
			rim.a = 0.45
			CWPix.ring(self, c + Vector2(0, HOMING_RIM), 19.0 * open, rim, HOMING_SQUASH, 0.0, TAU, HOMING_TILT)
			CWPix.ring(self, c, 19.0 * open, BLOOD, HOMING_SQUASH, 0.0, TAU, HOMING_TILT)
			CWPix.ring(self, c, 16.0 * open, BLOOD_PALE, HOMING_SQUASH,
				t * 3.0, t * 3.0 + 4.7, HOMING_TILT)
	## 血流**两个轴都要插值**（Kevin 2026-09-13 issue #37：「红线永远水平，不会连到传送目标」）——
	## 原来只插 x、y 钉死在起点那一行，于是不管落点在哪，血流都横着甩出去。
	## 抖动改成**垂直于连线**的，斜着连过去也还是一条抖动的血流，而不是被压扁的正弦
	if p > 0.0 and p < 1.0:
		for i in 13:
			var f := clampf(p - float(i) * 0.022, 0.0, 1.0)
			CWPix.px(self, homing_stream_pos(a, b, f),
				BLOOD_STREAM if i % 3 != 0 else BLOOD_SPARK, 2 if i % 4 != 0 else 3)
	if t >= HOMING_LAND and t < HOMING_LAND + 0.55:
		CWPix.burst(self, b + Vector2(0, -4), CWPix.phase(t, HOMING_LAND, 0.55), BLOOD_BURST, 17, 23.0)
	var spread := _pts(d, "spread")
	for i in spread.size():
		var at: Vector2 = spread[i]
		var start := 1.6 + float(i) * 0.18
		var approach := CWPix.phase(t, start - 0.25, 0.25)
		var sp := CWPix.phase(t, start, 0.65)
		if approach > 0.0 and approach < 1.0:
			CWPix.trail(self, b, at, approach, BLOOD_SPREAD, 5)
		if t >= start and sp < 1.0:
			## 透明度只取三档（纪律 ③）
			var alpha := 1.0 if sp < 0.34 else (0.66 if sp < 0.67 else 0.33)
			for k in 9:
				var angle := float(k) * 2.399
				var radius := 3.0 + sp * 13.0
				CWPix.px(self, Vector2(at.x + cos(angle) * radius, at.y + sin(angle) * radius * 0.45 - sp * 7.0),
					Color(BLOOD_SPREAD if k % 3 != 0 else BLOOD_SPARK, alpha), 1 if k % 3 != 0 else 2)


## 低弧牵引（issue #26 改成拉细胞）：新格的癌性邻格冒出根、伸出低弧触手到**旧格**抓住胞体边缘，
## 然后把细胞拉到新格（细胞的位置见 carry_pos），到位后收回。触手的抓点跟着胞体走，越拉越短。
func _pseudopod(t: float, d: Dictionary) -> void:
	var from := _v(d, "from")
	var to := _v(d, "to")
	var radius: float = float(d.get("r", 12.0))
	var from_body: Vector2 = _v(d, "from_body") if d.has("from_body") \
		else from + Vector2(0, CWMatch.CELL_FOOT_DY - radius)
	var actor := from_body + (to - from) * pull_phase(t)
	var retract := CWPix.phase(t, PSEUDOPOD_RETRACT_AT, PSEUDOPOD_RETRACT)
	var sprout := CWPix.phase(t, 0.0, PSEUDOPOD_SPROUT) * (1.0 - retract)
	var reach := CWPix.phase(t, PSEUDOPOD_SPROUT, PSEUDOPOD_REACH)
	var roots := _pts(d, "roots")
	if sprout > 0.0:
		for r: Vector2 in roots:
			CWPix.disc(self, r, 3.0 * sprout, ROOT, 0.6)
			CWPix.line(self, r, r + Vector2(0, -4.0 * sprout), ROOT_STEM, 2)
	var extension := reach * (1.0 - retract)
	if extension <= 0.0:
		return
	for r: Vector2 in roots:
		var angle := (r - actor).angle()
		var grip := actor + Vector2(cos(angle) * radius * 0.6, sin(angle) * radius * 0.45)
		var end := r.lerp(grip, extension)
		var pts: Array[Vector2] = []
		for i in 17:
			var f := float(i) / 16.0
			var q := r.lerp(end, f)
			pts.append(Vector2(q.x, q.y - sin(f * PI) * 8.0 * extension))
		for stroke in [[ARM_DARK, 4, 0.0], [ARM_LIGHT, 2, -1.0]]:
			var off := Vector2(0, float(stroke[2]))
			for i in range(1, pts.size()):
				CWPix.line(self, pts[i - 1] + off, pts[i] + off, stroke[0], int(stroke[1]))
		CWPix.disc(self, end + Vector2(0, -1), 2.0, ARM_TIP)


## 细线疾行：落点身后三道钢青短线，朝来路拖着
func _minimal(t: float, d: Dictionary) -> void:
	if t >= 1.2:
		return
	var from := _v(d, "from")
	var to := _v(d, "to")
	var dir := (to - from).normalized() if to != from else Vector2(1, 0)
	var at := to + Vector2(0, -5)
	for i in 3:
		var lift := Vector2(0, -5.0 + float(i) * 5.0)
		CWPix.line(self, at - dir * (17.0 + float(i) * 4.0) + lift, at - dir * (10.0 + float(i) * 4.0) + lift, STEEL)


## 粒子重组：青色碎粒从外圈收拢到胞体。逐参数照抄原型 `common-skills.js:67`
## `burst(c,a.x,a.y-5,p,cyan,9,20,true)` —— 硬像素。
## issue #53 ⑤：中心取**胞体中心**（原来是格心上方 5px，细胞越高错得越多）；
## 那条 issue 说的「虚化」是原型第 59 行**贴图的交叉淡入淡出**，落在 `CWMatch.cross_fade_art`，不在这儿。
func _differentiate(t: float, d: Dictionary) -> void:
	var a: Vector2 = _v(d, "at_body") if d.has("at_body") else _v(d, "at") + Vector2(0, -5)
	CWPix.burst(self, a, t / 1.65, CYAN, 9, 20.0, true)


## 轻量吸收：七粒青色颗粒沿螺旋往**胞体中心**收（issue #26 前对着脚底收，看着错位），尾声胞体右上亮一点
func _respire(t: float, d: Dictionary) -> void:
	var a: Vector2 = _v(d, "at_body") if d.has("at_body") else _v(d, "at")
	var radius: float = float(d.get("r", 12.0))
	var p := t / 1.65
	if p < 1.0:
		for i in 7:
			var f := fmod(p + float(i) / 9.0, 1.0)
			CWPix.px(self, Vector2(a.x + cos(float(i) * 2.4) * (1.0 - f) * 22.0, a.y + (1.0 - f) * 18.0), CYAN, 1 + i % 2)
	if p > 0.6:
		CWPix.px(self, a + Vector2(radius * 0.9, -radius * 0.75), CYAN, 2)


## 归拢重生：十四粒青色碎粒往复活格收拢（issue #53 ⑤ 的「分化等」：中心对胞体；粒子同原型是硬像素）
func _revive_immune(t: float, d: Dictionary) -> void:
	var a: Vector2 = _v(d, "at_body") if d.has("at_body") else _v(d, "at") + Vector2(0, -5)
	CWPix.burst(self, a, t / 1.65, CYAN, 14, 25.0, true)


## 碎石重生：铜色碎粒往格里收拢。
## issue #53 ⑥（2026-09-19）：原来这里还画一层 `stone_patch` 的**长方形马赛克**当「依托的石块散去」——
## HXR-I 报的「固化癌组织被解除时有一个长方形的马赛克」就是它，而且它画在**落点**、
## 真正降级的是 `anchor`（两格可以不同，见 `CWWorld.revive_cancer`），位置本来就常常是错的。
## 整条删掉：固化的解除现在由 `CWMatch._sync_tiles` 的镜像差分在**那一格**开 `solid_break`，
## 散的是那块六边形纹理本身。
func _revive_cancer(t: float, d: Dictionary) -> void:
	var a: Vector2 = _v(d, "at_body") if d.has("at_body") else _v(d, "at") + Vector2(0, -5)
	CWPix.burst(self, a, t / 1.65, COPPER, 14, 25.0, true)


## 一格固化癌组织切成 3px 的马赛克：[[相对顶面中心的偏移, 颜色], …]。**只算一次**（贴图不会变）。
## 透明的块直接不要，所以马赛克的外形就是**那块六边形组织本身**。
##
## 2026-09-19（issue #52 / #53 ⑥）：原来还夹一道 `|x| + 0.6|y| ≤ 17` 的方框、范围也只取中间
## 27×18 那一块 —— 散开时看着就是「一个长方形的马赛克」。现在按**贴图自己的 alpha** 取满张，
## 六边形的尖角、平边都在。
## 块心的对齐不能动：`(x + 13) % 3 == 0`、`(y + 9) % 3 == 0` —— 露出顺序的散列按它算，
## `t_issue31_fx` 也钉着它。所以范围从 -16 / -12 起（都还在那条格线上），而不是贴图边缘。
const MOSAIC_X0 := -16
const MOSAIC_Y0 := -12
static var _mosaic: Array = []
static func solid_mosaic() -> Array:
	if not _mosaic.is_empty():
		return _mosaic
	var img: Image = SOLID_TEX.get_image()
	var y := MOSAIC_Y0
	while y < img.get_height() - SOLID_TEX_CENTER.y:
		var x := MOSAIC_X0
		while x < img.get_width() - SOLID_TEX_CENTER.x:
			## 取块心那一颗的颜色（3px 块，块心 +1,+1）
			var px := SOLID_TEX_CENTER + Vector2i(x + 1, y + 1)
			if px.x >= 0 and px.y >= 0 and px.x < img.get_width() and px.y < img.get_height():
				var col := img.get_pixel(px.x, px.y)
				if col.a > 0.5:
					_mosaic.append([Vector2i(x, y), Color(col.r, col.g, col.b)])
			x += 3
		y += 3
	return _mosaic


## 第 idx 块（本位 cell）在进度 p 处的偏移与透明度。p = 1 全就位、p = 0 全散开。**纯函数**。
## 每块按自己的散列错峰动身 —— 散列要带交叉项：线性式（7x+13y）同余的块会排成一条条斜线，
## 散去时就成了「莫名其妙的白条」（HXR-I #27，2026-09-12）。
static func solid_block(idx: int, cell: Vector2i, p: float) -> Dictionary:
	var h: int = posmod((cell.x + 13) * 37 + (cell.y + 9) * 101 + (cell.x + 13) * (cell.y + 9) * 7, 23)
	var lead := float(h) / 23.0 * SOLID_STAGGER
	var f := clampf((p - lead) / (1.0 - SOLID_STAGGER), 0.0, 1.0)
	var ang := float(idx) * 2.399
	var away := (1.0 - f) * SOLID_SPREAD
	## 透明度只取三档（像素纪律 ③）。最淡那一档不能再淡了 —— 深红的矿物色落在深绿组织上，
	## 0.25 那一档在整屏尺度上根本看不见（第一版出图就是这么丢的）
	var alpha := 0.5 if f < 0.34 else (0.8 if f < 0.67 else 1.0)
	return { "off": Vector2(cos(ang) * away, sin(ang) * away * 0.7), "a": alpha, "f": f }


## 固化癌组织的生成 / 解除（issue #52 与 #53 ⑥ 成对）：**同一套粒子，只差方向** ——
## p 从 0 走到 1 是「聚拢成那块六边形纹理」，从 1 走到 0 是「纹理散成同样的块飞开」。
static func draw_solid_mosaic(ci: CanvasItem, p: float, at := Vector2.ZERO) -> void:
	var m := solid_mosaic()
	for i in m.size():
		var b: Array = m[i]
		var cell: Vector2i = b[0]
		var s := solid_block(i, cell, clampf(p, 0.0, 1.0))
		## 还在飞的块**提亮**，落位了才退回贴图本色 —— 矿物色本来就压在深绿组织上，
		## 不提亮的话整段演出只是「深红点在深绿上挪了一下」，一屏之外根本看不见
		var col: Color = (b[1] as Color).lerp(SOLID_SPARK, (1.0 - float(s["f"])) * 0.7)
		col.a = float(s["a"])
		CWPix.px(ci, at + Vector2(cell) + Vector2(s["off"]), col, 3)


## 双股消散：两股铜 / 粉像素绕着**胞体中心**扭动，七成时长后散尽。
## issue #53 ⑦「突变的特效有点靠下」：原来钉在脚底往上 23px 起、往下压到脚底，
## 整束落在细胞的下半身。改成以胞体中心为准、上下各 12px，正对着细胞。
func _mutate(t: float, d: Dictionary) -> void:
	var a: Vector2 = _v(d, "at_body") if d.has("at_body") else _v(d, "at") + Vector2(0, -11)
	if t / 1.65 >= 0.7:
		return
	for i in 9:
		var y := a.y - 12.0 + float(i) * 3.0
		var x := sin(float(i) + t * 5.0) * 7.0
		CWPix.px(self, Vector2(a.x + x, y), COPPER)
		CWPix.px(self, Vector2(a.x - x, y), PINK)


## 铜橙输能：同连通块的癌性格各送三串暖色颗粒进胞体，后半程胞体上方冒热气。
## 颗粒**停在胞体轮廓上**就消失（issue #26：原来全挤到贴图上方的一个点，看着诡异）—— 像是钻进了细胞
func _anaerobic(t: float, d: Dictionary) -> void:
	var has_body: bool = d.has("at_body")
	var a: Vector2 = _v(d, "at_body") if has_body else _v(d, "at") + Vector2(0, -5)
	var radius: float = float(d.get("r", 12.0))
	var p := t / 2.1
	if p > 0.0 and p < 1.0:
		for s: Vector2 in _pts(d, "sources"):
			var edge := a + (s - a).normalized() * (radius - 1.0) if has_body else a
			for i in 3:
				CWPix.trail(self, s, edge, fmod(p * 1.6 + float(i) / 3.0, 1.0), ANAEROBIC, 5)
	if p > 0.5:
		var lid := a.y - radius - 2.0 if has_body else a.y - 13.0
		for i in 6:
			CWPix.px(self, Vector2(a.x - 9.0 + float(i) * 3.0, lid - fmod(t * 9.0 + float(i) * 3.0, 14.0)),
				ANAEROBIC_RISE, 2)


# ============ 卡牌粒子（issue #28，选稿 R5 card-effects.js）============
# 公式照抄选稿，时钟先加回 CARD_LEAD；键全是格位（格顶面中心），碎粒 / 输送线 / 头顶按常量往上挪。
# 选稿里「胞体变暗」「后坐一两像素」没做：真身贴图归 CWMatch 画，为一两像素再开一条代管不值。

## 一口碎粒：选稿 dust —— 只在最后 1/4 淡出（globalAlpha = min(1, (1−f)×4)），透明度取三档
func _dust(p: Vector2, f: float, color: Color, radius := 23.0, inward := false) -> void:
	if f <= 0.0 or f >= 1.0:
		return
	var a := minf(1.0, (1.0 - f) * 4.0)
	var col := color
	col.a = 1.0 if a >= 0.75 else (0.5 if a >= 0.4 else 0.25)
	CWPix.burst(self, p + Vector2(0, CARD_DUST_DY), f, col, 16, radius, inward)


## 一道输送流：七颗沿 a→b 拖尾，头一颗大一档，走在格心上方 7 px
func _flow(a: Vector2, b: Vector2, f: float, color: Color) -> void:
	if f <= 0.0 or f >= 1.0:
		return
	for i in 7:
		var q := clampf(f - float(i) * 0.035, 0.0, 1.0)
		CWPix.px(self, a.lerp(b, q) + Vector2(0, CARD_FLOW_DY), color, 2 if i == 0 else 1)


## 范围结算三张：逐格扬起碎粒（放疗那张先落一道光柱），1.65 s 再齐扬一次
func _card_area(t: float, d: Dictionary, kind: String) -> void:
	var r := t + CARD_LEAD
	var color := CARD_AMBER if kind == "card_inflammation" else (CARD_SAND if kind == "card_radiation" else CARD_CYAN)
	var tiles := _pts(d, "tiles")
	for i in tiles.size():
		var p: Vector2 = tiles[i]
		var f := CWPix.phase(r, 0.45 + float(i) * 0.02, 1.0)
		if kind == "card_radiation" and f > 0.0 and f < 1.0:
			CWPix.line(self, Vector2(p.x, p.y - 55.0 + f * 40.0), Vector2(p.x, p.y - 38.0 + f * 30.0), color)
		else:
			_dust(p, f, color, 17.0)
		_dust(p, CWPix.phase(r, 1.65, 0.65), color, 17.0)


## 单体命中三张：三道流打到目标，目标扬碎粒；补体级联再从目标传到那两格
func _card_hit(t: float, d: Dictionary, kind: String) -> void:
	var r := t + CARD_LEAD
	var a := _v(d, "from")
	var b := _v(d, "to")
	var color := CARD_MAUVE if kind == "card_acid" else (CARD_AMBER if kind == "card_granule" else CARD_ICE)
	for i in 3:
		_flow(a, b, CWPix.phase(r, 0.45 + float(i) * 0.16, 0.7), color)
	_dust(b, CWPix.phase(r, 1.45, 0.65), color, 25.0)
	if kind == "card_cascade":
		var tiles := _pts(d, "tiles")
		for i in tiles.size():
			var p: Vector2 = tiles[i]
			_flow(b, p, CWPix.phase(r, 1.8 + float(i) * 0.2, 0.6), color)
			_dust(p, CWPix.phase(r, 2.4 + float(i) * 0.2, 0.6), color, 14.0)


## 代谢耦联：三道青流，收方回拢亮点
func _card_transfer(t: float, d: Dictionary) -> void:
	var r := t + CARD_LEAD
	var a := _v(d, "from")
	var b := _v(d, "to")
	for i in 3:
		_flow(a, b, CWPix.phase(r, 0.5 + float(i) * 0.25, 0.8), CARD_CYAN)
	_dust(b, CWPix.phase(r, 1.3, 1.1), CARD_ICE, 22.0, true)


## 免疫增援：原格散开、落点回拢（远跳另有 CWTeleportFx 的溶解）
func _card_teleport(t: float, d: Dictionary) -> void:
	var r := t + CARD_LEAD
	_dust(_v(d, "from"), CWPix.phase(r, 0.5, 1.1), CARD_CYAN)
	_dust(_v(d, "to"), CWPix.phase(r, 1.65, 0.8), CARD_ICE, 23.0, true)


## 交叉呈递：头顶到头顶的粉流，1.6 s 到了在目标头顶立一枚菱形头标（从 15 缩到 5，两侧带小钩）
func _card_mark(t: float, d: Dictionary) -> void:
	var r := t + CARD_LEAD
	var lift := Vector2(0, CARD_HEAD_DY - CARD_FLOW_DY)
	_flow(_v(d, "from") + lift, _v(d, "to") + lift, CWPix.phase(r, 0.5, 1.1), CARD_ROSE)
	if r > 1.6:
		_head_marker(_v(d, "to") + Vector2(0, CARD_HEAD_DY), r - 1.6)


func _head_marker(c: Vector2, age: float) -> void:
	var s := 5.0 + roundf((1.0 - CWPix.phase(age, 0.0, 0.6)) * 10.0)
	CWPix.line(self, c + Vector2(0, -s), c + Vector2(s, 0), CARD_ROSE)
	CWPix.line(self, c + Vector2(s, 0), c + Vector2(0, s), CARD_ROSE)
	CWPix.line(self, c + Vector2(0, s), c + Vector2(-s, 0), CARD_ROSE)
	CWPix.line(self, c + Vector2(-s, 0), c + Vector2(0, -s), CARD_ROSE)
	for side in [-1.0, 1.0]:
		CWPix.line(self, c + Vector2(side * 9.0, 3.0), c + Vector2(side * 14.0, -2.0), CARD_ROSE)
		CWPix.line(self, c + Vector2(side * 14.0, -2.0), c + Vector2(side * 14.0, -7.0), CARD_ROSE)
	CWPix.px(self, c, CARD_WHITE, 2)


## BCL-2 免死：先散开（胞体没变暗，见文件头），1.4 s 起回拢 —— 人还在原格
func _card_survive(t: float, d: Dictionary) -> void:
	var r := t + CARD_LEAD
	var p := _v(d, "at")
	if r < 1.4:
		_dust(p, CWPix.phase(r, 0.5, 0.9), CARD_MAUVE, 23.0, false)
	else:
		_dust(p, CWPix.phase(r, 1.4, 0.9), CARD_MAUVE, 23.0, true)


## 克隆增殖：紫红感染流逐格送到邻格，到了扬一口橙色碎粒（那一格的定殖过场等到这一刻，见 arrival_in）
func _card_clone(t: float, d: Dictionary) -> void:
	var r := t + CARD_LEAD
	var a := _v(d, "at")
	var tiles := _pts(d, "tiles")
	for i in tiles.size():
		var p: Vector2 = tiles[i]
		_flow(a, p, CWPix.phase(r, 0.5 + float(i) * CLONE_STAGGER, 0.8), CARD_MAUVE)
		_dust(p, CWPix.phase(r, CLONE_FLIP_AT + float(i) * CLONE_STAGGER, 0.55), CARD_AMBER, 14.0)


## 肿瘤血管生成：全体癌细胞各自回拢血色碎粒，抽卡者那口更大
func _card_blood(t: float, d: Dictionary) -> void:
	var r := t + CARD_LEAD
	var drawer := _v(d, "drawer")
	var cells := _pts(d, "cells")
	for i in cells.size():
		var p: Vector2 = cells[i]
		_dust(p, CWPix.phase(r, 0.5 + float(i) * 0.06, 1.3), CARD_MAUVE, 30.0 if p == drawer else 23.0, true)


## 这一刻盾放大几倍：3 → 2 → 1 三跳收束，**只取整数**（Kevin 2026-09-13：像素风）。0 = 还没出来 / 已经收了。**纯函数**
static func shield_scale(r: float) -> int:
	if r < 0.35 or r >= 2.3:
		return 0
	if r < 0.5:
		return 3
	return 2 if r < 0.65 else 1


## 细胞膜修复的盾：一面 13×16 的像素盾从三倍大小三跳收到细胞身上，停一会儿淡出。
## 笔画只有三种 —— 盾面（0.14 的青）、1px 青边、左上一道冰蓝高光加一点白反光；
## 透明度取四档、位置整数、放大只用整数倍（像素纪律三条）。
func _shield(p: Vector2, r: float) -> void:
	var scale := shield_scale(r)
	if scale == 0:
		return
	var op := floorf(CWPix.phase(r, 0.35, 0.12) * (1.0 - CWPix.phase(r, 1.9, 0.4)) * 4.0) / 4.0
	if op <= 0.0:
		return
	var c := Vector2(roundf(p.x), roundf(p.y) - 5.0)
	var fill := CARD_CYAN
	fill.a = SHIELD_FILL_A * op
	var ink := CARD_CYAN
	ink.a = 0.95 * op
	var s := float(scale)
	for row in shield_rows():
		var y: float = c.y + float(row[0]) * s
		var x0: float = c.x + float(row[1]) * s
		var x1: float = c.x + float(row[2]) * s + s - 1.0
		## 每行先铺底，再把这一行的两端画成边；顶行和底行整行都是边
		CWPix.line(self, Vector2(x0, y), Vector2(x1, y), fill, int(s))
		var edge: bool = int(row[0]) == SHIELD_TOP or int(row[0]) == SHIELD_TOP + SHIELD_HALF.size() - 1
		if edge:
			CWPix.line(self, Vector2(x0, y), Vector2(x1, y), ink, int(s))
		else:
			CWPix.px(self, Vector2(x0, y), ink, scale)
			CWPix.px(self, Vector2(x1 - s + 1.0, y), ink, scale)
	## 左上一道高光 + 一点白反光：盾有了厚度就不平了
	var hi := CARD_ICE
	hi.a = 0.8 * op
	CWPix.line(self, Vector2(c.x - 8.0 * s, c.y - 11.0 * s), Vector2(c.x - 8.0 * s, c.y - 2.0 * s), hi, scale)
	var white := CARD_WHITE
	white.a = 0.9 * op
	CWPix.px(self, Vector2(c.x - 8.0 * s, c.y - 11.0 * s), white, scale)
