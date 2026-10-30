## Editor helper: starts tools/troop_matrix.sh in the background with this
## editor's own Godot binary, so the troop-type sims run without a terminal.
## Script editor: open this file, then File > Run (Ctrl/Cmd+Shift+X).
## Results: tools/troop_matrix_out.txt (log: tools/troop_matrix_log.txt).
@tool
extends EditorScript


func _run() -> void:
	var root := ProjectSettings.globalize_path("res://")
	var godot := OS.get_executable_path()
	var cmd := "cd '%s' && GODOT='%s' bash tools/troop_matrix.sh 150 > tools/troop_matrix_log.txt 2>&1" % [root, godot]
	var pid := OS.create_process("/bin/bash", ["-c", cmd])
	print("troop matrix started (pid %d) -> tools/troop_matrix_out.txt" % pid)
