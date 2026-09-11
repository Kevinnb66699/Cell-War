## match.gd —— 一局对局的装配与呈现
##
## 职责只有两件：**把引擎组装起来跑**，以及**把引擎的状态画到棋盘上**。
## 规则一行都不在这里（规则全在 scripts/core/），界面交互在 CWUIBridge。
##
## 呈现走的是「每帧全量刷新」而不是事件驱动：引擎直接改 game.tiles / game.cells
## 的字典，没有变更信号，与其到处补信号，不如每帧把 127 格和几个细胞重刷一遍——
## board.set_tissue() 在贴图没变时会直接返回，所以这么做的代价接近零，
## 而好处是**画面永远不可能和状态对不上**（漏发一个信号那种 bug 从根上没有了）。
class_name CWMatch
extends Node2D

## 对局结束（winner = CWData.Faction）
signal finished(winner: int)

## 棋盘和相机都是**同级节点**：开场过场是同一个镜头往前推、不切场景，
## 所以菜单和对局共用同一张棋盘、同一台相机（见 Main.tscn 与 main.gd）。
@export var board_path: NodePath = ^"../Board"
@export var camera_path: NodePath = ^"../Camera2D"
@export var action_bar_path: NodePath = ^"UI/ActionBar"
@export var panel_path: NodePath = ^"UI/Panel"
@export var ui_path: NodePath = ^"UI"
@export var pause_path: NodePath = ^"UI/Pause"
@export var hand_path: NodePath = ^"UI/Hand"
@export var toast_path: NodePath = ^"UI/Toast"
@export var settle_path: NodePath = ^"UI/Settle"

@export var player_count := 4
## 哪几个位置由人来打；留空 = 一局可观战的 AI 互搏
@export var human_players: Array[int] = []
## AI 强度：false = 启发式（普通），true = 蒙特卡洛推演（较强）。
## 由对局配置面板拨；观战局也吃这一位。
## AI 强度档位：0 普通 / 1 较强 / 2 树搜索。原为 bool `ai_smart`，2026-09-07 第三档进来后改成下标。
@export var ai_level := 0
## AI 每步之间的停顿改由设置页管（CWSettings.ai_delay_ms），纯观感不影响结算
## 0 = 每局取当前时间做种子；填非 0 可复现同一局
@export var match_seed := 0
## 自定义对局钉死的癌种：按癌席顺序的 CWData.CancerType（-1 = 随机），空表 = 普通对局全随机。
## 只在 start() 开新局时喂给 tune；重开（_restart）沿用，读档 / 联机不经过这里。
@export var cancer_types: Array = []
## 世界事件开关（Kevin 2026-09-08）。关掉后整局不触发；联机由房主在建房页拨、随快照下发
@export var world_events := true
## 单独跑本场景时自己开局；挂在 Main 下面时由 main.gd 在过场结束后调 start()
@export var autostart := false
## 教程局（主菜单「新手引导」，main.gd 的 _begin_tutorial 置 true）：桥换成 CWGuideBridge、
## 开局挂新手引导面板；装配见 _attach_guide()，引导面板直达知识之书见 focus_codex_on_topic()。
## 正式局 / 读档 / 联机 / 再来一局的入口都把它复位成 false。
@export var tutorial := false

## 教程当前关（0 起）：start() 按 CWGuideProgress 算出，跨章时由 guide 的
## on_chapter_done 回调更新并换一局（见 _advance_tutorial_chapter）。
var _tutorial_ch := 0
## 运行代际号：教程跨章换局时 +1，让旧局的 _run 协程安静退场（不再发 finished）。
var _run_gen := 0

## 此刻能不能存档：引擎只在 pending 边界有完整快照（CWSave 的写入条件）。
## 暂停菜单拿它决定「保存并退出」亮不亮。联机局不写本地存档（状态在服务器，掉线凭令牌重连）。
## 错误气泡挂在哪一格：自己的细胞脚下（视线本来就在那儿）；没有细胞就挂棋盘中心。
func _error_at() -> Vector2i:
	if game == null or bridge == null:
		return Vector2i.ZERO
	var pid: int = bridge.viewing_pid()
	if pid < 0 or pid >= game.players.size():
		return Vector2i.ZERO
	var cell: Dictionary = game.cell_of(pid)
	return cell["pos"] if cell.get("alive", false) else Vector2i.ZERO


## 屏幕前这位属于哪个阵营；观战、热座换手中、对局已结束都返回 -1。
## 暂停菜单据此决定「投降」亮不亮（`pause_menu.surrender_faction`）。
func viewing_faction() -> int:
	if game == null or game.is_over() or bridge == null:
		return -1
	var pid: int = bridge.viewing_pid()
	if pid < 0 or pid >= game.players.size():
		return -1
	return int(game.player(pid)["faction"])


## 【投降】屏幕前这位代表本方认输。**两条路**：
##
## · **联机**：只是把「我要投降」送给服务器，够不够票由它算（`CWRoom.surrender`）。
##   本地这份影子对局一个字都不能改 —— 结果要等服务器的 game_over 报文回来。
##   自己先判的话，队友一反对就得把已经判过的胜负收回去。
## · **本地**：发起即生效，没有投票（Kevin 2026-09-09）。热座同阵营的人就坐在一起、
##   开口商量比走一遍投票 UI 快；单机的 AI 队友一律同意，投票也只是走个过场。
##
## 本地那条的顺序要紧：**先认定结果，再唤醒卡住的询问**。投降总是发生在「某人正被问着」
## 的时候（ESC 菜单压在询问界面上），先叫醒的话 run_game 会拿着一个无意义的答案 step() 一步。
func surrender_now() -> void:
	var faction := viewing_faction()
	if faction < 0:
		return
	if online:
		if _client != null:
			_client.surrender(true)
		return
	game.surrender(faction)
	if bridge != null:
		bridge.abort()


func can_save_now() -> bool:
	return game != null and not online and not game._pending.is_empty() and not game.is_over()

## 固化格曾经靠一层压暗（`MARK_SOLID = #0000004d`）认出来，
## **2026-09-09 随石化贴图上线删掉** —— 那一层的注释当初就写着「硬化外壳的美术还没有……
## 压暗一档是临时手段」。真机对照图（`tests/preview_solidify.gd` 出两张）显示：
## 压暗会把 1.5 和 2.0 两档的明度拉近，反而**削弱**了固化格的辨识度，
## 而固化是【裂解】和癌方【复活】唯一认的离散状态，必须最醒目。
## 癌细胞脚下固化组织的石化色；只覆盖细胞外圈，主体颜色仍保留癌细胞种类辨识度。
## 「回合末会被压死」的预警（Kevin 2026-09-08）：细胞外圈红色脉冲。
## 复用 solid_progress 那个 shader —— 别被文件名骗了，它干的事就是
## 「把贴图轮廓那一圈染成指定颜色」，和固化进度没有绑定关系
## （2026-09-09 癌细胞那圈删掉之后，这里是它**唯一**的使用者）。
const DOOM_COLOR := Color("ff4d4d")
const DOOM_ALPHA := Vector2(0.35, 1.0)   ## 脉冲的最暗 / 最亮
const DOOM_HZ := 2.0                     ## 每秒两次 —— 比骨样硬化(1.2)急，是要人马上看见
const SOLID_PROGRESS_SHADER := preload("res://assets/shaders/solid_progress.gdshader")

## 骨肉瘤【骨样硬化】标记格的脉冲色标（Kevin 2026-09-07 要的显示效果）。
## 这一格在倒计时，到点直接变固化癌组织 —— 而固化格【净化】不掉、只有 T 的【裂解】拆得动，
## 所以「哪几格正在硬化」是免疫方**必须看得见**的信息，否则只能靠翻日志。
## 用脉冲而不是静态色：静态色会和固化格的压暗混成一片，脉冲一眼就是「还在走的东西」。
## 最后一个世界回合脉冲加快 —— 同【趋化源】只剩 1 回合时的加速，玩家已经认得这套语言。
const MARK_OSSIFY := Color("e8d9a0")   ## 骨白偏暖，和癌方的洋红、固化的压暗都分得开
const OSSIFY_ALPHA := Vector2(0.18, 0.46)   ## 脉冲的最暗 / 最亮
const OSSIFY_HZ := 1.2                      ## 脉冲频率；最后一回合翻倍

## 印戒【黏液破裂】留下的「黏液侵染」画在哪：**见 `CWBoard.set_mucus`**。
##
## 这里只负责「哪几格有」，怎么画归棋盘 —— 那是一层照 `tools/art-preview`
## 「黏液纹理 A」烤出来的半透明覆膜贴图，不是色标。
## （第一版做成了色标，Kevin 2026-09-10 指出要的是选稿里那层膜：
## 色标会把整格染成一个颜色，而选稿的要求正是「保留底层组织识别」。）

## 开场绽开时每格翻面的那一下白闪
const FLASH_TIME := 0.22
const FLASH_ALPHA := 0.7

## 细胞出现/复活时的淡入。团队试玩反馈「显示得太突然」——
## 淡入 + 稍微放大到位，读起来像「就位」而不是「凭空冒出来」。
const CELL_POP := 0.32
const CELL_POP_SCALE := 0.7

## 细胞贴脚落在格子「顶面中心」再往下 6px，和主菜单的装饰细胞同一套。
const CELL_FOOT_DY := 6.0
## 同一格站了多个细胞时左右错开的间距
const STACK_DX := 9.0

## 棋盘上的细胞用**横排 6 帧的静息呼吸表**（美术 2026-08-29 交付，帧内容上下浮动 0~2px）。
## 静态单帧图仍在 cells/ 根目录，主菜单装饰、右侧面板等静态场合继续用它们。
const IMMUNE_ART := {
	CWData.ImmuneType.BASIC: preload("res://assets/art/cells/anim/immune_breath.png"),
	CWData.ImmuneType.B_CELL: preload("res://assets/art/cells/anim/bcell_breath.png"),
	CWData.ImmuneType.T_CELL: preload("res://assets/art/cells/anim/tcell_breath.png"),
	CWData.ImmuneType.MACRO: preload("res://assets/art/cells/anim/macrophage_breath.png"),
	CWData.ImmuneType.DENDRITIC: preload("res://assets/art/cells/anim/dendritic_breath.png"),
}

## 癌细胞四种。小细胞肺癌的帧只有 16x18（其余 32x34）—— 是美术故意画小的，
## 别拿缩放去凑齐：贴图过滤是最近邻，非整数倍缩放会磨出锯齿（约定 #13 同理）。
const CANCER_ART := {
	CWData.CancerType.MELANOMA: preload("res://assets/art/cells/anim/melanoma_breath.png"),
	CWData.CancerType.SIGNET: preload("res://assets/art/cells/anim/signet_breath.png"),
	CWData.CancerType.OSTEO: preload("res://assets/art/cells/anim/osteo_breath.png"),
	CWData.CancerType.SCLC: preload("res://assets/art/cells/anim/sclc_breath.png"),
}

## 呼吸动画：6 帧/秒 × 6 帧 = 一秒一次完整呼吸；相位按细胞编号错开，免得全场同频起伏
const BREATH_FPS := 6.0
const BREATH_FRAMES := 6

