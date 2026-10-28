## Plays whole wars on the world map with the AI on both sides and every
## battle auto-resolved (AutoBattle.gd). Checks the map rules work end to end
## and shows how long a war takes. Balance comes later.
##
##   godot --headless --path . --script tools/run_world.gd -- --runs=20 --log=1
##   --runs=N   wars to play (default 10) · --log=1 print the first war's events
##   --max-days=N  stop a war after N days (default 400)
extends SceneTree

const WorldSim = preload("res://scripts/world/WorldSim.gd")
const AutoBattle = preload("res://scripts/world/AutoBattle.gd")
const BattleSim = preload("res://scripts/battle/BattleSim.gd")

const STEP := 0.05  # days per step (the map scene uses frame time)


func _init() -> void:
	var opts := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		opts[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var runs := int(opts.get("runs", "10"))
	var log_first: bool = opts.get("log", "0") == "1"
	var max_days := float(opts.get("max-days", "400"))
	var cfg := BattleSim.load_config("res://data/battle_config.json")
	var data := WorldSim.load_map("res://data/world_map.json")
	var wins := {"S": 0, "K": 0, "": 0}
	var days := 0.0
	var fights := 0
	var t0 := Time.get_ticks_msec()
	for r in runs:
		var w := WorldSim.new(data, ["S", "K"])
		var seed_value := 1000 + r * 31
		while w.winner == "" and w.day < max_days:
			for e in w.step(STEP):
				if log_first and r == 0:
					print(_line(w, e))
			for b in w.battles.duplicate():
				var a := w.get_general(b.a)
				var d := w.get_general(b.d)
				var res := AutoBattle.resolve(cfg, {a.side: a.troops, d.side: d.troops}, seed_value)
				seed_value += 1
				fights += 1
				if log_first and r == 0:
					print("  day %.1f battle %s(%d) vs %s(%d) at %s -> %s left %s" % [w.day, a.name, a.troops,
							d.name, d.troops, w.castles[b.castle].name if b.castle != "" else "road",
							res.winner, res.left])
				w.resolve_battle(int(b.id), res.winner, res.left)
				for e in w._take_events():
					if log_first and r == 0:
						print(_line(w, e))
		wins[w.winner] += 1
		days += w.day
		print("war %d: winner %s day %.0f castles S%d K%d" % [r, w.winner if w.winner != "" else "-", w.day,
				w.castles_of("S").size(), w.castles_of("K").size()])
	print("S %d · K %d · none %d · avg %.0f days · %.1f battles/war · %.1fs" % [wins.S, wins.K, wins[""],
			days / runs, float(fights) / runs, (Time.get_ticks_msec() - t0) / 1000.0])
	quit()


func _line(w: WorldSim, e: Dictionary) -> String:
	var g := w.get_general(str(e.get("general", "")))
	var who: String = g.name if g != null else ""
	var at: String = w.castles[e.castle].name if e.has("castle") and e.castle != "" else ""
	match e.type:
		"depart":
			return "day %.1f %s -> %s" % [w.day, who, w.castles[e.to].name]
		"capture":
			return "day %.1f %s takes %s" % [w.day, who, at]
		"retreat":
			return "day %.1f %s retreats to %s" % [w.day, who, w.castles[e.to].name]
		"captured":
			return "day %.1f %s captured" % [w.day, who]
		"over":
			return "day %.1f WAR OVER: %s" % [w.day, e.winner]
	return "day %.1f %s %s %s" % [w.day, e.type, who, at]
