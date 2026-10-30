## Autoload "Settings": player options from the pause menu (like DF's option
## screen), kept in user://settings.cfg so they stay between plays.
##   map_speed     index into world_map.json time.speeds (×1 / ×2 / ×4): the
##                 speed the map starts at after a new game or a load
##   battle_speed  how fast the battle scene runs (Engine.time_scale while a
##                 battle is on; BattleSim still steps at its fixed dt, so the
##                 result is the same as at ×1)
##   volume        master volume 0..10 (no sound in the game yet: ready for it)
##   fullscreen    window or full screen
extends Node

const PATH := "user://settings.cfg"
const BATTLE_SPEEDS := [1.0, 1.5, 2.0]
const VOLUME_MAX := 10

var map_speed := 0
var battle_speed_i := 0
var volume := 8
var fullscreen := false


func _ready() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		map_speed = int(cf.get_value("game", "map_speed", map_speed))
		battle_speed_i = clampi(int(cf.get_value("game", "battle_speed", battle_speed_i)), 0, BATTLE_SPEEDS.size() - 1)
		volume = clampi(int(cf.get_value("sound", "volume", volume)), 0, VOLUME_MAX)
		fullscreen = bool(cf.get_value("display", "fullscreen", fullscreen))
	apply()


func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("game", "map_speed", map_speed)
	cf.set_value("game", "battle_speed", battle_speed_i)
	cf.set_value("sound", "volume", volume)
	cf.set_value("display", "fullscreen", fullscreen)
	cf.save(PATH)


## Push volume and window mode to the engine (battle speed is set by Battle.gd).
func apply() -> void:
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_mute(bus, volume <= 0)
	AudioServer.set_bus_volume_db(bus, linear_to_db(float(volume) / VOLUME_MAX) if volume > 0 else -80.0)
	var mode := DisplayServer.window_get_mode()
	var full := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if fullscreen != full:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)


func battle_speed() -> float:
	return float(BATTLE_SPEEDS[battle_speed_i])


func set_map_speed(i: int) -> void:
	map_speed = i
	save()


func cycle_battle_speed() -> void:
	battle_speed_i = (battle_speed_i + 1) % BATTLE_SPEEDS.size()
	save()


func add_volume(d: int) -> void:
	volume = clampi(volume + d, 0, VOLUME_MAX)
	apply()
	save()


func toggle_fullscreen() -> void:
	fullscreen = not fullscreen
	apply()
	save()