## 打出 / 抽到卡牌时在细胞头顶浮出的临时图标。用同一张像素 chip，和右侧的小卡保持一致。
##
## **三拍 + 起手蓄力**（Kevin 2026-09-07：原来 0.42 秒一口气窜完，太快，看不清是什么）：
##   ① 压：向下压 2px，横向拉宽、纵向压扁（0.07s）
##   ② 窜：快速上浮 10px并回弹到正常比例（0.16s，缓出）
##   ③ 停：缓慢上浮 3px并停一拍（0.30s + 0.08s）——给玩家看清「是张卡」
##   ④ 收：再上浮 17px并缩小淡出（0.36s，缓入）
## **抽到卡 = 把这三拍倒放**（卡从上方淡入、落到头顶；Kevin 问「能否倒放实现」——能，差的只有下面这一口）：
## 纯倒放的终态是卡停在头上不动，所以末尾补一下缩小 + 淡出，读作「被细胞吸进去了」。
const CARD_FX_TEXTURE := preload("res://assets/art/ui/card_chip.png")
const CARD_FX_HEAD := 30.0                        ## 起点：细胞脚下往上这么多
const CARD_FX_RISE: Array[float] = [10.0, 3.0, 17.0]
## 三拍各自的时长。**拆成三个具名常量**是为了让下面的总时长能写成常量表达式
## （GDScript 的 const 不能调函数，也不好对 const 数组下标求值）。
const CARD_FX_T0 := 0.16
const CARD_FX_T1 := 0.30
const CARD_FX_T2 := 0.36
const CARD_FX_TIME: Array[float] = [CARD_FX_T0, CARD_FX_T1, CARD_FX_T2]
const CARD_FX_WINDUP := 0.07                     ## 真正上冲前先蓄力一下
const CARD_FX_WINDUP_Y := 2.0
const CARD_FX_HOLD := 0.08                       ## 上冲后留一拍给玩家认出「这是卡」
const CARD_FX_ABSORB := 0.14                      ## 倒放落到头顶后「被吸进去」的那一下
const CARD_FX_SCALE := 1.1
const CARD_FX_SQUASH := Vector2(1.18, 0.84)       ## 出牌那一瞬先压一下，再弹开，更像 StS2 的出牌节奏
const REVIVE_FX_TEXTURE := preload("res://assets/art/ui/revive_totem_sheet.png")
const REVIVE_FX_FRAMES := 6
## 复活图腾的时长 = **抽卡那套的总时长**（蓄力 + 三拍 + 留拍），Kevin 2026-09-07 要求对齐。
## 两个演出都是「细胞头顶冒出一个东西」，节奏对不齐时同屏出现会显得一个赶一个拖。
## **从卡那套现算，不写第二个 0.xx** —— 以后调出牌节奏，复活自动跟着走（原值 0.48，约为一半）。
const REVIVE_FX_TIME := CARD_FX_WINDUP + CARD_FX_T0 + CARD_FX_T1 + CARD_FX_T2 + CARD_FX_HOLD

var game: CWGame
var bridge: CWUIBridge
## 联机模式（docs/联机设计 §七）：game 是客户端的影子对局（只读、由服务器的视角快照 restore），
## 桥仍是 CWUIBridge，但询问与演出由 _net_loop 从 client.stream 里按顺序取出来驱动，
## 引擎不在本机跑。start_online() 进入，teardown() 退出。
var online := false
var net_hud: CWNetHud
var _client: CWNetClient
var _vote: CWSurrenderVote   ## 投降票面（只有联机会用；本地是发起即生效，没有投票）
var _seen_error := 0         ## 已经弹过的最后一条 error 序号
var _loop_id := 0        ## 每次 start_online / teardown 递增：旧的 _net_loop 看到号变了就退出
## 回放（`start_replay` 进入）。speed = 每帧走几步（0.25 = 四帧一步，4 = 一帧四步）
var replay: CWReplay.Player
var replay_paused := false
var replay_speed := 1.0
var _replay_target := -1     ## 待执行的拖拽目标；-1 = 没有。只由 _replay_loop 消费
var _replay_bar: CWReplayBar ## 播放控制条（回放局才建）
## ── 临时下架的功能开关（Kevin 2026-09-10 拍板）──────────────────────────
##
## **三个开关都只管「界面上有没有入口」，一点底层都不动**：类还在、协议还在、
## 服务器那半边照常收发、回放照常录照常存 —— 所以开回来那天不用补数据、
## 不用改协议、也不必从头验一遍（各自的护栏测试仍在跑）。
##
## 放在同一个地方是有意的：**要开回来就在这三行改 true**，不必满仓库找开关。
## 每一处触点、每一条待修、怎么验，都写在 **`docs/临时下架清单.md`**；
## 动这三行要连着改那份文档。
##
## ① 聊天，**对局里和等待室两处一起收**（等待室那份 2026-09-10 晚追加）。
##    对局里：`_chat` 恒为 null（下面每一处早就按 null 兜底），迷你条那页「聊天」
##    跟着不出现。等待室：`CWOnlinePanel._build_room` 整块不建。
##    开回来之前要修三条（Kevin 实战报的，都是对局里那份）：
##      · 从迷你条点开之后关不掉 —— 展开的框（340×460）正好盖住迷你条自己那个
##        「聊天」页，而标题写着的「Enter 收起」在框开着时被输入框吃掉了
##        （空串提交 = 什么都不做）；
##      · 该能点框外空白处收起（`CWLogPanel` 早就是这么做的，这份漏了）；
##      · **打字打到 L 就弹出对局日志** —— `CWLogPanel._unhandled_input` 的单键
##        快捷键没有「玩家正在打字」这道闸。空格 / 方向键多半同病，要一并按焦点判。
const CHAT_ON := false

## ② 看回放。两个入口一起收：主菜单「对局回放」灰掉、结算屏「看这局回放」不建。
##    **录制不停** —— `start()` 里的 `record_replay` 照常，服务器的回放柜也照常存，
##    所以关着这段时间打的局，开回来之后还看得到。
const REPLAY_ON := false

## ③ 观战。大厅里「进行中 · 可观战」那一组不再列出（`_lobby_live` 收成空）。
##    协议的 watch / 服务器的观众席都还在，只是界面上没有入口。
const WATCH_ON := false
## ────────────────────────────────────────────────────────────────

var _chat: CWChatBox         ## 房内聊天（只有联机局有：本地局没人可聊）
var _chat_seen := 0          ## 已经搬到框里的第几条（同 _feed_seq 的路子）
var _ask_serial := 0     ## 每收到一次询问递增：作答时核对，服务器代打后重问的旧答案不发

@onready var board: Node2D = get_node(board_path)
@onready var camera: Camera2D = get_node(camera_path)
@onready var action_bar: CWActionBar = get_node_or_null(action_bar_path)
@onready var panel: CWMatchPanel = get_node_or_null(panel_path)
## 整层 HUD。开局前必须关掉 —— 棋盘和相机是和主菜单共用的同一份，
## 不关的话主菜单右边会凭空多出一条空竖条（2026-08-27 接上 Main 后出现的）。
@onready var ui: CanvasLayer = get_node_or_null(ui_path)
@onready var pause_menu: CWPauseMenu = get_node_or_null(pause_path)
@onready var hand: CWHand = get_node_or_null(hand_path)
@onready var toast: CWToast = get_node_or_null(toast_path)
## 结算屏。谁来开它、开完选了什么由 main.gd 管（那是场景流转，不是对局呈现），
## 这里只负责在拆局时把它擦掉。
@onready var settle: CWSettleScreen = get_node_or_null(settle_path)

var _dice: CWDice
var _cells_root: Node2D
## fade_out() 建的那几条补间的句柄。**必须留着**：它们绑在 `_cells_root` 和 HUD 上，
## 而这两个节点 teardown() 都不销毁 —— 补间会活过拆局、跑进下一局继续把 alpha 拉向 0。
## 返场过场被玩家点击跳过时最容易撞上：跳过只快进了相机补间（main.gd 的 `_tween`），
## 这几条没人管。表现是「新局开局细胞全不可见、HUD 却正常」
## （HUD 那几条只有 0.6 倍时长，通常已经先跑完）。start() 里统一杀掉。
var _fade_tws: Array[Tween] = []
var _cell_nodes: Array[Node2D] = []   ## 下标 = cell["id"]，和 game.cells 一一对应
var _was_alive: Array[bool] = []      ## 上一帧的存活状态，用来认出「复活」这一下
var _ever_alive: Array[bool] = []     ## 只要曾经活过，就允许复活演出；初始出生不算复活
var _bloom := {}      ## 开场还没揭开的格子：一律先按健康组织画
var _hand_seen := {}  ## pid -> 上一帧的手牌数，用来认出「刚抽了一张」
var _hand_pid := -1   ## 抽屉正在显示谁的手牌
var _opening := false ## 正在演开场；start() 会把它带给桥（桥是 start() 里才建的）
var _breath_acc := 0.0   ## 呼吸计时的小数积累
var _breath_step := 0    ## 全局呼吸步进（各细胞再按编号错相位）
var _fading := false  ## 正在演返场淡出：这期间**必须停掉每帧刷新**，
                      ## 否则 _sync_tiles 会把刚淡成健康的格子又刷回癌性
var _flash := {}      ## 刚翻面的格子 → 白闪剩余时间
var _tile_info: CWTileInfo   ## 悬停格子详情（_ready 里程序化补进 UI 层）
var _card_info: CWCardInfo   ## 悬停手牌详情，同样程序化补进；与格子详情同一套打法
var _feed: CWFeed            ## 棋盘左侧的出牌列（打出的卡 / 抽到的事件卡 / 世界事件）
var _feed_seq := 0           ## 已经补到 game.feed_log 的第几条（见 _sync_feed）
var _chemo_fx: CWChemoFx     ## 树突【I-趋化源】的漩涡核心演出（挂在棋盘层，跟着格子走）
## 【免疫猎杀】附在某个癌细胞身上的【追踪趋化源】。**另起一只**，不和上面那只共用 ——
## 两个源可以同时在场（普通源一个、追踪源一个），一只演出画不了两处。
var _chemo_track_fx: CWChemoFx
var _mark_aura_fx: CWMarkAuraFx  ## 树突【I-标记】光环范围的常驻粒子（同上，也挂棋盘层）
var _hunt_fx: CWHuntFx         ## 免疫猎杀捕获准星
var _mucus_fx: CWMucusFx       ## 印戒【黏液破裂】的引爆
var _beam_fx: CWBeamFx         ## T【Excalibur】的双螺旋光束
var _chain_fx: CWChainFx       ## 巨噬【连续吞噬】的每一口
var _skill_fx: CWSkillFx       ## 一次性技能演出的合集（issue #15）
var _decos: Array = []         ## 下标同 _cell_nodes：每只细胞 [背面, 正面] 两个 CWCellDeco（囊性护甲 / 刚性屏障 / 头顶标记）
var _seal_fx: CWSealFx         ## B【中和抗体】的投递与封禁环（后者常驻，见 _sync_seal）
## 【E-侵蚀】的两帧过场。不是节点：它只决定「这一格这一帧画哪张图」，由 _sync_tiles 落实
var _erosion_fx := CWErosionFx.new()
## 细胞传送的溶解演出（规格 docs/动画规格_传送.md）。同样不是节点：残影挂在 _cells_root 下，句柄它自己收。
## 「这是传送」由下面 _last_pos 的差分判定（上一帧与这一帧都活着、两格不相邻），不走引擎信号。
var _teleport_fx := CWTeleportFx.new()
var _last_pos: Array[Vector2i] = []   ## 上一帧位置，下标 = cell id；两格不相邻 = 传送
var _played_card_fx: Array[Sprite2D] = []   ## 本回合打出卡牌的头顶飞卡演出句柄
var _revive_fx: Array[Sprite2D] = []       ## 正在播放的复活图腾演出句柄
var _log_panel: CWLogPanel   ## 对局日志面板（L 键开关），同样程序化补进
var _log_hint: CWLogHint     ## 左上角「对局日志 L」入口提示（定案A），显隐跟着面板走
var _handoff: CWHandoff      ## 热座换手遮罩（UI 层，压在暂停菜单下面）；桥在换人时 await 它
var _guide: CWGuide          ## 教程局的新手引导面板（每局新建、拆局 queue_free；非教程为 null）
var _codex: CWCodex          ## 对局内的知识之书（引导面板直达时懒建，拆局只隐藏；非教程为 null）
var _spotlight: CWGuideSpotlight   ## 教程局的提亮层（引导面板之下，只画不挡；每局新建、拆局销毁；非教程为 null）


