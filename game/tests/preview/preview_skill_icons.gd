extends SceneTree
## Real CWActionBar rendering, with candidate textures injected ONLY into preview nodes.
## Run: godot --path game --script res://tests/preview/preview_skill_icons.gd -- <absolute output directory>
## Requires tools/build_skill_icon_previews.cjs first. Never replaces the runtime atlas.
var output_dir: String
var candidates: Array = []
var candidate_index := 0
var state_index := 0
var settle := 0
var started := false
var bar: CWActionBar
var board: Node2D
var game: CWGame
var reports: Array = []
const STATES := ["normal", "hover", "disabled"]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Provide an output directory")
		quit(1)
		return
	output_dir = args[0]
	candidates = JSON.parse_string(FileAccess.get_file_as_string(output_dir.path_join("candidates.json")))
	if candidates.size() != 39:
		quit(1)
		return
	board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(board)
	bar = CWActionBar.new()
	root.add_child(bar)

func add_caption(text: String, at: Vector2) -> void:
	var label := CWStyle.label(text, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	label.position = at
	root.add_child(label)

func setup_context() -> void:
	board.scale = Vector2.ONE * CWView.GAME_ZOOM
	board.position = CWView.GAME_ANCHOR - CWView.board_origin(board) * CWView.GAME_ZOOM
	game = CWGame.new()
	game.init(CWData.FACTION_ORDER[4], 7)
	game.setup.build_board()
	var locations := [Vector2i(-2, 0), Vector2i(2, 0), Vector2i(-1, 2), Vector2i(1, -2)]
	var art := ["bcell", "melanoma", "tcell", "osteo"]
	for i in 4:
		var faction: int = CWData.Faction.IMMUNE if i % 2 == 0 else CWData.Faction.CANCER
		var cell_data := CWSetup.make_cell(i, i, faction, locations[i], CWData.ImmuneType.B_CELL if i % 2 == 0 else -1, CWData.CancerType.MELANOMA if i % 2 == 1 else -1, 50)
		game.cells.append(cell_data)
		var sprite := Sprite2D.new()
		sprite.texture = load("res://assets/art/cells/anim/%s_breath.png" % art[i])
		sprite.hframes = 6
		sprite.offset = Vector2(0, -sprite.texture.get_height() / 2.0)
		sprite.position = board.tile_center(locations[i]) + Vector2(0, CWMatch.CELL_FOOT_DY)
		sprite.z_index = board.tile_z(locations[i], board.Z_CELL)
		board.add_child(sprite)
		if i % 2 == 1:
			board.set_tissue(locations[i], CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
	var panel := CWMatchPanel.new()
	root.add_child(panel)
	panel.refresh(game)
	var hand := CWHand.new()
	root.add_child(hand)
	hand.sync(3, Vector2.INF, PackedStringArray(["细胞膜修复", "免疫增援", "交叉呈递"]))
	var feed := CWFeed.new()
	root.add_child(feed)
	add_caption("技能图标选稿 / Godot 真实行动栏", Vector2(100, 24))
	add_caption("固定演示局面；费用仅作排版示例，不参与结算", Vector2(100, 44))
	add_caption("当前候选位于行动栏第 2 项", Vector2(324, 448))

func inject_icon(node: Node, texture: Texture2D) -> int:
	var count := 0
	for child in node.get_children():
		if child is TextureRect:
			child.texture = texture
			count += 1
		else:
			count += inject_icon(child, texture)
	return count

func show_candidate() -> void:
	var row: Dictionary = candidates[candidate_index]
	var icon := Image.new()
	if icon.load_svg_from_string(row["svg"]) != OK:
		push_error("Invalid SVG")
		quit(1)
		return
	bar.show_bar("", "", [
		{"title": "移动", "act": "move", "cost": "0.5"},
		{"title": row["name"], "act": row["key"], "cost": "1.0", "disabled": state_index == 2},
		{"title": "抽卡", "act": "draw", "cost": "1.0"}
	])
	if inject_icon(bar._buttons[1], ImageTexture.create_from_image(icon)) != 1:
		push_error("Expected one real 16x16 icon slot")
		quit(1)
		return
	bar._set_hot(1 if state_index == 1 else -1)
	settle = 0

func _process(_delta: float) -> bool:
	settle += 1
	if not started:
		if settle < 16:
			return false
		setup_context()
		started = true
		show_candidate()
		return false
	if settle < 6:
		return false
	# Wait for fonts, container layout and the GPU frame before reading the viewport.
	var frame := root.get_texture().get_image()
	var row: Dictionary = candidates[candidate_index]
	var stem := "%s-%s" % [row["key"], row["variant"]]
	var rect := Rect2i(bar._buttons[1].get_global_rect())
	var crop := frame.get_region(rect)
	var name := "%s-%s.png" % [stem, STATES[state_index]]
	if crop.save_png(output_dir.path_join(name)) != OK:
		quit(1)
		return true
	if state_index == 0:
		if frame.save_png(output_dir.path_join(stem + "-scene.png")) != OK:
			quit(1)
			return true
	reports.append({"key": row["key"], "variant": row["variant"], "state": STATES[state_index], "file": name, "width": crop.get_width(), "height": crop.get_height(), "icon_size": 16, "renderer": "CWActionBar"})
	state_index += 1
	if state_index == 3:
		state_index = 0
		candidate_index += 1
	if candidate_index == candidates.size():
		var file := FileAccess.open(output_dir.path_join("manifest.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(reports, "  "))
		print("PASS: 39 candidate scenes + 117 normal/hover/disabled button crops; runtime atlas untouched")
		game.dispose()
		quit(0)
		return true
	show_candidate()
	return false
