## Autoload "Campaign": keeps the war going between scenes. The world map lives
## here (WorldSim) while Battle.tscn fights one of its battles, then the result
## goes back into the map.
##
## Save slots (pause menu, like DF): SLOTS files user://save_<n>.json, each
## {meta: {side, day, time}, campaign: {...}, world: WorldSim.to_save()}.
## Saved on the map only (never mid-battle), so a load always lands on the map.
extends Node

const WorldSim = preload("res://scripts/world/WorldSim.gd")

const MAP_DATA := "res://data/world_map.json"
const MAP_SCENE := "res://scenes/WorldMap.tscn"
const BATTLE_SCENE := "res://scenes/Battle.tscn"
const SLOTS := 3

var world: WorldSim = null
var player_side := ""
## The map battle being fought in Battle.tscn: {id, player_side, troops: {side: n},
## castle name, names}. Empty = Battle.tscn runs on its own (test battle).
var battle := {}
## Map view state kept across a battle: selected general id, speed index.
var map_selected := ""
var map_speed := 0


func new_game(side: String) -> void:
	player_side = side
	world = WorldSim.new(WorldSim.load_map(MAP_DATA), [WorldSim.other_side(side)])
	battle = {}


func in_battle() -> bool:
	return not battle.is_empty()


## Fight a queued map battle in the battle scene.
func fight(b: Dictionary) -> void:
	battle = b
	Engine.time_scale = Settings.battle_speed()
	get_tree().change_scene_to_file(BATTLE_SCENE)


## Called by Battle.gd when a map battle is over.
## fell: side id -> true if that side's general fell (it may be taken prisoner).
func finish_battle(winner: String, left: Dictionary, fell: Dictionary = {}) -> void:
	if world != null and not battle.is_empty():
		world.resolve_battle(int(battle.id), winner, left, fell)
	battle = {}
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file(MAP_SCENE)


## A test battle straight from the title screen (no map).
func test_battle() -> void:
	battle = {}
	Engine.time_scale = Settings.battle_speed()
	get_tree().change_scene_to_file(BATTLE_SCENE)


func quit_war() -> void:
	world = null
	battle = {}
	player_side = ""


# --- save slots -----------------------------------------------------------------

func slot_path(n: int) -> String:
	return "user://save_%d.json" % n


## Write the war to slot n. Only between battles (the map scene calls it).
func save_game(n: int) -> bool:
	if world == null or in_battle():
		return false
	var d := {"meta": {"side": player_side, "day": int(world.day) + 1,
			"time": Time.get_datetime_string_from_system(false, true)},
			"campaign": {"player_side": player_side, "map_selected": map_selected},
			"world": world.to_save()}
	var f := FileAccess.open(slot_path(n), FileAccess.WRITE)
	if f == null:
		push_error("Campaign: cannot write %s" % slot_path(n))
		return false
	f.store_string(JSON.stringify(d, "\t"))
	return true


## Slot summary for the menu: {} = empty (or unreadable), else the meta.
func slot_info(n: int) -> Dictionary:
	var d := _read_slot(n)
	return d.get("meta", {}) if d.has("world") else {}


## Load slot n into Campaign.world. The caller (map scene) rebinds to it.
func load_game(n: int) -> bool:
	var d := _read_slot(n)
	if not d.has("world"):
		return false
	var side := str(d.campaign.player_side)
	var w := WorldSim.new(WorldSim.load_map(MAP_DATA), [WorldSim.other_side(side)])
	if not w.apply_save(d.world):
		return false
	world = w
	player_side = side
	map_selected = str(d.campaign.get("map_selected", ""))
	battle = {}
	return true


func _read_slot(n: int) -> Dictionary:
	if not FileAccess.file_exists(slot_path(n)):
		return {}
	var f := FileAccess.open(slot_path(n), FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}