func _ready() -> void:
	_cells_root = Node2D.new()
	_cells_root.name = "Cells"
	board.add_child(_cells_root)
	## 骰子挂在棋盘下面，这样 place_at() 收到的就是棋盘坐标，
	## z_index 也能和组织块用同一套画家算法（见 dice.gd 的 place_at）。
	_dice = CWDice.new()
	board.add_child(_dice)
	if ui != null:
		## 悬停格子详情：程序化补进 UI 层，但要压在暂停菜单**下面** ——
		## 暂停时 _process 停了，信息卡收不掉，不能让它浮在暂停层上。
		## 悬停信号在 start()/teardown() 里成对开合（拆局约定：信号必须断干净）。
		## 趋化源的漩涡：挂在**棋盘**上而不是 UI 层 —— 它是场上的东西，
		## 得跟着相机缩放/平移，也得按格子的 z 序压在细胞下面
		_chemo_fx = CWChemoFx.new()
		_chemo_fx.visible = false
		board.add_child(_chemo_fx)
		_chemo_track_fx = CWChemoFx.new()
		_chemo_track_fx.visible = false
		board.add_child(_chemo_track_fx)
		## 标记光环范围：同样挂棋盘层。**一只节点画所有树突的范围**——
		## 每只树突一个节点的话，两只挨在一起时重叠区会被画两遍、亮一倍。
		_mark_aura_fx = CWMarkAuraFx.new()
		_mark_aura_fx.visible = false
		board.add_child(_mark_aura_fx)
		_hunt_fx = CWHuntFx.new()
		_hunt_fx.visible = false
		## 不设这个就停在 z=0，整只准星沉到棋盘底下（格子的 z 是它自己的贴图 y）。
		## 骰子 2026-08-27 栽的是同一个坑，见 board.gd 的 z 约定
		_hunt_fx.z_index = board.Z_OVER_BOARD
		board.add_child(_hunt_fx)
		## 这两只同理：液浪 92px、封禁环立在细胞身上，都横跨好几排
		_mucus_fx = CWMucusFx.new()
		_mucus_fx.visible = false
		_mucus_fx.z_index = board.Z_OVER_BOARD
		board.add_child(_mucus_fx)
		_seal_fx = CWSealFx.new()
		_seal_fx.z_index = board.Z_OVER_BOARD
		board.add_child(_seal_fx)
		_beam_fx = CWBeamFx.new()
		_beam_fx.visible = false
		_beam_fx.z_index = board.Z_OVER_BOARD
		board.add_child(_beam_fx)
		_chain_fx = CWChainFx.new()
		_chain_fx.z_index = board.Z_OVER_BOARD
		board.add_child(_chain_fx)
		## 一次性技能演出的合集（issue #15）：同样横跨好几排，压在棋盘之上
		_skill_fx = CWSkillFx.new()
		_skill_fx.z_index = board.Z_OVER_BOARD
		board.add_child(_skill_fx)
		_tile_info = CWTileInfo.new()
		ui.add_child(_tile_info)
		if pause_menu != null:
			ui.move_child(_tile_info, pause_menu.get_index())
		## 手牌详情与格子详情同层。两者不会同时出现——鼠标只能停在一处
		_card_info = CWCardInfo.new()
		ui.add_child(_card_info)
		ui.move_child(_card_info, _tile_info.get_index())
		## 棋盘左侧的出牌列（Kevin 2026-09-07：顶带那条通报「太过拥挤」，删掉换成留得住的一列卡）。
		## 机位已为它让出 CWView.LEFT_STRIP，压不到棋盘
		_feed = CWFeed.new()
		ui.add_child(_feed)
		ui.move_child(_feed, _tile_info.get_index())
		## 投降票面（联机才会露面）。摆在顶部居中那条唯一还空着的带子上，不做模态 ——
		## 30 秒里对局照常进行，队友不该因为要投票被冻住
		_vote = CWSurrenderVote.new()
		ui.add_child(_vote)
		ui.move_child(_vote, _tile_info.get_index())
		_vote.voted.connect(func(agree: bool) -> void:
			if _client != null:
				_client.surrender(agree))
		## 日志面板压在信息卡下面：两者都开着时，悬停详情仍然读得到
		_log_panel = CWLogPanel.new()
		ui.add_child(_log_panel)
		ui.move_child(_log_panel, _tile_info.get_index())
		## 左上角入口提示（定案A·2026-08-30）：钉在面板展开的位置，点击 = 按 L。
		## 显隐归本类管：开局亮、面板开着让位（_process 每帧对齐）、拆局收起。
		_log_hint = CWLogHint.new()
		_log_hint.visible = false
		ui.add_child(_log_hint)
		ui.move_child(_log_hint, _tile_info.get_index())
		_log_hint.pressed.connect(func() -> void: _log_panel.toggle())
		## 联机的倒计时与断线遮罩，同层
		net_hud = CWNetHud.new()
		ui.add_child(net_hud)
		ui.move_child(net_hud, _tile_info.get_index())
		## **两只详情框排到这一组的最上面**（Kevin 2026-09-07 拍到出牌列的卡盖在卡面详情上）。
		## 这一组每个都是「插到 _tile_info 当前的位置」，于是**后插的反而更靠上**——
		## _card_info 是第一个插的，不补这一手就沉在最底下，被出牌列 / 日志面板压住。
		## 详情框是浮在别的东西上的提示，被压住就等于看不见。
		ui.move_child(_card_info, _tile_info.get_index())
		## 热座换手遮罩：盖住手牌 / 行动栏 / 详情框，只让暂停菜单压在它上面
		_handoff = CWHandoff.new()
		ui.add_child(_handoff)
		if pause_menu != null:
			ui.move_child(_handoff, pause_menu.get_index())
		ui.visible = false
	if autostart:
		CWView.apply(camera, board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
		start()


## snap 非空 = 从存档继续：装配完把快照原样放回去，run_game 会把存档那一刻
## 待决的询问重新问出来（恢复点必然是 pending 边界，CWSave 只在那儿写得出档）。
func start(snap: Dictionary = {}) -> void:
	_prepare_ui()
	if tutorial and snap.is_empty():
		## 教程局（16 关重构切片⑧）：按进度当前关用导演装配——1–15 关 fixture 小棋盘、
		## 第 16 关正式四人局；人类坐视角阵营的玩家席（第 5 关癌症视角坐 1 号席）。
		_tutorial_ch = clampi(CWGuideProgress.done_count(), 0, CWGuideData.CHAPTER_COUNT - 1)
		player_count = 4 if CWGuideLevels.formal(_tutorial_ch) else 2
		human_players = [1 if CWGuideLevels.player_faction(_tutorial_ch) == CWData.Faction.CANCER else 0]
		game = CWGuideDirector.assemble(_tutorial_ch, 0)
	else:
		game = CWGame.new()
		game.tune.cancer_types = cancer_types.duplicate()   ## 必须在 init 之前：抽种类在开局第一步
		game.tune.world_events_on = world_events
		game.init(CWData.FACTION_ORDER[player_count],
			match_seed if match_seed != 0 else int(Time.get_unix_time_from_system()))
		if not snap.is_empty():
			game.restore(snap)   ## rng 状态也在快照里，init 用的种子随之作废
	_bind_game_signals()
	_wire_bridge(ai_level)
	## 同一个桥对象注册给所有玩家：人类那几位走界面，其余走 AI，
	## 掷骰演出按对象去重所以只演一遍（理由见 ui_bridge.gd 文件头）。
	for pid in game.order:
		game.bridges[pid] = bridge
	game.record_replay = true          ## 真对局才录（MC 推演不录，见 CWGame.ask）
	if tutorial:
		_attach_guide()   ## 要在 _run()（第一次询问）之前：第一句提示 / 第一次演示就要读章节
	_run()


## 对局信号绑定（start 与教程跨章换局共用）：换的是新 CWGame，四个信号逐一接上；
## 棋盘网格也按新局的半径重建（教程小棋盘，正式局 127 格不变）。
func _bind_game_signals() -> void:
	board.build_for(game.board_radius)
	if not game.card_played.is_connected(_on_card_played):
		game.card_played.connect(_on_card_played)
	if not game.event_drawn.is_connected(_on_event_drawn):
		game.event_drawn.connect(_on_event_drawn)
	if not game.card_drawn.is_connected(_on_card_drawn):
		game.card_drawn.connect(_on_card_drawn)
	if not game.world_event.is_connected(_on_world_event):
		game.world_event.connect(_on_world_event)


## 教程跨章 = 换一局（CWGuide.on_chapter_done 回调）：新关局面由导演装配、
## 人类席位按视角换边；旧局按拆局次序收摊（先 aborted、再唤醒卡住的询问、
## 最后 dispose），旧运行协程由 _run 的代际号安静退场。
func _advance_tutorial_chapter(next_ch: int) -> void:
	if not tutorial or game == null:
		return
	_run_gen += 1
	var old := game
	_tutorial_ch = clampi(next_ch, 0, CWGuideData.CHAPTER_COUNT - 1)
	player_count = 4 if CWGuideLevels.formal(_tutorial_ch) else 2
	human_players = [1 if CWGuideLevels.player_faction(_tutorial_ch) == CWData.Faction.CANCER else 0]
	game = CWGuideDirector.assemble(_tutorial_ch, 0)
	_bind_game_signals()
	_wire_bridge(ai_level)
	for pid in game.order:
		game.bridges[pid] = bridge
	## **换局会新建一个桥**（_wire_bridge），所以要把**同一个**引导面板重新挂上去。
	## 不重挂的话新桥的 guide 是空的 —— CWGuideBridge 每处都判空，于是不崩、
	## 但从第 2 关起提示、演示、「继续」代做全部静默失效（合并时查出来的，
	## PR 原样是漏的）。这儿不重建面板、只重接线：面板正处在自己的回调里
	if _guide != null and is_instance_valid(_guide) and bridge is CWGuideBridge:
		(bridge as CWGuideBridge).guide = _guide
		bridge.set_meta("tutorial_guide", _guide)
		_guide.demo_ready = (bridge as CWGuideBridge).can_demo
	## 每一局都录（同 start()）：跨章换的是新 CWGame，不置位的话
	## 从第 2 关起就不再录，最后 CWReplay.save 存出个空
	game.record_replay = true
	old.aborted = true
	if bridge != null:
		bridge.abort()
	old.dispose()
	_run()


## 回放：局面是**本地重建**的（`CWReplay.Player` 已经建好并跑着），
## 界面这边只负责把它画出来 + 按播放控制推进。
##
## 与联机观战的区别：那边的 `game` 是服务器推下来的影子对局（手牌全是背面），
## 这边是本地重建的真局面 —— **所有人的真手牌都在**，因为这一局已经结束了，
## 没有什么可保密的（见 CWReplay 文件头）。
##
## 桥仍然是 `CWUIBridge`：掷骰演出、通报、过场全是走桥的，
## 换成纯数据桥回放就成了没有演出的哑剧。`human_players` 留空 = 谁也不问，
## 桥的 `replay_answers` 非空时 `ask()` 直接念下标。
func start_replay(p: CWReplay.Player) -> void:
	_prepare_ui()
	replay = p
	game = p.game
	player_count = game.players.size()
	for sig in [["card_played", _on_card_played], ["event_drawn", _on_event_drawn],
			["card_drawn", _on_card_drawn], ["world_event", _on_world_event]]:
		if not game.is_connected(sig[0], sig[1]):
			game.connect(sig[0], sig[1])
	human_players = []                 ## 回放没有「轮到你了」这回事
	_wire_bridge(0)
	p.attach(bridge)                   ## 下标串与进度交接给界面桥
	## 播放控制条。摆在行动栏那条位置 —— 回放局没有真人席位，行动栏根本不出现
	if _replay_bar == null and ui != null:
		_replay_bar = CWReplayBar.new()
		ui.add_child(_replay_bar)
		## **只发信号，不自己推**：真正的推进统一由 _replay_loop 执行，
		## 一帧一次，连点几下不会有两个 seek 同时推同一局（同键盘那条路）
		_replay_bar.jumped.connect(func(to: int) -> void:
			replay_paused = true
			_replay_target = clampi(to, 0, replay.total))
		_replay_bar.paused_toggled.connect(func() -> void:
			replay_paused = not replay_paused)
		_replay_bar.speed_cycled.connect(func() -> void:
			var i: int = REPLAY_SPEEDS.find(replay_speed)
			replay_speed = REPLAY_SPEEDS[(i + 1) % REPLAY_SPEEDS.size()])
	if _replay_bar != null:
		_replay_bar.visible = true
	if pause_menu != null:
		## 只留「退出回放」：回放不能存档、不能改规则。**不能借 online 那个开关** ——
		## 借了就会写成「离开房间？离开后本局由 AI 代打」，三个词全是假的
		pause_menu.replay = true
	_replay_loop(_loop_id)


## 开聊天页。**两页互斥** —— 它们共用左上角同一块地（CWLogPanel.RECT），
## 同时开着就是两层叠在一起，谁也看不清
func _toggle_chat() -> void:
	if _chat == null:
		return
	if not _chat.is_open() and _log_panel != null and _log_panel.visible:
		_log_panel.toggle()
	_chat.toggle()


## 把客户端收到的聊天搬进框里。只补没见过的那几条（同 _sync_feed 的游标办法）——
## 聊天**不进对局流**，所以它到得比演出早，不能等演出播完再搬
func _sync_chat() -> void:
	if _chat == null or _client == null:
		return
	while _chat_seen < _client.chat_log.size():
		_chat.push(_client.chat_log[_chat_seen])
		_chat_seen += 1


## 回放的播放键。返回是否吃掉了这一下。
##   空格 = 暂停 / 继续　　← → = 退 / 进 REPLAY_JUMP 步　　↑ ↓ = 倍速
## 快退是真的重算（还原关键帧 + 快进），所以按住不放不会失步，只是慢一点
const REPLAY_JUMP := 10        ## 一下跳几步
const REPLAY_SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]

