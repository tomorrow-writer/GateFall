## Castle walls in the field (feature/battle-walls): how much each wall level
## helps the defender, both sides AI, the way the world map fights them
## (AutoBattle.overrides + the mods WorldSim.battle_mods sends).
##
##   godot --headless --path . --script tools/run_siege.gd -- --runs=60
##   --runs=N     battles per row (default 60) · --seed=N first seed (default 1)
##   --levels=0,1,2,3  wall levels to try · --breach=0,1  engine breaches to try
##   --troops=30  troops per side · --att-troops=N  attacker troops (default = troops) · --order=hold  the walled AI's starting order
##                (hold | charge | none = the config's)
##   --units=S:slime_big,K:knight  troop type per side
##
## Each row: defender side and wall level (+ breached segments), both ways round
## (S defends against K, K defends against S). def% = defender wins, att% =
## attacker wins, draw% = time ran out (the map: the attacker turns back),
## time, defender / attacker troops left, broke = wall segments broken per
## battle, tower = tower shots that landed per battle.
extends SceneTree

const BattleSim = preload("res://scripts/battle/BattleSim.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")
const AutoBattle = preload("res://scripts/world/AutoBattle.gd")


func _init() -> void:
	var opts := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		opts[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var runs := int(opts.get("runs", "60"))
	var seed0 := int(opts.get("seed", "1"))
	var troops := int(opts.get("troops", "30"))
	var order := str(opts.get("order", "hold"))
	var att_troops := int(opts.get("att-troops", str(troops)))
	var levels: Array = []
	for t in str(opts.get("levels", "0,1,2,3")).split(","):
		levels.append(int(t))
	var breaches: Array = []
	for t in str(opts.get("breach", "0")).split(","):
		breaches.append(int(t))
	var unit_of := {}
	if opts.has("units"):
		for part in str(opts.units).split(","):
			var kv := part.split(":")
			unit_of[kv[0]] = kv[1]
	var cfg := BattleSim.load_config("res://data/battle_config.json")
	var dt := 1.0 / float(cfg.sim.steps_per_second)
	var ids: Array = []
	for sd in cfg.sides:
		ids.append(str(sd.id))
	print("Gatefall siege sims: %d runs/row, troops def %d / att %d, walled AI order %s" % [runs, troops, att_troops, order])
	print("def att  wall brch    def%    att%   draw%    time  defLeft  attLeft  broke  tower")
	for di in ids.size():
		var def_id: String = ids[di]
		var att_id: String = ids[1 - di]
		for lv in levels:
			for br in breaches:
				if br > 0 and lv < 1:
					continue
				var tally := {"def": 0, "att": 0, "draw": 0}
				var t_sum := 0.0
				var dl := 0.0
				var al := 0.0
				var broke := 0
				var tower := 0
				for r in runs:
					var mods := {def_id: {"wall": lv, "breach": br}}
					if lv >= 1 and order != "none":
						mods[def_id]["ai_order"] = order
					for id in unit_of:
						var m: Dictionary = mods.get(id, {})
						m["unit"] = unit_of[id]
						mods[id] = m
					var ov := AutoBattle.overrides(cfg, {def_id: troops, att_id: att_troops}, "", mods)
					var sim := BattleSim.new(cfg, ov, BattleRng.new(seed0 + r))
					var n := 0
					while sim.over == "" and n < 20000:
						for e in sim.step(dt):
							if e.type == "wallbreak":
								broke += 1
							elif e.type == "hit" and int(e.get("by", 0)) < 0:
								tower += 1
						n += 1
					var w := sim.over if sim.over != "" else "draw"
					if w == def_id:
						tally.def += 1
					elif w == att_id:
						tally.att += 1
					else:
						tally.draw += 1
					t_sum += sim.time
					dl += sim.troop_count(def_id)
					al += sim.troop_count(att_id)
					sim.dispose()
				var k := 100.0 / runs
				print("%-3s %-3s  %4d %4d  %5.1f%%  %5.1f%%  %5.1f%%  %5.1fs  %7.1f  %7.1f  %5.2f  %5.1f" % [
						def_id, att_id, lv, br, tally.def * k, tally.att * k, tally.draw * k, t_sum / runs,
						dl / runs, al / runs, float(broke) / runs, float(tower) / runs])
	quit()
