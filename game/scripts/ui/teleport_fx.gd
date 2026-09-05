## teleport_fx.gd —— 细胞传送的溶解演出（规格：docs/动画规格_传送.md，队友 2026-09-04 定案）
##
## 形态：原格**残影**向下偏置像素溶解离场（0.25s，边缘阵营色）→ 0.15s 后**真身**在新格
## 用同一 shader 倒放凝出（0.30s，边缘白 + scale 0.6→1.10→1.0 过冲）→ 落地目标格白闪。
## 全程 0.45s，**没有一个像素的位移**：CWMatch 每帧用引擎状态覆写细胞节点的 position / z_index，
## 演出全在精灵 UV 空间（shader）与 scale 上，天然不与之打架。
##
## 谁判定「这是传送」：CWMatch._sync_cells() 的**状态差分**（上一帧与这一帧都活着、两格不相邻），
## 引擎零改动、不加信号，联机影子对局（服务器快照 restore 后逐帧同步）下同样触发。
## 本类只管演：建残影、挂材质、推补间、收句柄。**不是节点**（同 CWErosionFx）：残影挂在
## 调用方给的父节点（细胞层 _cells_root）下，不进 _cell_nodes（那数组下标 = cell id，不许污染）。
##
## 句柄管理：所有补间收进 _tweens，clear_all() **先 kill 再删节点** —— queue_free 是帧末删除，
## 补间会活过拆局跑进下一局（match.gd 的 _fade_tws 有同样的血泪注释）。真身的材质与 scale 也在
## clear_all 里还原，否则拆局重开时那个细胞会带着 progress=1 的材质（整个透明）活到下一局。
class_name CWTeleportFx
extends RefCounted

const SHADER := preload("res://assets/shaders/teleport.gdshader")

## 时序按规格 §二的时间轴：离场 0→0.25、落场 0.15→0.45。
## （规格文字里写的「两段重叠 0.15s」与时间轴对不上，时间轴给的是 0.10s 重叠；按时间轴落地，已在开发日志记明。）
const SINK := 0.25         ## 离场：残影 progress 0→1
const LAG := 0.15          ## 落场比离场晚这么多开始
const EMERGE := 0.30       ## 落场：真身 progress 1→0
const RING_STEP := 0.045   ## 同帧多个传送（紊乱）按离重心的环数错峰，每环这么多秒（复用 board.ring_delays）
const VESSEL_LEAD := 0.10  ## 血管互换：两端血管格先亮这么久再开演（交代「是血管干的」）
const SCALE_FROM := 0.6
const SCALE_OVER := 1.10
const EDGE_IMMUNE := Color(0.188, 0.82, 0.98)   ## #30D1FA，与 board 的 MARK_MOVE 同源
const EDGE_CANCER := Color(1.0, 0.69, 0.23)     ## #FFB03A，与 MARK_ATTACK 同源

## 正在溶解的残影：[{ "node": Sprite2D, "idx": 细胞下标 }]。呼吸帧按下标错相位，与 _animate_breath 同式
var _ghosts: Array = []
## 正在凝出的真身。演完材质摘掉、scale 归一；clear_all 也要还原它们
var _bodies: Array = []
var _tweens: Array[Tween] = []
var played := 0     ## 累计开演次数（测试与统计用）


static func edge_for(faction: int) -> Color:
	return EDGE_IMMUNE if faction == CWData.Faction.IMMUNE else EDGE_CANCER


func busy() -> bool:
	return not _ghosts.is_empty() or not _bodies.is_empty()


func ghost_count() -> int:
	return _ghosts.size()