func _replay_key(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_accept"):
		replay_paused = not replay_paused
		return true
	if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		var d := REPLAY_JUMP if event.is_action_pressed("ui_right") else -REPLAY_JUMP
		replay_paused = true          ## 拖完停住 —— 手动找位置时不该被自动播放带走
		## **只设目标，不自己跑** —— `seek()` 是协程，在输入处理里 await 它
		## 会让这个函数也变成协程，而且连按两下就是两个 seek 同时在推同一局。
		## 交给 `_replay_loop` 单点执行：它一帧只处理一次，天然不会打架。
		var from: int = _replay_target if _replay_target >= 0 else replay.at()
		_replay_target = clampi(from + d, 0, replay.total)
		return true
	if event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down"):
		var i: int = REPLAY_SPEEDS.find(replay_speed)
		## 绕回 —— 条上那个倍速按钮**一直**是绕的（`(i + 1) % size`），
		## 键盘这条却是钳的，同一个控件两套手感（Kevin 2026-09-10 一并收口）
		i = posmod(i + (1 if event.is_action_pressed("ui_up") else -1),
			REPLAY_SPEEDS.size())
		replay_speed = REPLAY_SPEEDS[i]
		return true
	return false


## 回放的推进循环。**速度不在播放器里管** —— 它只提供「往前一步」，
## 隔多久走一步是这儿的事：暂停就不走，倍速就一帧多走几步。
func _replay_loop(id: int) -> void:
	var carry := 0.0
	while _loop_id == id and replay != null:
		await get_tree().process_frame
		## 拆局可能正好落在这一帧里（teardown 会把播放器撒手），下面每一处都要碰它
		if _loop_id != id or replay == null:
			return
		## 拖进度：一帧只做一次，做完清目标。快退是真的重算
		## （还原关键帧 + 快进），所以连按几下只是慢一点，不会失步
		if _replay_target >= 0:
			var to: int = _replay_target
			_replay_target = -1
			await replay.seek(to)
			continue
		if replay_paused or replay.done():
			continue
		carry += replay_speed
		while carry >= 1.0 and _loop_id == id and replay != null and not replay.done():
			carry -= 1.0
			await replay.step_once()


## 联机：影子对局来自客户端，桥只服务我这一席；询问与演出由 _net_loop 驱动。
## 调用前 client 已进入顺序播放模式且第一份状态已排在 stream 里（CWOnlinePanel 保证）。
func start_online(p_client: CWNetClient) -> void:
	_prepare_ui()
	online = true
	_client = p_client
	_loop_id += 1
	_ask_serial += 1
	while not _client.stream.is_empty() and _client.stream[0]["t"] == "state":
		_client.apply_now(_client.stream.pop_front())   ## 先让第一份状态生效，影子对局才存在
	if _client.shadow == null:
		_client.shadow = CWGame.new()
		_client.shadow.init(CWData.FACTION_ORDER[player_count], 0)
	game = _client.shadow
	if not game.card_played.is_connected(_on_card_played):
		game.card_played.connect(_on_card_played)
	if not game.event_drawn.is_connected(_on_event_drawn):
		game.event_drawn.connect(_on_event_drawn)
	if not game.card_drawn.is_connected(_on_card_drawn):
		game.card_drawn.connect(_on_card_drawn)
	if not game.world_event.is_connected(_on_world_event):
		game.world_event.connect(_on_world_event)
	player_count = game.players.size()
	var seats: Array[int] = []
	if _client.my_seat >= 0:
		seats.append(_client.my_seat)
	human_players = seats
	_wire_bridge(false)
	if pause_menu != null:
		pause_menu.online = true
	if settle != null:
		settle.online = true
	if net_hud != null:
		net_hud.set_link("")
		net_hud.stop_countdown()
		net_hud.hide_ping()
	_net_loop(_loop_id)


func start_online_with_bloom(p_client: CWNetClient, seconds: float) -> void:
	_opening = true
	start_online(p_client)
	await _play_bloom(seconds)


## 开局前把上一局留下的东西还原、HUD 亮起来（start / start_online 共用）
func _prepare_ui() -> void:
	_fading = false
	## 先杀上一局的淡出补间，再还原 alpha —— 顺序反了等于没改：
	## 补间还活着的话，下一帧它会把刚设回 1.0 的 alpha 继续拉向 0。
	for tw in _fade_tws:
		if tw != null and tw.is_valid():
			tw.kill()
	_fade_tws.clear()
	## 棋盘那边同一回事：fade_to_healthy() 的过渡叠层不归 set_marks 管，
	## 残留回调会在这一局里把格子刷成健康贴图
	if board != null:
		board.cancel_fade()
	if _cells_root != null:
		_cells_root.modulate.a = 1.0     ## 上一局淡出留下的，开新局要还原
	_clear_played_card_fx()
	_clear_revive_fx()
	if hand != null:
		hand.visible = true              ## 热座换手期间会收起，开新局要还原
	if ui != null:
		ui.visible = true
		for c in ui.get_children():
			if c is Control:
				(c as Control).modulate.a = 1.0
	if pause_menu != null:
		pause_menu.active = true
		## 菜单形制一律先还原成本地局，联机 / 回放各自的 start 会紧接着再打开。
		## teardown 只在 online 时复位 online，所以看完一份回放再开本地局，
		## 「保存并退出」会凭空消失、「返回主菜单」还写着「离开房间」
		pause_menu.online = false
		pause_menu.replay = false
		pause_menu.can_save = can_save_now
		## 对局内知识之书开着时 Esc 先关书、不弹暂停（非教程局 _codex 恒为 null = 没开书）
		pause_menu.codex_open = func() -> bool:
			return _codex != null and is_instance_valid(_codex) and _codex.visible
		pause_menu.surrender_faction = viewing_faction
		## 「反馈 bug」要带走此刻的对局快照（issue #19）；联机 / 回放里 game 是本地镜像，照样抓得到
		pause_menu.feedback_snapshot = func() -> Dictionary:
			return game.snapshot() if game != null else {}
	if _tile_info != null and not board.tile_hovered.is_connected(_tile_info.on_hover):
		board.tile_hovered.connect(_tile_info.on_hover)
	if _card_info != null and hand != null 			and not hand.card_hovered.is_connected(_card_info.on_hover):
		hand.card_hovered.connect(_card_info.on_hover)
	## 右栏固定详情里停在某条技能上 → 同一只详情框浮 PRD 原文（2026-09-04 Kevin 要的）
	if _card_info != null and panel != null 			and not panel.skill_hovered.is_connected(_card_info.on_hover_info):
		panel.skill_hovered.connect(_card_info.on_hover_info)
	if _card_info != null and _feed != null and is_instance_valid(_feed) \
			and not _feed.card_pressed.is_connected(_card_info.show_info):
		_feed.card_pressed.connect(_card_info.show_info)
	if _log_panel != null:
		_log_panel.active = true
	if _log_hint != null:
		_log_hint.visible = true


## 三档 AI 的名字。**唯一一处**：配置面板的行文、存档的兼容映射、装配都读它。
const AI_LEVEL_NAMES := ["普通", "较强", "树搜索"]
const AI_NORMAL := 0
const AI_MC := 1        ## 扁平蒙特卡洛（CWUIBridge 的基类本体），也是平衡标尺
const AI_MCTS := 2      ## UCT 树搜索（队友 2026-09-07 的 CWMCTSBridge）
## 树搜索档的预算。扁平 MC 的专家档是 192 个模拟 step；树搜索给两倍，
## 依据是「它该更强，也该更慢一点，但仍要有可预测的上限」——
## ⚠ **这三个数没有对局数据支撑**，只是量纲上的合理取值，等有了 AI 互搏基准再定。
const MCTS_ITERATIONS := 160
const MCTS_HORIZON := 12
const MCTS_MAX_STEPS := 384


func _wire_bridge(level: int) -> void:
	## 教程局包一层引导桥（子类，只多演示与提示，其余装配完全相同）
	bridge = CWGuideBridge.new() if tutorial else CWUIBridge.new()
	bridge.hunt_fx = _hunt_fx
	bridge.mucus_fx = _mucus_fx
	bridge.seal_fx = _seal_fx
	bridge.beam_fx = _beam_fx
	bridge.chain_fx = _chain_fx
	bridge.skill_fx = _skill_fx
	## 聊天框只在联机局建：本地局没人可聊，教程局更不该多一个能抢回车的东西。
	## **CHAT_ON 现在是关的**（Kevin 2026-09-10 拍板先停）—— 三条待修见常量那儿。
	if CHAT_ON and online and _chat == null and ui != null:
		_chat = CWChatBox.new()
		ui.add_child(_chat)
		_chat.said.connect(func(text: String, team: bool) -> void:
			if _client != null:
				_client.say(text, team))
		## 和对局日志共用左上角那块：迷你条上多一页「聊天」，两页互斥
		if _log_hint != null:
			_log_hint.set_chat(_chat)
			_log_hint.chat_pressed.connect(_toggle_chat)
	bridge.game = game
	bridge.board = board
	bridge.dice = _dice
	bridge.bar = action_bar
	bridge.info = _card_info   ## 分化提问里悬停种类按钮 → 细胞种类详情（同一只详情框）
	bridge.panel = panel
	bridge.toast = toast
	bridge.camera = camera
	bridge.erosion = _erosion_fx
	bridge.hand = hand   ## 方案甲：打出/弃置手势从手牌抽屉来
	bridge.handoff = _handoff
	bridge.hotseat = human_players.size() >= 2   ## 热座 = 一台电脑坐了两位以上真人
	bridge.human_pids = human_players
	bridge.enabled = level == AI_MC   ## 「较强」= 扁平蒙特卡洛（桥的基类），默认启发式
	## 真人档要有可预测的响应上限；预算按模拟 step 计，不受本机快慢影响。
	bridge.max_sim_steps = 192 if level == AI_MC else 0
	## 会推演的两档都把评估放进副线程（修「较强 AI 卡前端」）：主线程提交后只 await，
	## 评估在 `Thread` 上跑，相机/输入不再被同步评估块整段堵住。
	## 教程局从不推演（CWGuideBridge 不开 MC），不冒线程化的险。
	var thinking: bool = level != AI_NORMAL and not tutorial
	bridge.use_threading = level == AI_MC and thinking
	## 第三档：挂一只 MCTS 桥当代打。**组合而不是继承** —— CWUIBridge 已经继承了扁平 MC，
	## 而 CWMCTSBridge 是与扁平 MC 并列的另一棵（队友刻意不继承，为的是不动平衡标尺）。
	## 共用同一个 game；非顶层询问它自己会回落到启发式，delay 也走基类那条，行为与另两档一致。
	bridge.mcts = null
	if level == AI_MCTS and not tutorial:
		var tree_ai := CWMCTSBridge.new()
		tree_ai.game = game
		tree_ai.iterations = MCTS_ITERATIONS
		tree_ai.horizon = MCTS_HORIZON
		tree_ai.max_sim_steps = MCTS_MAX_STEPS
		tree_ai.use_threading = thinking
		tree_ai.delay_ms = CWSettings.ai_delay_ms
		tree_ai.delay_node = self
		bridge.mcts = tree_ai
	bridge.opening = _opening    ## 绽开演完前先不弹询问界面
	bridge.delay_ms = CWSettings.ai_delay_ms
	bridge.delay_node = self


## 结算屏出场前，把还飘在棋盘上的临时 HUD 收掉。
## 出牌列是「这一局发生了什么」的流水账，局都结束了就没有继续占着左边那条的理由 ——
## 它压在结算屏上（Kevin 2026-09-07 拍到）。提示气泡同理（实测截到过「突变：无事发生」）。
## **不拆节点、只清内容**：再来一局还用同一批控件。
func clear_transient_hud() -> void:
	if toast != null:
		toast.hide_now()
	if _feed != null and is_instance_valid(_feed):
		_feed.clear_all()
		_feed_seq = 0


## 教程局装配：建引导面板（UI 层、压在暂停菜单下面）并把它交给引导桥。
## start() 里在桥注册给所有玩家之后、_run()（第一次询问）之前调用 ——
## 第一句提示 / 第一次演示发生时面板已经能读章节。每局都新建实例、不复用：
## guide.setup() 会 _build()，复用等于把控件再挂一遍。
func _attach_guide() -> void:
	if ui == null:
		return
	if _guide != null and is_instance_valid(_guide):
		_guide.queue_free()
	_guide = CWGuide.new()
	_guide.visible = false
	ui.add_child(_guide)
	if pause_menu != null:
		ui.move_child(_guide, pause_menu.get_index())
	_guide.setup(self)
	_guide.visible = true
	if bridge is CWGuideBridge:
		(bridge as CWGuideBridge).guide = _guide
		bridge.set_meta("tutorial_guide", _guide)
		## 「继续」代做（Kevin 2026-09-05）：面板问桥「此刻能代做吗」，按下时让桥替玩家作答
		_guide.demo_ready = (bridge as CWGuideBridge).can_demo
		_guide.demo = (bridge as CWGuideBridge).take_offer
		_guide.hint_now = (bridge as CWGuideBridge).current_hint
		## 跨章换局（16 关重构切片⑧）：面板翻章只管翻页，局面由对局侧重装配
		_guide.on_chapter_done = _advance_tutorial_chapter
	## 提亮层压在 HUD 之上、引导面板之下；每帧在 _process 里按当前步骤的 flag 重算目标
	if _spotlight != null and is_instance_valid(_spotlight):
		_spotlight.queue_free()
	_spotlight = CWGuideSpotlight.new()
	ui.add_child(_spotlight)
	ui.move_child(_spotlight, _guide.get_index())


## 引导面板「知识之书」直达：对局内把图鉴翻到当前关卡对应的章节（CWGuideData.CODEX_PAGE）。
## 图鉴盖在引导面板上面，Esc / 右键关掉就回到引导；实例懒建，拆局只隐藏不销毁。
func focus_codex_on_topic(page: int) -> void:
	if ui == null:
		return
	if _codex == null or not is_instance_valid(_codex):
		_codex = CWCodex.new()
		ui.add_child(_codex)
		if pause_menu != null:
			ui.move_child(_codex, pause_menu.get_index())
	_codex.open_to(page)


## 开场第二拍：初始癌组织从正中一格一格翻出来（团队定的三拍开场之二）。
##
## 顺序很讲究：start() 会一路跑到**第一次询问**才挂起，那时初始癌组织已经躺在
## game.tiles 里了，而本帧的 _process 还没跑 —— 所以在这中间把它们记进 _bloom
## 还来得及，玩家看到的第一帧仍是干净的健康组织。
##
## 揭示顺序不写死「中央 + 第一环」，而是按「离中心几格、同环按角度」排 ——
## 地图生成还在讨论中，初始癌区形状随时可能变，排序法对什么形状都成立。
func start_with_bloom(seconds: float) -> void:
	## 必须在 start() **之前**置位：桥是 start() 里才 new 出来的，
	## 在这之后再写 bridge.opening 就晚了（第一版就是这么错的，
	## 守卫静默失效、绽开还没演完落子提示就弹了出来）。
	_opening = true
	start()
	await _play_bloom(seconds)


func _play_bloom(seconds: float) -> void:
	var order := _bloom_order()
	for c in order:
		_bloom[c] = true
	var step := seconds / maxf(order.size(), 1)
	for c in order:
		_bloom.erase(c)
		_flash[c] = FLASH_TIME
		await get_tree().create_timer(step).timeout
	_opening = false
	bridge.opening = false


func _bloom_order() -> Array:
	var out: Array = []
	for c: Vector2i in game.tiles:
		if game.is_cancerous(c):
			out.append(c)
	var origin: Vector2 = board.tile_center(Vector2i.ZERO)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := CWData.hex_dist(a, Vector2i.ZERO)
		var db := CWData.hex_dist(b, Vector2i.ZERO)
		if da != db:
			return da < db
		return (board.tile_center(a) - origin).angle() < (board.tile_center(b) - origin).angle())
	return out


