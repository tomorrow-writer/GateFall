## Settles a map battle without the battle scene: the same BattleSim with the
## AI commanding both sides (cast, dodge, send the general in, duel choice).
## Used by the map's "auto" button and by tools/run_world.gd.
extends RefCounted

const BattleSim = preload("res://scripts/battle/BattleSim.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")

const MAX_STEPS := 20000


## troops: side id -> troop count for this battle ({"S": 30, "K": 12}).
## Returns {winner: side id | "draw", left: {side id: troops left}, time}.
static func resolve(cfg: Dictionary, troops: Dictionary, seed_value: int) -> Dictionary:
	var sim := BattleSim.new(cfg, overrides(cfg, troops, ""), BattleRng.new(seed_value))
	sim.record_events = false
	var dt := 1.0 / float(cfg.sim.steps_per_second)
	var n := 0
	while sim.over == "" and n < MAX_STEPS:
		sim.step(dt)
		n += 1
	var left := {}
	for sd in cfg.sides:
		left[sd.id] = sim.troop_count(sd.id)
	var out := {"winner": sim.over if sim.over != "" else "draw", "left": left, "time": sim.time}
	sim.dispose()
	return out


## BattleSim overrides for a map battle: each side's troop count; every side
## except `player_side` is commanded by the AI.
static func overrides(cfg: Dictionary, troops: Dictionary, player_side: String) -> Dictionary:
	var ov := {}
	for sd in cfg.sides:
		var o := {}
		if sd.id != player_side:
			o["ai"] = true
		if troops.has(sd.id):
			o["units"] = [[sd.unit, int(troops[sd.id])]]
		ov[sd.id] = o
	return ov
