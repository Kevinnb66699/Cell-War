## cw_sfx.gd —— 界面音效。目前只有一声：**游戏外按钮的点击**
## （主菜单 / Esc 菜单 / 设置 / 开局配置 / 联机各页 / 知识之书 / 回放列表 / 结算屏）。
## 棋盘上的操作（迁移、打牌、攻击）**不响** —— 那是对局本身的节奏，另说。
##
## **为什么是「静态函数 + 懒建节点」**：
## ① 按钮散在十来个面板里，谁都不该为了响一声去持有一个播放器、也不该层层往下传；
## ② **不走 autoload** —— 那要改 `project.godot`，而它一动就只能全量发版（见架构说明书热更那节），
##    音效这种还要反复调的东西，值得留在能热更的那一侧；
## ③ **不给 `class_name`** —— 补丁里新增的 class_name 认不出来（全局类表导出时烘死），
##    调用方一律 `const SFX := preload("res://scripts/ui/cw_sfx.gd")`。
##
## 播放器挂在**场景树 root 底下**：主菜单 ↔ 对局是同一棵树里换页（见 main.gd 文件头），
## 挂在面板上的话，面板一 free 声音就断在半截。
##
## ⚠ 贴图、音频这类**要过导入的资源进不了热更**（包里用的是 `.godot/imported/` 下的导入产物）——
## 所以这个文件可以热更，`click_stereo.ogg` 本身要等全量发版才到玩家手里。
extends RefCounted

const CLICK := preload("res://assets/audio/click_stereo.ogg")
## 同时最多响几声。连点不该把前一声掐掉（那听起来像卡了），也不该无限堆节点
const POOL := 4
## 音量（分贝）。素材本身偏响，压一点才不至于盖过说话
const VOLUME_DB := -6.0

static var _players: Array[AudioStreamPlayer] = []


## 点一下按钮的那一声。**随手调，不必判空**：没有场景树（纯逻辑测试）就什么都不做
static func click() -> void:
	play(CLICK)


static func play(stream: AudioStream) -> void:
	var p := _idle_player()
	if p == null or stream == null:
		return
	p.stream = stream
	p.play()


## 取一个空闲播放器；池子没建就现建。返回 null = 这个进程里没有场景树可挂
static func _idle_player() -> AudioStreamPlayer:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	## 上一局的节点会随场景一起被清掉，所以每次都要核一遍有效性（别缓存一堆野指针）
	var alive: Array[AudioStreamPlayer] = []
	for p in _players:
		if is_instance_valid(p) and p.is_inside_tree():
			alive.append(p)
	_players = alive
	for p in _players:
		if not p.playing:
			return p
	if _players.size() >= POOL:
		return _players[0]     ## 池子满了：抢最早那个（连点四下以上，掐掉最旧的一声）
	var made := AudioStreamPlayer.new()
	made.name = "CWSfx%d" % _players.size()
	made.volume_db = VOLUME_DB
	## **换场景不跟着死**：主菜单 ↔ 对局在同一棵树里换页，但保险起见挂到 root 上
	tree.root.add_child(made)
	_players.append(made)
	return made