func _run() -> void:
	var gen := _run_gen
	var winner: int = await game.run_game()
	if gen != _run_gen:
		return    ## 教程跨章换局：旧局协程安静退场，finished 由新局的 _run 发
	finished.emit(winner)


## 联机：按服务器发来的顺序消费对局流。演出（掷骰）要等播完再让下一条生效，
## 所以 state 不在收到时 restore、而是在这里轮到它时才 apply_now。
func _net_loop(id: int) -> void:
	while online and _loop_id == id and _client != null and is_inside_tree():
		if _client.stream.is_empty():
			_sync_link()
			await get_tree().process_frame
			continue
		var m: Dictionary = _client.stream.pop_front()
		match m["t"]:
			"state":
				_client.apply_now(m)
			"roll":
				if bridge != null:
					await bridge.show_roll(m["reason"], m["value"], m["sides"], m["pid"], m["at"])
			"result":
				if bridge != null:
					bridge.show_result(m["text"], m["at"], bool(m.get("linger", false)))
			"notice":
				if bridge != null:
					bridge.show_notice(m["text"])
			"card_played":
				if bridge != null:
					bridge.show_card_played(int(m["pid"]), m["text"])
				## 影子对局不跑 card_fx.play、发不出 card_played 信号：头顶飞卡靠报文里的细胞信息驱动
				if m.has("card"):
					_on_card_played(int(m["cell_id"]), int(m["pid"]), m["pos"], int(m["faction"]), m["card"], {})
			"event_drawn":
				## 同上：抽到即结算的事件卡，影子对局也发不出信号
				_on_event_drawn(int(m["cell_id"]), int(m["pid"]), m["pos"], int(m["faction"]), m["card"])
			"card_drawn":
				_on_card_drawn(int(m["cell_id"]), int(m["pid"]), m["pos"], String(m.get("source", "")))
			"world_event":
				## 影子对局不跑 world_fx，同样发不出信号 —— 靠报文驱动
				_on_world_event(String(m["ev"]), int(m.get("left", 1)))
			"erosion":
				if bridge != null:
					bridge.show_erosion(m["at"], int(m["dir"]))
			"beam":
				if bridge != null:
					bridge.show_beam(m["from"], m["to"], m.get("splash", []))
			"fx":
				if bridge != null:
					bridge.show_fx(String(m["kind"]), m.get("data", {}))
			"ask":
				_serve_ask(m)
			"game_over":
				_client.apply_now(m)
				if online and _loop_id == id:
					finished.emit(int(m["winner"]))
				return


## 一次询问：交给现有的界面桥，答完把下标发回服务器。不 await 它 —— 玩家在想的时候，
## 对局流里的其它条目照常处理。服务器代打后重问的旧一问：先 abort 收掉界面，
## 旧协程醒来发现序号变了就丢弃答案。
func _serve_ask(m: Dictionary) -> void:
	if bridge == null:
		return
	_ask_serial += 1
	var my := _ask_serial
	bridge.abort()
	if net_hud != null:
		net_hud.start_countdown(int(m.get("left_ms", -1)))
	var idx: int = await bridge.ask(m["req"])
	if _ask_serial != my or not online or _client == null or game == null:
		return
	if net_hud != null:
		net_hud.stop_countdown()
	_client.answer(int(m["ask_id"]), idx)


## 断线遮罩与席位状态跟着客户端走
func _sync_link() -> void:
	if _client == null:
		return
	if net_hud != null:
		net_hud.set_link("" if _client.status == "open" else "连接断开，正在重连…")
		net_hud.set_ping(_client.ping_ms)   ## 数字由客户端的心跳往返给（Kevin 2026-09-07）
	if panel != null:
		panel.net_seats = _client.room.get("seats", [])
	## 票面每帧对一次：倒计时要走，票况随时会变（服务器每收一票就重播一遍）
	if _vote != null:
		_vote.sync(_client.surrender_vote, _client.my_seat, get_viewport_rect().size.x)
	## 服务器的拒绝理由要让人看见。**对局中联机面板是隐藏的**，它那句 _set_status()
	## 写进的是看不见的标签 —— 于是「投降被冷却挡了」表现为点了没反应（Kevin 2026-09-09）。
	## 这里统一兜住**所有**对局中的 error，不只是投降那几条。
	if _client.error_seq != _seen_error and bridge != null:
		_seen_error = _client.error_seq
		var msg: String = str(_client.last_error.get("msg", ""))
		if msg != "":
			bridge.show_result(msg, _error_at(), true)


## 返场淡出：让棋盘上的东西**淡着消失**，而不是啪地不见（团队 2026-08-27 反馈）。
## 真正的拆解由 teardown() 在淡完之后做 —— 这里只管演。
##
## 第一件事是把对局叫停：不然淡出途中 AI 还在走棋、组织还在变色，
## 一边淡一边动，看起来像出了故障。
func fade_out(seconds: float) -> void:
	if game == null or _fading:
		return
	if not online:
		game.aborted = true     ## 联机的影子对局没有引擎在跑，也不归本节点收摊
	if bridge != null:
		bridge.abort()
	_fading = true
	board.set_marks({})                      ## 高亮自己会淡掉
	board.fade_to_healthy(seconds)
	if _cells_root != null:
		var tw := _cells_root.create_tween()
		tw.tween_property(_cells_root, "modulate:a", 0.0, seconds)
		_fade_tws.append(tw)
	## HUD 稍微早一点淡完 —— 它不在棋盘上，跟着棋盘一起慢慢消反而拖沓
	if ui != null:
		for c in ui.get_children():
			if c is Control and (c as Control).visible:
				var ui_tw := (c as Control).create_tween()
				ui_tw.tween_property(c, "modulate:a", 0.0, seconds * 0.6)
				_fade_tws.append(ui_tw)


## 拆掉当前这一局，把棋盘擦回开局前的样子。
##
## 返回主菜单必须走这里：棋盘和相机是**和菜单共用的同一份**，
## 不擦干净的话上一局的癌组织和细胞会留在菜单背景里。
func teardown() -> void:
	_fading = false
	_loop_id += 1            ## 联机：让 _net_loop 退出（回放的 _replay_loop 同理）
	## 播放器和控制条是这一份回放的，拆局就得撒手。**不撒手的话下一局带着走**：
	## 控制条留在屏幕上；更糟的是 `_unhandled_input` 见 `replay != null` 就把方向键
	## 和空格当播放键吃掉 —— 空格正是「结束回合」。（2026-09-10 顺着小字那条查出来的）
	replay = null
	replay_paused = false
	replay_speed = 1.0
	_replay_target = -1
	if _replay_bar != null:
		_replay_bar.visible = false
	var active_game: CWGame = game
	if online:
		## 影子对局属于客户端（回到等待室还要用），这里只放手不销毁
		if bridge != null:
			bridge.abort()
		game = null
		online = false
		_client = null
		if net_hud != null:
			net_hud.stop_countdown()
			net_hud.set_link("")
			net_hud.hide_ping()
		if pause_menu != null:
			pause_menu.online = false
		if settle != null:
			settle.online = false
	if active_game != null and active_game.card_played.is_connected(_on_card_played):
		active_game.card_played.disconnect(_on_card_played)
	if active_game != null and active_game.event_drawn.is_connected(_on_event_drawn):
		active_game.event_drawn.disconnect(_on_event_drawn)
	if active_game != null and active_game.card_drawn.is_connected(_on_card_drawn):
		active_game.card_drawn.disconnect(_on_card_drawn)
	if active_game != null and active_game.world_event.is_connected(_on_world_event):
		active_game.world_event.disconnect(_on_world_event)
	_clear_played_card_fx()
	_clear_revive_fx()
	if game != null:
		## 顺序要紧：先让引擎收摊、再唤醒卡住的询问（它会同步一路展开回来），
		## **最后**才 dispose。反过来的话展开途中会碰到已经置空的模块。
		game.aborted = true
		if bridge != null:
			bridge.abort()
		game.dispose()
		game = null
	bridge = null
	_opening = false
	if _handoff != null:
		_handoff.hide_now()
	_teleport_fx.clear_all()   ## 先杀补间再删节点：残影/真身的补间不能活过拆局
	for node in _cell_nodes:
		node.queue_free()
	_cell_nodes.clear()
	for pair in _decos:
		for deco in pair:
			(deco as Node).queue_free()
	_decos.clear()
	_was_alive.clear()
	_ever_alive.clear()
	_last_pos.clear()
	_bloom.clear()
	_flash.clear()
	_erosion_fx.clear_all()
	_hand_seen.clear()
	_hand_pid = -1
	if hand != null:
		hand.clear()
	if toast != null:
		toast.hide_now()
	if _feed != null and is_instance_valid(_feed):
		_feed.clear_all()
		_feed_seq = 0
	if _tile_info != null:
		_tile_info.hide_now()
	if _card_info != null:
		_card_info.hide_now()
	## 手牌不属于棋盘，不能等下面那段 is_instance_valid(board) 里再断
	if _card_info != null and hand != null and hand.card_hovered.is_connected(_card_info.on_hover):
		hand.card_hovered.disconnect(_card_info.on_hover)
	if _card_info != null and panel != null 			and panel.skill_hovered.is_connected(_card_info.on_hover_info):
		panel.skill_hovered.disconnect(_card_info.on_hover_info)
	if _log_panel != null:
		_log_panel.active = false
		_log_panel.hide_now()
	if _log_hint != null:
		_log_hint.visible = false
	if _guide != null and is_instance_valid(_guide):
		_guide.queue_free()   ## 引导面板一局一份，拆局就销毁（下一局教程 _attach_guide 重建）
	_guide = null
	if _spotlight != null and is_instance_valid(_spotlight):
		_spotlight.queue_free()
	_spotlight = null
	if _codex != null and is_instance_valid(_codex):
		_codex.visible = false
	if settle != null:
		settle.reset()
	## 退出游戏时 _exit_tree 也会走到这里，那时棋盘可能已经被释放了
	if is_instance_valid(board):
		if _tile_info != null and board.tile_hovered.is_connected(_tile_info.on_hover):
			board.tile_hovered.disconnect(_tile_info.on_hover)
		for c in CWData.all_coords():
			board.set_tissue(c, CWData.Tissue.HEALTHY, CWData.special_of(c))
		board.set_marks({})
		board.set_mucus([])   ## 覆膜也归拆局清：它不在 marks 里，set_marks({}) 收不掉
	if action_bar != null:
		action_bar.clear()
	if panel != null:
		panel.reset()
	if ui != null:
		ui.visible = false
	if pause_menu != null:
		pause_menu.codex_open = Callable()
		pause_menu.surrender_faction = Callable()
		pause_menu.feedback_snapshot = Callable()
		pause_menu.active = false
		pause_menu.close()


