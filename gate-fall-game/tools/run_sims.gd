## Headless balance runner.
##
##   godot --headless --path gate-fall-game --script res://tools/run_sims.gd
##   godot --headless --path gate-fall-game --script res://tools/run_sims.gd -- --runs=300 --side=S
##
## Options (after "--"):
##   --runs=N        battles per combo (default 300)
##   --seed=N        rng seed, restarted for every combo like prototype simulate() (default from config)
##   --side=ID       side the player commands (default: first side in the config)
##   --config=PATH   config file (default res://data/battle_config.json)
##   --per-battle    also print every battle's result (for comparing with prototype/run_sims.js)
##
## Each combo = formation x order x special (auto-cast on/off) for the commanded side.
## The other side keeps the formation and order from the config.
extends SceneTree

const BattleSim = preload("res://scripts/battle/BattleSim.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")

const PLAYER_ORDERS := ["charge", "hold"]


func _init() -> void:
	var opts := _parse_args(OS.get_cmdline_user_args())
	var cfg := BattleSim.load_config(opts.get("config", "res://data/battle_config.json"))
	if cfg.is_empty():
		quit(1)
		return
	var runs := int(opts.get("runs", 300))
	var seed_value := int(opts.get("seed", cfg.sim.seed))
	var side_id: String = opts.get("side", cfg.sides[0].id)
	var per_battle := opts.has("per-battle")
	var dt := 1.0 / float(cfg.sim.steps_per_second)
	var enemy_id := ""
	for sd in cfg.sides:
		if sd.id != side_id:
			enemy_id = sd.id

	print("Gatefall battle sims: %d runs/combo, seed %d, player side %s vs %s" % [runs, seed_value, side_id, enemy_id])
	print("%-9s %-7s %-8s %7s %7s %10s %10s" % ["formation", "order", "special", "win%", "time", "surv(win)", "enemy(loss)"])
	var started := Time.get_ticks_msec()
	for form in cfg.formations.keys():
		for order in PLAYER_ORDERS:
			for auto in [false, true]:
				var r := _run_combo(cfg, side_id, enemy_id, form, order, auto, runs, seed_value, dt, per_battle)
				print("%-9s %-7s %-8s %6.1f%% %6.1fs %10.2f %10.2f" % [form, order, "on" if auto else "off",
						r.win * 100.0, r.time, r.surv_win, r.surv_enemy])
	print("done in %.1fs" % ((Time.get_ticks_msec() - started) / 1000.0))
	quit()


func _run_combo(cfg: Dictionary, side_id: String, enemy_id: String, form: String, order: String,
		auto: bool, runs: int, seed_value: int, dt: float, per_battle: bool) -> Dictionary:
	var rng := BattleRng.new(seed_value)
	var overrides := {side_id: {"formation": form, "order": order, "auto_cast": auto}}
	var wins := 0
	var total_time := 0.0
	var surv := 0
	var enemy_left := 0
	for i in runs:
		var sim := BattleSim.new(cfg, overrides, rng)
		sim.record_events = false
		while sim.over == "":
			sim.step(dt)
		var c := sim.count()
		if sim.over == side_id:
			wins += 1
			surv += c[side_id]
		else:
			enemy_left += c[enemy_id]
		total_time += sim.time
		if per_battle:
			print("B %s %s %d %d %s %d %d %.6f" % [form, order, int(auto), i, sim.over, c[side_id], c[enemy_id], sim.time])
	return {
		"win": float(wins) / runs,
		"time": total_time / runs,
		"surv_win": float(surv) / wins if wins > 0 else 0.0,
		"surv_enemy": float(enemy_left) / (runs - wins) if runs > wins else 0.0,
	}


func _parse_args(args: PackedStringArray) -> Dictionary:
	var out := {}
	for a in args:
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else true
	return out