## 开演一次传送。
##   parent      残影挂哪（细胞层）；补间也从它建，所以它必须在场景树里
##   body        真身精灵 —— 调用时已被 _sync_cells 摆到新格
##   idx         细胞下标（呼吸相位用）
##   ghost_pos / ghost_z   残影的位置与 z：调用方在覆写前抄下的**上一帧实际值**，
##               同格多细胞的 STACK_DX 错位因此自动带上，不必再算
##   edge        离场边缘色（阵营色，见 edge_for）
##   delay       启动延迟（紊乱错峰 / 血管前置）
##   on_land     落地完成回调（调用方拿它去白闪目标格）；传 Callable() 表示不要
func play(parent: Node2D, body: Sprite2D, idx: int, ghost_pos: Vector2, ghost_z: int,
		edge: Color, delay: float, on_land: Callable) -> void:
	played += 1
	_prune()
	## ---- 残影：复制离场那一帧，原地溶解 ----
	var ghost := Sprite2D.new()
	ghost.texture = body.texture
	ghost.hframes = body.hframes
	ghost.offset = body.offset
	ghost.frame = body.frame
	ghost.position = ghost_pos
	ghost.z_index = ghost_z
	var gmat := ShaderMaterial.new()      ## progress 是逐细胞的，material 必须逐实例，不能共用
	gmat.shader = SHADER
	gmat.set_shader_parameter("emerge", 0.0)
	gmat.set_shader_parameter("edge_color", edge)
	gmat.set_shader_parameter("progress", 0.0)
	ghost.material = gmat
	parent.add_child(ghost)
	var entry := { "node": ghost, "idx": idx }
	_ghosts.append(entry)
	var tw := parent.create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.tween_method(func(v: float) -> void: gmat.set_shader_parameter("progress", v), 0.0, 1.0, SINK)
	tw.tween_callback(func() -> void:
		_ghosts.erase(entry)
		ghost.queue_free())
	_tweens.append(tw)

	## ---- 真身：先整个溶掉藏住（它已经站在新格了），到点再从脚底凝出 ----
	var bmat := ShaderMaterial.new()
	bmat.shader = SHADER
	bmat.set_shader_parameter("emerge", 1.0)   ## 必须先置 1 再倒放 progress，否则从头顶冒出来（规格踩过的坑）
	bmat.set_shader_parameter("edge_color", Color.WHITE)
	bmat.set_shader_parameter("progress", 1.0)
	body.material = bmat
	_bodies.append(body)
	var tw2 := parent.create_tween()
	tw2.tween_interval(delay + LAG)
	tw2.tween_method(func(v: float) -> void: bmat.set_shader_parameter("progress", v), 1.0, 0.0, EMERGE)
	tw2.tween_callback(func() -> void:
		body.material = null          ## 摘掉而不是留着 progress=0：真身平时就该是干净的精灵
		body.scale = Vector2.ONE      ## 规格：凝出结束必须回到 ONE，否则下一帧 _sync_cells 覆写出一帧抖动
		_bodies.erase(body)
		if on_land.is_valid():
			on_land.call())
	_tweens.append(tw2)
	## scale 过冲单开一条：0.6 → 1.10（凝出的前 70%）→ 1.0（后 30%），与凝出同始同终
	var tw3 := parent.create_tween()
	tw3.tween_interval(delay + LAG)
	tw3.tween_callback(func() -> void: body.scale = Vector2.ONE * SCALE_FROM)
	tw3.tween_property(body, "scale", Vector2.ONE * SCALE_OVER, EMERGE * 0.7) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw3.tween_property(body, "scale", Vector2.ONE, EMERGE * 0.3)
	_tweens.append(tw3)


## 残影的呼吸帧跟全局步进走，相位 = 步进 + 细胞下标（与 CWMatch._animate_breath 同一条式子）。
## 不跟的话残影定格、真身在呼吸，帧率不一致一眼穿帮。
func sync_breath(step: int, frames: int) -> void:
	for e in _ghosts:
		var s: Sprite2D = e["node"]
		if is_instance_valid(s) and s.hframes == frames:
			s.frame = (step + int(e["idx"])) % frames


## 拆局 / 重开：先杀补间、再删残影、最后把真身还原。三步顺序不能换。
func clear_all() -> void:
	for tw in _tweens:
		if tw != null and tw.is_valid():
			tw.kill()
	_tweens.clear()
	for e in _ghosts:
		var n: Node = e["node"]
		if is_instance_valid(n):
			n.queue_free()
	_ghosts.clear()
	for b in _bodies:
		if is_instance_valid(b):
			b.material = null
			b.scale = Vector2.ONE
	_bodies.clear()


## 跑完的补间句柄不再有效，顺手清掉，免得一局紊乱几十次之后数组无限长
func _prune() -> void:
	var i := _tweens.size() - 1
	while i >= 0:
		var tw: Tween = _tweens[i]
		if tw == null or not tw.is_valid():
			_tweens.remove_at(i)
		i -= 1