## 对局用完必须显式拆，否则 game 与各模块之间的强引用环不会被回收。
func _exit_tree() -> void:
	teardown()


## 对局内知识之书开着时的键盘路由：Esc 关书、方向键翻页。书自己不收键盘 ——
## 覆盖层统一由宿主路由（主菜单那份也是 CWMainMenu 路由的）。书没开就不管，
## 暂停菜单 / 行动栏各管各的，不和 L / 空格抢。
func _unhandled_input(event: InputEvent) -> void:
	## 聊天：回车唤出 / Esc 收起。**排在暂停菜单前面** ——
	## 框开着时 Esc 该先收框，而不是弹出暂停菜单
	if _chat != null:
		if CWChatBox.is_enter(event) and not _chat.is_open():
			get_viewport().set_input_as_handled()
			_toggle_chat()
			return
		if _chat.handle_key(event):
			get_viewport().set_input_as_handled()
			return
	## 回放的播放控制。**接在这一层**：回放局没有行动栏、没有手牌手势，
	## 方向键与空格本来就没人要，正好拿来当播放键
	if replay != null and (_codex == null or not _codex.visible):
		if _replay_key(event):
			get_viewport().set_input_as_handled()
			return
	if _codex == null or not is_instance_valid(_codex) or not _codex.visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_left") \
			or event.is_action_pressed("ui_right") or event.is_action_pressed("ui_up") \
			or event.is_action_pressed("ui_down"):
		_codex.handle_input(event)


func _process(delta: float) -> void:
	if game == null or game.tiles.is_empty() or _fading:
		return
	_sync_feed()   ## 出牌列跟着对局状态走（方案甲）：只补没见过的那几条，便宜
	_sync_chat()
	if _replay_bar != null and replay != null:
		_replay_bar.refresh(replay.at(), replay.total, replay_paused, replay_speed)
	for c: Vector2i in _flash.keys():
		_flash[c] -= delta
		if _flash[c] <= 0.0:
			_flash.erase(c)
	_erosion_fx.advance(delta)
	_sync_tiles()
	_sync_cells()
	_animate_breath(delta)
	_sync_chemo(delta)
	_sync_chemo_track(delta)
	_sync_mark_aura(delta)
	if _hunt_fx != null:
		_hunt_fx.sync(delta)
	if _mucus_fx != null:
		_mucus_fx.sync(delta)
	if _beam_fx != null:
		_beam_fx.sync(delta)
	if _chain_fx != null:
		_chain_fx.sync(delta)
	if _skill_fx != null:
		_skill_fx.sync(delta)
	_sync_seal(delta)
	_sync_hand()
	if panel != null:
		if online and _client != null:
			panel.net_seats = _client.room.get("seats", [])
		panel.refresh(game)
	if _tile_info != null:
		## 迁移态的每格耗能由询问桥转手过来（它那边是从引擎算好的选项里抄的）。
		## 桥可能是纯 AI 桥（无界面跑测试时），所以要判一下有没有这两个字段
		var costs: Dictionary = bridge.move_costs if bridge is CWUIBridge else {}
		var verb: String = bridge.move_verb if bridge is CWUIBridge else ""
		_tile_info.sync(delta, game, board, camera, _opening or _fading, costs, verb)
	if _card_info != null:
		## 阵营取「抽屉正在显示谁的手牌」，不是 current_pid —— 观战/热座时它们会不一样，
		## 而详情框说的是**手上这张卡**，得跟着卡的主人走（只影响【代谢耦联】的措辞）
		var info_faction: int = game.player(_hand_pid)["faction"] if _hand_pid >= 0 			else CWData.Faction.IMMUNE
		## 分期给分档写法的高亮用（Kevin 2026-09-06）
		_card_info.sync(delta, info_faction, _opening or _fading, CWCardData.cancer_phase(game.round_no))
	if _log_panel != null:
		## 日志按「屏幕前这位真人」的视角过滤：别人（含 AI）抽到什么牌换成公开替身（Kevin 2026-09-05：单人局也收）。
		## 热座下视角 = 当前露牌的真人，换手期间（-1）所有秘密行都是替身；单人局 = 那一席；无真人的观战局不过滤、全看
		var hs := bridge is CWUIBridge and (bridge as CWUIBridge).hotseat
		_log_panel.filter = not human_players.is_empty()
		if hs:
			_log_panel.viewer = (bridge as CWUIBridge).current_human
		else:
			_log_panel.viewer = human_players[0] if not human_players.is_empty() else -1
		_log_panel.refresh(game)
	if _log_hint != null and _log_panel != null:
		_log_hint.visible = not _log_panel.visible   ## 面板开着就让位（同一个角）
		_log_hint.refresh(game, _log_panel)          ## 迷你日志：日志尾巴两行，视角跟面板同一份（方案 A，Kevin 2026-09-06）
	## 状态推进：带 watch 的步骤由真实局面翻页（不代做）；讲解型步骤不受影响
	if _guide != null and is_instance_valid(_guide) and _guide.active:
		_guide.check_progress()
	if _spotlight != null and is_instance_valid(_spotlight):
		var flag := ""
		if _guide != null and is_instance_valid(_guide) and _guide.active:
			## 渐进 UI：第一关只保留棋盘状态，不提前亮出行动控件；后续阶段
			## 由剧本数据逐步开放目标高亮。正式局没有 guide，不经过此闸。
			flag = _guide.highlight_flag() if _guide.ui_stage() >= 1 else ""
		_spotlight.sync(flag, self)


func _sync_tiles() -> void:
	var marks := {}
	var mucus: Array[Vector2i] = []
	var necro: Array[Vector2i] = []
	for c: Vector2i in game.tiles:
		var t: Dictionary = game.tiles[c]
		## 癌蔓延过场（侵蚀 / 增生 / 定殖共用）：引擎早就把这一格翻成癌了，但玩家还没看见「癌是从哪边漫过来的」。
		## 过场这 0.32 秒里改画过场图 —— 不加覆盖层，所以不会和高亮剪影抢 Z_MARK。
		## 演完 frame_of() 返回 null，下面那行自然把它换成癌组织，不需要收尾代码。
		var ero: Texture2D = _erosion_fx.frame_of(c)
		if ero != null:
			board.set_tile_tex(c, ero)
			continue
		## 开场绽开期间，还没轮到的那几格先按健康组织画
		var tissue: int = CWData.Tissue.HEALTHY if _bloom.has(c) else int(t["tissue"])
		## 骨髓空仓换另一张贴图（Kevin 2026-09-08）；其余组织忽略 stocked。
		## 最后那个是固化进度（2026-09-09）：算式在 CWData.solid_progress，界面不自己算。
		## 绽开期间按健康组织画，所以进度也得跟着按 tissue 走，不能直接读 t。
		var solid: float = 0.0 if tissue == CWData.Tissue.HEALTHY \
			else CWData.solid_progress(t, game.solidify_threshold())
		## 骨髓「进度到头、卡还没结算」（Kevin 2026-09-11）：图标和进度环一起变淡，判据在 CWData.store_pending
		var pending: bool = CWData.store_pending(t)
		board.set_tissue(c, tissue, t["special"], int(t["cards"]) > 0, solid, pending)
		## 积累进度外圈（2026-09-08）：算式在 CWData.store_progress，界面不自己算
		board.set_store(c, CWData.store_progress(t), int(t["special"]), pending)
		## 黏液侵染：**覆膜是一层贴图，不走色标**（见 CWBoard.set_mucus）——
		## 选稿那句「保留底层组织识别」用色标做不到，色标会把整格染成一个颜色
		if bool(t.get("mucus", false)):
			mucus.append(c)
		## 坏死：整格灰褐纹理（issue #15），此前根本没画
		if int(t.get("necrosis", 0)) > 0:
			necro.append(c)
		if int(t.get("ossify_at", 0)) > 0:
			marks[c] = ossify_mark(int(t["ossify_at"]), game.round_no)
	for c: Vector2i in _flash:
		marks[c] = Color(1, 1, 1, _flash[c] / FLASH_TIME * FLASH_ALPHA)
	## 热座换手中：该玩家细胞脚下一圈阵营色光环呼吸，告诉 TA 自己在哪（开局还没落子时没有）
	if _handoff != null and _handoff.active and _handoff.cell_pos != CWHandoff.INVALID:
		marks[_handoff.cell_pos] = Color(_handoff.faction_color, 0.18 + 0.32 * _handoff.pulse())
	## 交互高亮压过状态色标：正在选目标时，「这格能不能选」比「它是不是固化」重要。
	if bridge != null:
		marks.merge(bridge.marks, true)
	board.set_marks(marks)
	board.set_mucus(mucus)
	board.set_necrosis(necro)


## 【骨样硬化】标记格这一帧画成什么色。**纯函数**（时间从外面进来，无头测试直接核对）：
## at_round = 转固化的那个世界回合，now = 当前世界回合。到期回合越近脉冲越快。
static func ossify_mark(at_round: int, now: int, ms: int = -1) -> Color:
	var t: float = float(Time.get_ticks_msec() if ms < 0 else ms) / 1000.0
	var hz := OSSIFY_HZ * (2.0 if at_round - now <= 1 else 1.0)
	var k := 0.5 + 0.5 * sin(t * hz * TAU)
	return Color(MARK_OSSIFY, lerpf(OSSIFY_ALPHA.x, OSSIFY_ALPHA.y, k))


## 趋化源：场上有就把漩涡摆到那一格，没有就收起。
## 「只剩 1 回合」喂给演出层换色加速 —— 玩家不必去翻日志就知道它快没了。
func _sync_chemo(delta: float) -> void:
	if _chemo_fx == null:
		return
	if game.chemo.is_empty():
		_chemo_fx.visible = false
		return
	var at: Vector2i = game.chemo["at"]
	_chemo_fx.visible = true
	## 压在细胞下面（Z_MARK 那一层）：漩涡是地面上的东西，不该盖住站在上面的细胞
	_chemo_fx.sync(delta, board.tile_center(at), board.tile_z(at, board.Z_MARK),
		int(game.chemo["left"]) <= 1)


