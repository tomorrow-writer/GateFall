## Autoload "Campaign": keeps the war going between scenes. The world map lives
## here (WorldSim) while Battle.tscn fights one of its battles, then the result
## goes back into the map.
extends Node

const WorldSim = preload("res://scripts/world/WorldSim.gd")

const MAP_DATA := "res://data/world_map.json"
const MAP_SCENE := "res://scenes/WorldMap.tscn"
const BATTLE_SCENE := "res://scenes/Battle.tscn"

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
	get_tree().change_scene_to_file(BATTLE_SCENE)


## Called by Battle.gd when a map battle is over.
func finish_battle(winner: String, left: Dictionary) -> void:
	if world != null and not battle.is_empty():
		world.resolve_battle(int(battle.id), winner, left)
	battle = {}
	get_tree().change_scene_to_file(MAP_SCENE)


## A test battle straight from the title screen (no map).
func test_battle() -> void:
	battle = {}
	get_tree().change_scene_to_file(BATTLE_SCENE)


func quit_war() -> void:
	world = null
	battle = {}
	player_side = ""
