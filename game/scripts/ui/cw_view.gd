## cw_view.gd —— 机位：把棋盘上的「看点」摆到屏幕的「锚点」，再按 zoom 放大
##
## 全工程只有一台相机。主菜单和对局共用它，「开始对局」的过场就是在
## 下面两组参数之间插值 —— 所以这两组参数必须放在一起，而不是各自散在两个界面里。
##
## 看点(look_at)：相对**中央格贴图中心**的偏移，单位是棋盘像素。
## 锚点(anchor)：这个看点要落在 960×540 画布上的哪个位置。
## 两者加 zoom 就唯一确定了相机位置，反解见 camera_pos_for()。
class_name CWView
extends RefCounted

## ── 菜单机位（定稿原型的 CAM_MENU）──
const MENU_ZOOM := 3.2
const MENU_LOOK_AT := Vector2(-40, -10)
const MENU_ANCHOR := Vector2(595, 227)

## ── 对局机位（定稿「方案戊」：棋盘偏左，右侧让出 264px 竖条）──
##
## 棋盘包围盒 464×274 棋盘像素，×1.45 = 673×397 屏幕像素，
## 正好等于设计稿里那张 board.png 的尺寸。
## 画布 960 减去右侧竖条 264 = 696，锚点取它的中点 348，棋盘就落在 x 12..685，
## 与设计稿逐像素一致；纵向 540 对 397，居中即锚点 270。
##
## 为什么是右侧竖条而不是底部横条：横向自由空间的增长速度是纵向的两倍，
## 同样让出 264px，放在右边只要缩到 1.45，放在底部要缩到 1.01（团队 2026-08-27 定）。
const GAME_ZOOM := 1.45
const GAME_LOOK_AT := Vector2.ZERO       ## 看棋盘正中 —— 中央格的贴图中心正是包围盒中心
const GAME_ANCHOR := Vector2(348, 270)
const PANEL_WIDTH := 264                 ## 右侧竖条宽度，HUD 与本机位必须用同一个数


## 由「看哪儿 / 摆到屏幕哪儿 / 放多大」反推相机该站在哪儿。
## 是 static 的，好让无头测试直接核对这套换算，不用真开窗口。
## 第一个参数别叫 look_at —— Node2D 自带同名方法，会报遮蔽警告。
static func camera_pos_for(focus: Vector2, anchor: Vector2, zoom: float, screen: Vector2) -> Vector2:
	return focus - (anchor - screen / 2.0) / zoom


## 工程设置里的设计分辨率（架构约定 #12：960×540，不要改）
static func screen_size() -> Vector2:
	return Vector2(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))


## 棋盘包围盒的中心，也就是中央格的**贴图中心**。
## tile_center() 给的是顶面中心，要加回那 4px —— 看点偏移都是相对贴图中心量的。
static func board_origin(board: Node2D) -> Vector2:
	return board.tile_center(Vector2i.ZERO) + Vector2(0, board.TOP_FACE_DY)


## 把相机摆到指定机位。
static func apply(camera: Camera2D, board: Node2D, zoom: float,
		look_at: Vector2, anchor: Vector2) -> void:
	camera.zoom = Vector2(zoom, zoom)
	camera.position = camera_pos_for(
		board_origin(board) + look_at, anchor, zoom, screen_size())