## 【免疫猎杀】的【追踪趋化源】。**在此之前它在棋盘上一点表示都没有**
## （HXR-I 2026-09-10 报「树突细胞的猎杀后没有持续锁定效果」，issue #13 第 5 条）——
## 而它是个实打实的两回合机制：被追的癌细胞怎么走都算「远离」、多付 20%，
## 免疫向它靠近还便宜 30%。看不见的话，猎杀演出闪完就像什么都没发生。
##
## 位置**每帧现读** `chemo_track_at()`：活着跟着那个癌细胞走，死了冻在死亡格上。
## 引擎那头早就是这么算的，这儿只是跟着它画，不另存一份坐标。
func _sync_chemo_track(delta: float) -> void:
	if _chemo_track_fx == null:
		return
	var at := game.chemo_track_at()
	if game.chemo_track.is_empty() or at == Vector2i.MAX:
		_chemo_track_fx.visible = false
		return
	_chemo_track_fx.visible = true
	_chemo_track_fx.sync(delta, board.tile_center(at), board.tile_z(at, board.Z_MARK),
		int(game.chemo_track.get("left", 0)) <= 1)


## 【I-标记】光环范围的常驻粒子（Kevin 2026-09-08）：
## 每只**活着的**树突罩住 `CWData.MARK_RANGE` 格，那一片里每格飘两个像素朝它去。
##
## 范围算式**现读 CWData.MARK_RANGE**，不写第二份 —— 规则那边（CWGame._refresh_marks）
## 用的是同一个常量，两处对不上就会出现「画着光环却不标记」这种最难查的错。
##
## 树突自己站的那一格不画：它在范围内是不言自明的，画上去反而只是被细胞贴图盖住的一团。
## 【中和抗体】的封禁环：**常驻**，压制期间一直在。谁还被压着一律问 `game.neutralized`，
## 不在这儿重算「谁挨着健康组织」——那是规则，表现层抄第二份迟早对不上。
func _sync_seal(delta: float) -> void:
	if _seal_fx == null:
		return
	var sealed: Array[Vector2] = []
	for c in game.living_cells(CWData.Faction.CANCER):
		if game.neutralized(c):
			sealed.append(board.tile_center(c["pos"]))
	_seal_fx.sync(delta, sealed)


func _sync_mark_aura(delta: float) -> void:
	if _mark_aura_fx == null:
		return
	var auras: Array = []
	for cell in game.living_cells(CWData.Faction.IMMUNE):
		if cell["itype"] != CWData.ImmuneType.DENDRITIC:
			continue
		var at: Vector2i = cell["pos"]
		var tiles: Array = []
		## 遍历**这一局真有的格**，不是正式布局的 127 格 —— 教程小棋盘上
		## 板外格的 tile_center() 返回 (0,0)，粒子会全飘到棋盘原点去
		for c in game.tiles:
			var d := CWData.hex_dist(c, at)
			if d > 0 and d <= CWData.MARK_RANGE:
				## **z 按格给**：棋盘是按排分层的，整只演出共用一个 z 的话，
				## 比它靠前的那些排会把粒子盖掉（Kevin 2026-09-08 报的「有时候不显示」）。
				## Z_MARK 这一层：压在细胞下面 —— 这是地面上的东西，不该盖住站在上面的细胞。
				tiles.append({ "pos": board.tile_center(c), "z": board.tile_z(c, board.Z_MARK) })
		auras.append({ "origin": board.tile_center(at), "tiles": tiles })
	_mark_aura_fx.sync(delta, auras)


func _sync_cells() -> void:
	while _cell_nodes.size() < game.cells.size():
		_cell_nodes.append(_make_cell_node(game.cells[_cell_nodes.size()]))
	## 同格可能站着多个细胞，得先数清楚每格几个才能左右错开
	var per_tile := {}
	for c in game.cells:
		if c["alive"]:
			per_tile[c["pos"]] = per_tile.get(c["pos"], 0) + 1
	var placed := {}
	var jumps: Array = []   ## 本帧检出的传送：{ i, from, to, ghost_pos, ghost_z }
	for i in game.cells.size():
		var c: Dictionary = game.cells[i]
		var node: Node2D = _cell_nodes[i]
		## 【连续吞噬】那一口由 CWChainFx 整只代画（选稿画的是张着口的胞体，
		## 不是在细胞上叠一层），所以这几帧真身要让位
		node.visible = c["alive"] and not (_chain_fx != null and _chain_fx.chewing_cid == i)
		var became_alive: bool = c["alive"] and not _was_alive[i]
		## 死而复活的也要淡入一次 —— 它和刚落子一样是「凭空出现」
		if became_alive:
			_pop_in(node)
		## 传送 = 上一帧与这一帧都活着、两格**不相邻**（六邻域按轴坐标算，别用像素距离）。
		## 判定顺序先复活再传送：复活走 _pop_in，不和传送混淆（规格 §三.1）。
		## 残影要站在它上一帧**实际画的位置**：趁下面覆写 position 之前抄走，同格错位也就自动对上
		elif c["alive"] and CWData.hex_dist(_last_pos[i], c["pos"]) > 1:
			jumps.append({ "i": i, "from": _last_pos[i], "to": c["pos"],
				"ghost_pos": node.position, "ghost_z": node.z_index })
		_was_alive[i] = c["alive"]
		if c["alive"]:
			_ever_alive[i] = true
		if not c["alive"]:
			for deco in _decos[i]:
				(deco as CWCellDeco).visible = false
			continue
		_last_pos[i] = c["pos"]
		var pos: Vector2i = c["pos"]
		var n: int = per_tile[pos]
		var k: int = placed.get(pos, 0)
		placed[pos] = k + 1
		var top: Vector2 = board.tile_center(pos)
		node.position = top + Vector2((k - (n - 1) / 2.0) * STACK_DX, CELL_FOOT_DY)
		node.z_index = board.tile_z(pos, board.Z_CELL)
		## 装饰跟着走：位置是格顶面中心（选稿的坐标系）+ 同格错位，z 夹着细胞节点一前一后
		for side in 2:
			var deco: CWCellDeco = _decos[i][side]
			deco.visible = true
			deco.game = game
			deco.position = top + Vector2((k - (n - 1) / 2.0) * STACK_DX, 0.0)
			deco.z_index = node.z_index + (1 if side == 1 else -1)
		if c["faction"] == CWData.Faction.IMMUNE:
			_apply_immune_art(node as Sprite2D, c["itype"])
			_sync_doom(node as Sprite2D, c)
		## 复活的图腾 2026-09-11 撤了（issue #15）：复活改由引擎报的 revive_immune / revive_cancer 演出
		## （CWSkillFx「归拢重生」/「碎石重生」），单机联机都走同一条通报
	if not jumps.is_empty():
		_play_teleports(jumps)


## 本帧检出的传送开演（规格 §三.2~3）。同一帧多个（紊乱全场齐传）按离重心的环数错峰；
## 两端都是血管格 = 血管互换：两端同一延迟、完全同时演，血管格先白闪一下交代「是血管干的」。
## 开关关着时检测照做、演出全跳（细胞照旧瞬移）—— AI 互搏观战局紊乱频繁，要这个降噪开关。
func _play_teleports(jumps: Array) -> void:
	if not CWSettings.teleport_anim:
		return
	var dests: Array = []
	for j in jumps:
		dests.append(j["to"])
	var delays: Dictionary = board.ring_delays(dests, CWTeleportFx.RING_STEP) if jumps.size() > 1 else {}
	for j in jumps:
		var i: int = j["i"]
		var from: Vector2i = j["from"]
		var to: Vector2i = j["to"]
		var delay: float = float(delays.get(to, 0.0))
		if game.tiles[from]["special"] == CWData.Special.VESSEL \
				and game.tiles[to]["special"] == CWData.Special.VESSEL:
			_flash[from] = FLASH_TIME
			_flash[to] = FLASH_TIME
			delay = CWTeleportFx.VESSEL_LEAD
		_teleport_fx.play(_cells_root, _cell_nodes[i] as Sprite2D, i, j["ghost_pos"], int(j["ghost_z"]),
			CWTeleportFx.edge_for(int(game.cells[i]["faction"])), delay,
			func() -> void: _flash[to] = FLASH_TIME)


## 手牌抽屉。抽到的卡从**发起抽卡的那个细胞**身上飞出来 ——
## 让「是谁抽的」这件事自己说清楚，而不是凭空出现在角落里。
##
## 显示谁的手牌：轮到哪个人类玩家就显示谁的；不是人类回合时保持上一次。
## （热座还没定案，定了之后这里就是现成的。）
func _sync_hand() -> void:
	if hand == null or human_players.is_empty():
		return
	if bridge is CWUIBridge and (bridge as CWUIBridge).hotseat:
		## 热座：抽屉跟「当前露牌的真人」（遮罩确认过的那一席），不跟「当前回合席位」——
		## A 结束回合到 B 点「开始回合」之间谁也不该看见 B 的牌。换手期间整个收起，
		## 确认后 B 的牌从 B 的细胞飞进抽屉（复用抽卡动画），行动栏随即出现。
		var who: int = (bridge as CWUIBridge).current_human
		if who < 0:
			if _hand_pid >= 0:
				hand.clear()
				hand.visible = false
				_hand_pid = -1
				_hand_seen.clear()
			return
		if who >= game.cells.size():
			return                   ## 开局布置阶段，这个人还没落子
		if _hand_pid != who:
			_hand_pid = who
			hand.visible = true
			var c0: Dictionary = game.cell_of(who)
			var cards0: PackedStringArray = PackedStringArray(c0["hand"])
			_hand_seen[who] = cards0.size()
			hand.deal_from(cards0.size(), CWView.board_to_screen(camera, board.tile_center(c0["pos"])), cards0)
			return
	elif game.current_pid in human_players:
		_hand_pid = game.current_pid
	elif _hand_pid < 0:
		_hand_pid = human_players[0]
	if _hand_pid >= game.cells.size():
		return                       ## 开局布置阶段，这个人还没落子
	var cell: Dictionary = game.cell_of(_hand_pid)
	var cards: PackedStringArray = PackedStringArray(cell["hand"])
	var n: int = cards.size()
	var was: int = _hand_seen.get(_hand_pid, -1)
	if was == n:
		return
	_hand_seen[_hand_pid] = n
	if was >= 0 and n > was:
		hand.deal_from(n, CWView.board_to_screen(camera, board.tile_center(cell["pos"])), cards)
	else:
		hand.sync(n, Vector2.INF, cards)   ## 首次显示 / 换人 / 打出去了：直接就位，不演


func _make_cell_node(cell: Dictionary) -> Node2D:
	var node := Sprite2D.new()
	## 癌细胞的种类一局之内不会变（会变形态的只有免疫方的分化），贴图建节点时定一次就够。
	## 免疫的 itype 会变，所以它的贴图交给 _sync_cells 每帧对一次。
	## 死亡占位（教程 fixture 的缺席方，ctype -1）：不配贴图，反正永不可见。
	if cell["faction"] == CWData.Faction.CANCER:
		if int(cell["ctype"]) >= 0:
			_set_cell_art(node, CANCER_ART[cell["ctype"]])
	else:
		_add_doom_overlay(node)
	_cells_root.add_child(node)
	## 常驻装饰（囊性护甲 / 刚性屏障 / 头顶标记，issue #15）：前后各一个节点，跟着这只细胞走
	var decos: Array = []
	for is_front in [false, true]:
		var deco := CWCellDeco.new()
		deco.front = bool(is_front)
		deco.game = game
		deco.index = _cell_nodes.size()
		deco.visible = false
		_cells_root.add_child(deco)
		decos.append(deco)
	_decos.append(decos)
	_was_alive.append(false)   ## 下一次 _sync_cells 就会认出「刚出现」并淡入
	_ever_alive.append(false)
	_last_pos.append(cell["pos"])
	return node


