extends SceneTree
func _initialize() -> void:
	for p in ["res://assets/shaders/solid_progress.gdshader",
			"res://assets/shaders/silhouette.gdshader",
			"res://assets/shaders/teleport.gdshader"]:
		var sh: Shader = load(p)
		var m := ShaderMaterial.new()
		m.shader = sh
		print("加载 ", p.get_file(), " -> ", "ok" if sh != null else "FAIL")
	quit()
