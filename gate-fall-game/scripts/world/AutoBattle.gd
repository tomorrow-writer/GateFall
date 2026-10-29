## Settles a map battle without the battle scene: the same BattleSim with the
## AI commanding both sides (cast, dodge, send the general in, duel choice).
## Used by the map's "auto" button and by tools/run_world.gd.
extends RefCounted

const BattleSim = preload("res://scripts/battle/BattleSim.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")

const MAX_STEPS := 20000


## troops: side id -> troop count for this battle ({"S": 30, "K": 12}).
## mods: extra BattleSim overrides per side id (castle walls: WorldSim.battle_mods).
## Returns {winner: side id | "draw", left: {side id: troops left},
## fell: {side id: true if its general fell (not pulled out)}, time}.
static func resolve(cfg: Dictionary, troops: Dictionary, seed_value: int, mods: Dictionary = {}) -> Dictionary:
	var sim := BattleSim.new(cfg, overrides(cfg, troops, "", mods), BattleRng.new(seed_value))
	sim.record_events = false
	var dt := 1.0 / float(cfg.sim.steps_per_second)
	var n := 0
	while sim.over == "" and n < MAX_STEPS:
		sim.step(dt)
		n += 1
	var left := {}
	for sd in cfg.sides:
		left[sd.id] = sim.troop_count(sd.id)
	var out := {"winner": sim.over if sim.over != "" else "draw", "left": left, "fell": fell_of(cfg, sim),
			"time": sim.time}
	sim.dispose()
	return out


## Which sides lost their general in battle (field or duel), as opposed to
## pulling out before the duel. The map may take those generals prisoner.
static func fell_of(cfg: Dictionary, sim) -> Dictionary:
	var out := {}
	if sim.over == "" or sim.over == "draw":
		return out
	for sd in cfg.sides:
		if sd.id != sim.over:
			out[sd.id] = sim.defeat_reason(sd.id) in ["duel", "general"]
	return out


## BattleSim overrides for a map battle: each side's troop count; every side
## except `player_side` is commanded by the AI. mods: more overrides per side.
static func overrides(cfg: Dictionary, troops: Dictionary, player_side: String, mods: Dictionary = {}) -> Dictionary:
	var ov := {}
	for sd in cfg.sides:
		var o: Dictionary = mods.get(sd.id, {}).duplicate()
		if sd.id != player_side:
			o["ai"] = true
		if troops.has(sd.id):
			o["units"] = [[sd.unit, int(troops[sd.id])]]
		ov[sd.id] = o
	return ov