## 把 `game.feed_log` 投影到左侧出牌列（方案甲，2026-09-07）。
##
## **这一列只有这一条数据通路**。原先是三个回调各自 `add_card`，那样它是「广播的副产品」——
## 而广播是一次性的：客户端断线重连期间（哪怕只断两秒、玩家毫无察觉）那几条就永久错过了。
## 日志有游标会整份补发、棋盘有整份重推，唯独这一列什么都没有。线上日志显示当晚这种
## 「连断带连」出现了十几次，正好对上「有时候别人看不到我打的牌」。
##
## 改成投影之后：状态每推一次就补齐一次 —— 重连、中途观战、快照回滚全都自愈。
## 幂等靠 seq，只补没见过的；seq 倒退 = 新开一局或回滚 → 整列重来。
##
## 代价：联机时这一列跟着状态推送走（每次询问推一次），最坏比头顶飞卡晚一次询问。
## 用「晚一点但从不丢」换「快一点但偶尔永久缺一条」，这笔账值得。
func _sync_feed() -> void:
	if _feed == null or not is_instance_valid(_feed) or game == null:
		return
	## 对局一结束就收起（Kevin 2026-09-08 截图：结算屏都出来了，左边那一列还挂着）。
	## 它在 CWView.LEFT_STRIP 里、结算屏盖不到，所以得自己藏。
	## 判的是 `game.winner`（而不是「结算屏可见吗」）：这一列归对局层管，
	## 不该反过来去问另一个面板的显隐状态。
	_feed.visible = game.winner < 0
	if game.feed_seq < _feed_seq:
		_feed.clear_all()
		_feed_seq = 0
	for e in game.feed_log:
		var seq: int = int(e["seq"])
		if seq <= _feed_seq:
			continue
		_feed_seq = seq
		_feed_note(e)


## 一条流水 → 一张卡面。世界事件不属于任何一方，走另一个入口（中性色 + 底行「世界事件」）。
func _feed_note(e: Dictionary) -> void:
	var card: String = String(e["card"])
	if String(e["kind"]) == "world":
		_feed.add_world_event(card, int(e["left"]))
		return
	var pid: int = int(e["pid"])
	var faction: int = int(e["faction"])
	var who := ""
	if pid >= 0 and pid < game.players.size():
		who = String(game.player(pid)["name"])   ## 联机局里这就是昵称
	_feed.add_card(card, who, faction,
		CWCardInfo.describe(card, faction, CWCardData.cancer_phase(game.round_no)),
		String(e["kind"]) == "event")


func _on_card_played(cell_id: int, _pid: int, pos: Vector2i, _faction: int, card_name: String, _data: Dictionary) -> void:
	if card_name == "":
		return
	## 左侧出牌列**不在这里喂** —— 它由 `_sync_feed()` 从 `game.feed_log` 投影（方案甲，2026-09-07）。
	## 这里只管头顶飞卡（右栏那排本回合历史小卡 2026-09-11 按 Kevin 的意思删了）。
	_play_card_fx(cell_id, pos)


## 抽到即结算的事件卡。**不演头顶飞卡** —— 事件的效果自己会在那一格喊一句，两样叠在同一格上太吵；
## 右栏「回合数」那一栏的事件卡横排（09-07 方案乙）2026-09-11 按 Kevin 的意思删了，出牌列由 `_sync_feed()` 投影，
## 于是这里和 `_on_world_event` 一样只是**接住信号 / 报文**。
func _on_event_drawn(_cell_id: int, _pid: int, _pos: Vector2i, _faction: int, _card_name: String) -> void:
	pass


## 抽到一个世界事件：进棋盘左侧那一列（Kevin 2026-09-07）。**不演头顶飞卡** ——
## 它不属于任何一个细胞，没有起飞的地方。
func _on_world_event(_ev_name: String, _left: int) -> void:
	## 回调留着是为了**接住信号 / 报文**（不接的话联机那条 world_event 报文没人要），
	## 但列的内容由 `_sync_feed()` 投影 —— 一条数据通路，重连才补得齐。
	pass


## 抽到一张卡：头顶演出（倒放）。**三种来源都演**（基因表达 / 骨髓 / 突变）——
## 对玩家是同一件事「这个细胞抽到了一张」，来源在日志里分得清。要只演某一种就在这里按 source 过滤。
func _on_card_drawn(cell_id: int, _pid: int, pos: Vector2i, _source: String) -> void:
	_play_card_fx(cell_id, pos, true)


## drawing = false：打出一张卡（三拍上浮）；true：抽到一张卡（三拍倒放，落进细胞）。见上面常量那段。
func _play_card_fx(cell_id: int, pos: Vector2i, drawing := false) -> void:
	if _cells_root == null or board == null:
		return
	var base: Vector2 = board.tile_center(pos) + Vector2(0, -CARD_FX_HEAD)
	if cell_id >= 0 and cell_id < _cell_nodes.size():
		var node: Node2D = _cell_nodes[cell_id]
		if node != null and is_instance_valid(node):
			base = node.position + Vector2(0, -CARD_FX_HEAD)
	var total: float = CARD_FX_RISE[0] + CARD_FX_RISE[1] + CARD_FX_RISE[2]
	var fx := Sprite2D.new()
	fx.texture = CARD_FX_TEXTURE
	fx.centered = true
	fx.scale = CARD_FX_SQUASH if not drawing else Vector2.ONE * 0.82
	fx.z_index = board.tile_z(pos, board.Z_DICE) + 1
	## 打出：从头顶起、看得见；抽到：从三拍的终点（上方）起、全透明
	fx.position = base - Vector2(0, total if drawing else 0.0)
	fx.modulate = Color(1, 1, 1, 0.0 if drawing else 1.0)
	_cells_root.add_child(fx)
	_played_card_fx.append(fx)
	## 默认线性（第②拍就该是匀速的慢），头尾两拍各自换成缓出 / 缓入
	var tw := fx.create_tween().set_trans(Tween.TRANS_LINEAR)
	var y: float = fx.position.y
	if drawing:
		y += CARD_FX_RISE[2]
		tw.tween_property(fx, "position:y", y, CARD_FX_TIME[2]).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(fx, "modulate:a", 1.0, CARD_FX_TIME[2])
		y += CARD_FX_RISE[1]
		tw.tween_property(fx, "position:y", y, CARD_FX_TIME[1])
		y += CARD_FX_RISE[0]
		tw.tween_property(fx, "position:y", y, CARD_FX_TIME[0]).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		## 倒放差的那一口：落到头顶后被吸进去
		tw.tween_property(fx, "scale", Vector2.ONE * (CARD_FX_SCALE * 0.5), CARD_FX_ABSORB)
		tw.parallel().tween_property(fx, "modulate:a", 0.0, CARD_FX_ABSORB)
	else:
		## 先向下压 2px，卡面横向拉宽、纵向压扁；这一拍很短，但能让后面的上冲有「蓄力」
		## 而不是图标从头到尾匀速往上飘。
		y += CARD_FX_WINDUP_Y
		tw.tween_property(fx, "position:y", y, CARD_FX_WINDUP) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(fx, "scale",
			CARD_FX_SQUASH * Vector2(1.02, 0.96), CARD_FX_WINDUP)
		y -= CARD_FX_RISE[0]
		tw.tween_property(fx, "position:y", y, CARD_FX_TIME[0]) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(fx, "scale",
			Vector2.ONE * CARD_FX_SCALE, CARD_FX_TIME[0])
		y -= CARD_FX_RISE[1]
		tw.tween_property(fx, "position:y", y, CARD_FX_TIME[1]) \
			.set_trans(Tween.TRANS_LINEAR)
		tw.parallel().tween_property(fx, "scale",
			Vector2.ONE * (CARD_FX_SCALE * 1.04), CARD_FX_TIME[1] * 0.7)
		tw.tween_interval(CARD_FX_HOLD)
		y -= CARD_FX_RISE[2]
		tw.tween_property(fx, "position:y", y, CARD_FX_TIME[2]) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(fx, "modulate:a", 0.0, CARD_FX_TIME[2])
		tw.parallel().tween_property(fx, "scale",
			Vector2.ONE * (CARD_FX_SCALE * 0.86), CARD_FX_TIME[2])
	tw.tween_callback(func() -> void:
		_played_card_fx.erase(fx)
		if is_instance_valid(fx):
			fx.queue_free())


func _clear_played_card_fx() -> void:
	for fx in _played_card_fx:
		if fx != null and is_instance_valid(fx):
			fx.queue_free()
	_played_card_fx.clear()


func _clear_revive_fx() -> void:
	for fx in _revive_fx:
		if fx != null and is_instance_valid(fx):
			fx.queue_free()
	_revive_fx.clear()


## 淡入 + 放大到位。只动 modulate 和 scale ——
## position 每帧都被 _sync_cells 重写，拿它做补间会被当场覆盖掉。
func _pop_in(node: Node2D) -> void:
	node.modulate.a = 0.0
	node.scale = Vector2.ONE * CELL_POP_SCALE
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "modulate:a", 1.0, CELL_POP)
	tw.parallel().tween_property(node, "scale", Vector2.ONE, CELL_POP)


## 静息呼吸：所有活细胞的帧号循环推进。相位 = 全局步进 + 细胞编号——
## 刻意不用随机数（UI 不碰 game.rng，那是对局状态的一部分；别的随机源又破坏可复现）。
func _animate_breath(delta: float) -> void:
	_breath_acc += delta * BREATH_FPS
	if _breath_acc < 1.0:
		return
	var steps := int(_breath_acc)
	_breath_acc -= steps
	_breath_step = (_breath_step + steps) % BREATH_FRAMES
	for i in _cell_nodes.size():
		var s := _cell_nodes[i] as Sprite2D
		if s.visible and s.hframes == BREATH_FRAMES:
			s.frame = (_breath_step + i) % BREATH_FRAMES
			## 预警圈是同一张呼吸表叠上去的，不跟帧就会和身体错开一格穿帮
			var ring := s.get_node_or_null("DoomRing") as Sprite2D
			if ring != null:
				ring.frame = s.frame
	_teleport_fx.sync_breath(_breath_step, BREATH_FRAMES)   ## 残影也要跟着呼吸，否则帧率不一致穿帮


## 分化会改 itype，所以贴图每帧对一次。
func _apply_immune_art(s: Sprite2D, itype: int) -> void:
	var tex: Texture2D = IMMUNE_ART[itype]
	if s.texture != tex:
		_set_cell_art(s, tex)


## offset 把锚点从贴图中心挪到脚底中心 —— 细胞是「站」在格子上的，
## 而贴图有 24/32/16 三种高度，只有对齐脚底才不会因为大小不同而上下乱跳。
func _set_cell_art(s: Sprite2D, tex: Texture2D) -> void:
	s.texture = tex
	s.hframes = BREATH_FRAMES   ## 所有对局细胞贴图都是横排 6 帧呼吸表
	s.offset = Vector2(0, -tex.get_height() / 2.0)
	## 必死预警的描边覆盖跟着换贴图 —— 免疫分化会换贴图，不跟的话轮廓会对着上一形态描
	var ring := s.get_node_or_null("DoomRing") as Sprite2D
	if ring != null:
		ring.texture = tex
		ring.hframes = BREATH_FRAMES
		ring.offset = s.offset


## 免疫细胞的「回合末必死」预警圈。建法与固化进度那圈相同，只差颜色和 progress 固定为 1
## （整圈都画，不分半圈 —— 这不是进度，是一个开关）。
func _add_doom_overlay(s: Sprite2D) -> void:
	var ring := Sprite2D.new()
	ring.name = "DoomRing"
	ring.texture = s.texture
	ring.hframes = s.hframes
	ring.offset = s.offset
	ring.z_index = 1
	ring.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var material := ShaderMaterial.new()
	material.shader = SOLID_PROGRESS_SHADER
	material.set_shader_parameter("solid_color", DOOM_COLOR)
	material.set_shader_parameter("progress", 1.0)
	ring.material = material
	ring.visible = false
	s.add_child(ring)


## 「这只细胞撑不到下个回合」的预警：外圈红色脉冲。
##
## 判定现读 `CWWorld.pressure_lethal` —— 它走的是真结算那条伤害管线，
## 界面不自己算（自己算就会漏掉【缺氧适应】那面盾，对着死不了的细胞报警）。
func _sync_doom(s: Sprite2D, cell: Dictionary) -> void:
	var ring := s.get_node_or_null("DoomRing") as Sprite2D
	if ring == null:
		return
	var doomed: bool = game.world.pressure_lethal(cell)
	ring.visible = doomed
	if doomed:
		ring.modulate.a = doom_pulse()


## 预警的脉冲透明度。**纯函数**（时间从外面进来，无头测试直接核对），同 ossify_mark 的写法。
static func doom_pulse(ms: int = -1) -> float:
	var t: float = float(Time.get_ticks_msec() if ms < 0 else ms) / 1000.0
	var k := 0.5 + 0.5 * sin(t * DOOM_HZ * TAU)
	return lerpf(DOOM_ALPHA.x, DOOM_ALPHA.y, k)
